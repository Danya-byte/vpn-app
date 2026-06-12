import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/censorship_facts.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// ② live ТСПУ-fact feed — the parse path is the trust boundary: a fetched feed
/// is untrusted DATA, so every field must be type-checked, clamped, and fall back
/// to the baked defaults. These lock that a hostile/garbage document can only
/// nudge within safe bounds (never inject a scheme/path into a routing rule, an
/// http probe, or an absurd threshold), and that a stale/replayed doc is a no-op.
void main() {
  group('CensorshipFacts.parse (clamp + per-field fallback)', () {
    test('a valid newer feed is parsed', () {
      final f = CensorshipFacts.parse(jsonEncode({
        'version': 5,
        'updated': '2026-06-01',
        'desyncDomains': ['youtube.com', 'rutube.ru'],
        'freezeProbeUrl': 'https://speed.example.com/__down?bytes=65536',
        'freezeThresholdKb': 48,
      }))!;
      expect(f.version, 5);
      expect(f.updated, '2026-06-01');
      expect(f.desyncDomains, ['youtube.com', 'rutube.ru']);
      expect(f.freezeProbeUrl, 'https://speed.example.com/__down?bytes=65536');
      expect(f.freezeThresholdKb, 48);
    });

    test('latestVersion is clamped to a digits+dots version (else dropped)', () {
      CensorshipFacts? withLatest(Object? v) => CensorshipFacts.parse(jsonEncode({
            'version': 6,
            'latestVersion': v,
          }));
      expect(withLatest('1.0.4')!.latestVersion, '1.0.4');
      expect(withLatest('2')!.latestVersion, '2');
      // anything that isn't a plain version is rejected (no string/URL smuggling)
      expect(withLatest('1.0.4; rm -rf')!.latestVersion, '');
      expect(withLatest('https://evil/x')!.latestVersion, '');
      expect(withLatest('latest')!.latestVersion, '');
      expect(withLatest(123)!.latestVersion, ''); // non-string
      expect(withLatest(null)!.latestVersion, '');
    });

    test('a not-newer version is ignored (replay/stale → null)', () {
      final body = jsonEncode({'version': 3, 'desyncDomains': ['a.com']});
      expect(CensorshipFacts.parse(body, haveVersion: 3), isNull);
      expect(CensorshipFacts.parse(body, haveVersion: 9), isNull);
      expect(CensorshipFacts.parse(body, haveVersion: 2), isNotNull);
    });

    test('non-JSON / non-object → null (never throws)', () {
      expect(CensorshipFacts.parse('not json {'), isNull);
      expect(CensorshipFacts.parse('[1,2,3]'), isNull);
      expect(CensorshipFacts.parse('"a string"'), isNull);
    });

    test('hostile domain entries are filtered (no scheme/path/wildcard/space)',
        () {
      final f = CensorshipFacts.parse(jsonEncode({
        'version': 1,
        'desyncDomains': [
          'good.com',
          'https://evil.com/path', // scheme + path
          '*.wild.com', // wildcard
          'has space.com', // space
          'UPPER.COM', // normalised to lower, kept
          'ok.sub.domain.io',
          42, // non-string
          '', // empty
        ],
      }))!;
      expect(f.desyncDomains, ['good.com', 'upper.com', 'ok.sub.domain.io']);
    });

    test('a non-HTTPS probe URL falls back to the baked default', () {
      final f = CensorshipFacts.parse(jsonEncode({
        'version': 1,
        'freezeProbeUrl': 'http://insecure.example.com/x', // not https
      }))!;
      expect(f.freezeProbeUrl, CensorshipFacts.defaults.freezeProbeUrl);
    });

    test('threshold is clamped to a sane KB window AND to the probe payload', () {
      // Default probe is 64KB → a high threshold is clamped to ~90% of it (57KB)
      // so the bulk-probe stays SATISFIABLE (no permanent false-freeze → no
      // endless transport hops). This is the anti-self-DoS clamp.
      expect(
          CensorshipFacts.parse(
                  jsonEncode({'version': 1, 'freezeThresholdKb': 999}))!
              .freezeThresholdKb,
          57);
      // A big probe lets the 256 KB ceiling apply.
      expect(
          CensorshipFacts.parse(jsonEncode({
            'version': 1,
            'freezeProbeUrl': 'https://speed.example.com/__down?bytes=10485760',
            'freezeThresholdKb': 999,
          }))!
              .freezeThresholdKb,
          256);
      expect(
          CensorshipFacts.parse(
                  jsonEncode({'version': 1, 'freezeThresholdKb': 1}))!
              .freezeThresholdKb,
          8);
    });

    test('an implausibly-large version is rejected (poison → no channel brick)',
        () {
      // An int64-max-ish poison would otherwise permanently win the monotonic
      // check and persist to the cache, bricking the data-push channel.
      expect(CensorshipFacts.parse(jsonEncode({'version': 99999999999999})),
          isNull);
      expect(CensorshipFacts.parse(jsonEncode({'version': 4102444800001})),
          isNull);
      // A small counter, a date (YYYYMMDD), and epoch-millis all still apply
      // (the ceiling admits real versioning schemes, just not a poison).
      expect(CensorshipFacts.parse(jsonEncode({'version': 7})), isNotNull);
      expect(CensorshipFacts.parse(jsonEncode({'version': 20260601})), isNotNull);
      expect(CensorshipFacts.parse(jsonEncode({'version': 1700000000000})),
          isNotNull);
    });

    test('missing/empty desyncDomains → baked defaults (never an empty list)',
        () {
      final f = CensorshipFacts.parse(jsonEncode({'version': 1}))!;
      expect(f.desyncDomains, CensorshipFacts.defaults.desyncDomains);
      final g = CensorshipFacts.parse(
          jsonEncode({'version': 1, 'desyncDomains': <String>[]}))!;
      expect(g.desyncDomains, CensorshipFacts.defaults.desyncDomains);
    });
  });

  group('CensorshipFacts.apply (engine wiring)', () {
    final savedDomains = SingBoxConfig.desyncDomains;
    final savedActive = CensorshipFacts.active;
    tearDown(() {
      SingBoxConfig.desyncDomains = savedDomains;
      CensorshipFacts.apply(savedActive); // restore so other tests are clean
      CensorshipFacts.active = savedActive;
    });

    test('apply pushes the desync list into SingBoxConfig', () {
      final f = CensorshipFacts.parse(jsonEncode({
        'version': 7,
        'desyncDomains': ['only-this.com'],
      }))!;
      CensorshipFacts.apply(f);
      expect(CensorshipFacts.active.version, 7);
      expect(SingBoxConfig.desyncDomains, ['only-this.com']);
    });
  });
}
