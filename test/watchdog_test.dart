import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/cascade.dart';

/// Safety-critical watchdog logic, extracted PURE so the failure modes the code
/// review flagged (#1 cascade-on-dead-network, #6 episode reset) are locked by
/// tests instead of living only in _checkHealth's imperative flow.
void main() {
  group('watchdogShouldClearEpisode (#6 episode reset)', () {
    test('clears ONLY on sustained recovery (≥3 healthy ticks) + active episode',
        () {
      expect(
          watchdogShouldClearEpisode(episodeActive: true, healthyStreak: 3),
          isTrue);
      expect(
          watchdogShouldClearEpisode(episodeActive: true, healthyStreak: 4),
          isTrue);
      // The first/second healthy tick must NOT clear — a family blocked early in
      // a wave stays tried until the wave demonstrably passed.
      expect(
          watchdogShouldClearEpisode(episodeActive: true, healthyStreak: 2),
          isFalse);
      expect(
          watchdogShouldClearEpisode(episodeActive: true, healthyStreak: 1),
          isFalse);
    });

    test('never clears when no dark episode is active', () {
      expect(
          watchdogShouldClearEpisode(episodeActive: false, healthyStreak: 99),
          isFalse);
    });
  });

  group('familyResistsFpCycling (skip a wasted fp-restart)', () {
    test('Reality + QUIC families resist fp/fragment/mux cycling', () {
      expect(familyResistsFpCycling('vless-reality'), isTrue);
      expect(familyResistsFpCycling('vmess-reality'), isTrue);
      expect(familyResistsFpCycling('trojan-reality'), isTrue);
      expect(familyResistsFpCycling('hysteria2'), isTrue);
      expect(familyResistsFpCycling('hysteria'), isTrue);
      expect(familyResistsFpCycling('tuic'), isTrue);
    });

    test('plain-TLS / TCP-transport families do NOT resist (fp can help)', () {
      expect(familyResistsFpCycling('vless-tls'), isFalse);
      expect(familyResistsFpCycling('vless-xhttp'), isFalse);
      expect(familyResistsFpCycling('vless-ws'), isFalse);
      expect(familyResistsFpCycling('trojan-tls'), isFalse);
      expect(familyResistsFpCycling(null), isFalse);
    });
  });

  group('runDarkPath (dark-episode ordering)', () {
    test('#1 GATE: network down → bail; cascade + foreign-probe NEVER run',
        () async {
      var hopped = false, foreignAsked = false;
      final action = await runDarkPath(
        networkUp: () async => false,
        foreignReachable: () async {
          foreignAsked = true;
          return true;
        },
        tryHop: () async {
          hopped = true;
          return true;
        },
        allDark: () => false,
        leafFamily: () async => 'vless-tls',
        variantsExhausted: false,
      );
      expect(action, DarkAction.networkDownBail);
      expect(hopped, isFalse,
          reason: 'a downed local network must not trigger a transport hop');
      expect(foreignAsked, isFalse,
          reason: 'network-down is decided before the foreign/whitelist probe');
    });

    test(
        'WHITELIST GATE: RU up but all foreign dark → whitelistMode, NO cascade',
        () async {
      var hopped = false;
      final action = await runDarkPath(
        networkUp: () async => true,
        foreignReachable: () async => false, // every foreign control IP dark
        tryHop: () async {
          hopped = true;
          return true;
        },
        allDark: () => false,
        leafFamily: () async => 'vless-tls',
        variantsExhausted: false,
      );
      expect(action, DarkAction.whitelistMode);
      expect(hopped, isFalse,
          reason: 'no foreign exit is reachable — hopping transports is futile');
    });

    test('foreign reachable (normal block) → proceeds to the cascade', () async {
      var hopped = false;
      final action = await runDarkPath(
        networkUp: () async => true,
        foreignReachable: () async => true, // foreign fine — the NODE is blocked
        tryHop: () async {
          hopped = true;
          return true;
        },
        allDark: () => false,
        leafFamily: () async => 'vless-tls',
        variantsExhausted: false,
      );
      expect(action, DarkAction.cascaded);
      expect(hopped, isTrue);
    });

    test('a successful hop short-circuits BEFORE any fp logic', () async {
      var leafAsked = false;
      final action = await runDarkPath(
        networkUp: () async => true,
        foreignReachable: () async => true,
        tryHop: () async => true,
        allDark: () => false,
        leafFamily: () async {
          leafAsked = true;
          return 'vless-tls';
        },
        variantsExhausted: false,
      );
      expect(action, DarkAction.cascaded);
      expect(leafAsked, isFalse, reason: 'no fp decision once a hop broke through');
    });

    test('all-dark (IP block) stops before an fp-restart', () async {
      final action = await runDarkPath(
        networkUp: () async => true,
        foreignReachable: () async => true,
        tryHop: () async => false,
        allDark: () => true,
        leafFamily: () async => 'vless-tls',
        variantsExhausted: false,
      );
      expect(action, DarkAction.stopIpBlock);
    });

    test('Reality/QUIC surviving leaf → stopFpNoop (no wasted restart)',
        () async {
      final action = await runDarkPath(
        networkUp: () async => true,
        foreignReachable: () async => true,
        tryHop: () async => false,
        allDark: () => false,
        leafFamily: () async => 'vless-reality',
        variantsExhausted: false,
      );
      expect(action, DarkAction.stopFpNoop);
    });

    test('plain-TLS leaf with variants left → fpEscalate', () async {
      final action = await runDarkPath(
        networkUp: () async => true,
        foreignReachable: () async => true,
        tryHop: () async => false,
        allDark: () => false,
        leafFamily: () async => 'vless-tls',
        variantsExhausted: false,
      );
      expect(action, DarkAction.fpEscalate);
    });

    test('plain-TLS leaf but every variant exhausted → stopExhausted', () async {
      final action = await runDarkPath(
        networkUp: () async => true,
        foreignReachable: () async => true,
        tryHop: () async => false,
        allDark: () => false,
        leafFamily: () async => 'vless-tls',
        variantsExhausted: true,
      );
      expect(action, DarkAction.stopExhausted);
    });
  });

  group('decideFreeze (16KB connection-freeze, healthy-branch watch)', () {
    test('bulk flows → none (genuinely healthy), whatever the counter', () {
      expect(decideFreeze(bulkOk: true, freezeFails: 0), FreezeAction.none);
      expect(decideFreeze(bulkOk: true, freezeFails: 9), FreezeAction.none);
    });

    test('a single bulk stall does NOT act (debounce ≥2)', () {
      expect(decideFreeze(bulkOk: false, freezeFails: 1), FreezeAction.none);
    });

    test('sustained stall → hop off the long TLS stream (XHTTP/QUIC)', () {
      // Battle-tested: reshaping a flow-mandating Reality node breaks it, so the
      // remedy is a transport hop, not a same-node reshape.
      expect(decideFreeze(bulkOk: false, freezeFails: 2), FreezeAction.hop);
      expect(decideFreeze(bulkOk: false, freezeFails: 5), FreezeAction.hop);
    });
  });
}
