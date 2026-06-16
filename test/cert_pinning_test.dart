import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/core/profiles_controller.dart';
import 'package:vpn_app/core/proxy_node.dart';

// A REAL self-signed X.509 cert (generated via `sing-box generate tls-keypair`).
// The validator base64-decodes the body and rejects a too-small / garbled one, so
// a fake body no longer passes.
const _pem = '''-----BEGIN CERTIFICATE-----
MIIDADCCAeigAwIBAgIQfEEEr5gEe2grBgmlJSvgHzANBgkqhkiG9w0BAQsFADAV
MRMwEQYDVQQDEwp0ZXN0LmxvY2FsMB4XDTI2MDYxNjE1NDYxOFoXDTI3MDYxNjE2
NDYxN1owFTETMBEGA1UEAxMKdGVzdC5sb2NhbDCCASIwDQYJKoZIhvcNAQEBBQAD
ggEPADCCAQoCggEBAKlkCFusaHzC2MSo5Z/aWgv8vsHy5tFUiXGj8JA8SZP6MebG
mkLe2u1sa8vVS/tuqvJTPDuLzzTWdYBPQbmxuTVT/ttDjQWNRfRS/WZ+RhDHOxY0
NpHJbVVCvXxTY/Ln0jiExDCKKsEJ7m8ejnneGQ5kpOjVzXsHBj4usOG4yrjN0mZ6
/CaqKlRmyCRgT1zxcSjOj6uSkBgP0lmpWEVT6XMejYFjNF2qc4TFbNc5W6hPuBpG
rMTRqPZQ8cUTfs2iggyywLZgbaHgvoJhAGYS853LynM8ILOv09myDjIPimDjvus+
3uukof0I05TAEbQKB8xjZG69GgWErJvtLZUTvy8CAwEAAaNMMEowDgYDVR0PAQH/
BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAwGA1UdEwEB/wQCMAAwFQYDVR0R
BA4wDIIKdGVzdC5sb2NhbDANBgkqhkiG9w0BAQsFAAOCAQEAWTX3OAI3K6fYIEf7
xzcXAjw9/1tLTWvdEOv6lBJEKBQcRoDgxezjWKEIXzfHh3ON6lP/htY8yO6uwvCH
uLlCSkn0GWbmT9bxzWn6t9JsxCk9cHtyVthN5KBP5C1tiX5ouVVdwI8tNWxxCjQl
f2TRUapYAgD6AXN9rQk48LWhu6Y/i1ElCI4JWDbEjGDW5pbAetG1YZxCuMEXTP8z
8b5Dxw4IELkEAlQ1gJBVLZOxIxD/aY6Jh+atmdojQr++0QQ3g6EjOvcrA1x2Np5J
SnRrmTLB+/gYs7M/ip+vz3gJD4586WHoImcE//9yEteIbwJhc5CjL1ExYXawlt13
lXlwMg==
-----END CERTIFICATE-----''';

ParsedNode _selected() => ParsedNode(tag: 'sel', outbound: {
      'type': 'vless',
      'tag': 'sel',
      'server': 'a.example',
      'server_port': 443,
      'uuid': 'u',
    });

ParsedNode _insecureHy2({String tag = 'hy', String server = 'b.example'}) =>
    ParsedNode(tag: tag, outbound: {
      'type': 'hysteria2',
      'tag': tag,
      'server': server,
      'server_port': 443,
      'password': 'p',
      'tls': {'enabled': true, 'insecure': true},
    });

void main() {
  group('ParsedNode.pinned', () {
    test('false with no certificate; true once a TLS cert is present', () {
      expect(_insecureHy2().pinned, isFalse);
      expect(_insecureHy2().insecure, isTrue);

      final pinnedNode = ParsedNode(tag: 'b', outbound: {
        'type': 'hysteria2',
        'server': 's',
        'server_port': 443,
        'tls': {
          'enabled': true,
          'insecure': false,
          'certificate': ['x']
        },
      });
      expect(pinnedNode.pinned, isTrue);
      expect(pinnedNode.insecure, isFalse);
    });
  });

  group('pinCertificate', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('vpn_pin_test');
      ProfileStore.overrideDir = tmp.path;
    });
    tearDown(() {
      ProfileStore.overrideDir = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('pins a valid PEM and turns insecure off', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(profilesProvider.notifier);
      notifier.clear();
      // 'sel' is the active node, so pinning the NON-selected 'hy' never touches
      // the core controller (keeps the test free of FFI/native side effects).
      notifier.importNodes([_selected(), _insecureHy2()], selectFirst: true);

      expect(notifier.pinCertificate('hy', _pem), PinResult.ok);

      final n =
          c.read(profilesProvider).nodes.firstWhere((x) => x.tag == 'hy');
      expect(n.pinned, isTrue);
      expect(n.insecure, isFalse);
      final tls = n.outbound['tls'] as Map;
      expect(tls['insecure'], isFalse);
      expect(tls['certificate'], isA<List>());
    });

    test('rejects non-PEM and a marker-only garbled body', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(profilesProvider.notifier);
      notifier.clear();
      notifier.importNodes([_selected(), _insecureHy2()], selectFirst: true);

      expect(notifier.pinCertificate('hy', 'just some random text'),
          PinResult.badPem);
      // markers present but the body isn't valid base64 → still rejected
      expect(
          notifier.pinCertificate('hy',
              '-----BEGIN CERTIFICATE-----\nnot base64!!!\n-----END CERTIFICATE-----'),
          PinResult.badPem);
      final n =
          c.read(profilesProvider).nodes.firstWhere((x) => x.tag == 'hy');
      expect(n.insecure, isTrue);
      expect(n.pinned, isFalse);
    });

    test('refuses a config with more than one insecure server', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(profilesProvider.notifier);
      notifier.clear();
      final multi = ParsedNode(tag: 'multi', outbound: const {}, config: {
        'outbounds': [
          {
            'tag': 'a',
            'type': 'hysteria2',
            'server': 'a.example',
            'server_port': 443,
            'tls': {'enabled': true, 'insecure': true}
          },
          {
            'tag': 'b',
            'type': 'hysteria2',
            'server': 'b.example',
            'server_port': 443,
            'tls': {'enabled': true, 'insecure': true}
          },
        ],
      });
      notifier.importNodes([_selected(), multi], selectFirst: true);

      expect(
          notifier.pinCertificate('multi', _pem), PinResult.multipleServers);
      final n =
          c.read(profilesProvider).nodes.firstWhere((x) => x.tag == 'multi');
      expect(n.insecure, isTrue); // untouched — no cert written
      expect(n.pinned, isFalse);
    });

    test('unpinCertificate reverses a pin back to insecure (recovery path)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(profilesProvider.notifier);
      notifier.clear();
      notifier.importNodes([_selected(), _insecureHy2()], selectFirst: true);
      expect(notifier.pinCertificate('hy', _pem), PinResult.ok);

      expect(notifier.unpinCertificate('hy'), isTrue);
      final n =
          c.read(profilesProvider).nodes.firstWhere((x) => x.tag == 'hy');
      expect(n.pinned, isFalse);
      expect(n.insecure, isTrue);
      expect((n.outbound['tls'] as Map)['certificate'], isNull);
      // a node that isn't pinned can't be unpinned
      expect(notifier.unpinCertificate('sel'), isFalse);
    });
  });
}
