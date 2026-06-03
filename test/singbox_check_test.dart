import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Real-core validation (test-plan #6): the generated configs must pass the
/// ACTUAL `sing-box check`, not just our in-process corpus — so a schema drift
/// on a core bump is caught. Skipped when the bundled binary isn't present
/// (fresh checkout before fetch-cores), so CI without it stays green.
void main() {
  final cwd = Directory.current.path;
  final sb = File('$cwd${Platform.pathSeparator}core'
      '${Platform.pathSeparator}windows${Platform.pathSeparator}sing-box.exe');
  final rs = Directory('$cwd${Platform.pathSeparator}core'
      '${Platform.pathSeparator}rule-sets');
  final hasCore = sb.existsSync();

  const env = {
    'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
    'ENABLE_DEPRECATED_GEOSITE': 'true',
    'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS': 'true',
    'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEMS': 'true',
    'ENABLE_DEPRECATED_DNS_RULE_ACTIONS': 'true',
    'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
  };

  setUpAll(() {
    if (rs.existsSync()) SingBoxConfig.ruleSetDir = rs.path;
  });

  // Returns null on success, else the first FATAL/ERROR line from the core.
  Future<String?> check(Map<String, dynamic> cfg, String name) async {
    final dir = Directory.systemTemp.createTempSync('sbcheck');
    try {
      final f = File('${dir.path}${Platform.pathSeparator}$name.json')
        ..writeAsStringSync(SingBoxConfig.encode(cfg));
      final r =
          await Process.run(sb.path, ['check', '-c', f.path], environment: env);
      if (r.exitCode == 0) return null;
      final out = '${r.stdout}${r.stderr}';
      return out.trim().isEmpty ? 'exit ${r.exitCode}' : out.trim();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  test('desyncOnly() passes real `sing-box check`', () async {
    expect(await check(SingBoxConfig.desyncOnly(), 'desync'), isNull);
  }, skip: hasCore ? false : 'sing-box.exe not bundled');

  test('m0Local() passes real `sing-box check`', () async {
    expect(await check(SingBoxConfig.m0Local(), 'm0'), isNull);
  }, skip: hasCore ? false : 'sing-box.exe not bundled');

  // #9: the TUN now captures IPv6 too (ULA address) so v6 can't leak direct —
  // verify the dual-family address list is accepted by the real core.
  test('withTun (IPv4+IPv6 capture) passes real `sing-box check`', () async {
    final cfg = SingBoxConfig.withTun(SingBoxConfig.desyncOnly());
    final tun = (cfg['inbounds'] as List)
        .cast<Map>()
        .firstWhere((i) => i['type'] == 'tun');
    expect((tun['address'] as List).any((a) => '$a'.contains(':')), isTrue);
    expect(await check(cfg, 'tun_v6'), isNull);
  }, skip: hasCore ? false : 'sing-box.exe not bundled');

  // #24: Brutal up_mbps/down_mbps are real hysteria2 fields — verify a tuned
  // outbound validates against the core (catches a field-name drift).
  test('hysteria2 with Brutal up/down passes real `sing-box check`', () async {
    final cfg = {
      'log': {'level': 'warn'},
      'outbounds': [
        {
          'type': 'hysteria2',
          'tag': 'hy2',
          'server': '1.2.3.4',
          'server_port': 443,
          'password': 'pw',
          'tls': {'enabled': true, 'insecure': true},
        },
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'hy2'},
    };
    final tuned = SingBoxConfig.tuneHysteria2(cfg, 50, 200);
    final hy2 = (tuned['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['type'] == 'hysteria2');
    expect(hy2['up_mbps'], 50);
    expect(hy2['down_mbps'], 200);
    expect(await check(tuned, 'hy2_brutal'), isNull);
  }, skip: hasCore ? false : 'sing-box.exe not bundled');

  // #19: a custom DoH resolver must still produce a config the core accepts.
  test('a custom DoH resolver passes real `sing-box check`', () async {
    SingBoxConfig.dnsServer = '1.1.1.1';
    final cfg = SingBoxConfig.desyncOnly();
    SingBoxConfig.dnsServer = '77.88.8.8'; // restore the default for other tests
    expect(await check(cfg, 'dns_custom'), isNull);
  }, skip: hasCore ? false : 'sing-box.exe not bundled');
}
