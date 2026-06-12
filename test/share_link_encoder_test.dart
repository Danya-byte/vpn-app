import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/app_settings.dart';
import 'package:vpn_app/core/proxy_node.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/share_link_encoder.dart';

/// The encoder is the inverse of [ShareLink] parsing, so the strongest proof is
/// a ROUND-TRIP: encode a node → parse the link back → the key fields survive.
/// Locks the share format so old links keep importing in future builds.
void main() {
  group('encodeNode round-trips through ShareLink.parse', () {
    test('vless + Reality + Vision', () {
      final n = ParsedNode(tag: 'Reality', outbound: {
        'type': 'vless',
        'tag': 'Reality',
        'server': '1.2.3.4',
        'server_port': 443,
        'uuid': 'uuid-123',
        'flow': 'xtls-rprx-vision',
        'tls': {
          'enabled': true,
          'server_name': 'apple.com',
          'utls': {'enabled': true, 'fingerprint': 'chrome'},
          'reality': {
            'enabled': true,
            'public_key': 'PBKEY123',
            'short_id': 'ab12',
          },
        },
      });
      final link = ShareLinkEncoder.encodeNode(n)!;
      expect(link.startsWith('vless://'), isTrue);
      final b = ShareLink.parse(link)!.outbound;
      expect(b['server'], '1.2.3.4');
      expect(b['server_port'], 443);
      expect(b['uuid'], 'uuid-123');
      expect(b['flow'], 'xtls-rprx-vision');
      final tls = b['tls'] as Map;
      expect(tls['server_name'], 'apple.com');
      expect((tls['utls'] as Map)['fingerprint'], 'chrome');
      expect((tls['reality'] as Map)['public_key'], 'PBKEY123');
      expect((tls['reality'] as Map)['short_id'], 'ab12');
    });

    test('trojan over WebSocket with a special-char password', () {
      final n = ParsedNode(tag: 'T', outbound: {
        'type': 'trojan',
        'tag': 'T',
        'server': 'ex.com',
        'server_port': 8443,
        'password': 'p@ss w/ord#1',
        'tls': {
          'enabled': true,
          'server_name': 'ex.com',
          'utls': {'enabled': true, 'fingerprint': 'firefox'},
        },
        'transport': {
          'type': 'ws',
          'path': '/abc',
          'headers': {'Host': 'cdn.com'},
        },
      });
      final b = ShareLink.parse(ShareLinkEncoder.encodeNode(n)!)!.outbound;
      expect(b['server'], 'ex.com');
      expect(b['server_port'], 8443);
      expect(b['password'], 'p@ss w/ord#1');
      final t = b['transport'] as Map;
      expect(t['type'], 'ws');
      expect(t['path'], '/abc');
      expect((t['headers'] as Map)['Host'], 'cdn.com');
    });

    test('hysteria2 + obfs + port-hopping', () {
      final n = ParsedNode(tag: 'H', outbound: {
        'type': 'hysteria2',
        'tag': 'H',
        'server': '9.9.9.9',
        'server_port': 443,
        'password': 'pw',
        'tls': {'enabled': true, 'server_name': 'h.com', 'insecure': true},
        'obfs': {'type': 'salamander', 'password': 'obf'},
        'server_ports': ['20000:21000', '8443:8443'],
      });
      final b = ShareLink.parse(ShareLinkEncoder.encodeNode(n)!)!.outbound;
      expect(b['server'], '9.9.9.9');
      expect(b['server_ports'], ['20000:21000', '8443:8443']);
      expect(b['hop_interval'], '30s');
      expect((b['obfs'] as Map)['type'], 'salamander');
      expect((b['tls'] as Map)['insecure'], true);
    });

    test('shadowsocks', () {
      final n = ParsedNode(tag: 'S', outbound: {
        'type': 'shadowsocks',
        'tag': 'S',
        'server': '5.5.5.5',
        'server_port': 8388,
        'method': 'aes-256-gcm',
        'password': 'sspw',
      });
      final b = ShareLink.parse(ShareLinkEncoder.encodeNode(n)!)!.outbound;
      expect(b['server'], '5.5.5.5');
      expect(b['server_port'], 8388);
      expect(b['method'], 'aes-256-gcm');
      expect(b['password'], 'sspw');
    });

    test('hysteria2 invalid mport (out-of-range / reversed) is dropped', () {
      // A bad range must NOT strip the single port and leave a dead node.
      for (final bad in ['70000-80000', '8443-443', '0-100', 'abc']) {
        final ob =
            ShareLink.parse('hysteria2://pw@1.2.3.4:443?mport=$bad')!.outbound;
        expect(ob.containsKey('server_ports'), isFalse, reason: bad);
        expect(ob['server_port'], 443, reason: bad);
      }
      // A mix keeps only the valid entries.
      final ok = ShareLink.parse(
              'hysteria2://pw@1.2.3.4:443?mport=70000-80000,20000-21000')!
          .outbound;
      expect(ok['server_ports'], ['20000:21000']);
    });

    test('whole-config node has no single-URI form (null)', () {
      final n = ParsedNode(
          tag: 'C', outbound: const {}, config: {'outbounds': []});
      expect(ShareLinkEncoder.encodeNode(n), isNull);
    });
  });

  group('bundle (vpn://share) carries nodes + settings + auto-update', () {
    test('round-trips losslessly', () {
      final vless = ParsedNode(tag: 'R', outbound: {
        'type': 'vless',
        'tag': 'R',
        'server': '1.2.3.4',
        'server_port': 443,
        'uuid': 'uuid-123',
      });
      final link = ShareLinkEncoder.encodeBundle(
        nodes: [vless],
        settings: {
          'antiDpi': true,
          'desyncStrategy': 'fake_split',
          'splitTunnelApps': ['a.exe'],
        },
        subUrl: 'https://1-2-3-4.sslip.io/sub',
        autoUpdate: false,
      );
      expect(link.startsWith('vpn://share?d='), isTrue);
      final d = ShareLinkEncoder.decodeBundle(link)!;
      expect(d.nodes.length, 1);
      expect(d.nodes.first.outbound['uuid'], 'uuid-123');
      expect(d.settings!['antiDpi'], true);
      expect(d.settings!['desyncStrategy'], 'fake_split');
      expect(d.settings!['splitTunnelApps'], ['a.exe']);
      expect(d.subUrl, 'https://1-2-3-4.sslip.io/sub');
      expect(d.autoUpdate, false);
    });

    test('a whole-config node survives the bundle (lossless)', () {
      final cfg = ParsedNode(
          tag: 'C', outbound: const {}, config: {'outbounds': [], 'route': {}});
      final d = ShareLinkEncoder.decodeBundle(
          ShareLinkEncoder.encodeBundle(nodes: [cfg]))!;
      expect(d.nodes.first.isConfig, isTrue);
      expect(d.nodes.first.config!['outbounds'], isEmpty);
    });

    test('malformed / non-bundle input returns null (falls back to parsers)',
        () {
      expect(ShareLinkEncoder.decodeBundle('vless://x@y:443'), isNull);
      expect(ShareLinkEncoder.decodeBundle('vpn://share?d=!!!notb64'), isNull);
      expect(ShareLinkEncoder.decodeBundle('garbage'), isNull);
      expect(ShareLinkEncoder.decodeBundle('vpn://share'), isNull);
    });

    test('a big whole-config bundle is gzipped → much smaller, round-trips', () {
      // A config with the kind of repetitive bulk a real share carries (a long
      // RU-direct domain list + rule-sets) — exactly what blew the link size up.
      final domains = [
        for (var i = 0; i < 80; i++) 'site$i.example.ru',
      ];
      final cfg = ParsedNode(tag: '🌍 VPN', outbound: const {}, config: {
        'route': {
          'rules': [
            {'domain': domains, 'outbound': 'direct'},
            {'geosite': ['category-gov-ru', 'yandex', 'vk'], 'outbound': 'direct'},
          ],
          'rule_set': [
            {
              'tag': 'geosite-ru',
              'type': 'remote',
              'url':
                  'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs',
            },
          ],
          'final': '🌍 VPN',
        },
        'outbounds': [
          {'tag': '🌍 VPN', 'type': 'selector', 'outbounds': ['n1', 'n2']},
          {'tag': 'n1', 'type': 'vless', 'server': '1.2.3.4', 'server_port': 443, 'uuid': 'u1'},
          {'tag': 'n2', 'type': 'vless', 'server': '5.6.7.8', 'server_port': 443, 'uuid': 'u2'},
        ],
      });
      final link = ShareLinkEncoder.encodeBundle(nodes: [cfg]);

      // The gzipped link must be materially smaller than the plain-JSON form.
      final plainLen = 'vpn://share?d='.length +
          base64Url
              .encode(utf8.encode(jsonEncode({
                'v': 1,
                'nodes': [
                  {'tag': cfg.tag, 'config': cfg.config},
                ],
                'auto': true,
              })))
              .replaceAll('=', '')
              .length;
      expect(link.length, lessThan(plainLen),
          reason: 'gzip should shrink a bulky config link');

      // …and it still round-trips losslessly.
      final d = ShareLinkEncoder.decodeBundle(link)!;
      expect(d.nodes.single.isConfig, isTrue);
      expect((d.nodes.single.config!['outbounds'] as List).length, 3);
      expect(
          ((d.nodes.single.config!['route'] as Map)['rules'] as List).first['domain'],
          domains);
    });

    test('decodeBundle reads BOTH a plain-JSON and a gzip link (compat both ways)',
        () {
      final n = ParsedNode(tag: 'x', outbound: const {
        'type': 'vless',
        'server': '1.2.3.4',
        'server_port': 443,
        'uuid': 'u',
      });
      // A PLAIN link as an older build (pre-gzip) would have emitted it.
      final plain = 'vpn://share?d=${base64Url.encode(utf8.encode(jsonEncode({
            'v': 1,
            'nodes': [
              {'tag': n.tag, 'outbound': n.outbound},
            ],
            'auto': true,
          }))).replaceAll('=', '')}';
      expect(ShareLinkEncoder.decodeBundle(plain)!.nodes.single.outbound['uuid'], 'u');
      // The current encoder (may gzip) also round-trips.
      final cur = ShareLinkEncoder.encodeBundle(nodes: [n]);
      expect(ShareLinkEncoder.decodeBundle(cur)!.nodes.single.outbound['uuid'], 'u');
    });
  });

  // The goal: "however many updates we ship, OLD client versions keep working."
  // The bundle is versioned + purely additive and the interop form is a standard
  // URI — these prove both directions across versions.
  group('backward / forward compatibility (old clients keep working)', () {
    String mkBundle(Map<String, dynamic> j) =>
        'vpn://share?d=${base64Url.encode(utf8.encode(jsonEncode(j))).replaceAll('=', '')}';

    test('an OLD build reads a FUTURE link — unknown fields ignored, nodes import',
        () {
      final link = mkBundle({
        'v': 7, // a future version
        'futureKnob': {'x': 1}, // unknown top-level
        'nodes': [
          {
            'tag': 'n',
            'outbound': {
              'type': 'trojan',
              'server': '1.2.3.4',
              'server_port': 443,
              'password': 'p',
            },
            'futurePerNode': true, // unknown per-node
          },
        ],
        'settings': {'antiDpi': true, 'futureSetting': 42}, // unknown setting
        'auto': false,
        'sub': 'https://x.example/s',
      });
      final d = ShareLinkEncoder.decodeBundle(link)!;
      expect(d.nodes.single.tag, 'n');
      expect(d.nodes.single.outbound['server'], '1.2.3.4');
      expect(d.autoUpdate, false);
      expect(d.subUrl, 'https://x.example/s');
      expect(d.settings!['antiDpi'], true); // the known knob still survives
    });

    test('a NEW build reads an OLD minimal link — safe defaults, no crash', () {
      final link = mkBundle({
        'v': 1,
        'nodes': [
          {
            'tag': 'old',
            'outbound': {
              'type': 'vless',
              'server': '9.9.9.9',
              'server_port': 443,
              'uuid': 'u',
            },
          },
        ],
      });
      final d = ShareLinkEncoder.decodeBundle(link)!;
      expect(d.nodes.single.tag, 'old');
      expect(d.settings, isNull);
      expect(d.autoUpdate, isTrue); // default when absent
      expect(d.subUrl, isNull);
    });

    test('the interop form is a STANDARD scheme any 3rd-party client imports', () {
      final n = ParsedNode(tag: 'x', outbound: const {
        'type': 'vless',
        'server': '1.2.3.4',
        'server_port': 443,
        'uuid': 'u',
        'tls': {'enabled': true, 'server_name': 's.com'},
      });
      final uri = ShareLinkEncoder.encodeNode(n)!;
      expect(uri.startsWith('vless://'), isTrue); // not our proprietary scheme
      expect(uri.contains('vpn://'), isFalse); // carries no app-only payload
    });
  });

  group('nodeLinks extracts servers from a whole config (share for any client)',
      () {
    test('a config profile yields one standard link per real exit', () {
      final cfg = ParsedNode(tag: '🌍 VPN', outbound: const {}, config: {
        'outbounds': [
          {'tag': 'select', 'type': 'selector', 'outbounds': ['n1', 'n2']},
          {
            'tag': 'n1',
            'type': 'vless',
            'server': '1.2.3.4',
            'server_port': 443,
            'uuid': 'u1',
            'tls': {
              'enabled': true,
              'server_name': 's.com',
              'reality': {'enabled': true, 'public_key': 'k', 'short_id': 'ab'},
            },
          },
          {
            'tag': 'n2',
            'type': 'hysteria2',
            'server': '5.6.7.8',
            'server_port': 443,
            'password': 'pw',
            'tls': {'server_name': 'h.com'},
          },
          {'tag': 'direct', 'type': 'direct'}, // skipped
          {'tag': 'block', 'type': 'block'}, // skipped
        ],
      });
      final links = ShareLinkEncoder.nodeLinks([cfg]);
      expect(links.length, 2); // n1 + n2, NOT the selector/direct/block
      expect(links.any((l) => l.startsWith('vless://')), isTrue);
      expect(links.any((l) => l.startsWith('hysteria2://')), isTrue);
      // …and the subscription form is non-empty (the bug: it copied "").
      expect(ShareLinkEncoder.encodeSubscription([cfg]).isNotEmpty, isTrue);
    });

    test('a config with ONLY non-exit outbounds yields nothing (honest empty)',
        () {
      final cfg = ParsedNode(tag: 'x', outbound: const {}, config: {
        'outbounds': [
          {'tag': 'direct', 'type': 'direct'},
          {'tag': 'block', 'type': 'block'},
        ],
      });
      expect(ShareLinkEncoder.nodeLinks([cfg]), isEmpty);
    });
  });

  group('shareableSubset is safe to share', () {
    test('includes protection knobs, NEVER personal state / credentials', () {
      const s = AppSettings(
        antiDpi: false,
        desyncStrategy: 'fake_disorder',
        splitTunnelApps: ['game.exe'],
        ech: true,
        webdavPass: 'secret',
        webdavUser: 'me',
        localeCode: 'ru',
        hy2UpMbps: 50,
        customDns: '1.1.1.1',
      );
      final sub = s.shareableSubset();
      // protection knobs present
      expect(sub['antiDpi'], false);
      expect(sub['desyncStrategy'], 'fake_disorder');
      expect(sub['splitTunnelApps'], ['game.exe']);
      expect(sub['ech'], true);
      // personal / secret state NEVER leaves
      expect(sub.containsKey('webdavPass'), isFalse);
      expect(sub.containsKey('webdavUser'), isFalse);
      expect(sub.containsKey('localeCode'), isFalse);
      expect(sub.containsKey('hy2UpMbps'), isFalse);
      expect(sub.containsKey('customDns'), isFalse);
      expect(sub.containsKey('insecureAccepted'), isFalse);
    });
  });

  group('sslipHost wraps a bare IP for TLS/SNI', () {
    test('IPv4 → dashed sslip.io host', () {
      expect(ShareLinkEncoder.sslipHost('1.2.3.4'), '1-2-3-4.sslip.io');
    });
    test('a real hostname is left unchanged', () {
      expect(ShareLinkEncoder.sslipHost('example.com'), 'example.com');
    });
  });
}
