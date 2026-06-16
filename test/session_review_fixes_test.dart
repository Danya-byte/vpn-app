import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vpn_app/core/amnezia_config.dart';
import 'package:vpn_app/core/app_settings.dart';
import 'package:vpn_app/core/cascade.dart';
import 'package:vpn_app/core/diagnostics.dart';
import 'package:vpn_app/core/proxy_node.dart';
import 'package:vpn_app/core/route_rule.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/share_link_encoder.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Regressions for the adversarial review of this session's feature code.
/// Each test pins a confirmed bug so it can't silently come back.
void main() {
  // ── HIGH: AmneziaWG isConfig path ──────────────────────────────────────────
  // fromConfig strips `_`-prefixed stash keys before the family classifier and
  // the bridge consume them, so an imported AmneziaWG config used to be (a)
  // misclassified as plain (blocked) WireGuard and (b) never bridged. The fix
  // preserves `_amneziawg` THROUGH the strip when the awg bridge is available.
  group('AmneziaWG survives fromConfig when the bridge is available', () {
    Map<String, dynamic> amneziaSrc() => {
          'outbounds': [
            {
              'type': 'selector',
              'tag': 'select',
              'outbounds': ['wg', 'direct'],
            },
            {'type': 'direct', 'tag': 'direct'},
          ],
          'endpoints': [
            {
              'type': 'wireguard',
              'tag': 'wg',
              'address': ['10.0.0.2/32'],
              'private_key': 'cHJpdmF0ZQ==',
              'peers': [
                {
                  'public_key': 'cHVibGlj',
                  'address': '1.2.3.4',
                  'port': 51820,
                  'allowed_ips': ['0.0.0.0/0'],
                }
              ],
              '_amneziawg': {
                'jc': 4,
                'jmin': 8,
                'jmax': 80,
                's1': 0,
                's2': 0,
                'h1': 1,
                'h2': 2,
                'h3': 3,
                'h4': 4,
              },
            },
          ],
          'route': {'final': 'select'},
        };

    test('keepAmneziaMarker:true → marker kept, family=amneziawg, needsAmnezia',
        () {
      final cfg = SingBoxConfig.fromConfig(amneziaSrc(), keepAmneziaMarker: true);
      final ep = (cfg['endpoints'] as List).first as Map;
      expect(ep.containsKey('_amneziawg'), isTrue,
          reason: 'bridge must still see the obfs params');
      expect(AmneziaConfig.needsAmnezia(ep), isTrue);
      // The classifier runs on this same (pre-bridge) cfg in the controller.
      expect(familiesFromConfig(cfg)['wg'], 'amneziawg');
    });

    test('default (no awg bridge) → marker stripped, plain wireguard', () {
      final cfg = SingBoxConfig.fromConfig(amneziaSrc());
      final ep = (cfg['endpoints'] as List).first as Map;
      expect(ep.containsKey('_amneziawg'), isFalse,
          reason: 'bundled core FATALs on unknown fields');
      expect(AmneziaConfig.needsAmnezia(ep), isFalse);
      // No bridge available → it genuinely is plain (blocked) WG, classify it so.
      expect(familiesFromConfig(cfg)['wg'], 'wireguard');
    });
  });

  // ── HIGH: H5 MITM consent for hy2/tuic in the Policies switcher ─────────────
  // The auto-failover pool excuses hy2/tuic (PSK auth), but a USER-driven manual
  // switch must still raise the MITM consent — tls.insecure is a no-cert-check
  // hole regardless of the PSK. mitmTagsFromConfig flags them; the cascade-scoped
  // insecureTagsFromConfig must keep excusing them.
  group('mitmTagsFromConfig vs insecureTagsFromConfig', () {
    final cfg = {
      'outbounds': [
        {
          'tag': 'hy2',
          'type': 'hysteria2',
          'tls': {'enabled': true, 'insecure': true},
        },
        {
          'tag': 'tu',
          'type': 'tuic',
          'tls': {'enabled': true, 'insecure': true},
        },
        {
          'tag': 'vl',
          'type': 'vless',
          'tls': {'enabled': true, 'insecure': true},
        },
        {
          'tag': 'safe',
          'type': 'vless',
          'tls': {'enabled': true, 'insecure': false},
        },
        {
          'tag': 'real',
          'type': 'vless',
          'tls': {
            'insecure': true,
            'reality': {'enabled': true},
          },
        },
      ],
    };

    test('mitm set flags insecure hy2/tuic (user-switch guard)', () {
      final mitm = mitmTagsFromConfig(cfg);
      expect(mitm, containsAll(['hy2', 'tu', 'vl']));
      expect(mitm.contains('safe'), isFalse);
      expect(mitm.contains('real'), isFalse, reason: 'Reality is not a MITM hole');
    });

    test('insecure set still excuses hy2/tuic (auto-failover pool)', () {
      final ins = insecureTagsFromConfig(cfg);
      expect(ins.contains('hy2'), isFalse);
      expect(ins.contains('tu'), isFalse);
      expect(ins.contains('vl'), isTrue);
    });
  });

  // ── HIGH: applyShared must not throw on a type-confused untrusted bundle ─────
  group('applyShared hardens an untrusted vpn://share bundle', () {
    test('type-confused fields are coerced to null (kept), never thrown', () {
      final tmp = Directory.systemTemp.createTempSync('vpn_share_fix_');
      SettingsController.overrideDir = tmp.path;
      addTearDown(() {
        SettingsController.overrideDir = null;
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final before = container.read(settingsProvider);

      expect(
        () => container.read(settingsProvider.notifier).applyShared({
          'muxStreams': '8', // string, not num
          'antiDpi': 1, // int, not bool
          'splitTunnelApps': 'x', // string, not list
          'ecsSubnet': 42, // num, not string
          'desyncStrategy': true, // bool, not string
          'customRules': 'nope', // string, not list
          'mux': 'yes', // string, not bool
        }),
        returnsNormally,
      );

      final after = container.read(settingsProvider);
      expect(after.antiDpi, before.antiDpi);
      expect(after.mux, before.mux);
      expect(after.muxStreams, before.muxStreams);
      expect(after.splitTunnelApps, before.splitTunnelApps);
      expect(after.ecsSubnet, before.ecsSubnet);
    });

    test('well-typed fields still apply', () {
      final tmp = Directory.systemTemp.createTempSync('vpn_share_ok_');
      SettingsController.overrideDir = tmp.path;
      addTearDown(() {
        SettingsController.overrideDir = null;
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(settingsProvider.notifier).applyShared({
        'antiDpi': false,
        'muxStreams': 8,
        'splitTunnelApps': ['game.exe'],
      });
      final after = container.read(settingsProvider);
      expect(after.antiDpi, isFalse);
      expect(after.muxStreams, 8);
      expect(after.splitTunnelApps, ['game.exe']);
    });
  });

  // ── Full-diff audit regressions ─────────────────────────────────────────────
  group('audit: route_rule overflow must not throw (settings-wipe class)', () {
    test('absurdly long CIDR bits → invalid, not FormatException', () {
      expect(
          () => RouteRule.isValidValue(
              RuleField.ipCidr, '1.2.3.4/99999999999999999999999999999'),
          returnsNormally);
      expect(
          RouteRule.isValidValue(
              RuleField.ipCidr, '1.2.3.4/99999999999999999999999999999'),
          isFalse);
      expect(RouteRule.isValidValue(RuleField.ipCidr, '1.2.3.4/24'), isTrue);
      expect(RouteRule.isValidValue(RuleField.ipCidr, '::1/128'), isTrue);
    });
    test('fromJson with the overflow value yields null, never throws', () {
      expect(
          RouteRule.fromJson({
            'field': 'ipCidr',
            'value': '1.2.3.4/99999999999999999999999999999',
            'action': 'direct',
          }),
          isNull);
    });
  });

  group('audit: gzip bomb in vpn://share is rejected', () {
    test('a multi-MB-inflating link decodes to null, app stays alive', () {
      // 64 MB of zeros gzips to a few KB — over our 4 MB decompressed cap.
      final bomb = gzip.encode(List.filled(64 * 1024 * 1024, 0));
      final link =
          'vpn://share?d=${base64Url.encode(bomb).replaceAll('=', '')}';
      expect(ShareLinkEncoder.decodeBundle(link), isNull);
    });
    test('an over-cap COMPRESSED payload is rejected before gunzip', () {
      final big = List<int>.filled(600 * 1024, 0x41); // > 512 KB input cap
      final link = 'vpn://share?d=${base64Url.encode(big).replaceAll('=', '')}';
      expect(ShareLinkEncoder.decodeBundle(link), isNull);
    });
  });

  group('audit: bundle subUrl is clamped to https', () {
    String mk(Map<String, dynamic> j) =>
        'vpn://share?d=${base64Url.encode(utf8.encode(jsonEncode(j))).replaceAll('=', '')}';
    final node = {
      'tag': 'n',
      'outbound': {'type': 'vless', 'server': '1.2.3.4', 'server_port': 443, 'uuid': 'u'},
    };
    test('http / garbage schemes are dropped, https survives', () {
      expect(
          ShareLinkEncoder.decodeBundle(mk({
            'v': 1, 'nodes': [node], 'sub': 'http://evil.example/s',
          }))!.subUrl,
          isNull);
      expect(
          ShareLinkEncoder.decodeBundle(mk({
            'v': 1, 'nodes': [node], 'sub': 'file:///C:/x',
          }))!.subUrl,
          isNull);
      expect(
          ShareLinkEncoder.decodeBundle(mk({
            'v': 1, 'nodes': [node], 'sub': 'https://sub.example/s',
          }))!.subUrl,
          'https://sub.example/s');
    });
  });

  group('audit: insecureKey identity', () {
    test('config key tracks the INSECURE exits, not the whole roster', () {
      Map<String, dynamic> cfg(String insecureTag) => {
            'outbounds': [
              {
                'tag': 'a',
                'type': 'vless',
                'server': 'evil.example',
                'server_port': 443,
                'tls': {'enabled': true, 'insecure': insecureTag == 'a'},
              },
              {
                'tag': 'b',
                'type': 'vless',
                'server': 'good.example',
                'server_port': 443,
                'tls': {'enabled': true, 'insecure': insecureTag == 'b'},
              },
            ],
          };
      final k1 = ParsedNode(tag: 'x', outbound: const {}, config: cfg('a'))
          .insecureKey;
      final k2 = ParsedNode(tag: 'x', outbound: const {}, config: cfg('b'))
          .insecureKey;
      // The risky flag MOVED to another server → the consent key must change.
      expect(k1, isNot(k2));
      expect(k1, contains('evil.example'));
      expect(k2, contains('good.example'));
    });
    test('hy2 port-hopping nodes on one host do not collide', () {
      ParsedNode hop(List<String> ports) => ParsedNode(tag: 'h', outbound: {
            'type': 'hysteria2',
            'server': 'h.example',
            'server_ports': ports,
            'tls': {'enabled': true, 'insecure': true},
          });
      expect(hop(['400:500']).insecureKey,
          isNot(hop(['600:700']).insecureKey));
    });
  });

  group('audit: WG keepalive clamped', () {
    test('negative / huge PersistentKeepalive cannot reach the core', () {
      final conf = '''
[Interface]
PrivateKey = cHJpdmF0ZWtleWJhc2U2NA==
Address = 10.0.0.2/32
[Peer]
PublicKey = cHVibGlja2V5YmFzZTY0x=
AllowedIPs = 0.0.0.0/0
Endpoint = 1.2.3.4:51820
PersistentKeepalive = -5
''';
      final nodes = ShareLink.parseSubscription(conf);
      expect(nodes, isNotEmpty);
      final ep =
          ((nodes.first.config!['endpoints'] as List).first as Map);
      final ka = (ep['peers'] as List).first['persistent_keepalive_interval']
          as int;
      expect(ka, inInclusiveRange(0, 65535));
    });
  });

  group('audit: dnsInconclusive verdict (system-resolver fallback)', () {
    test('a connect success via an UNTRUSTED resolver is not reachableL4', () {
      expect(
          Diagnostics.verdictFor(
              controlUp: true,
              udp: false,
              reachable: true,
              resolverTrusted: false),
          ServerVerdict.dnsInconclusive);
      expect(
          Diagnostics.verdictFor(
              controlUp: true, udp: false, reachable: true),
          ServerVerdict.reachableL4);
    });
  });

  group('audit: pruneDeadOutbounds re-pins a dns detour (no DoH leak)', () {
    test('dns.server detour onto a dropped tag re-pins to the survivor', () {
      final cfg = {
        'dns': {
          'servers': [
            {'tag': 'doh', 'address': 'https://1.1.1.1/dns-query', 'detour': 'dead'},
          ],
        },
        'outbounds': [
          {'tag': 'alive', 'type': 'vless', 'server': '1.2.3.4', 'server_port': 443, 'uuid': 'u'},
          {'tag': 'direct', 'type': 'direct'},
        ],
        'route': {'final': 'alive'},
      };
      final ok = SingBoxConfig.pruneDeadOutbounds(cfg, {'dead'});
      expect(ok, isTrue);
      final srv = ((cfg['dns'] as Map)['servers'] as List).first as Map;
      expect(srv['detour'], 'alive',
          reason: 'DNS must keep riding the tunnel, not leak DIRECT');
    });
  });

  // urltest interrupt_exist_connections must be OFF so a latency re-pick doesn't
  // cut live connections — Telegram's long-lived MTProto socket kept reconnecting.
  group('urltest does not interrupt live connections', () {
    Map urltestOf(Map<String, dynamic> cfg) =>
        (cfg['outbounds'] as List).firstWhere((o) => o['type'] == 'urltest')
            as Map;

    test('fromConfig forces an imported urltest interrupt:true to false', () {
      final cfg = SingBoxConfig.fromConfig({
        'outbounds': [
          {
            'tag': 'auto',
            'type': 'urltest',
            'outbounds': ['n1', 'n2'],
            'interrupt_exist_connections': true,
            'interval': '5m',
          },
          {
            'tag': 'n1',
            'type': 'vless',
            'server': '1.2.3.4',
            'server_port': 443,
            'uuid': 'u1',
            'tls': {
              'enabled': true,
              'server_name': 's.com',
              'reality': {'enabled': true, 'public_key': 'k'},
            },
          },
          {
            'tag': 'n2',
            'type': 'vless',
            'server': '5.6.7.8',
            'server_port': 443,
            'uuid': 'u2',
            'tls': {
              'enabled': true,
              'server_name': 's.com',
              'reality': {'enabled': true, 'public_key': 'k'},
            },
          },
        ],
        'route': {'final': 'auto'},
      });
      expect(urltestOf(cfg)['interrupt_exist_connections'], isFalse);
    });

    test('fromNodes auto-pool urltest sets interrupt:false', () {
      final cfg = SingBoxConfig.fromNodes([
        ParsedNode(tag: 'A', outbound: {
          'type': 'vless',
          'tag': 'A',
          'server': '1.2.3.4',
          'server_port': 443,
          'uuid': 'u',
        }),
        ParsedNode(tag: 'B', outbound: {
          'type': 'hysteria2',
          'tag': 'B',
          'server': '5.6.7.8',
          'server_port': 443,
          'password': 'p',
        }),
      ]);
      expect(urltestOf(cfg)['interrupt_exist_connections'], isFalse);
    });
  });
}
