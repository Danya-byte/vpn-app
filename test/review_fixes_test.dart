import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/amnezia_config.dart';
import 'package:vpn_app/core/share_link.dart';

/// Regression tests for the xhigh /code-review findings that are pure + unit-
/// testable: the Shadowsocks none-cipher empty-password guard, the WireGuard
/// empty-host drop, and the AmneziaWG keepalive uint16 clamp.
void main() {
  group('Clash ss: empty password is valid for none/plain, required otherwise', () {
    test("cipher 'none' with empty password still imports", () {
      const yaml = '''
proxies:
  - {name: ss-none, type: ss, server: 1.2.3.4, port: 443, cipher: none, password: ''}
''';
      final nodes = ShareLink.parseSubscription(yaml);
      expect(nodes.length, 1);
      expect(nodes.first.outbound['method'], 'none');
    });

    test('a real cipher with an empty password is still dropped', () {
      const yaml = '''
proxies:
  - {name: ss-ok, type: ss, server: 1.2.3.4, port: 443, cipher: none, password: ''}
  - {name: ss-bad, type: ss, server: 5.6.7.8, port: 443, cipher: aes-256-gcm, password: ''}
''';
      final nodes = ShareLink.parseSubscription(yaml);
      // Only the none-cipher node survives; the auth-requiring one is dropped.
      expect(nodes.map((n) => n.tag).toList(), ['ss-ok']);
    });
  });

  group('WireGuard .conf: an empty peer host is dropped, not emitted', () {
    test('Endpoint `[]:51820` (empty host) yields no node — no throw', () {
      final conf = '''
[Interface]
PrivateKey = $_k1
Address = 10.0.0.2/32

[Peer]
PublicKey = $_k2
Endpoint = []:51820
AllowedIPs = 0.0.0.0/0
''';
      expect(ShareLink.parseSubscription(conf), isEmpty);
    });

    test('a well-formed Endpoint still imports', () {
      final conf = '''
[Interface]
PrivateKey = $_k1
Address = 10.0.0.2/32

[Peer]
PublicKey = $_k2
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0
''';
      final nodes = ShareLink.parseSubscription(conf);
      expect(nodes.length, 1);
    });
  });

  group('AmneziaWG keepalive is clamped to the WG uint16 range', () {
    Map endpoint(Object? ka) => {
          'private_key': _k1,
          'peers': [
            {
              'public_key': _k2,
              'address': '1.2.3.4',
              'port': 51820,
              'allowed_ips': ['0.0.0.0/0'],
              'persistent_keepalive_interval': ?ka,
            }
          ],
        };

    test('an out-of-range value is clamped to 65535 (not emitted verbatim)', () {
      final ini = AmneziaConfig.fromEndpoint(endpoint(99999), 1080);
      expect(ini, isNotNull);
      expect(ini, contains('PersistentKeepalive = 65535'));
    });

    test('an explicit 0 (disabled) is honoured', () {
      final ini = AmneziaConfig.fromEndpoint(endpoint(0), 1080);
      expect(ini, contains('PersistentKeepalive = 0'));
    });

    test('an absent interval defaults to 25', () {
      final ini = AmneziaConfig.fromEndpoint(endpoint(null), 1080);
      expect(ini, contains('PersistentKeepalive = 25'));
    });
  });
}

// Valid 32-byte base64 keys (WG/AWG key shape: 44 chars, '='-padded).
final String _k1 = base64.encode(List<int>.filled(32, 1));
final String _k2 = base64.encode(List<int>.filled(32, 2));
