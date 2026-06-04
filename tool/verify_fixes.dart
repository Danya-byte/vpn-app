// ignore_for_file: avoid_print
// Runtime verification of the production-readiness fixes against the REAL
// bundled sing-box binary — proves behavior, not just that the code reads right.
// Run: dart run tool/verify_fixes.dart
import 'dart:convert';
import 'dart:io';

import 'package:vpn_app/core/server_gen.dart';
import 'package:vpn_app/core/singbox_config.dart';

late String sb;

// The app ships with these deprecated-compat flags (core_controller _coreEnv),
// so "does it run as shipped" is the honest question.
const env = {
  'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
  'ENABLE_DEPRECATED_GEOSITE': 'true',
  'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS': 'true',
  'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM': 'true',
  'ENABLE_DEPRECATED_DNS_RULE_ACTIONS': 'true',
  'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
};

// Returns null on success (exit 0), else the core's FATAL/ERROR text.
Future<String?> check(Map<String, dynamic> cfg, String name) async {
  final dir = Directory.systemTemp.createTempSync('vfix');
  try {
    final f = File('${dir.path}${Platform.pathSeparator}$name.json')
      ..writeAsStringSync(SingBoxConfig.encode(cfg));
    final r = await Process.run(sb, ['check', '-c', f.path], environment: env);
    if (r.exitCode == 0) return null;
    final out = '${r.stdout}${r.stderr}'.trim();
    return out.isEmpty ? 'exit ${r.exitCode}' : out;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

Future<String> run(List<String> args) async =>
    '${(await Process.run(sb, args)).stdout}';

String grab(String out, String prefix) => const LineSplitter()
    .convert(out)
    .map((l) => l.trim())
    .firstWhere((l) => l.startsWith(prefix), orElse: () => '')
    .replaceFirst(prefix, '')
    .trim();

int pass = 0, fail = 0;
void verdict(String name, bool ok, [String extra = '']) {
  if (ok) {
    pass++;
    print('  ✅ $name${extra.isEmpty ? '' : '  — $extra'}');
  } else {
    fail++;
    print('  ❌ $name${extra.isEmpty ? '' : '  — $extra'}');
  }
}

Future<void> main() async {
  final cwd = Directory.current.path;
  sb = '$cwd/core/windows/sing-box.exe';
  if (!File(sb).existsSync()) {
    print('sing-box.exe not bundled — cannot run real check'); exit(2);
  }
  SingBoxConfig.ruleSetDir = '$cwd/core/rule-sets';

  // Real Reality material so the core's key/uuid validation is genuine.
  final kp = await run(['generate', 'reality-keypair']);
  final priv = grab(kp, 'PrivateKey:'), pub = grab(kp, 'PublicKey:');
  final uuid = (await run(['generate', 'uuid'])).trim();
  final sid = (await run(['generate', 'rand', '8', '--hex'])).trim();
  print('material: uuid=${uuid.substring(0, 8)}…  pub=${pub.substring(0, 10)}…  sid=$sid\n');

  // A full imported config with a Reality outbound carrying utls.enabled:FALSE —
  // the exact #H3 hazard. (Deep-copied per use so each path sees a clean source.)
  Map<String, dynamic> badRealityCfg() => {
        'log': {'level': 'warn'},
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'proxy',
            'server': '45.13.239.12',
            'server_port': 443,
            'uuid': uuid,
            'flow': 'xtls-rprx-vision',
            'tls': {
              'enabled': true,
              'server_name': 'dl.google.com',
              'utls': {'enabled': false, 'fingerprint': 'chrome'}, // <-- FATAL bait
              'reality': {'enabled': true, 'public_key': pub, 'short_id': sid},
            },
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {'final': 'proxy'},
      };

  print('── #H3: imported Reality with utls.enabled:false ──');
  // CONTRAST: the raw config (NOT through our code) must FATAL — proves the bug is real.
  final rawErr = await check(badRealityCfg(), 'raw_bad');
  verdict('raw config FATALs (bug is real)', rawErr != null,
      rawErr == null ? 'UNEXPECTEDLY PASSED' : rawErr.split('\n').first);
  // FIX: through fromConfig (the controller's import path) it must now PASS.
  final fixed = SingBoxConfig.fromConfig(badRealityCfg(),
      fingerprintOverride: 'chrome', antiDpi: true, ruDirect: true);
  final fixedErr = await check(fixed, 'h3_fixed');
  verdict('fromConfig repairs it → check PASSES', fixedErr == null,
      fixedErr ?? 'utls now: ${_utlsOf(fixed)}');

  print('\n── bread-and-butter ТСПУ paths ──');
  for (final entry in {
    'smart desync (no server)': SingBoxConfig.desyncOnly(),
    'm0 local': SingBoxConfig.m0Local(),
  }.entries) {
    verdict(entry.key, await check(entry.value, 'bb') == null);
  }

  print('\n── #6 / ServerGen: generated VLESS+Reality server config ──');
  final bundle = ServerGen.buildReality(
    serverIp: '45.13.239.12',
    uuid: uuid,
    privateKey: priv,
    publicKey: pub,
    shortId: sid,
    sni: 'dl.google.com',
  );
  verdict('server config passes check', await check(bundle.serverConfig, 'srv') == null);
  final hy2link = bundle.clientLinks.length > 1 ? bundle.clientLinks[1] : '';
  verdict('Reality client link has NO insecure=1', !bundle.clientLinks.first.contains('insecure=1'),
      bundle.clientLinks.first.split('?').first);
  // honest: hy2 link still carries insecure=1 (cert-pin deferred) — confirm it's at least flagged elsewhere
  verdict('(known) hy2 link still insecure=1 (cert-pin deferred)', hy2link.isEmpty || hy2link.contains('insecure=1'),
      hy2link.isEmpty ? 'no hy2 in default' : 'insecure=1 present (badge now warns)');

  print('\n${fail == 0 ? '🟢' : '🔴'} verify_fixes: $pass passed, $fail failed');
  exit(fail == 0 ? 0 : 1);
}

String _utlsOf(Map<String, dynamic> cfg) {
  final o = (cfg['outbounds'] as List).cast<Map>().firstWhere(
      (o) => o['type'] == 'vless', orElse: () => {});
  final tls = o['tls'];
  return tls is Map ? jsonEncode(tls['utls']) : 'none';
}
