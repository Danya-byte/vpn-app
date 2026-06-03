import 'dart:io';

import 'package:vpn_app/core/route_mode.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Repro harness for the user's real inputs: parse + build the EXACT runtime the
/// app would, and run `sing-box check` — covering the single-link path that the
/// store-only doctor never exercised.
Future<void> main() async {
  final cwd = Directory.current.path;
  SingBoxConfig.ruleSetDir = '$cwd\\core\\rule-sets';
  Directory('build').createSync(recursive: true);
  const env = {
    'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
    'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
  };
  final sb = '$cwd\\core\\windows\\sing-box.exe';

  Future<void> check(String name, Map<String, dynamic> cfg) async {
    final path = '$cwd\\build\\_probe_$name.json';
    File(path).writeAsStringSync(SingBoxConfig.encode(cfg));
    final r = await Process.run(sb, ['check', '-c', path], environment: env);
    if (r.exitCode == 0) {
      stdout.writeln('$name: OK');
    } else {
      stdout.writeln('$name: FAIL -> ${'${r.stderr}${r.stdout}'.trim()}');
    }
  }

  // 1) A VLESS+Reality link (single node) — Smart, Global, TUN, anti-DPI.
  // Pass YOUR node via env so no real credential is ever committed:
  //   PROBE_LINK="vless://..." dart run tool/probe_link.dart
  final link = Platform.environment['PROBE_LINK'];
  final node =
      (link == null || link.isEmpty) ? null : ShareLink.parse(link);
  if (link == null || link.isEmpty) {
    stdout.writeln(
        'link: set PROBE_LINK to your node to run the single-link checks (skipped)');
  } else if (node == null) {
    stdout.writeln('link: PARSE FAILED');
  } else {
    await check('smart', SingBoxConfig.fromNode(node, mode: RouteMode.smart));
    await check('global', SingBoxConfig.fromNode(node, mode: RouteMode.global));
    await check('antidpi',
        SingBoxConfig.fromNode(node, mode: RouteMode.smart, antiDpi: true));
    await check(
        'tun', SingBoxConfig.withTun(SingBoxConfig.fromNode(node)));
    // #2 anti-DPI layer on the real Reality link (ech/mux are no-ops for
    // Reality+Vision, but the fingerprint pool applies):
    await check('fp-firefox',
        SingBoxConfig.fromNode(node, tlsFingerprint: 'firefox'));
    await check('fp-random', SingBoxConfig.fromNode(node, tlsFingerprint: 'random'));
  }

  // A plain TLS (non-Reality, non-Vision) node to actually exercise mux + ECH.
  final plain = ShareLink.parse(
      'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=tls&sni=example.com&type=tcp#plain');
  if (plain != null) {
    await check('plain-mux', SingBoxConfig.fromNode(plain, mux: true));
    await check('plain-ech', SingBoxConfig.fromNode(plain, ech: true));
    await check(
        'plain-all',
        SingBoxConfig.fromNode(plain,
            antiDpi: true, mux: true, ech: true, tlsFingerprint: 'firefox'));
  }

  // 2) An AmneziaWG .conf (the format sing-box can't obfuscate). Point at one via:
  //   PROBE_WG_CONF="C:\path\to\file.amneziawg.conf"
  final confPath = Platform.environment['PROBE_WG_CONF'];
  if (confPath != null && File(confPath).existsSync()) {
    final wg = ShareLink.parseSubscription(File(confPath).readAsStringSync());
    stdout.writeln('wg parsed nodes: ${wg.length}'
        '${wg.isNotEmpty ? ' (config=${wg.first.config != null})' : ''}');
    if (wg.isNotEmpty && wg.first.config != null) {
      await check('wg', SingBoxConfig.fromConfig(wg.first.config!));
    }
  } else {
    stdout.writeln('wg: set PROBE_WG_CONF to an AmneziaWG .conf to test (skipped)');
  }
}
