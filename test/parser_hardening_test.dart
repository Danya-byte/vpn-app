import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/share_link.dart';

/// Locks in the parser-correctness fixes from the independent audit.
void main() {
  // Real SIP002 puts a `/` before the query: ss://userinfo@host:port/?plugin=…
  String ssLink(String hostPort, {String? query}) {
    final user = base64.encode(utf8.encode('aes-256-gcm:pass'));
    return 'ss://$user@$hostPort${query == null ? '' : '/?$query'}#node';
  }

  test('VLESS Reality without a public key is rejected, not silently dead (A9)',
      () {
    expect(
      ShareLink.parse('vless://uuid@server.com:443?security=reality&sid=ab#X'),
      isNull,
    );
    final ok = ShareLink.parse(
        'vless://uuid@server.com:443?security=reality&pbk=KEY&sid=ab#X');
    expect(ok, isNotNull);
    expect((ok!.outbound['tls'] as Map)['reality']['public_key'], 'KEY');
  });

  test('IPv6-literal endpoints parse host (no brackets) + port correctly (A2)',
      () {
    final n = ShareLink.parse(ssLink('[2001:db8::1]:8388'));
    expect(n, isNotNull);
    expect(n!.outbound['server'], '2001:db8::1');
    expect(n.outbound['server_port'], 8388);
  });

  test('ss:// SIP002 plugin is preserved, not downgraded to plaintext (A3)', () {
    final plugin =
        Uri.encodeComponent('obfs-local;obfs=http;obfs-host=www.bing.com');
    final n = ShareLink.parse(ssLink('1.2.3.4:8388', query: 'plugin=$plugin'));
    expect(n, isNotNull);
    expect(n!.outbound['plugin'], 'obfs-local');
    expect(n.outbound['plugin_opts'], 'obfs=http;obfs-host=www.bing.com');
    // SIP002's `/?` before the query must NOT eat the port (regression).
    expect(n.outbound['server_port'], 8388);
  });

  test('a plain ss:// (no plugin) carries no plugin keys', () {
    final n = ShareLink.parse(ssLink('1.2.3.4:8388'));
    expect(n!.outbound.containsKey('plugin'), isFalse);
  });

  // Format-omnivore (#17): schemes the audit found were SILENTLY dropped.
  test('socks:// and socks5:// parse to a socks outbound', () {
    final a = ShareLink.parse('socks://1.2.3.4:1080#s');
    expect(a, isNotNull);
    expect(a!.outbound['type'], 'socks');
    expect(a.outbound['server_port'], 1080);
    expect(ShareLink.parse('socks5://1.2.3.4:1080#s')?.outbound['type'], 'socks');
  });

  test('anytls:// parses to an anytls outbound with TLS', () {
    final n = ShareLink.parse('anytls://pw@1.2.3.4:443?sni=ex.com#a');
    expect(n, isNotNull);
    expect(n!.outbound['type'], 'anytls');
    expect(n.outbound['password'], 'pw');
    expect((n.outbound['tls'] as Map)['server_name'], 'ex.com');
  });

  test('hysteria:// (v1) parses distinct from hysteria2, with mbps + auth', () {
    final n = ShareLink.parse(
        'hysteria://1.2.3.4:443?auth=secret&upmbps=20&downmbps=100&peer=ex.com#h');
    expect(n, isNotNull);
    expect(n!.outbound['type'], 'hysteria'); // NOT hysteria2
    expect(n.outbound['auth_str'], 'secret');
    expect(n.outbound['up_mbps'], 20);
    expect(n.outbound['down_mbps'], 100);
    // hysteria2 must still resolve to its own type.
    expect(ShareLink.parse('hysteria2://pw@1.2.3.4:443#h2')?.outbound['type'],
        'hysteria2');
  });

  test('a 5-link mixed sub imports 4 (only unsupported ssr:// dropped)', () {
    final sub = [
      'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=reality&pbk=K&sid=ab#v',
      'socks://1.2.3.4:1080#s',
      'anytls://pw@1.2.3.4:443#a',
      'hysteria://1.2.3.4:443?auth=x&upmbps=10&downmbps=50#h',
      'ssr://no-sing-box-equivalent',
    ].join('\n');
    final nodes = ShareLink.parseSubscription(sub);
    expect(nodes.length, 4, reason: 'was silently importing only 1 of 5');
    expect(nodes.map((n) => n.outbound['type']).toSet(),
        {'vless', 'socks', 'anytls', 'hysteria'});
  });
}
