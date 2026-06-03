import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/amnezia_config.dart';

/// The AmneziaWG bridge config generator (our superstructure for a transport no
/// bundled core can dial). Pure → the wireproxy INI shape is locked here.
void main() {
  Map<String, dynamic> awgEndpoint() => {
        'type': 'wireguard',
        'tag': 'wg',
        'address': ['10.8.0.2/32'],
        'private_key': 'PRIVKEY==',
        'mtu': 1280,
        'peers': [
          {
            'address': '1.2.3.4',
            'port': 51820,
            'public_key': 'PUBKEY==',
            'allowed_ips': ['0.0.0.0/0', '::/0'],
            'pre_shared_key': 'PSK==',
          }
        ],
        '_amneziawg': {
          'jc': 4, 'jmin': 40, 'jmax': 70,
          's1': 50, 's2': 100,
          'h1': 1234567, 'h2': 7654321, 'h3': 1112223, 'h4': 3332221,
        },
      };

  group('needsAmnezia', () {
    test('true only for a WireGuard endpoint carrying obfs params', () {
      expect(AmneziaConfig.needsAmnezia(awgEndpoint()), isTrue);
      // Plain WireGuard (no _amneziawg) goes through the core, not the bridge.
      final plain = awgEndpoint()..remove('_amneziawg');
      expect(AmneziaConfig.needsAmnezia(plain), isFalse);
      // Non-wireguard never needs it.
      expect(AmneziaConfig.needsAmnezia({'type': 'vless'}), isFalse);
      // Empty params map → not amnezia.
      expect(
          AmneziaConfig.needsAmnezia({'type': 'wireguard', '_amneziawg': {}}),
          isFalse);
    });
  });

  group('fromEndpoint → wireproxy INI', () {
    test('emits Interface (WG + canonical Amnezia params), Peer, Socks5', () {
      final ini = AmneziaConfig.fromEndpoint(awgEndpoint(), 24200)!;
      // Interface
      expect(ini, contains('[Interface]'));
      expect(ini, contains('PrivateKey = PRIVKEY=='));
      expect(ini, contains('Address = 10.8.0.2/32'));
      expect(ini, contains('MTU = 1280'));
      // Amnezia params with CANONICAL casing (Jc not JC / jc).
      expect(ini, contains('Jc = 4'));
      expect(ini, contains('Jmin = 40'));
      expect(ini, contains('Jmax = 70'));
      expect(ini, contains('S1 = 50'));
      expect(ini, contains('H1 = 1234567'));
      expect(ini, contains('H4 = 3332221'));
      // Peer
      expect(ini, contains('[Peer]'));
      expect(ini, contains('PublicKey = PUBKEY=='));
      expect(ini, contains('PresharedKey = PSK=='));
      expect(ini, contains('Endpoint = 1.2.3.4:51820'));
      expect(ini, contains('AllowedIPs = 0.0.0.0/0, ::/0'));
      // Socks5 listener — what sing-box dials as a plain socks outbound.
      expect(ini, contains('[Socks5]'));
      expect(ini, contains('BindAddress = 127.0.0.1:24200'));
    });

    test('omits params that are absent + the optional PSK/MTU', () {
      final ep = awgEndpoint();
      (ep['_amneziawg'] as Map).remove('s2'); // drop one
      (ep['peers'][0] as Map).remove('pre_shared_key');
      ep.remove('mtu');
      final ini = AmneziaConfig.fromEndpoint(ep, 24201)!;
      expect(ini, isNot(contains('S2 =')));
      expect(ini, isNot(contains('PresharedKey')));
      expect(ini, isNot(contains('MTU =')));
      expect(ini, contains('S1 = 50')); // others still present
    });

    test('null when essentials are missing', () {
      expect(AmneziaConfig.fromEndpoint({'type': 'wireguard'}, 1), isNull);
      final noPeer = awgEndpoint()..['peers'] = [];
      expect(AmneziaConfig.fromEndpoint(noPeer, 1), isNull);
    });
  });
}
