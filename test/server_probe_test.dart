import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/diagnostics.dart';

/// The server-connect diagnostic ("works on Wi-Fi, not on mobile"): endpoint
/// extraction + the staged layer verdict. The socket probes need a real network
/// (run on-device), but the extraction + verdict logic — where a bug would
/// mislabel the failing layer — are locked here.
void main() {
  group('Diagnostics.endpointsOf', () {
    test('pulls host/port + UDP flag from proxy outbounds, dedups, skips groups',
        () {
      final cfg = {
        'outbounds': [
          {'type': 'vless', 'tag': 'r', 'server': '1.2.3.4', 'server_port': 443},
          {
            'type': 'hysteria2',
            'tag': 'h',
            'server': '5.6.7.8',
            'server_port': 8443
          },
          {
            'type': 'vless',
            'tag': 'x',
            'server': '1.2.3.4',
            'server_port': 443
          }, // dup host:port:udp → collapsed
          {
            'type': 'selector',
            'tag': 'VPN',
            'outbounds': ['r', 'h']
          }, // no server → skipped
          {'type': 'direct', 'tag': 'direct'}, // no server → skipped
        ],
      };
      final eps = Diagnostics.endpointsOf(cfg);
      expect(eps.length, 2);
      final r = eps.firstWhere((e) => e.host == '1.2.3.4');
      expect(r.port, 443);
      expect(r.udp, isFalse);
      expect(eps.firstWhere((e) => e.host == '5.6.7.8').udp, isTrue); // hy2 = UDP
    });

    test('extracts a WireGuard endpoint from peers[].address', () {
      final cfg = {
        'endpoints': [
          {
            'type': 'wireguard',
            'tag': 'wg',
            'peers': [
              {'address': '9.9.9.9', 'port': 51820}
            ]
          },
        ],
      };
      final eps = Diagnostics.endpointsOf(cfg);
      expect(eps.length, 1);
      expect(eps.first.host, '9.9.9.9');
      expect(eps.first.port, 51820);
      expect(eps.first.udp, isTrue);
    });
  });

  group('Diagnostics.verdictFor (staged layer verdict)', () {
    test('no foreign reachable + server unreachable → whitelist collapse', () {
      // No foreign control reachable AND the server didn't answer → allowlist.
      expect(Diagnostics.verdictFor(controlUp: false, udp: false, reachable: false),
          ServerVerdict.whitelistCollapse);
      expect(Diagnostics.verdictFor(controlUp: false, udp: true, reachable: null),
          ServerVerdict.whitelistCollapse);
    });
    test('server ANSWERED beats whitelist — a reachable server is the strongest '
        'signal even if the baked control IPs are blocked (audit #9)', () {
      expect(Diagnostics.verdictFor(controlUp: false, udp: false, reachable: true),
          ServerVerdict.reachableL4);
    });
    test('local network down → offline, NOT a whitelist false-alarm (audit #8)',
        () {
      expect(
          Diagnostics.verdictFor(
              controlUp: false, udp: false, reachable: false, localUp: false),
          ServerVerdict.offline);
      // offline wins even over a (stale) reachable flag — there is no network.
      expect(
          Diagnostics.verdictFor(
              controlUp: true, udp: false, reachable: true, localUp: false),
          ServerVerdict.offline);
    });
    test('foreign up + TCP server reachable → L4 ok (suspect protocol DPI)', () {
      expect(Diagnostics.verdictFor(controlUp: true, udp: false, reachable: true),
          ServerVerdict.reachableL4);
    });
    test('foreign up + server SYN dropped → IP/port block', () {
      expect(Diagnostics.verdictFor(controlUp: true, udp: false, reachable: false),
          ServerVerdict.serverBlocked);
    });
    test('UDP/QUIC → inconclusive (cannot passively SYN-probe)', () {
      expect(Diagnostics.verdictFor(controlUp: true, udp: true, reachable: null),
          ServerVerdict.udpInconclusive);
    });
  });
}
