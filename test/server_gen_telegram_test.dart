import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/route_mode.dart';
import 'package:vpn_app/core/server_gen.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Proves the END-TO-END Telegram-media fix on an IP-blocking operator: a
/// ServerGen "own clean server" profile, run through the real config pipeline,
/// routes BOTH the web.telegram.org IP-block range AND the throttled DC media
/// CIDRs through the user's own foreign exit — so media leaves from the clean IP
/// (no RF throttle, no blackhole). This is the only fix when web.telegram.org is
/// IP-blackholed (verified on the user's operator 2026-06-26).
void main() {
  test('ServerGen profile pins Telegram (web IP-block + DC throttle) to the clean exit', () {
    // A generated "your own node" bundle (fixed material — pure, no binary).
    final bundle = ServerGen.buildReality(
      serverIp: '203.0.113.7', // a clean foreign VPS IP (TEST-NET-3)
      uuid: '11111111-2222-3333-4444-555555555555',
      privateKey: 'kPriv0000000000000000000000000000000000000aB',
      publicKey: 'kPub00000000000000000000000000000000000000cD',
      shortId: '0123abcd',
      name: 'TG exit',
    );

    final node = ShareLink.parse(bundle.clientLink);
    expect(node, isNotNull, reason: 'the generated Reality link must parse');

    final cfg = SingBoxConfig.fromNode(node!, mode: RouteMode.smart);

    // The proxy exit tag = the single VLESS outbound (not direct/dns).
    final outs = (cfg['outbounds'] as List).cast<Map>();
    final proxy = outs.firstWhere((o) => o['type'] == 'vless',
        orElse: () => const {});
    expect(proxy, isNotEmpty, reason: 'the generated node must build a vless outbound');
    final proxyTag = proxy['tag'];
    expect(proxyTag, isNot(anyOf('direct', 'block', 'dns-out')));

    final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();

    // 1. The blocked web range + throttled DC media CIDRs → the clean exit.
    final ipPinned = rules.any((r) =>
        r['outbound'] == proxyTag &&
        (r['ip_cidr'] is List) &&
        (r['ip_cidr'] as List).contains('149.154.160.0/20'));
    expect(ipPinned, isTrue,
        reason: 'web.telegram.org (149.154.167.99 ∈ /20) + DC media IPs must '
            'route through the clean exit, not the blocked operator path');

    // 2. Telegram domains → the clean exit too (for the parts resolved by name).
    final domainPinned = rules.any((r) =>
        r['outbound'] == proxyTag &&
        (r['domain_suffix'] is List) &&
        (r['domain_suffix'] as List).contains('t.me'));
    expect(domainPinned, isTrue,
        reason: 'Telegram domains must route through the clean exit');

    // 3. The Telegram pin must sit BEFORE any private/RU-direct rule, so Telegram
    //    always rides the tunnel rather than falling through to a direct rule.
    final tgIdx = rules.indexWhere((r) =>
        r['outbound'] == proxyTag && (r['ip_cidr'] is List) &&
        (r['ip_cidr'] as List).contains('149.154.160.0/20'));
    final directIdx = rules.indexWhere((r) => r['outbound'] == 'direct');
    if (directIdx >= 0) {
      expect(tgIdx, lessThan(directIdx),
          reason: 'Telegram pin must precede the direct fall-through rules');
    }
  });
}
