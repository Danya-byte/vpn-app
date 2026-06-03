import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// #24: Hysteria2 Brutal bandwidth caps are stamped onto hysteria2 outbounds
/// ONLY when set, ONLY on hysteria2, and are a safe no-op otherwise.
void main() {
  Map<String, dynamic> cfg() => {
        'outbounds': [
          {
            'type': 'hysteria2',
            'tag': 'hy2',
            'server': '1.2.3.4',
            'server_port': 443,
            'password': 'p',
          },
          {'type': 'vless', 'tag': 'v', 'server': '5.6.7.8'},
          {'type': 'direct', 'tag': 'direct'},
        ],
      };

  test('stamps up/down on hysteria2 only', () {
    final outs = (SingBoxConfig.tuneHysteria2(cfg(), 50, 200)['outbounds'] as List)
        .cast<Map>();
    final hy2 = outs.firstWhere((o) => o['type'] == 'hysteria2');
    expect(hy2['up_mbps'], 50);
    expect(hy2['down_mbps'], 200);
    expect(outs.firstWhere((o) => o['type'] == 'vless').containsKey('up_mbps'),
        isFalse,
        reason: 'never touches non-hysteria2 outbounds');
  });

  test('0/0 = auto: no fields added (safe no-op)', () {
    final hy2 = (SingBoxConfig.tuneHysteria2(cfg(), 0, 0)['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['type'] == 'hysteria2');
    expect(hy2.containsKey('up_mbps'), isFalse);
    expect(hy2.containsKey('down_mbps'), isFalse);
  });

  test('only one side set → only that field', () {
    final hy2 = (SingBoxConfig.tuneHysteria2(cfg(), 0, 100)['outbounds'] as List)
        .cast<Map>()
        .firstWhere((o) => o['type'] == 'hysteria2');
    expect(hy2.containsKey('up_mbps'), isFalse);
    expect(hy2['down_mbps'], 100);
  });

  test('tolerates a config with no outbounds list', () {
    expect(() => SingBoxConfig.tuneHysteria2({}, 10, 10), returnsNormally);
  });
}
