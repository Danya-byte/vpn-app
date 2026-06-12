import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/route_mode.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/server_gen.dart';
import 'package:vpn_app/core/singbox_config.dart';
import 'package:vpn_app/core/xray_config.dart';

void main() {
  test('parses VLESS+Reality+Vision and builds a valid-shaped config', () {
    const link =
        'vless://b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b@example.com:443'
        '?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome'
        '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=0123abcd'
        '&flow=xtls-rprx-vision&type=tcp#Test%20Node';

    final node = ShareLink.parse(link);
    expect(node, isNotNull);
    expect(node!.tag, 'Test Node');
    expect(node.outbound['type'], 'vless');
    expect(node.outbound['flow'], 'xtls-rprx-vision');

    final tls = node.outbound['tls'] as Map<String, dynamic>;
    expect(tls['server_name'], 'www.microsoft.com');
    expect((tls['reality'] as Map)['enabled'], true);
    expect((tls['utls'] as Map)['fingerprint'], 'chrome');

    // Write the generated config so an out-of-process `sing-box check` can
    // validate it against the real schema.
    final cfg = SingBoxConfig.fromNode(node);
    expect(cfg['route']['final'], node.tag);
    Directory('build').createSync(recursive: true);
    File('build/gen_sample.json')
        .writeAsStringSync(SingBoxConfig.encode(cfg));
  });

  test('builds a valid-shaped Smart-mode config', () {
    final node = ShareLink.parse(
      'vless://b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b@example.com:443'
      '?security=reality&sni=www.microsoft.com&fp=chrome'
      '&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=0123abcd'
      '&flow=xtls-rprx-vision&type=tcp#Smart Node',
    );
    final cfg = SingBoxConfig.fromNode(node!, mode: RouteMode.smart);
    expect(cfg['dns'], isNotNull);
    expect((cfg['route'] as Map)['default_domain_resolver'], isNotNull);
    expect((cfg['route'] as Map)['final'], 'Smart Node');
    Directory('build').createSync(recursive: true);
    File('build/gen_smart.json')
        .writeAsStringSync(SingBoxConfig.encode(cfg));
  });

  test('parses a base64 subscription with multiple links', () {
    const links =
        'vless://b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b@a.com:443?security=reality&pbk=k&sid=1#A\n'
        'hysteria2://pass@b.com:8443?sni=b.com&obfs=salamander&obfs-password=x#B\n'
        'trojan://secret@c.com:443?sni=c.com#C';
    final nodes = ShareLink.parseSubscription(links);
    expect(nodes.length, 3);
    expect(nodes.map((n) => n.type).toList(),
        ['vless', 'hysteria2', 'trojan']);
  });

  test('anti-DPI fragments a plain TLS node (not Reality)', () {
    final node = ShareLink.parse(
      'vless://b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b@example.com:443'
      '?security=tls&sni=example.com&fp=chrome#Frag',
    );
    expect(node, isNotNull);
    final cfg =
        SingBoxConfig.fromNode(node!, mode: RouteMode.global, antiDpi: true);
    final ob = (cfg['outbounds'] as List).first as Map<String, dynamic>;
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls['fragment'], true);
    expect(tls['fragment_fallback_delay'], '500ms');
    Directory('build').createSync(recursive: true);
    File('build/gen_frag.json').writeAsStringSync(SingBoxConfig.encode(cfg));
  });

  test('anti-DPI leaves Reality untouched', () {
    final node = ShareLink.parse(
      'vless://b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b@example.com:443'
      '?security=reality&sni=www.microsoft.com&pbk=k&sid=1#R',
    );
    final cfg =
        SingBoxConfig.fromNode(node!, mode: RouteMode.global, antiDpi: true);
    final ob = (cfg['outbounds'] as List).first as Map<String, dynamic>;
    final tls = ob['tls'] as Map<String, dynamic>;
    expect(tls.containsKey('fragment'), false);
  });

  test('imports a Clash YAML subscription', () {
    const yaml = '''
proxies:
  - name: "SS-Node"
    type: ss
    server: a.com
    port: 8388
    cipher: aes-256-gcm
    password: pass
  - name: "VLESS-Reality"
    type: vless
    server: b.com
    port: 443
    uuid: b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b
    tls: true
    servername: www.microsoft.com
    reality-opts:
      public-key: jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0
      short-id: "0123abcd"
    client-fingerprint: chrome
  - name: "Trojan-Node"
    type: trojan
    server: c.com
    port: 443
    password: secret
    sni: c.com
''';
    final nodes = ShareLink.parseSubscription(yaml);
    expect(nodes.length, 3);
    expect(nodes.map((n) => n.type).toList(),
        ['shadowsocks', 'vless', 'trojan']);
    final vless = nodes[1].outbound;
    expect(((vless['tls'] as Map)['reality'] as Map)['public_key'],
        'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0');
    final cfg = SingBoxConfig.fromNodes(nodes, mode: RouteMode.smart);
    Directory('build').createSync(recursive: true);
    File('build/gen_clash.json').writeAsStringSync(SingBoxConfig.encode(cfg));
  });

  test('auto-failover builds a urltest group over all nodes', () {
    final nodes = ShareLink.parseSubscription(
      'vless://b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b@a.com:443?security=reality&sni=www.microsoft.com&pbk=k&sid=1#A\n'
      'trojan://secret@c.com:443?sni=c.com#C',
    );
    final cfg = SingBoxConfig.fromNodes(nodes, mode: RouteMode.global);
    final obs = (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
    final auto = obs.firstWhere((o) => o['type'] == 'urltest');
    expect(auto['tag'], SingBoxConfig.autoTag);
    expect((auto['outbounds'] as List).length, 2);
    // The route final is now a Selector (Auto + each node) so the user can pin a
    // specific server in Policies — a bare URLTest can't be hand-selected.
    final sel = obs.firstWhere((o) => o['type'] == 'selector');
    expect(sel['tag'], SingBoxConfig.selectorTag);
    expect((sel['outbounds'] as List).length, 3); // Auto + 2 nodes
    expect((cfg['route'] as Map)['final'], SingBoxConfig.selectorTag);
    Directory('build').createSync(recursive: true);
    File('build/gen_auto.json').writeAsStringSync(SingBoxConfig.encode(cfg));
  });

  test('fromConfig keeps XHTTP outbounds only when the xray bridge is on', () {
    final raw = {
      'route': {'final': 'X'},
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'X',
          'server': 'a.com',
          'server_port': 443,
          'uuid': 'u',
          'transport': {'type': 'xhttp', 'path': '/p'},
        },
        {'type': 'direct', 'tag': 'direct'},
      ],
    };
    final dropped = SingBoxConfig.fromConfig(raw);
    expect((dropped['outbounds'] as List).any((o) => o['type'] == 'vless'),
        false);
    final kept = SingBoxConfig.fromConfig(raw, keepXray: true);
    final vless = (kept['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['type'] == 'vless');
    expect(XrayConfig.needsXray(vless), true);
  });

  test('xray bridge converts a VLESS+XHTTP+Reality outbound', () {
    final ob = {
      'type': 'vless',
      'tag': 'XH',
      'server': 'b.com',
      'server_port': 443,
      'uuid': 'b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b',
      'tls': {
        'enabled': true,
        'server_name': 'www.microsoft.com',
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
        'reality': {
          'enabled': true,
          'public_key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
          'short_id': '0123abcd',
        },
      },
      'transport': {'type': 'xhttp', 'path': '/x'},
    };
    expect(XrayConfig.needsXray(ob), true);
    final xr = XrayConfig.fromOutbound(ob, 2081)!;
    final inbound = (xr['inbounds'] as List).first as Map;
    expect(inbound['port'], 2081);
    expect(inbound['protocol'], 'socks');
    final out = (xr['outbounds'] as List).first as Map;
    expect(out['protocol'], 'vless');
    final stream = out['streamSettings'] as Map;
    expect(stream['network'], 'xhttp');
    expect(stream['security'], 'reality');
    expect((stream['realitySettings'] as Map)['publicKey'],
        'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0');
    expect((stream['xhttpSettings'] as Map)['path'], '/x');
  });

  test('xray bridge forces a randomized fingerprint to chrome', () {
    // 'randomized' is a synthetic ClientHello that can break Reality — the
    // bridge must never emit it (mirrors the sing-box-side normalize).
    final ob = {
      'type': 'vless',
      'tag': 'XH',
      'server': 'b.com',
      'server_port': 443,
      'uuid': 'u',
      'tls': {
        'enabled': true,
        'server_name': 'm.vk.com',
        'utls': {'enabled': true, 'fingerprint': 'randomized'},
        'reality': {'enabled': true, 'public_key': 'k', 'short_id': '1'},
      },
      'transport': {'type': 'xhttp', 'path': '/x'},
    };
    final xr = XrayConfig.fromOutbound(ob, 2082)!;
    final stream =
        ((xr['outbounds'] as List).first as Map)['streamSettings'] as Map;
    expect((stream['realitySettings'] as Map)['fingerprint'], 'chrome');
  });

  test('ServerGen builds a Reality + Hysteria2 multi-transport bundle', () {
    final b = ServerGen.buildReality(
      serverIp: '203.0.113.10',
      uuid: 'b3fe651c-41b2-4d42-8b98-6822ecb1514e',
      privateKey: 'iGi6_j_5dAqUgU5ZO9KOAazH-NoRI-70FATex3fkJEU',
      publicKey: 'EKMbPORrYF4u99Hqd-SXf8_zHh-Mlw3cuu2is5qJWhU',
      shortId: '7f0fed6e2b2ffc03',
      hy2Password: 'deadbeefcafebabe',
      obfsPassword: 'salamanderpass',
    );
    // Two transports on one box: VLESS+Reality (TCP) + Hysteria2 (QUIC).
    final inbounds = b.serverConfig['inbounds'] as List;
    expect(inbounds.length, 2);
    expect((inbounds[0] as Map)['type'], 'vless');
    expect((inbounds[1] as Map)['type'], 'hysteria2');
    expect(b.clientLinks.length, 2);
    final reality = ShareLink.parse(b.clientLinks[0])!;
    final hy2 = ShareLink.parse(b.clientLinks[1])!;
    expect(reality.outbound['type'], 'vless');
    expect(((reality.outbound['tls'] as Map)['reality'] as Map)['public_key'],
        'EKMbPORrYF4u99Hqd-SXf8_zHh-Mlw3cuu2is5qJWhU');
    expect(hy2.outbound['type'], 'hysteria2');
    expect(hy2.outbound['password'], 'deadbeefcafebabe');
    Directory('build').createSync(recursive: true);
    File('build/gen_server.json').writeAsStringSync(b.serverConfigJson);
  });

  test('ServerGen builds a domestic-relay chain (client dials exit via relay)',
      () {
    final b = ServerGen.buildRelayChain(
      relayIp: '45.10.20.30', // pretend RU-cloud IP
      relayUuid: 'b3fe651c-41b2-4d42-8b98-6822ecb1514e',
      relayPriv: 'iGi6_j_5dAqUgU5ZO9KOAazH-NoRI-70FATex3fkJEU',
      relayPub: 'EKMbPORrYF4u99Hqd-SXf8_zHh-Mlw3cuu2is5qJWhU',
      relayShortId: '7f0fed6e2b2ffc03',
      exitIp: '203.0.113.10',
      exitUuid: 'a1b2c3d4-0000-1111-2222-333344445555',
      exitPriv: 'iGi6_j_5dAqUgU5ZO9KOAazH-NoRI-70FATex3fkJEV',
      exitPub: 'EKMbPORrYF4u99Hqd-SXf8_zHh-Mlw3cuu2is5qJWhV',
      exitShortId: '0011223344556677',
    );
    final outs = (b.clientConfig['outbounds'] as List).cast<Map>();
    final exit = outs.firstWhere((o) => o['tag'] == 'exit');
    final relay = outs.firstWhere((o) => o['tag'] == 'relay');
    // The client connects ONLY to the relay; the exit is dialed THROUGH it.
    expect(exit['detour'], 'relay');
    expect((b.clientConfig['route'] as Map)['final'], 'exit');
    // Relay fronts a RU SNI; each hop carries its own Reality public key.
    expect((relay['tls'] as Map)['server_name'], 'dzen.ru');
    expect(((relay['tls'] as Map)['reality'] as Map)['public_key'],
        'EKMbPORrYF4u99Hqd-SXf8_zHh-Mlw3cuu2is5qJWhU');
    expect((exit['tls'] as Map)['server_name'], 'www.microsoft.com');
    expect(
        ((b.relayServerConfig['inbounds'] as List)[0] as Map)['type'], 'vless');
    // The chain survives the app's import migration (detour preserved).
    final runtime = SingBoxConfig.fromConfig(b.clientConfig);
    final rOuts = (runtime['outbounds'] as List).cast<Map>();
    expect(rOuts.firstWhere((o) => o['tag'] == 'exit')['detour'], 'relay');
    Directory('build').createSync(recursive: true);
    File('build/gen_chain_client.json')
        .writeAsStringSync(SingBoxConfig.encode(runtime));
  });

  test('imported config is hardened for RF (ipv4_only, randomized fp, no github)',
      () {
    const json = '{'
        '"dns":{"servers":[{"tag":"d","address":"https://1.1.1.1/dns-query"}],"strategy":"prefer_ipv4"},'
        '"route":{"final":"VPN","rules":[{"rule_set":"geosite-ru","outbound":"direct"}],'
        '"rule_set":[{"type":"remote","tag":"geosite-ru","format":"binary",'
        '"url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs","download_detour":"direct"}]},'
        '"outbounds":[{"type":"vless","tag":"VPN","server":"a.com","server_port":443,"uuid":"u",'
        '"tls":{"enabled":true,"server_name":"m.vk.com","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"k"}}},'
        '{"type":"direct","tag":"direct"}]}';
    final nodes = ShareLink.parseSubscription(json);
    expect(nodes.length, 1);
    final out =
        SingBoxConfig.encode(SingBoxConfig.fromConfig(nodes.first.config!));
    expect(out.contains('raw.githubusercontent.com'), false,
        reason: 'remote rule-sets must be localized (RF blocks github)');
    expect(out.contains('"fingerprint": "randomized"'), false,
        reason: 'randomized is synthetic and can break Reality');
    expect(out.contains('"fingerprint": "chrome"'), true,
        reason: 'uTLS must mimic a real browser (Chrome)');
    expect(out.contains('"strategy": "ipv4_only"'), true,
        reason: 'must force IPv4 (RF networks usually have no IPv6)');
  });

  test('extracts links from arbitrary surrounding text (CRLF, html, junk)', () {
    const messy = 'Here are your servers:\r\n'
        '  1) vless://b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b@a.com:443?security=reality&pbk=k&sid=1#A  \r\n'
        '<a href="trojan://secret@c.com:443?sni=c.com#C">link</a>\n'
        'garbage hysteria2://pass@b.com:8443?sni=b.com#B end';
    final nodes = ShareLink.parseSubscription(messy);
    expect(nodes.length, 3);
    expect(nodes.map((n) => n.type).toSet(), {'vless', 'trojan', 'hysteria2'});
  });

  test('imports a sing-box JSON config as a single profile', () {
    const json =
        '{"route":{"final":"VPN"},"outbounds":[{"type":"vless","tag":"X","server":"a.com","server_port":443,"uuid":"u"},{"type":"direct","tag":"direct"}]}';
    final nodes = ShareLink.parseSubscription(json);
    expect(nodes.length, 1);
    expect(nodes.first.isConfig, true);
    expect(nodes.first.tag, 'VPN');
  });

  test('migrates legacy DNS servers to the 1.13 typed format', () {
    // Pre-1.12 `address:` servers FATAL on sing-box 1.14 (legacy DNS removed).
    // fromConfig must rewrite them to the typed form so no deprecated flag is
    // needed — and drop a redundant `detour: direct` (1.13 rejects it).
    const json = '{'
        '"dns":{"servers":['
        '{"tag":"remote","address":"https://1.1.1.1/dns-query","detour":"VPN"},'
        '{"tag":"local","address":"https://77.88.8.8/dns-query","detour":"direct"},'
        '{"tag":"sys","address":"local"}'
        '],"final":"remote"},'
        '"route":{"final":"VPN"},'
        '"outbounds":[{"type":"vless","tag":"VPN","server":"a.com","server_port":443,"uuid":"u"},'
        '{"type":"direct","tag":"direct"}]}';
    final cfg = SingBoxConfig.fromConfig(
        ShareLink.parseSubscription(json).first.config!);
    final servers = ((cfg['dns'] as Map)['servers'] as List).cast<Map>();
    Map srv(String t) => servers.firstWhere((s) => s['tag'] == t);
    expect(servers.every((s) => s['type'] != null), true,
        reason: 'every server must use the typed format');
    expect(servers.any((s) => s.containsKey('address')), false,
        reason: 'the legacy `address` field must be gone');
    expect(srv('remote')['type'], 'https');
    expect(srv('remote')['server'], '1.1.1.1');
    expect(srv('sys')['type'], 'local');
    expect(srv('local').containsKey('detour'), false,
        reason: 'redundant `detour: direct` must be dropped');
    expect(srv('remote')['detour'], 'VPN', reason: 'a real detour stays');
    expect((cfg['route'] as Map)['default_domain_resolver'], isNotNull,
        reason: 'dial fields need an explicit direct resolver in 1.13+');
  });

  test('imports a WireGuard .conf as a sing-box endpoint profile', () {
    const conf = '[Interface]\n'
        'PrivateKey = aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789AbCd=\n'
        'Address = 10.7.0.2/32\n'
        'MTU = 1420\n'
        '[Peer]\n'
        'PublicKey = ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210ZyXw=\n'
        'PresharedKey = pReShArEdKeY1234567890pReShArEdKeY12345678=\n'
        'Endpoint = vpn.example.com:51820\n'
        'AllowedIPs = 0.0.0.0/0, ::/0\n';
    final nodes = ShareLink.parseSubscription(conf);
    expect(nodes.length, 1);
    expect(nodes.first.isConfig, true, reason: 'WG is a full config profile');
    final cfg = nodes.first.config!;
    final ep = (cfg['endpoints'] as List).first as Map;
    expect(ep['type'], 'wireguard');
    expect(ep['address'], ['10.7.0.2/32']);
    expect(ep['mtu'], 1420);
    final peer = (ep['peers'] as List).first as Map;
    expect(peer['address'], 'vpn.example.com');
    expect(peer['port'], 51820);
    expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
    // No PersistentKeepalive in the conf → default to WG's standard 25s so the
    // tunnel stays alive (the "long-lived" behaviour WG is known for).
    expect(peer['persistent_keepalive_interval'], 25);
    expect((cfg['route'] as Map)['final'], 'wg');
  });

  test('WG .conf: an explicit PersistentKeepalive is honoured, incl. a '
      'deliberate 0 (not overridden)', () {
    String conf(String ka) => '[Interface]\n'
        'PrivateKey = aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789AbCd=\n'
        'Address = 10.7.0.2/32\n'
        '[Peer]\n'
        'PublicKey = ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210ZyXw=\n'
        'Endpoint = vpn.example.com:51820\n'
        'PersistentKeepalive = $ka\n';
    Map peerOf(String ka) => ((ShareLink.parseSubscription(conf(ka)).first.config!
        ['endpoints'] as List).first as Map)['peers'][0] as Map;
    expect(peerOf('15')['persistent_keepalive_interval'], 15); // honoured
    // An EXPLICIT 0 is the author's deliberate choice → honoured, NOT forced to 25
    // (only an ABSENT key defaults to 25, covered by the test above).
    expect(peerOf('0')['persistent_keepalive_interval'], 0);
    // garbage → the 25s default
    expect(peerOf('abc')['persistent_keepalive_interval'], 25);
  });
}
