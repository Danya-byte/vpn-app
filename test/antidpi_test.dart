import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Locks in the #2 anti-DPI layer: uTLS fingerprint pool, mux, ECH.
void main() {
  Map<String, dynamic> outboundOf(Map<String, dynamic> cfg) =>
      (cfg['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere(
          (o) => o['type'] == 'vless' || o['type'] == 'trojan' || o['type'] == 'vmess');

  final reality = ShareLink.parse(
      'vless://u@1.2.3.4:443?security=reality&pbk=K&sid=ab&flow=xtls-rprx-vision#R')!;
  final plain = ShareLink.parse(
      'vless://u@1.2.3.4:443?security=tls&sni=example.com&type=tcp#P')!;

  test('uTLS fingerprint pool is applied (real browsers only)', () {
    final ob = outboundOf(SingBoxConfig.fromNode(plain, tlsFingerprint: 'firefox'));
    expect(((ob['tls'] as Map)['utls'] as Map)['fingerprint'], 'firefox');
  });

  test('synthetic "randomized" is never emitted; "random" on Reality → chrome',
      () {
    final r = outboundOf(
        SingBoxConfig.fromNode(reality, tlsFingerprint: 'random'));
    // Reality keeps chrome (the synthetic-safe choice); never "randomized".
    expect(((r['tls'] as Map)['utls'] as Map)['fingerprint'], 'chrome');
    final p =
        outboundOf(SingBoxConfig.fromNode(plain, tlsFingerprint: 'random'));
    expect(((p['tls'] as Map)['utls'] as Map)['fingerprint'], 'random');
  });

  test('mux on plain TCP-TLS, but NOT with Vision flow', () {
    expect(outboundOf(SingBoxConfig.fromNode(plain, mux: true))['multiplex'],
        isNotNull);
    // Reality link carries xtls-rprx-vision → mux must be skipped.
    expect(outboundOf(SingBoxConfig.fromNode(reality, mux: true))['multiplex'],
        isNull);
  });

  test('ECH on non-Reality TLS only', () {
    expect((outboundOf(SingBoxConfig.fromNode(plain, ech: true))['tls'] as Map)['ech'],
        isNotNull);
    expect(
        (outboundOf(SingBoxConfig.fromNode(reality, ech: true))['tls'] as Map)['ech'],
        isNull);
  });

  test('fingerprintOverride NEVER corrupts a Reality fp on imported configs', () {
    // Audit #8: the old override loop rewrote a Reality node's chrome with
    // firefox/safari/edge/random during auto-adapt — corrupting the very
    // handshake fingerprint of the nodes it was trying to rescue. The author's
    // (or safe-default) Reality fp must survive ANY override.
    Map<String, dynamic> realityConfig() => {
          'outbounds': [
            {
              'type': 'vless',
              'tag': 'r',
              'server': 'a.com',
              'uuid': 'u',
              'tls': {
                'enabled': true,
                'utls': {'enabled': true, 'fingerprint': 'chrome'},
                'reality': {'enabled': true, 'public_key': 'K'}
              }
            }
          ],
          'route': {'final': 'r'},
        };
    String fpOf(Map<String, dynamic> cfg) =>
        (((cfg['outbounds'] as List).cast<Map>().firstWhere(
                    (o) => o['tag'] == 'r')['tls'] as Map)['utls'] as Map)['fingerprint']
            as String;
    // Reality keeps chrome regardless of the override — never firefox/random.
    for (final ov in ['firefox', 'safari', 'edge', 'random', 'randomized', 'yandex']) {
      expect(fpOf(SingBoxConfig.fromConfig(realityConfig(), fingerprintOverride: ov)),
          'chrome',
          reason: 'override "$ov" must not touch a Reality handshake fp');
    }
  });

  test('imported plain-TLS node with no utls gets a synthesized fingerprint', () {
    // Audit #25: a bare tls:{enabled:true} import presented the trivially
    // fingerprintable Go-stdlib ClientHello. fromConfig now synthesizes uTLS.
    final cfg = SingBoxConfig.fromConfig({
      'outbounds': [
        {'type': 'vmess', 'tag': 'v', 'server': 'a.com', 'server_port': 443,
          'uuid': 'u', 'tls': {'enabled': true, 'server_name': 'a.com'}},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'v'},
    }, fingerprintOverride: 'chrome');
    final v = (cfg['outbounds'] as List).cast<Map>().firstWhere((o) => o['tag'] == 'v');
    expect(((v['tls'] as Map)['utls'] as Map)['fingerprint'], 'chrome');
  });

  test('antiDpi/mux/ech now apply to imported configs (non-Reality TCP-TLS)', () {
    // Audit #6: these settings were dead controls for imported configs.
    final cfg = SingBoxConfig.fromConfig({
      'outbounds': [
        {'type': 'vless', 'tag': 'p', 'server': 'a.com', 'server_port': 443,
          'uuid': 'u', 'tls': {'enabled': true, 'server_name': 'a.com'}},
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'p'},
    }, antiDpi: true, mux: true, ech: true);
    final p = (cfg['outbounds'] as List).cast<Map>().firstWhere((o) => o['tag'] == 'p');
    expect((p['tls'] as Map)['fragment'], isTrue, reason: 'anti-DPI fragment');
    expect((p['tls'] as Map)['ech'], isNotNull, reason: 'ECH');
    expect(p['multiplex'], isNotNull, reason: 'mux');
  });
}
