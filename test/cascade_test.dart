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

  test('freezeContext: a freeze-hop prefers the immune transport in the same tier',
      () {
    // Current leaf = plain vless-tls (tier 1). Two tier-3 candidates: a Reality
    // (freeze-VULNERABLE TCP-TLS) and an XHTTP (freeze-IMMUNE). Under a freeze the
    // hop must land on XHTTP, not another frozen Reality+Vision stream.
    final groups = [
      g('VPN', 'Selector', now: 'n-tls', all: ['n-tls', 'n-reality', 'n-xhttp']),
      g('n-tls', 'Vless'),
      g('n-reality', 'Vless'),
      g('n-xhttp', 'Socks'),
    ];
    final fams = {
      'n-tls': 'vless-tls',
      'n-reality': 'vless-reality',
      'n-xhttp': 'vless-xhttp',
    };
    final frozen = planCascade(groups, {}, families: fams, freezeContext: true);
    expect(frozen.candidates.first, 'n-xhttp'); // immune first under freeze
    // Both are tier-3 survivors regardless; freezeImmune separates them.
    expect(freezeImmune('vless-xhttp'), isTrue);
    expect(freezeImmune('vless-reality'), isFalse);
    expect(freezeImmune('hysteria2'), isTrue);
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

  // ── RF-2026 transport survivability (Dec-2025 protocol-block intel) ───────
  group('transportSurvivability', () {
    test('verified survivors (reality / xhttp / QUIC) are the top tier', () {
      for (final f in [
        'vless-reality',
        'vless-xhttp',
        'hysteria2',
        'tuic',
        'hysteria'
      ]) {
        expect(transportSurvivability(f), 3, reason: f);
      }
    });
    test('obfuscated/wrapped (non-VLESS) transports are mid tier', () {
      for (final f in ['shadowtls', 'anytls', 'trojan-grpc', 'vmess-ws']) {
        expect(transportSurvivability(f), 2, reason: f);
      }
    });
    test('ALL plain VLESS is low tier — ws/grpc wrapper does NOT mask the '
        'Dec-2025 signature (only reality/xhttp survive)', () {
      expect(transportSurvivability('vless-tls'), 1);
      expect(transportSurvivability('vless-ws'), 1); // was wrongly tier-2
      expect(transportSurvivability('vless-grpc'), 1); // was wrongly tier-2
      expect(transportSurvivability('vless-httpupgrade'), 1);
      expect(transportSurvivability('trojan-tls'), 1);
      expect(transportSurvivability(null), 1);
      // …but the masked VLESS forms stay top-tier survivors:
      expect(transportSurvivability('vless-reality'), 3);
      expect(transportSurvivability('vless-xhttp'), 3);
    });
    test('detected-by-design transports are the bottom tier', () {
      for (final f in ['wireguard', 'shadowsocks', 'socks', 'http']) {
        expect(transportSurvivability(f), 0, reason: f);
      }
    });
    test('obfuscated WG/SS are NOT bottom-tier (no false "widely blocked")', () {
      // AmneziaWG + plugin-SS evade DPI, unlike their plain forms → tier 2.
      expect(transportSurvivability('amneziawg'), 2);
      expect(transportSurvivability('shadowsocks-plugin'), 2);
      expect(transportWidelyBlocked('amneziawg'), isFalse);
      expect(transportWidelyBlocked('shadowsocks-plugin'), isFalse);
      // Plain forms are still flagged.
      expect(transportWidelyBlocked('wireguard'), isTrue);
      expect(transportWidelyBlocked('shadowsocks'), isTrue);
    });
    test('familiesFromConfig splits obfuscated WG/SS from plain', () {
      final fams = familiesFromConfig({
        'outbounds': [
          {'tag': 'wg-plain', 'type': 'wireguard'},
          {'tag': 'wg-amnezia', 'type': 'wireguard', '_amneziawg': {'jc': 4}},
          {'tag': 'ss-plain', 'type': 'shadowsocks'},
          {'tag': 'ss-obfs', 'type': 'shadowsocks', 'plugin': 'obfs-local'},
        ],
      });
      expect(fams['wg-plain'], 'wireguard');
      expect(fams['wg-amnezia'], 'amneziawg');
      expect(fams['ss-plain'], 'shadowsocks');
      expect(fams['ss-obfs'], 'shadowsocks-plugin');
    });
    test('transportWidelyBlocked flags the dead transports + plain VLESS', () {
      expect(transportWidelyBlocked('wireguard'), isTrue);
      expect(transportWidelyBlocked('shadowsocks'), isTrue);
      expect(transportWidelyBlocked('vless-tls'), isTrue); // VLESS signature target
      expect(transportWidelyBlocked('vless-ws'), isTrue); // bare VLESS, any wrapper
      expect(transportWidelyBlocked('vless-grpc'), isTrue);
      expect(transportWidelyBlocked('vless-reality'), isFalse);
      expect(transportWidelyBlocked('vless-xhttp'), isFalse);
      expect(transportWidelyBlocked('hysteria2'), isFalse);
      expect(transportWidelyBlocked(null), isFalse);
    });
  });

  test('cascade orders by survivability first: XHTTP beats plain VLESS+TLS at '
      'the same physical layer', () {
    // Active leaf is QUIC (Hysteria2). Both candidates are TCP, so the L4-diversity
    // tiebreak is a wash — survivability decides: XHTTP (verified survivor) must
    // come before plain VLESS+TLS (now signature-blocked).
    final groups = [
      g('VPN', 'Selector', now: 'h1', all: ['h1', 'n-xhttp', 'n-tls']),
      g('h1', 'Hysteria2'),
      g('n-xhttp', 'Vless'),
      g('n-tls', 'Vless'),
    ];
    final fams = {
      'h1': 'hysteria2',
      'n-xhttp': 'vless-xhttp',
      'n-tls': 'vless-tls',
    };
    final plan = planCascade(groups, {}, families: fams);
    expect(plan.candidates, ['n-xhttp', 'n-tls']);
  });
}
