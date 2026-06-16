import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/cascade.dart';
import 'package:vpn_app/core/clash_api.dart';
import 'package:vpn_app/core/desync_config.dart';

ProxyGroup g(String name, String type,
        {String? now, List<String> all = const []}) =>
    ProxyGroup(name: name, type: type, now: now, all: all);

void main() {
  group('① learned network memory', () {
    test('transportScoreAfter EWMA: survive rises, fail falls, neutral start', () {
      // A fresh family starts neutral; one outcome nudges it.
      expect(transportScoreAfter(null, true), greaterThan(0.5)); // 0.7
      expect(transportScoreAfter(null, false), lessThan(0.5)); // 0.3
      // Repeated outcomes converge toward 1 / 0.
      expect(transportScoreAfter(0.7, true), greaterThan(0.7));
      expect(transportScoreAfter(0.7, false), lessThan(0.7));
    });

    test('planCascade orders a same-tier family by learned score', () {
      // VLESS leaf is dark; both candidates are tier-3 QUIC (Hy2 + TUIC), so the
      // baked tier can't separate them — the LEARNED score must.
      List<ProxyGroup> twoQuic() => [
            g('VPN', 'Selector',
                now: 'n-vless', all: ['n-vless', 'n-hy2', 'n-tuic']),
            g('n-vless', 'VLESS'),
            g('n-hy2', 'Hysteria2'),
            g('n-tuic', 'Tuic'),
          ];
      // No scores → input order (both QUIC, L4-tie).
      expect(planCascade(twoQuic(), {}).candidates, ['n-hy2', 'n-tuic']);
      // TUIC has survived more on this network lately → it leads.
      expect(
          planCascade(twoQuic(), {},
              scores: {'Tuic': 0.9, 'Hysteria2': 0.2}).candidates,
          ['n-tuic', 'n-hy2']);
    });

    test('learned score NEVER demotes a survivor below a lower tier', () {
      // Even a high score on the tier-0 SOCKS node must not jump it ahead of the
      // tier-3 Hysteria2 — tier dominates, score only tie-breaks within a tier.
      final plan = planCascade([
        g('VPN', 'Selector', now: 'n-vless', all: ['n-vless', 'n-hy2', 'n-socks']),
        g('n-vless', 'VLESS'),
        g('n-hy2', 'Hysteria2'),
        g('n-socks', 'SOCKS'),
      ], {}, scores: {'SOCKS': 0.99, 'Hysteria2': 0.1});
      expect(plan.candidates.first, 'n-hy2'); // tier-3 still leads
    });
  });

  group('② desync strategy cascade', () {
    test('nextStrategy walks the untried presets, then exhausts', () {
      expect(DesyncConfig.nextStrategy({}), 'fake_split');
      expect(DesyncConfig.nextStrategy({'fake_split'}), 'fake_disorder');
      expect(DesyncConfig.nextStrategy({'fake_split', 'fake_disorder'}), 'split');
      expect(
          DesyncConfig.nextStrategy(
              {'fake_split', 'fake_disorder', 'split'}),
          isNull);
    });
  });

  group('④ SNI / front rotation', () {
    test('nextFront skips current + tried, then exhausts', () {
      expect(nextFront('a', ['a', 'b', 'c'], {}), 'b');
      expect(nextFront('a', ['a', 'b', 'c'], {'b'}), 'c');
      expect(nextFront('a', ['a', 'b'], {'b'}), isNull);
    });

    test('decoySnis are RU-safe never-blocked hosts', () {
      expect(decoySnis, contains('gosuslugi.ru'));
      expect(decoySnis.length, greaterThan(2));
    });

    test('winwsArgs rotates the fake-TLS decoy SNI when given', () {
      final base = DesyncConfig.winwsArgs(hostlistPath: 'h.txt').join(' ');
      expect(base, contains('sni=gosuslugi.ru')); // baked default decoy
      final rot = DesyncConfig.winwsArgs(hostlistPath: 'h.txt', decoySni: 'vk.com')
          .join(' ');
      expect(rot, contains('sni=vk.com'));
      expect(rot, isNot(contains('sni=gosuslugi.ru')));
    });

    test('winwsArgs injects a decoy SNI into a fake preset that lacks one', () {
      // fake_disorder has a `fake` packet but no sni= — the decoy must be ADDED
      // (was a silent no-op before), so the ④ rotation has on-wire effect.
      final rot = DesyncConfig.winwsArgs(
              hostlistPath: 'h.txt', strategy: 'fake_disorder', decoySni: 'mail.ru')
          .join(' ');
      expect(rot, contains('sni=mail.ru'));
    });
  });
}
