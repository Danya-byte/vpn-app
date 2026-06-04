import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/proxy_node.dart';

/// Locks in that the MITM-warning badge also fires for imported full-config
/// profiles, not just simple nodes (B4 gap: configs slipped through silently).
/// Built from ParsedNode directly — never touches the real ProfileStore.
void main() {
  ParsedNode config(Map<String, dynamic> cfg) =>
      ParsedNode(tag: 'cfg', outbound: const {}, config: cfg);

  test('config with an insecure outbound is flagged insecure', () {
    final n = config({
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'x',
          'server': 'a.com',
          'tls': {'enabled': true, 'insecure': true},
        },
      ],
    });
    expect(n.insecure, isTrue);
  });

  test('config with a Reality outbound is NOT flagged (insecure is moot there)',
      () {
    final n = config({
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'x',
          'server': 'a.com',
          // insecure:true is meaningless under Reality (pinned-key auth).
          'tls': {
            'enabled': true,
            'insecure': true,
            'reality': {'enabled': true, 'public_key': 'KEY'},
          },
        },
      ],
    });
    expect(n.insecure, isFalse);
  });

  test('insecure Hysteria2/TUIC ARE flagged (password auths client, not server)',
      () {
    for (final type in ['hysteria2', 'tuic']) {
      final n = config({
        'outbounds': [
          {
            'type': type,
            'tag': 'x',
            'server': 'a.com',
            'password': 'p',
            'tls': {'enabled': true, 'insecure': true},
          },
        ],
      });
      expect(n.insecure, isTrue,
          reason: '$type with insecure:true disables SERVER auth → MITM-able');
    }
  });

  test('an insecure entry parked under `endpoints` is also caught', () {
    final n = config({
      'outbounds': [
        {'type': 'direct', 'tag': 'd'}, // clean
      ],
      'endpoints': [
        {
          'tag': 'e',
          'tls': {'enabled': true, 'insecure': true},
        },
      ],
    });
    expect(n.insecure, isTrue);
  });
}
