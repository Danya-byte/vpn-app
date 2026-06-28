import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/proxy_node.dart';
import 'package:vpn_app/core/server_gen.dart';

void main() {
  group('config-cast hardening — a hostile/hand-edited config must not crash', () {
    // A `vpn://share` bundle or hand-edited store envelope can carry outbounds/
    // endpoints as a Map/String/number. The cast used to throw a TypeError inside
    // the safety-preview dialog — the exact gate meant to protect the user.
    final malformed = <Map<String, dynamic>>[
      {'outbounds': <String, dynamic>{}},
      {'outbounds': 'not-a-list'},
      {'outbounds': 5},
      {'endpoints': <String, dynamic>{}},
      {'endpoints': 7},
      {'outbounds': null, 'endpoints': 'x'},
    ];
    for (final cfg in malformed) {
      test('insecure / pinned / insecureKey survive $cfg', () {
        final n = ParsedNode(tag: 'n', outbound: const {}, config: cfg);
        expect(() => n.insecure, returnsNormally);
        expect(() => n.pinned, returnsNormally);
        expect(() => n.insecureKey, returnsNormally);
      });
    }
  });

  group('ServerGen relay chain — NEITHER hop mandates Vision flow', () {
    test('relay + exit server users both carry NO flow', () {
      final b = ServerGen.buildRelayChain(
        relayIp: '1.1.1.1',
        relayUuid: 'u1',
        relayPriv: 'p1',
        relayPub: 'P1',
        relayShortId: 'aa',
        exitIp: '2.2.2.2',
        exitUuid: 'u2',
        exitPriv: 'p2',
        exitPub: 'P2',
        exitShortId: 'bb',
      );
      Map firstUser(Map<String, dynamic> cfg) =>
          (((cfg['inbounds'] as List).first as Map)['users'] as List).first
              as Map;
      // The relay leg TUNNELS the exit's own Reality+VLESS TLS as its payload, so
      // XTLS-Vision splicing can't apply to it either — Vision on the relay broke
      // the nested handshake (the chain passed no traffic). So NEITHER server user
      // mandates flow; Vision belongs only on a single, non-nesting outermost hop.
      expect(firstUser(b.relayServerConfig).containsKey('flow'), isFalse);
      // Exit is dialed THROUGH the relay (detour), client carries no flow → the
      // exit server must not mandate Vision or the handshake fails (dead leg).
      expect(firstUser(b.exitServerConfig).containsKey('flow'), isFalse);
    });
  });
}
