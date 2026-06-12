import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/proxy_node.dart';
import 'package:vpn_app/core/route_mode.dart';
import 'package:vpn_app/core/route_rule.dart';
import 'package:vpn_app/core/share_link.dart';
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
    'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM': 'true',
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

  // FakeIP TUN DNS (opt-in latency win): the generated config + TUN must stay
  // valid against the real core, and actually carry a fakeip server + A/AAAA rule.
  test('FakeIP (TUN) config passes real `sing-box check` — smart + global',
      () async {
    final node = ParsedNode(tag: 'n', outbound: {
      'type': 'trojan',
      'tag': 'n',
      'server': '1.2.3.4',
      'server_port': 443,
      'password': 'pw',
      'tls': {'enabled': true, 'server_name': 'a.com'},
    });
    for (final mode in [RouteMode.smart, RouteMode.global]) {
      final cfg = SingBoxConfig.withTun(
          SingBoxConfig.fromNode(node, mode: mode, fakeip: true));
      final servers = ((cfg['dns'] as Map)['servers'] as List).cast<Map>();
      expect(servers.any((s) => s['type'] == 'fakeip'), isTrue,
          reason: 'fakeip server must be present in $mode');
      expect(await check(cfg, 'fakeip_${mode.name}'), isNull);
    }
  }, skip: hasCore ? false : 'sing-box.exe not bundled');

  test('FakeIP off (default) → NO fakeip server (back-compat)', () {
    final node = ParsedNode(tag: 'n', outbound: {
      'type': 'trojan',
      'tag': 'n',
      'server': '1.2.3.4',
      'server_port': 443,
      'password': 'pw',
      'tls': {'enabled': true, 'server_name': 'a.com'},
    });
    final cfg = SingBoxConfig.fromNode(node); // fakeip defaults false
    final servers = ((cfg['dns'] as Map)['servers'] as List).cast<Map>();
    expect(servers.any((s) => s['type'] == 'fakeip'), isFalse);
  });

  // Competitor parity: user routing rules (domain/ip → proxy/direct/block).
  group('applyCustomRules', () {
    Map<String, dynamic> base() => {
          'log': {'level': 'warn'},
          'dns': {
            'servers': [
              {'type': 'https', 'tag': 'd', 'server': '77.88.8.8'},
            ],
            'final': 'd',
            'strategy': 'ipv4_only',
          },
          'outbounds': [
            {
              'type': 'trojan',
              'tag': 'proxy',
              'server': '1.2.3.4',
              'server_port': 443,
              'password': 'pw',
              'tls': {'enabled': true, 'server_name': 'x.com', 'insecure': true},
            },
            {'type': 'direct', 'tag': 'direct'},
          ],
          'route': {
            'default_domain_resolver': {'server': 'd'},
            'rules': [
              {'action': 'sniff'},
              {'protocol': 'dns', 'action': 'hijack-dns'},
              {'ip_is_private': true, 'outbound': 'direct'},
            ],
            'final': 'proxy',
          },
        };

    test('emits valid rules the REAL core accepts, ordered after hijack-dns and '
        'before the geo/smart rules', () async {
      final cfg = SingBoxConfig.applyCustomRules(base(), const [
        RouteRule(
            field: RuleField.domainSuffix,
            value: 'openai.com',
            action: RuleAction.proxy),
        RouteRule(
            field: RuleField.domain,
            value: 'example.ru',
            action: RuleAction.direct),
        RouteRule(
            field: RuleField.ipCidr,
            value: '10.20.30.0/24',
            action: RuleAction.block),
      ]);
      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();
      final hijackAt = rules.indexWhere((r) => r['action'] == 'hijack-dns');
      final proxyAt = rules.indexWhere(
          (r) => (r['domain_suffix'] as List?)?.contains('openai.com') ?? false);
      final privateAt = rules.indexWhere((r) => r['ip_is_private'] == true);
      expect(proxyAt, greaterThan(hijackAt)); // DNS still resolves
      expect(proxyAt, lessThan(privateAt)); // user rule wins over geo/smart
      expect(rules[proxyAt]['outbound'], 'proxy');
      expect(
          rules.firstWhere((r) =>
              (r['domain'] as List?)?.contains('example.ru') ?? false)['outbound'],
          'direct');
      expect(
          rules.firstWhere((r) =>
              (r['ip_cidr'] as List?)?.contains('10.20.30.0/24') ??
              false)['action'],
          'reject');
      expect(await check(cfg, 'customrules'), isNull);
    }, skip: hasCore ? false : 'sing-box.exe not bundled');

    test('a "proxy" rule is dropped in no-server mode (nothing to proxy through)',
        () {
      final noServer = {
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'rules': [
            {'action': 'sniff'},
            {'protocol': 'dns', 'action': 'hijack-dns'},
          ],
          'final': 'direct',
        },
      };
      final cfg = SingBoxConfig.applyCustomRules(noServer, const [
        RouteRule(
            field: RuleField.domainSuffix,
            value: 'openai.com',
            action: RuleAction.proxy),
        RouteRule(
            field: RuleField.domainSuffix,
            value: 'ads.example.com',
            action: RuleAction.block),
      ]);
      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();
      expect(
          rules.any((r) =>
              (r['domain_suffix'] as List?)?.contains('openai.com') ?? false),
          isFalse); // proxy rule dropped
      expect(
          rules.any((r) =>
              (r['domain_suffix'] as List?)?.contains('ads.example.com') ??
              false),
          isTrue); // block rule kept
    });

    test('garbage / injection values are sanitised away, never emitted', () {
      final cfg = SingBoxConfig.applyCustomRules(base(), const [
        RouteRule(
            field: RuleField.domainSuffix,
            value: 'bad value.com\n"inject',
            action: RuleAction.direct),
        RouteRule(
            field: RuleField.ipCidr,
            value: 'not-an-ip',
            action: RuleAction.block),
      ]);
      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map>();
      expect(rules.any((r) => r.containsKey('domain_suffix')), isFalse);
      expect(
          rules.any((r) =>
              (r['ip_cidr'] as List?)?.contains('not-an-ip') ?? false),
          isFalse);
    });
  });

  // #4 advanced transport knobs — verify the REAL core accepts every key we emit
  // (ech / mux protocol+padding+streams / tcp_fast_open / tcp_multi_path / ecs
  // client_subnet / system TUN stack). Resets the statics in a finally so the rest
  // of the suite sees defaults (mirrors the custom-DoH test's restore).
  test('advanced knobs (ech/mux/tfo/mptcp/ecs/system-stack) pass real check',
      () async {
    SingBoxConfig.muxProtocol = 'smux';
    SingBoxConfig.muxStreams = 4;
    SingBoxConfig.muxPadding = true;
    SingBoxConfig.tcpFastOpen = true;
    SingBoxConfig.mptcp = true;
    SingBoxConfig.ecsSubnet = '1.2.3.0/24';
    SingBoxConfig.tunStack = 'system';
    try {
      final node = ParsedNode(tag: 'n', outbound: {
        'type': 'trojan',
        'tag': 'n',
        'server': '1.2.3.4',
        'server_port': 443,
        'password': 'pw',
        'tls': {'enabled': true, 'server_name': 'a.com'},
      });
      var cfg = SingBoxConfig.fromNode(node, mux: true, ech: true);
      cfg = SingBoxConfig.applyEcs(cfg);
      cfg = SingBoxConfig.withTun(cfg);
      final ob = (cfg['outbounds'] as List)
          .cast<Map>()
          .firstWhere((o) => o['type'] == 'trojan');
      final mx = ob['multiplex'] as Map;
      expect(mx['protocol'], 'smux');
      expect(mx['max_streams'], 4);
      expect(mx['padding'], true);
      expect(ob['tcp_fast_open'], true);
      expect(ob['tcp_multi_path'], true);
      expect((ob['tls'] as Map)['ech'], isNotNull);
      expect((cfg['dns'] as Map)['client_subnet'], '1.2.3.0/24');
      final tun = (cfg['inbounds'] as List)
          .cast<Map>()
          .firstWhere((i) => i['type'] == 'tun');
      expect(tun['stack'], 'system');
      expect(await check(cfg, 'adv_knobs'), isNull);
    } finally {
      SingBoxConfig.muxProtocol = 'h2mux';
      SingBoxConfig.muxStreams = 8;
      SingBoxConfig.muxPadding = false;
      SingBoxConfig.tcpFastOpen = false;
      SingBoxConfig.mptcp = false;
      SingBoxConfig.ecsSubnet = '';
      SingBoxConfig.tunStack = 'gvisor';
    }
  }, skip: hasCore ? false : 'sing-box.exe not bundled');

  // #4 Hysteria2 port-hopping: a link carrying `mport` must parse into the
  // sing-box `server_ports` array (ranges colon-joined) + `hop_interval`, drop
  // the single `server_port`, and still pass the real core.
  test('hysteria2 mport link → server_ports + hop_interval, real check',
      () async {
    final node = ShareLink.parse(
        'hysteria2://pw@1.2.3.4:443?sni=a.com&insecure=1&mport=20000-21000,8443');
    expect(node, isNotNull);
    final ob = node!.outbound;
    expect(ob['server_ports'], ['20000:21000', '8443:8443']);
    expect(ob['hop_interval'], '30s');
    expect(ob.containsKey('server_port'), isFalse);
    expect(await check(SingBoxConfig.fromNode(node), 'hy2_hop'), isNull);
  }, skip: hasCore ? false : 'sing-box.exe not bundled');

  // ── RF-condition coverage: the OPERATOR / hard-network path the app produces ──
  // "Constantly check the diff under RF conditions": the hard-network escalation
  // forces TLS fragmentation ON and steers to the survivor transports. The
  // sing-box-NATIVE survivors (Reality TCP-TLS + Hysteria2 QUIC) must produce a
  // config the REAL core accepts in BOTH proxy AND TUN — a FATAL here = a server
  // that's fine on Wi-Fi but dead on a mobile operator the instant hard-network
  // kicks in. (XHTTP is xray-bridged — the core replaces it at runtime, so its
  // pre-bridge form is intentionally NOT a `sing-box check` target.)
  group('RF operator / hard-network configs pass real check', () {
    const reality =
        'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?'
        'security=reality&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&'
        'sid=0123abcd&sni=www.microsoft.com&fp=chrome&flow=xtls-rprx-vision&type=tcp#R';
    const hy2 = 'hysteria2://pw@1.2.3.4:443?sni=a.com#H';
    for (final e in {'reality': reality, 'hy2': hy2}.entries) {
      test('${e.key}: antiDpi forced (hard-network) — proxy + TUN', () async {
        final node = ShareLink.parse(e.value);
        expect(node, isNotNull, reason: 'survivor link must parse: ${e.key}');
        // hard-network ≡ antiDpi:true (force fragmentation); both VPN modes.
        expect(await check(SingBoxConfig.fromNode(node!, antiDpi: true),
            'rf_${e.key}_proxy'), isNull);
        expect(
            await check(
                SingBoxConfig.withTun(
                    SingBoxConfig.fromNode(node, antiDpi: true)),
                'rf_${e.key}_tun'),
            isNull);
      }, skip: hasCore ? false : 'sing-box.exe not bundled');
    }
  });

  // #4 audit fix: an invalid ECS subnet must NOT reach the config — a typo'd
  // subnet would FATAL the core and bounce the live tunnel. applyEcs drops it.
  test('applyEcs drops an invalid subnet (no client_subnet emitted)', () {
    SingBoxConfig.ecsSubnet = '300.1.1.0/24';
    try {
      final cfg = SingBoxConfig.applyEcs({'dns': <String, dynamic>{}});
      expect((cfg['dns'] as Map).containsKey('client_subnet'), isFalse);
      SingBoxConfig.ecsSubnet = '1.2.3.0/24';
      final ok = SingBoxConfig.applyEcs({'dns': <String, dynamic>{}});
      expect((ok['dns'] as Map)['client_subnet'], '1.2.3.0/24');
    } finally {
      SingBoxConfig.ecsSubnet = '';
    }
  });
}
