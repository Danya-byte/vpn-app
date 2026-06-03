import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/cascade.dart';
import 'package:vpn_app/core/clash_api.dart';

/// Safety-critical: the transport-cascade decision (planCascade) is PURE, so its
/// failure modes are unit-tested here (a bug = stuck-in-the-dark or a wrong hop).
ProxyGroup g(String name, String type, {String? now, List<String> all = const []}) =>
    ProxyGroup(name: name, type: type, now: now, all: all);

void main() {
  // A realistic multi-family config: VPN selector → Auto urltest → nodes, with
  // three transport families (VLESS/TCP, Hysteria2/QUIC, SOCKS/bridged).
  List<ProxyGroup> config({String selNow = 'Auto'}) => [
        g('GLOBAL', 'Fallback', now: 'VPN', all: ['VPN']),
        g('VPN', 'Selector', now: selNow,
            all: ['Auto', 'n-vless', 'n-hy2', 'n-socks']),
        g('Auto', 'URLTest', now: 'n-vless', all: ['n-vless', 'n-hy2', 'n-socks']),
        g('n-vless', 'VLESS'),
        g('n-hy2', 'Hysteria2'),
        g('n-socks', 'SOCKS'),
      ];

  test('resolves the leaf through nested selector→urltest→node', () {
    final plan = planCascade(config(), {});
    expect(plan.selector, 'VPN');
    expect(plan.leaf, 'n-vless'); // VPN→Auto(urltest)→n-vless
    expect(plan.leafType, 'VLESS');
  });

  test('orders candidates by PHYSICAL-LAYER diversity (QUIC before TCP)', () {
    // Current leaf is VLESS (TCP). A TCP wave kills TCP, so the QUIC family must
    // come first — n-hy2 (Hysteria2/QUIC) before n-socks (TCP-ish).
    final plan = planCascade(config(), {});
    expect(plan.candidates, ['n-hy2', 'n-socks']);
  });

  test('excludes the current family AND already-tried families', () {
    // Hysteria2 already tried this episode → only the SOCKS node remains.
    final plan = planCascade(config(), {'Hysteria2'});
    expect(plan.candidates, ['n-socks']);
    // The current VLESS leaf is never a candidate (it's the dark one).
    expect(plan.candidates.contains('n-vless'), isFalse);
  });

  test('dead-end (all members same family as current) → no candidates', () {
    // IP/server-block shape: the selector only has same-family nodes left.
    final plan = planCascade([
      g('VPN', 'Selector', now: 'a', all: ['a', 'b']),
      g('a', 'VLESS'),
      g('b', 'VLESS'),
    ], {});
    expect(plan.selector, 'VPN');
    expect(plan.candidates, isEmpty); // → caller flags _allTransportsDark / IP-block
  });

  test('no switchable Selector → empty plan (cascade cannot run)', () {
    // A urltest-only config (no manual Selector) can't be PUT — nothing to hop.
    final plan = planCascade([
      g('GLOBAL', 'Fallback', now: 'Auto', all: ['Auto']),
      g('Auto', 'URLTest', now: 'n1', all: ['n1', 'n2']),
      g('n1', 'VLESS'),
      g('n2', 'Hysteria2'),
    ], {});
    expect(plan.selector, isNull);
    expect(plan.candidates, isEmpty);
  });

  test('GLOBAL is never chosen as the top selector', () {
    final plan = planCascade(config(), {});
    expect(plan.selector, isNot('GLOBAL'));
  });

  test('a single-member selector is not cascaded', () {
    final plan = planCascade([
      g('VPN', 'Selector', now: 'only', all: ['only']),
      g('only', 'VLESS'),
    ], {});
    expect(plan.selector, isNull); // < 2 members → nothing to hop to
  });

  // ── Review finding A: refined family classification ──────────────────────
  test('finding A: refined families split Reality from plain-TLS VLESS', () {
    // Two VLESS nodes — SAME Clash type, DIFFERENT signature. Active leaf is the
    // plain-TLS one; the cascade must be willing to hop to Reality. Keying on the
    // raw type alone wrongly merges them and refuses the hop.
    final groups = [
      g('VPN', 'Selector', now: 'n-tls', all: ['n-tls', 'n-reality']),
      g('n-tls', 'Vless'),
      g('n-reality', 'Vless'),
    ];
    final fams = {'n-tls': 'vless-tls', 'n-reality': 'vless-reality'};
    final plan = planCascade(groups, {}, families: fams);
    expect(plan.leafType, 'vless-tls');
    expect(plan.candidates, ['n-reality']); // hops ACROSS the signature
    // Without the map both read as 'Vless' → one family → no hop (the old bug).
    expect(planCascade(groups, {}).candidates, isEmpty);
  });

  test('finding A: bridged XHTTP (vless-xhttp) is distinct from a real socks', () {
    // Both surface as Clash-type 'Socks' (XHTTP rides the xray bridge), but the
    // PRE-bridge family map keeps them distinct so the cascade can still hop.
    final groups = [
      g('VPN', 'Selector', now: 'n-xhttp', all: ['n-xhttp', 'n-socks']),
      g('n-xhttp', 'Socks'),
      g('n-socks', 'Socks'),
    ];
    final fams = {'n-xhttp': 'vless-xhttp', 'n-socks': 'socks'};
    final plan = planCascade(groups, {}, families: fams);
    expect(plan.leafType, 'vless-xhttp');
    expect(plan.candidates, ['n-socks']);
  });

  // ── Review finding B: cascade across single-transport POOLS (sub-groups) ──
  test('finding B: a sub-group pool is a candidate (PUT by name, probed at leaf)',
      () {
    // Selector[ Reality-pool(urltest), Hy2-pool(urltest) ] — the structure for
    // multi-node-per-transport failover. Leaf drills into the Reality pool; the
    // Hy2 POOL (a group) must be a candidate — selectable by group name, but its
    // /delay must target a concrete leaf node.
    final groups = [
      g('VPN', 'Selector', now: 'Reality', all: ['Reality', 'Hy2']),
      g('Reality', 'URLTest', now: 'r1', all: ['r1', 'r2']),
      g('Hy2', 'URLTest', now: 'h1', all: ['h1', 'h2']),
      g('r1', 'Vless'),
      g('r2', 'Vless'),
      g('h1', 'Hysteria2'),
      g('h2', 'Hysteria2'),
    ];
    final fams = {
      'r1': 'vless-reality',
      'r2': 'vless-reality',
      'h1': 'hysteria2',
      'h2': 'hysteria2',
    };
    final plan = planCascade(groups, {}, families: fams);
    expect(plan.selector, 'VPN');
    expect(plan.leaf, 'r1'); // VPN → Reality(urltest) → r1
    expect(plan.leafType, 'vless-reality');
    expect(plan.candidates, ['Hy2']); // the POOL itself is the selectable hop
    expect(plan.probeFor('Hy2'), 'h1'); // but probe a concrete node in it
  });

  // ── familiesFromConfig: the pre-bridge classifier feeding finding A ───────
  group('familiesFromConfig', () {
    test('refines vless by reality / transport / plain-tls; types stand alone',
        () {
      final cfg = {
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'reality',
            'tls': {
              'enabled': true,
              'reality': {'enabled': true}
            }
          },
          {
            'type': 'vless',
            'tag': 'xhttp',
            'tls': {'enabled': true},
            'transport': {'type': 'xhttp'}
          },
          {
            'type': 'vless',
            'tag': 'plain',
            'tls': {'enabled': true}
          },
          {'type': 'hysteria2', 'tag': 'hy2'},
          {'type': 'tuic', 'tag': 'tuic'},
          {
            'type': 'selector',
            'tag': 'VPN',
            'outbounds': ['reality', 'hy2']
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'endpoints': [
          {'type': 'wireguard', 'tag': 'wg'},
        ],
      };
      final fams = familiesFromConfig(cfg);
      expect(fams['reality'], 'vless-reality');
      expect(fams['xhttp'], 'vless-xhttp');
      expect(fams['plain'], 'vless-tls');
      expect(fams['hy2'], 'hysteria2');
      expect(fams['tuic'], 'tuic');
      expect(fams['wg'], 'wireguard');
      expect(fams.containsKey('VPN'), isFalse); // selector — not a proxy leaf
      expect(fams.containsKey('direct'), isFalse); // direct — not a proxy leaf
    });

    test('reality:{enabled:false} is NOT treated as Reality', () {
      final cfg = {
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'v',
            'tls': {
              'reality': {'enabled': false}
            }
          },
        ]
      };
      expect(familiesFromConfig(cfg)['v'], 'vless-tls');
    });
  });
}
