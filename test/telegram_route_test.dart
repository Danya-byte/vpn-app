import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Native Telegram unblock (под капотом): RF IP-blocks Telegram and blocks its
/// UDP calls, so every built config must PIN Telegram (DC/relay CIDRs + domains,
/// TCP and UDP) to the proxy exit — above the RU-direct/private rules — so
/// messaging and calls ride the foreign tunnel. These lock the routing shape
/// without a live network.
void main() {
  Map<String, dynamic> imported(String finalTag, [List<dynamic>? rules]) => {
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'px',
            'server': '1.2.3.4',
            'server_port': 443,
            'uuid': '11111111-1111-1111-1111-111111111111',
            'tls': {'enabled': true, 'server_name': 'vk.com'},
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {'final': finalTag, if (rules != null) 'rules': rules},
      };

  List<Map> _rules(Map<String, dynamic> cfg) =>
      (cfg['route'] as Map)['rules'] == null
          ? const []
          : ((cfg['route'] as Map)['rules'] as List).cast<Map>();

  String _join(dynamic v) => v is List ? v.join(',') : '${v ?? ''}';

  setUp(() => SingBoxConfig.telegramUnblock = true);
  tearDown(() => SingBoxConfig.telegramUnblock = true);

  test('pins Telegram DC CIDRs + domains to the proxy (TCP+UDP, no network filter)',
      () {
    final cfg = SingBoxConfig.fromConfig(imported('px'));
    final rules = _rules(cfg);
    final cidrRule = rules.firstWhere(
        (r) => _join(r['ip_cidr']).contains('149.154.160.0/20'),
        orElse: () => {});
    final domRule = rules.firstWhere(
        (r) => _join(r['domain_suffix']).contains('t.me'),
        orElse: () => {});
    expect(cidrRule['outbound'], 'px', reason: 'TG IPs → the proxy exit');
    expect(domRule['outbound'], 'px', reason: 'TG domains → the proxy exit');
    // No `network` key ⇒ matches BOTH tcp and udp ⇒ calls (UDP) ride the tunnel.
    expect(cidrRule.containsKey('network'), isFalse);
  });

  test('Telegram pin sits BEFORE the private/RU-direct rules (it wins)', () {
    final cfg = SingBoxConfig.fromConfig(imported('px'));
    final rules = _rules(cfg);
    final tgAt =
        rules.indexWhere((r) => _join(r['ip_cidr']).contains('149.154.16'));
    final privAt = rules.indexWhere((r) => r['ip_is_private'] == true);
    expect(tgAt, greaterThanOrEqualTo(0));
    if (privAt >= 0) {
      expect(tgAt, lessThan(privAt),
          reason: 'Telegram must be pinned before any private/direct rule');
    }
  });

  test('no proxy exit (final=direct) → no Telegram pin (can\'t help, physics)',
      () {
    final cfg = SingBoxConfig.fromConfig(imported('direct'));
    expect(
        _rules(cfg)
            .any((r) => _join(r['ip_cidr']).contains('149.154.16')),
        isFalse);
  });

  test('respects an author who already routes Telegram (no double-inject)', () {
    final cfg = SingBoxConfig.fromConfig(imported(
        'px', [
      {'domain_suffix': ['t.me'], 'outbound': 'direct'},
    ]));
    final pinned = _rules(cfg).where((r) =>
        r['outbound'] == 'px' && _join(r['ip_cidr']).contains('149.154.16'));
    expect(pinned, isEmpty, reason: 'author Telegram routing left intact');
  });

  test('telegramUnblock=false → no pin', () {
    SingBoxConfig.telegramUnblock = false;
    final cfg = SingBoxConfig.fromConfig(imported('px'));
    expect(
        _rules(cfg)
            .any((r) => _join(r['ip_cidr']).contains('149.154.16')),
        isFalse);
  });
}
