import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/cascade.dart';
import 'package:vpn_app/core/clash_api.dart';

/// H5 auto-vector: the UNATTENDED watchdog cascade (and the auto-failover pool it
/// hops within) must NEVER silently route through a cert-unvalidated (MITM-able)
/// node — that is exactly the silent interception the manual H5 consent gate
/// prevents. Locks insecureTagsFromConfig + the planCascade insecure-exclusion.
void main() {
  group('insecureTagsFromConfig', () {
    test('flags tls.insecure leaves, NOT Reality / hysteria2 / tuic', () {
      final cfg = {
        'outbounds': [
          {
            'tag': 'plain-insecure',
            'type': 'vless',
            'tls': {'insecure': true},
          },
          {
            'tag': 'reality', // self-authenticates via pinned key → not a hole
            'type': 'vless',
            'tls': {
              'insecure': true,
              'reality': {'enabled': true},
            },
          },
          {
            'tag': 'hy2', // PSK-authed → insecure is its norm, excluded
            'type': 'hysteria2',
            'tls': {'insecure': true},
          },
          {
            'tag': 'tuic',
            'type': 'tuic',
            'tls': {'insecure': true},
          },
          {
            'tag': 'secure',
            'type': 'vless',
            'tls': {'insecure': false},
          },
        ],
      };
      final ins = insecureTagsFromConfig(cfg);
      expect(ins, contains('plain-insecure'));
      expect(ins, isNot(contains('reality')));
      expect(ins, isNot(contains('hy2')));
      expect(ins, isNot(contains('tuic')));
      expect(ins, isNot(contains('secure')));
    });
  });

  group('planCascade excludes insecure candidates (H5)', () {
    // Top selector over: a Reality leaf (current/dark) + a plain-insecure leaf +
    // a secure Hysteria2 leaf. The cascade may hop to hy2 but NEVER to insecure.
    final groups = [
      ProxyGroup(
          name: 'VPN',
          type: 'Selector',
          now: 'reality',
          all: const ['reality', 'insecure-tls', 'hy2']),
      ProxyGroup(name: 'reality', type: 'Vless', now: null, all: const []),
      ProxyGroup(name: 'insecure-tls', type: 'Vless', now: null, all: const []),
      ProxyGroup(name: 'hy2', type: 'Hysteria2', now: null, all: const []),
    ];
    const families = {
      'reality': 'vless-reality',
      'insecure-tls': 'vless-tls',
      'hy2': 'hysteria2',
    };

    test('an insecure leaf is never a cascade candidate', () {
      final plan = planCascade(groups, <String>{},
          families: families, insecure: {'insecure-tls'});
      expect(plan.candidates, contains('hy2'));
      expect(plan.candidates, isNot(contains('insecure-tls')),
          reason: 'the unattended cascade must not hop onto a MITM-able node');
    });

    test('WITHOUT the insecure set it would be a candidate (guard really bites)',
        () {
      final plan = planCascade(groups, <String>{}, families: families);
      expect(plan.candidates, contains('insecure-tls'));
    });
  });
}
