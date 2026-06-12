import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/singbox_config.dart';
import 'package:vpn_app/core/xray_config.dart';

/// The xray bridge (XHTTP/SplitHTTP) now relays the server's `extra` split-tuning
/// blob faithfully instead of dropping it — so the server's sub-16KB-freeze tuning
/// actually applies. Verified config-valid against the real xray binary separately
/// (`xray run -test` → "Configuration OK"); this locks the parse→emit wiring.
void main() {
  test('XHTTP extra (sc*/xPadding) survives parse → xray bridge', () {
    const extra =
        '{"scMaxEachPostBytes":15000,"scMinPostsIntervalMs":30,"xPaddingBytes":"100-1000"}';
    final link = 'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443'
        '?security=tls&sni=a.com&type=xhttp&mode=packet-up&path=%2Fx'
        '&extra=${Uri.encodeQueryComponent(extra)}#n';
    final node = ShareLink.parse(link)!;
    final ob = node.outbound;
    final tr = ob['transport'] as Map;
    expect(tr['type'], 'xhttp');
    expect(tr['mode'], 'packet-up');
    expect((tr['extra'] as Map)['scMaxEachPostBytes'], 15000);

    expect(XrayConfig.needsXray(ob), isTrue);
    final x = ((XrayConfig.fromOutbound(ob, 24100)!['outbounds'] as List).first
        as Map)['streamSettings']['xhttpSettings'] as Map;
    expect(x['mode'], 'packet-up'); // link mode wins
    expect(x['path'], '/x');
    expect(x['scMaxEachPostBytes'], 15000); // server tuning relayed
    expect(x['scMinPostsIntervalMs'], 30);
    expect(x['xPaddingBytes'], '100-1000');
  });

  test('XHTTP without extra still works (back-compat, xray defaults)', () {
    final node = ShareLink.parse(
        'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=tls&sni=a.com&type=xhttp&mode=auto#n')!;
    final ob = node.outbound;
    expect((ob['transport'] as Map).containsKey('extra'), isFalse);
    final x = ((XrayConfig.fromOutbound(ob, 24100)!['outbounds'] as List).first
        as Map)['streamSettings']['xhttpSettings'] as Map;
    expect(x['mode'], 'auto');
    expect(x.containsKey('scMaxEachPostBytes'), isFalse);
  });

  test('malformed extra is ignored, not fatal', () {
    final link = 'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443'
        '?security=tls&sni=a.com&type=xhttp&extra=${Uri.encodeQueryComponent("not json")}#n';
    final ob = ShareLink.parse(link)!.outbound;
    expect((ob['transport'] as Map).containsKey('extra'), isFalse);
  });

  // When xray REJECTS a generated bridge config (e.g. a wrong-typed `extra` that
  // makes `xray run -test` exit 23), CoreController must NOT leave the original
  // `type: xhttp` outbound (sing-box FATALs on it → kills the WHOLE config) nor
  // point a socks outbound at a dead port (silent-dead node). It drops the member
  // via [SingBoxConfig.pruneDeadOutbounds] and either runs the surviving pool or
  // surfaces a precise error. These lock the pool-safety of that failure path.
  group('pruneDeadOutbounds (xray bridge failure path)', () {
    Map<String, dynamic> pool() => <String, dynamic>{
          'outbounds': [
            {
              'type': 'vless',
              'tag': 'reality',
              'tls': {
                'reality': {'enabled': true}
              }
            },
            {
              'type': 'vless',
              'tag': 'xh',
              'transport': {'type': 'xhttp'}
            },
            {
              'type': 'urltest',
              'tag': 'auto',
              'outbounds': ['reality', 'xh']
            },
            {
              'type': 'selector',
              'tag': 'select',
              'outbounds': ['auto', 'reality', 'xh'],
              'default': 'auto'
            },
            {'type': 'direct', 'tag': 'direct'},
          ],
          'route': {'final': 'select'},
        };

    test('drops a dead member, keeps the rest of the pool (survives)', () {
      final cfg = pool();
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'xh'});
      expect(ok, isTrue);
      final outs = cfg['outbounds'] as List;
      expect(outs.any((o) => o['tag'] == 'xh'), isFalse); // dropped
      expect(outs.any((o) => o['tag'] == 'reality'), isTrue); // kept
      final auto = outs.firstWhere((o) => o['tag'] == 'auto');
      expect(auto['outbounds'], ['reality']); // scrubbed from the urltest
      final sel = outs.firstWhere((o) => o['tag'] == 'select');
      expect((sel['outbounds'] as List).contains('xh'), isFalse);
      expect((cfg['route'] as Map)['final'], 'select'); // still resolves
    });

    test('single dead leaf pinned as route.final → no survivor (caller errors)',
        () {
      final cfg = <String, dynamic>{
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'xh',
            'transport': {'type': 'xhttp'}
          },
          {'type': 'direct', 'tag': 'direct'},
          {'type': 'dns', 'tag': 'dns-out'},
        ],
        'route': {'final': 'xh'},
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'xh'});
      expect(ok, isFalse); // only direct/dns left = no exit
      // a dangling final would default to `direct` (everything direct = leak) —
      // it's removed and the false verdict makes the caller refuse to launch.
      expect((cfg['route'] as Map).containsKey('final'), isFalse);
    });

    test('cascades empty groups: every member dead → groups removed → no survivor',
        () {
      final cfg = <String, dynamic>{
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'x1',
            'transport': {'type': 'xhttp'}
          },
          {
            'type': 'vless',
            'tag': 'x2',
            'transport': {'type': 'xhttp'}
          },
          {
            'type': 'urltest',
            'tag': 'auto',
            'outbounds': ['x1', 'x2']
          },
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['auto', 'x1', 'x2'],
            'default': 'auto'
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {'final': 'select'},
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'x1', 'x2'});
      expect(ok, isFalse);
      final outs = cfg['outbounds'] as List;
      expect(outs.any((o) => o['type'] == 'urltest'), isFalse); // emptied → gone
      expect(outs.any((o) => o['type'] == 'selector'), isFalse); // cascaded → gone
      expect((cfg['route'] as Map).containsKey('final'), isFalse);
    });

    test('a successfully-bridged socks sibling counts as a surviving proxy', () {
      // one xhttp already rewritten to socks by the bridge, the other failed.
      final cfg = <String, dynamic>{
        'outbounds': [
          {
            'type': 'socks',
            'tag': 'x1',
            'server': '127.0.0.1',
            'server_port': 24100
          },
          {
            'type': 'vless',
            'tag': 'x2',
            'transport': {'type': 'xhttp'}
          },
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['x1', 'x2']
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {'final': 'select'},
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'x2'});
      expect(ok, isTrue);
      final sel =
          (cfg['outbounds'] as List).firstWhere((o) => o['tag'] == 'select');
      expect(sel['outbounds'], ['x1']); // x2 scrubbed, socks survivor kept
    });

    test('re-pins route.rules[].outbound off a dropped leaf (no FATAL dangle)', () {
      // route.final AND route rules (an always-injected Telegram rule, a custom /
      // force-VPN rule) all point at the xhttp leaf 'xh'; the bridge fails it while
      // 'reality' survives. The re-pin must fix BOTH — a rule still pointing at the
      // dropped tag passes `sing-box check` but FATALs the core at service-start.
      final cfg = <String, dynamic>{
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'reality',
            'tls': {
              'reality': {'enabled': true}
            }
          },
          {
            'type': 'vless',
            'tag': 'xh',
            'transport': {'type': 'xhttp'}
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'rules': [
            {'ip_is_private': true, 'outbound': 'direct'}, // untouched
            {
              'ip_cidr': ['149.154.160.0/20'],
              'outbound': 'xh'
            }, // Telegram-style
            {
              'domain_suffix': ['example.com'],
              'outbound': 'xh'
            }, // custom / force
          ],
          'final': 'xh',
        },
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'xh'});
      expect(ok, isTrue);
      final route = cfg['route'] as Map;
      expect(route['final'], 'reality'); // re-pinned
      final rules = (route['rules'] as List).cast<Map>();
      expect(rules.any((r) => r['outbound'] == 'xh'), isFalse); // none dangle
      expect(rules.firstWhere((r) => r['ip_is_private'] == true)['outbound'],
          'direct'); // direct rule untouched
      expect(rules.where((r) => r['outbound'] == 'reality').length, 2); // ride survivor
    });

    test('drops a route rule pinned to a dropped leaf when NO exit survives', () {
      final cfg = <String, dynamic>{
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'xh',
            'transport': {'type': 'xhttp'}
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'rules': [
            {
              'domain_suffix': ['example.com'],
              'outbound': 'xh'
            },
          ],
          'final': 'xh',
        },
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'xh'});
      expect(ok, isFalse); // no surviving exit → caller refuses to launch
      final rules = (cfg['route'] as Map)['rules'] as List;
      expect(rules.any((r) => r is Map && r['outbound'] == 'xh'),
          isFalse); // dropped, not left dangling
    });

    test('strips a detour left dangling by a dropped member', () {
      final cfg = <String, dynamic>{
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'xh',
            'transport': {'type': 'xhttp'}
          },
          {
            'type': 'vless',
            'tag': 'reality',
            'tls': {
              'reality': {'enabled': true}
            }
          },
          {'type': 'direct', 'tag': 'dns-proxy', 'detour': 'xh'},
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['xh', 'reality']
          },
        ],
        'route': {'final': 'select'},
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'xh'});
      expect(ok, isTrue);
      final dnsProxy = (cfg['outbounds'] as List)
          .firstWhere((o) => o['tag'] == 'dns-proxy');
      expect(dnsProxy.containsKey('detour'), isFalse); // dangling detour stripped
    });

    test('strips a dangling dns.server detour (else core FATALs at runtime, '
        'check passes)', () {
      // Verified against the real sing-box: a dns.server detouring a dropped tag
      // PASSES `sing-box check` but FATALs at service-start ("outbound detour not
      // found") — taking the whole pool down. Must be scrubbed like outbound ones.
      final cfg = <String, dynamic>{
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'reality',
            'tls': {
              'reality': {'enabled': true}
            }
          },
          {
            'type': 'vless',
            'tag': 'xh',
            'transport': {'type': 'xhttp'}
          },
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': ['reality', 'xh']
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'dns': {
          'servers': [
            {'type': 'https', 'tag': 'doh', 'server': '1.1.1.1', 'detour': 'xh'},
            {'type': 'https', 'tag': 'doh-ok', 'server': '8.8.8.8',
              'detour': 'select'},
          ],
          'final': 'doh',
        },
        'route': {'final': 'select'},
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'xh'});
      expect(ok, isTrue);
      final servers = (cfg['dns'] as Map)['servers'] as List;
      final doh = servers.firstWhere((s) => s['tag'] == 'doh');
      // Dangling DNS detour is RE-PINNED to the surviving exit, not stripped:
      // stripping sent the DoH queries DIRECT out the physical uplink (an
      // ISP-visible/blockable leak). The selector survives → ride it.
      expect(doh['detour'], 'select');
      final dohOk = servers.firstWhere((s) => s['tag'] == 'doh-ok');
      expect(dohOk['detour'], 'select'); // valid detour to a survivor → untouched
    });

    test('no-op when nothing failed', () {
      final cfg = pool();
      final before = jsonEncode(cfg);
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, <String>{});
      expect(ok, isTrue);
      expect(jsonEncode(cfg), before); // untouched
    });

    test('re-pins a dangling route.final to a surviving proxy (no direct-default '
        'fail-OPEN leak)', () {
      // Imported-config trap: route.final pinned DIRECTLY at the dead member, and
      // `direct` is the FIRST outbound. Just removing final would default sing-box
      // to the first outbound (direct) → everything direct = leak. It must re-pin.
      final cfg = <String, dynamic>{
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'}, // FIRST = the leak trap
          {
            'type': 'vless',
            'tag': 'reality',
            'tls': {
              'reality': {'enabled': true}
            }
          },
          {
            'type': 'vless',
            'tag': 'xh',
            'transport': {'type': 'xhttp'}
          },
        ],
        'route': {'final': 'xh'},
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'xh'});
      expect(ok, isTrue);
      expect((cfg['route'] as Map)['final'], 'reality',
          reason: 'final must be RE-PINNED to the surviving proxy, never left to '
              'default to the first outbound (direct)');
    });
  });
}
