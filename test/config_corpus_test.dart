import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Universality guard (roadmap #22): fromConfig must PRESERVE every outbound
/// protocol the bundled core can run — never silently drop one. Empirically
/// each of these also passes a real `sing-box check` (see tool corpus run); this
/// fast test locks the "no type filtering" guarantee so a future edit can't
/// regress it.
void main() {
  test('fromConfig preserves every supported outbound type', () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'a', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'hysteria2', 'tag': 'b', 'server': 's', 'server_port': 443, 'password': 'p'},
        {'type': 'tuic', 'tag': 'c', 'server': 's', 'server_port': 443, 'uuid': 'u', 'password': 'p'},
        {'type': 'shadowtls', 'tag': 'd', 'server': 's', 'server_port': 443, 'version': 3, 'password': 'p'},
        {'type': 'anytls', 'tag': 'e', 'server': 's', 'server_port': 443, 'password': 'p'},
        {'type': 'ssh', 'tag': 'f', 'server': 's', 'server_port': 22, 'user': 'r'},
        {'type': 'tor', 'tag': 'g'},
        {'type': 'shadowsocks', 'tag': 'h', 'server': 's', 'server_port': 443, 'method': 'aes-128-gcm', 'password': 'p'},
        {'type': 'trojan', 'tag': 'i', 'server': 's', 'server_port': 443, 'password': 'p'},
        {'type': 'vmess', 'tag': 'j', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'http', 'tag': 'k', 'server': 's', 'server_port': 8080},
        {'type': 'socks', 'tag': 'l', 'server': 's', 'server_port': 1080},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'a'},
    };
    final cfg = SingBoxConfig.fromConfig(raw);
    final tags = (cfg['outbounds'] as List).map((o) => (o as Map)['tag']).toSet();
    for (final t in const ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l']) {
      expect(tags.contains(t), isTrue, reason: 'outbound "$t" was dropped');
    }
  });

  test('fromConfig drops ONLY the xray-only transports it cannot run', () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'keep', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'vless', 'tag': 'grpc', 'server': 's', 'server_port': 443, 'uuid': 'u', 'transport': {'type': 'grpc', 'service_name': 'x'}},
        {'type': 'vless', 'tag': 'ws', 'server': 's', 'server_port': 443, 'uuid': 'u', 'transport': {'type': 'ws', 'path': '/x'}},
        {'type': 'vless', 'tag': 'mkcp', 'server': 's', 'server_port': 443, 'uuid': 'u', 'transport': {'type': 'mkcp'}},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'keep'},
    };
    final cfg = SingBoxConfig.fromConfig(raw);
    final tags = (cfg['outbounds'] as List).map((o) => (o as Map)['tag']).toSet();
    expect(tags.contains('keep'), isTrue);
    expect(tags.contains('grpc'), isTrue, reason: 'gRPC is core-supported');
    expect(tags.contains('ws'), isTrue, reason: 'WebSocket is core-supported');
    expect(tags.contains('mkcp'), isFalse, reason: 'mKCP is xray-only → dropped');
  });

  test('fromConfig keeps logical rules + newer matchers (denylist, not whitelist)',
      () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'type': 'logical', 'mode': 'and', 'rules': [
            {'domain_suffix': ['x.com']}, {'port': 443}
          ], 'outbound': 'direct'},
          {'source_port': [12345], 'outbound': 'direct'},
          {'process_path': [r'C:\game.exe'], 'outbound': 'direct'},
        ],
        'final': 'p',
      },
    };
    final rules = ((SingBoxConfig.fromConfig(raw)['route'] as Map)['rules']) as List;
    expect(rules.any((r) => r is Map && r['type'] == 'logical'), isTrue,
        reason: 'logical rule was dropped');
    expect(rules.any((r) => r is Map && r['source_port'] != null), isTrue);
    expect(rules.any((r) => r is Map && r['process_path'] != null), isTrue);
  });

  test('fromConfig migrates geoip INSIDE a logical rule + drops the empty sub',
      () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'type': 'logical', 'mode': 'or', 'rules': [
            {'geosite': ['cn']}, {'geoip': ['private']}
          ], 'outbound': 'direct'},
        ],
        'final': 'p',
      },
    };
    final rules = ((SingBoxConfig.fromConfig(raw)['route'] as Map)['rules']) as List;
    final logical = rules.firstWhere((r) => r is Map && r['type'] == 'logical') as Map;
    final sub = logical['rules'] as List;
    expect(sub.any((r) => r is Map && r['ip_is_private'] == true), isTrue);
    expect(sub.any((r) => r is Map && r['geosite'] != null), isFalse);
    expect(sub.any((r) => r is Map && r['geoip'] != null), isFalse);
  });

  test('fromConfig strips Linux-only `resolved` service, keeps cross-platform ones',
      () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'p'},
      'services': [
        {'type': 'resolved', 'tag': 'res', 'listen': '127.0.0.1', 'listen_port': 5353},
        {'type': 'derp', 'tag': 'd', 'listen': '127.0.0.1', 'listen_port': 3340},
      ],
    };
    final cfg = SingBoxConfig.fromConfig(raw);
    final types = (cfg['services'] as List?)?.map((s) => (s as Map)['type']).toList();
    expect(types, isNotNull, reason: 'cross-platform services must survive');
    expect(types!.contains('resolved'), isFalse,
        reason: 'resolved FATALs off-Linux → must be stripped');
    expect(types.contains('derp'), isTrue,
        reason: 'derp is cross-platform → faithful passthrough');
  });

  test('fromConfig drops `services` key entirely when only `resolved` was present',
      () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'p'},
      'services': [
        {'type': 'resolved', 'tag': 'res', 'listen': '127.0.0.1', 'listen_port': 5353},
      ],
    };
    final cfg = SingBoxConfig.fromConfig(raw);
    expect(cfg.containsKey('services'), isFalse,
        reason: 'empty services array would be tidier absent than []');
  });

  test('fromConfig drops an un-bundleable remote rule_set + cleans its references',
      () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'rule_set': ['custom-remote'], 'outbound': 'direct'},
          {'domain_suffix': ['x.com'], 'outbound': 'p'},
        ],
        'rule_set': [
          {'type': 'remote', 'tag': 'custom-remote', 'format': 'binary',
            'url': 'https://example.com/custom.srs', 'download_detour': 'direct'},
        ],
        'final': 'p',
      },
    };
    final route = SingBoxConfig.fromConfig(raw)['route'] as Map;
    final rsTags = (route['rule_set'] as List?)
            ?.map((r) => (r as Map)['tag'])
            .toSet() ??
        const {};
    expect(rsTags.contains('custom-remote'), isFalse,
        reason: 'un-bundleable remote rule_set deadlocks startup in RF → dropped');
    // The rule that referenced ONLY the dropped set must be gone (no dangling ref
    // = no FATAL); the unrelated domain_suffix rule must survive.
    final rules = route['rules'] as List;
    final refsDropped = rules.any((r) =>
        r is Map &&
        (r['rule_set'] is List
            ? (r['rule_set'] as List).contains('custom-remote')
            : r['rule_set'] == 'custom-remote'));
    expect(refsDropped, isFalse, reason: 'dangling rule_set ref FATALs the core');
    expect(rules.any((r) => r is Map && r['domain_suffix'] != null), isTrue);
  });

  test('fromConfig swaps imported inbounds for our loopback mixed; '
      'inbound-matcher rules survive harmlessly (no FATAL — verified via check)',
      () {
    final raw = {
      'inbounds': [
        {'type': 'tun', 'tag': 'tun-orig', 'address': ['172.19.0.1/30'],
          'auto_route': true, 'stack': 'system'},
        {'type': 'mixed', 'tag': 'mixed-orig', 'listen': '127.0.0.1', 'listen_port': 7890},
      ],
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'inbound': ['tun-orig'], 'outbound': 'p'},
          {'inbound': ['mixed-orig'], 'action': 'reject'},
        ],
        'final': 'p',
      },
    };
    final cfg = SingBoxConfig.fromConfig(raw);
    final inTags = (cfg['inbounds'] as List).map((i) => (i as Map)['tag']).toSet();
    // Loopback-only inbound (no admin needed; Happ-vuln protection). The user's
    // own listen ports / TUN params are intentionally NOT honored.
    expect(inTags, {'mixed-in'},
        reason: 'imported inbounds must be swapped for our loopback mixed');
    // inbound matchers are kept (they have a matcher) but reference tags that no
    // longer exist — sing-box treats this as never-fires, NOT a FATAL.
    final rules = (cfg['route'] as Map)['rules'] as List;
    expect(rules.where((r) => r is Map && r['inbound'] != null).length, 2);
  });

  test('fromConfig scrubs a dangling detour after the target node is dropped',
      () {
    // front detours through an xhttp relay; with keepXray=false the relay drops,
    // so front.detour would dangle → core FATALs at runtime (check passes!).
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'front', 'server': 's', 'server_port': 443,
          'uuid': 'u', 'detour': 'relay'},
        {'type': 'vless', 'tag': 'relay', 'server': 's', 'server_port': 443,
          'uuid': 'u', 'transport': {'type': 'xhttp', 'path': '/x'}},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'front'},
    };
    final outs = (SingBoxConfig.fromConfig(raw, keepXray: false)['outbounds']
        as List);
    final front = outs.cast<Map>().firstWhere((o) => o['tag'] == 'front');
    expect(front.containsKey('detour'), isFalse,
        reason: 'dangling detour FATALs at runtime — must be stripped');
  });

  test('fromConfig migrates legacy fakeip to a typed server + drops the block',
      () {
    final raw = {
      'dns': {
        'fakeip': {'enabled': true, 'inet4_range': '198.18.0.0/15',
          'inet6_range': 'fc00::/18'},
        'servers': [
          {'tag': 'fake', 'address': 'fakeip'},
          {'tag': 'r', 'address': 'https://1.1.1.1/dns-query'},
        ],
        'final': 'r',
      },
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'p'},
    };
    final dns = SingBoxConfig.fromConfig(raw)['dns'] as Map;
    expect(dns.containsKey('fakeip'), isFalse,
        reason: 'legacy top-level fakeip block FATALs without the rescue env');
    final fake = (dns['servers'] as List)
        .cast<Map>()
        .firstWhere((s) => s['tag'] == 'fake');
    expect(fake['type'], 'fakeip');
    expect(fake['inet4_range'], '198.18.0.0/15');
  });

  test('fromConfig drops a DNS rule scoped only to a legacy geosite (no match-all)',
      () {
    final raw = {
      'dns': {
        'servers': [
          {'type': 'https', 'tag': 'remote', 'server': '1.1.1.1'},
          {'type': 'https', 'tag': 'local', 'server': '77.88.8.8'},
        ],
        'rules': [{'geosite': ['google'], 'server': 'local'}],
        'final': 'remote',
      },
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'p'},
    };
    final rules = ((SingBoxConfig.fromConfig(raw)['dns'] as Map)['rules']) as List;
    // The geosite matcher is stripped (legacy); a leftover {server:'local'} would
    // be a MATCH-ALL that hijacks every query. It must be dropped instead.
    final matchAll = rules.any((r) =>
        r is Map &&
        r.keys.toSet().difference({'server', 'action', 'invert'}).isEmpty);
    expect(matchAll, isFalse, reason: 'DNS rule collapsed to match-all');
  });

  test('fromConfig drops an unknown/future outbound type, keeps the valid ones',
      () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'good', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'futureproto', 'tag': 'bad', 'server': 's', 'server_port': 443},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'good'},
    };
    final tags = (SingBoxConfig.fromConfig(raw)['outbounds'] as List)
        .cast<Map>()
        .map((o) => o['tag'])
        .toSet();
    expect(tags.contains('good'), isTrue,
        reason: 'one unknown node must not FATAL the valid ones');
    expect(tags.contains('bad'), isFalse);
  });

  test('fromConfig does NOT inject RU-direct over a config that routes RU geo',
      () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [{'rule_set': 'geosite-ru', 'outbound': 'p'}], // deliberate: RU via proxy
        'final': 'p',
      },
    };
    final rules =
        ((SingBoxConfig.fromConfig(raw, ruDirect: true)['route'] as Map)['rules'])
            as List;
    final injectedDirect = rules.any((r) =>
        r is Map &&
        r['outbound'] == 'direct' &&
        r['rule_set'] is List &&
        (r['rule_set'] as List).contains('geoip-ru'));
    expect(injectedDirect, isFalse,
        reason: 'must respect an author who already routes RU geo');
  });

  test('fromConfig never corrupts a Reality fingerprint with the fp override', () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'r', 'server': 's', 'server_port': 443, 'uuid': 'u',
          'flow': 'xtls-rprx-vision',
          'tls': {'enabled': true, 'server_name': 'x.com',
            'utls': {'enabled': true, 'fingerprint': 'chrome'},
            'reality': {'enabled': true, 'public_key': 'k', 'short_id': '00'}}},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'r'},
    };
    final out = (SingBoxConfig.fromConfig(raw, fingerprintOverride: 'firefox')[
            'outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['tag'] == 'r');
    final fp = ((out['tls'] as Map)['utls'] as Map)['fingerprint'];
    expect(fp, 'chrome',
        reason: 'Reality handshake fp must survive an fp override (memory rule)');
  });

  test('fromConfig replaces the imported log block with the app safe default', () {
    final raw = {
      'log': {'level': 'debug', 'output': r'C:\leak.log'},
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'p'},
    };
    final log = SingBoxConfig.fromConfig(raw)['log'] as Map;
    expect(log.containsKey('output'), isFalse,
        reason: 'an author log.output would persist every destination host');
    expect(log['level'], 'warn');
  });

  test('fromConfig forces ipv4_only but honors an explicit IPv6 strategy', () {
    Map<String, dynamic> withStrategy(String? s) => {
          'dns': {
            'servers': [{'type': 'https', 'tag': 'd', 'server': '1.1.1.1'}],
            'strategy': ?s,
            'final': 'd',
          },
          'outbounds': [
            {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
            {'type': 'direct', 'tag': 'direct'},
          ],
          'route': {'final': 'p'},
        };
    String stratOf(Map<String, dynamic> raw) =>
        (SingBoxConfig.fromConfig(raw)['dns'] as Map)['strategy'] as String;
    expect(stratOf(withStrategy(null)), 'ipv4_only', reason: 'RF default');
    expect(stratOf(withStrategy('prefer_ipv4')), 'ipv4_only',
        reason: 'v4-first normalizes to ipv4_only for RF');
    expect(stratOf(withStrategy('prefer_ipv6')), 'prefer_ipv6',
        reason: 'a deliberate IPv6 choice must survive');
    expect(stratOf(withStrategy('ipv6_only')), 'ipv6_only');
  });

  test('fromConfig preserves clash_mode rules (Global/Direct switching)', () {
    final raw = {
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 's', 'server_port': 443, 'uuid': 'u'},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'rules': [
          {'clash_mode': 'Direct', 'outbound': 'direct'},
          {'clash_mode': 'Global', 'outbound': 'p'},
        ],
        'final': 'p',
      },
    };
    final rules = ((SingBoxConfig.fromConfig(raw)['route'] as Map)['rules']) as List;
    expect(rules.where((r) => r is Map && r['clash_mode'] != null).length, 2,
        reason: 'clash_mode is a matcher → must survive the denylist');
  });
}
