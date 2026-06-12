import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/route_rule.dart';

/// Locks the custom-rule validator (the single source of truth shared by the
/// Settings editor AND the config emitter). The audit found the old loose regex
/// let typo'd CIDRs through → they reached the core → FATAL → the whole tunnel
/// failed to start. These cases must now be rejected BEFORE emission.
void main() {
  group('RouteRule.isValidValue — IP/CIDR', () {
    test('accepts real IPv4/IPv6 and CIDRs', () {
      for (final v in [
        '1.2.3.4',
        '1.2.3.4/24',
        '10.0.0.0/8',
        '0.0.0.0/0',
        '255.255.255.255/32',
        '2001:db8::/32',
        '::1',
        'fe80::1/64',
      ]) {
        expect(RouteRule.isValidValue(RuleField.ipCidr, v), isTrue, reason: v);
      }
    });

    test('rejects typos the old regex passed (would FATAL the core)', () {
      for (final v in [
        '1.2.3.4/33', // prefix > 32
        '1.2.3.4/999',
        '1.2.3.4/-1',
        '1.2.3', // 3 octets
        '1.2.3.4.5', // 5 octets
        '999.999.999.999',
        '256.1.1.1',
        '01.02.03.04', // leading-zero octets — Go's netip.ParseAddr FATALs on these
        '1.2.3.04',
        '+1.2.3.4', // leading-sign octet — int.tryParse('+1')==1 slipped through, Go FATALs
        '1.2.3.+4',
        '-1.2.3.4',
        '+1.2.3.4/24',
        '1.2.3.4/01', // leading-zero prefix bits — netip.ParsePrefix FATALs
        '1.2.3.4/00',
        '1.2.3.4/ 24', // whitespace in the prefix
        '2001:db8::/032',
        'deadbeef',
        'ffff.ffff',
        'a',
        '.',
        '',
      ]) {
        expect(RouteRule.isValidValue(RuleField.ipCidr, v), isFalse, reason: v);
      }
    });
  });

  group('RouteRule.isValidValue — host', () {
    test('accepts real domains, any case', () {
      for (final v in [
        'openai.com',
        'OpenAI.COM',
        'a.b.c.example.co.uk',
        'sub-domain.example.com',
      ]) {
        expect(RouteRule.isValidValue(RuleField.domainSuffix, v), isTrue,
            reason: v);
      }
    });

    test('rejects shapes the core would silently never match', () {
      for (final v in [
        'localhost', // no dot
        '*.openai.com', // wildcard
        'https://x.com', // scheme
        'x.com/path', // path
        'has space.com',
        'under_score.com',
        '',
      ]) {
        expect(RouteRule.isValidValue(RuleField.domain, v), isFalse, reason: v);
      }
    });
  });

  test('cleanValue lowercases hosts, preserves IPs, strips control chars', () {
    expect(RouteRule.cleanValue(RuleField.domain, '  OpenAI.COM\n'),
        'openai.com');
    expect(RouteRule.cleanValue(RuleField.ipCidr, ' 1.2.3.4/24 '), '1.2.3.4/24');
  });

  group('RouteRule.fromJson — store-wipe guard', () {
    test('a non-String value returns null, NEVER throws', () {
      // The wipe bug: `value as String?` threw a TypeError on a numeric value,
      // which bubbled through SettingsController.build()'s catch and reset EVERY
      // setting. One bad rule must drop to null, not nuke the store.
      for (final bad in <Object?>[
        {'field': 'domain', 'value': 42, 'action': 'proxy'},
        {'field': 'domain', 'value': true, 'action': 'block'},
        {'field': 'ipCidr', 'value': ['1.2.3.4'], 'action': 'direct'},
        {'field': 'domain', 'value': null, 'action': 'proxy'},
        {'field': 'domain', 'action': 'proxy'}, // value missing
        'not even a map',
        42,
      ]) {
        expect(() => RouteRule.fromJson(bad), returnsNormally, reason: '$bad');
        expect(RouteRule.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('unknown enum field/action returns null (forward-compat)', () {
      expect(
          RouteRule.fromJson(
              {'field': 'regexHost', 'value': 'x.com', 'action': 'proxy'}),
          isNull);
      expect(
          RouteRule.fromJson(
              {'field': 'domain', 'value': 'x.com', 'action': 'tproxy'}),
          isNull);
    });

    test('valid entry round-trips and is normalised on load', () {
      final r = RouteRule.fromJson(
          {'field': 'domain', 'value': '  OpenAI.COM ', 'action': 'proxy'})!;
      expect(r.field, RuleField.domain);
      expect(r.action, RuleAction.proxy);
      expect(r.value, 'openai.com'); // cleanValue applied → matches the editor
    });
  });
}
