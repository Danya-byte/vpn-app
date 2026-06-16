import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/proxy_node.dart';
import 'package:vpn_app/core/share_link_encoder.dart';

ParsedNode _config() => ParsedNode(tag: '🌍 VPN', outbound: const {}, config: {
      'outbounds': [
        {
          'tag': '🌍 VPN',
          'type': 'selector',
          'outbounds': ['n1', 'n2']
        },
        {
          'tag': 'n1',
          'type': 'vless',
          'server': 'a.example',
          'server_port': 443,
          'uuid': 'u1'
        },
        {
          'tag': 'n2',
          'type': 'vless',
          'server': 'b.example',
          'server_port': 8443,
          'uuid': 'u2'
        },
      ],
    });

void main() {
  group('nodeLinks (share for any app)', () {
    test('extracts EVERY exit server from a config, not just one', () {
      // The user wants "share for any app" to copy the WHOLE server list, not just
      // the currently-connected exit — every real exit becomes a link.
      final links = ShareLinkEncoder.nodeLinks([_config()]);
      expect(links.length, 2);
      expect(links.any((l) => l.contains('a.example')), isTrue);
      expect(links.any((l) => l.contains('b.example')), isTrue);
    });

    test('skips the selector member (no server)', () {
      final links = ShareLinkEncoder.nodeLinks([_config()]);
      expect(links.every((l) => !l.contains('selector')), isTrue);
      expect(links.length, 2);
    });

    test('a simple node yields its single link', () {
      final n = ParsedNode(tag: 'A', outbound: {
        'type': 'trojan',
        'tag': 'A',
        'server': 'c.example',
        'server_port': 443,
        'password': 'p'
      });
      expect(ShareLinkEncoder.nodeLinks([n]).single, contains('c.example'));
    });
  });
}
