import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/proxy_node.dart';
import 'package:vpn_app/core/route_mode.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// #19: the DoH resolver is configurable via SingBoxConfig.dnsServer (default
/// 77.88.8.8, the RF-safe Yandex endpoint). A custom value flows into every
/// generated config's DNS; the default is preserved when unset.
void main() {
  tearDown(() => SingBoxConfig.dnsServer = '77.88.8.8'); // restore the default

  ParsedNode node() => ParsedNode(
        tag: 'n',
        outbound: {
          'type': 'vless',
          'tag': 'n',
          'server': '1.2.3.4',
          'server_port': 443,
          'uuid': '11111111-1111-1111-1111-111111111111',
        },
      );

  List<String> dnsServers(Map<String, dynamic> cfg) =>
      ((cfg['dns'] as Map)['servers'] as List)
          .cast<Map>()
          .map((s) => '${s['server']}')
          .toList();

  test('default is the RF-safe Yandex resolver', () {
    expect(dnsServers(SingBoxConfig.desyncOnly()), contains('77.88.8.8'));
    expect(dnsServers(SingBoxConfig.fromNodes([node()], mode: RouteMode.smart)),
        contains('77.88.8.8'));
  });

  test('a custom DoH server flows into every build path', () {
    SingBoxConfig.dnsServer = '1.1.1.1';
    expect(dnsServers(SingBoxConfig.desyncOnly()), contains('1.1.1.1'));
    final cfg = SingBoxConfig.fromNodes([node()], mode: RouteMode.smart);
    expect(dnsServers(cfg), contains('1.1.1.1'));
    expect(dnsServers(cfg), isNot(contains('77.88.8.8')));
  });
}
