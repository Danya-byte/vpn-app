import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/route_mode.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Locks in the connection-killer fix: a DNS server with `detour: direct` makes
/// sing-box 1.13 FATAL ("detour to an empty direct outbound makes no sense"),
/// which crash-looped every single-link connection. No config path may emit it.
void main() {
  void assertNoDirectDetour(Map<String, dynamic> cfg, String label) {
    final dns = cfg['dns'] as Map?;
    final servers = (dns?['servers'] as List?)?.cast<Map>() ?? const [];
    expect(servers, isNotEmpty, reason: '$label has no DNS servers');
    for (final s in servers) {
      expect(s['detour'], isNot('direct'),
          reason: '$label: DNS server ${s['tag']} must not use detour:direct');
    }
  }

  test('no config path emits a DNS server with detour:direct', () {
    final node = ShareLink.parse(
        'vless://u@1.2.3.4:443?security=reality&pbk=K&sid=ab&flow=xtls-rprx-vision#N')!;
    assertNoDirectDetour(
        SingBoxConfig.fromNode(node, mode: RouteMode.smart), 'smart');
    assertNoDirectDetour(
        SingBoxConfig.fromNode(node, mode: RouteMode.global), 'global');
    assertNoDirectDetour(
        SingBoxConfig.withTun(SingBoxConfig.fromNode(node)), 'tun');

    // Imported config WITHOUT its own DNS → fromConfig synthesizes one.
    final synth = SingBoxConfig.fromConfig({
      'outbounds': [
        {'type': 'vless', 'tag': 'x', 'server': 'a.com', 'uuid': 'u'}
      ],
      'route': {'final': 'x'},
    });
    assertNoDirectDetour(synth, 'fromConfig-synth');
  });

  test('a real-shaped VLESS+Reality single link parses and builds a clean config',
      () {
    // Same SHAPE as a real node (Reality, vision flow, fronting SNI) but with
    // synthetic credentials — never commit a working node's UUID/keys.
    final node = ShareLink.parse(
        'vless://11111111-1111-1111-1111-111111111111@198.51.100.10:443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=TEST0reality0public0key0synthetic0only00000&sid=00ff00ff00ff00ff&type=tcp&flow=xtls-rprx-vision&headerType=none#node');
    expect(node, isNotNull);
    expect(node!.outbound['flow'], 'xtls-rprx-vision');
    final reality = (node.outbound['tls'] as Map)['reality'] as Map;
    expect(reality['public_key'], 'TEST0reality0public0key0synthetic0only00000');
    assertNoDirectDetour(
        SingBoxConfig.fromNode(node, mode: RouteMode.smart), 'user-link-smart');
  });
}
