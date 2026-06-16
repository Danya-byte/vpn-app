import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/latency_probe.dart';
import 'package:vpn_app/core/proxy_node.dart';

void main() {
  group('tcpPing', () {
    test('returns a non-null latency for a reachable port', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final ms = await tcpPing('127.0.0.1', server.port);
      expect(ms, isNotNull);
      expect(ms! >= 0, isTrue);
    });

    test('returns null for a closed port', () async {
      // Bind then immediately release to get a port nothing is listening on.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final ms = await tcpPing('127.0.0.1', port,
          timeout: const Duration(seconds: 1));
      expect(ms, isNull);
    });
  });

  group('nodeEndpoint', () {
    test('simple vless node -> host:port, not udp', () {
      final n = ParsedNode(
          tag: 'a',
          outbound: {'type': 'vless', 'server': 'ex.com', 'server_port': 443});
      final e = nodeEndpoint(n);
      expect(e?.host, 'ex.com');
      expect(e?.port, 443);
      expect(e?.udp, isFalse);
    });

    test('hysteria2 node -> udp flagged', () {
      final n = ParsedNode(
          tag: 'h',
          outbound: {
            'type': 'hysteria2',
            'server': 'ex.com',
            'server_port': 443
          });
      expect(nodeEndpoint(n)?.udp, isTrue);
    });

    test('hysteria2 port-hopping (server_ports) -> first port', () {
      final n = ParsedNode(
          tag: 'h',
          outbound: {
            'type': 'hysteria2',
            'server': 'ex.com',
            'server_ports': ['443:8443', '9000']
          });
      expect(nodeEndpoint(n)?.port, 443);
    });

    test('config with a proxy outbound -> its endpoint', () {
      final n = ParsedNode(tag: 'c', outbound: const {}, config: {
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'trojan', 'server': 'srv', 'server_port': 8443},
        ]
      });
      final e = nodeEndpoint(n);
      expect(e?.host, 'srv');
      expect(e?.port, 8443);
    });

    test('config with no proxy outbound -> null', () {
      final n = ParsedNode(tag: 'c', outbound: const {}, config: {
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'block', 'tag': 'block'},
        ]
      });
      expect(nodeEndpoint(n), isNull);
    });

    test('node without a server -> null', () {
      final n = ParsedNode(
          tag: 'x', outbound: {'type': 'vless', 'server_port': 443});
      expect(nodeEndpoint(n), isNull);
    });
  });

  group('isUdpTransport', () {
    test('hy2/tuic/wireguard are udp, vless is not', () {
      expect(isUdpTransport('hysteria2'), isTrue);
      expect(isUdpTransport('tuic'), isTrue);
      expect(isUdpTransport('wireguard'), isTrue);
      expect(isUdpTransport('vless'), isFalse);
    });
  });

  group('LatencyProbe.measureAll', () {
    test('populates results for reachable + unreachable nodes', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = closed.port;
      await closed.close();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final probe = container.read(latencyProbeProvider.notifier);
      final nodes = [
        ParsedNode(
            tag: 'up',
            outbound: {
              'type': 'vless',
              'server': '127.0.0.1',
              'server_port': server.port
            }),
        ParsedNode(
            tag: 'down',
            outbound: {
              'type': 'vless',
              'server': '127.0.0.1',
              'server_port': closedPort
            }),
      ];
      await probe.measureAll(nodes);
      final state = container.read(latencyProbeProvider);
      expect(state.measured('up'), isTrue);
      expect(state.results['up'], isNotNull);
      expect(state.measured('down'), isTrue);
      expect(state.results['down'], isNull);
      expect(state.measuring, isEmpty);
    });

    test('a UDP transport is never TCP-probed (result null, not a TCP RTT)',
        () async {
      // server:port is a LIVE TCP listener, but the node is hysteria2 (UDP) — the
      // probe must NOT report its TCP RTT (a masquerade front would mislead).
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final probe = container.read(latencyProbeProvider.notifier);
      await probe.measureAll([
        ParsedNode(tag: 'hy', outbound: {
          'type': 'hysteria2',
          'server': '127.0.0.1',
          'server_port': server.port
        }),
      ]);
      final state = container.read(latencyProbeProvider);
      expect(state.measured('hy'), isTrue);
      expect(state.results['hy'], isNull);
    });

    test('abort stops dialing in-flight', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final probe = container.read(latencyProbeProvider.notifier);
      await probe.measureAll([
        ParsedNode(tag: 'a', outbound: {
          'type': 'vless',
          'server': '127.0.0.1',
          'server_port': server.port
        }),
      ], abort: () => true);
      final state = container.read(latencyProbeProvider);
      expect(state.measured('a'), isFalse); // skipped — never dialed
      expect(state.measuring, isEmpty);
    });

    test('multi-exit config reports the BEST reachable exit, not the first', () async {
      final live = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => live.close());
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = closed.port;
      await closed.close();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final probe = container.read(latencyProbeProvider.notifier);
      // DEAD exit listed FIRST, LIVE exit second → the chip must read the live one.
      await probe.measureAll([
        ParsedNode(tag: 'multi', outbound: const {}, config: {
          'outbounds': [
            {
              'tag': 'dead',
              'type': 'vless',
              'server': '127.0.0.1',
              'server_port': deadPort,
              'uuid': 'u'
            },
            {
              'tag': 'live',
              'type': 'vless',
              'server': '127.0.0.1',
              'server_port': live.port,
              'uuid': 'u'
            },
          ],
        }),
      ]);
      final state = container.read(latencyProbeProvider);
      expect(state.measured('multi'), isTrue);
      expect(state.results['multi'], isNotNull); // the live exit's latency
    });
  });
}
