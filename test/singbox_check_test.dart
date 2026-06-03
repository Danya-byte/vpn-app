import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/singbox_config.dart';

/// Real-core validation (test-plan #6): the generated configs must pass the
/// ACTUAL `sing-box check`, not just our in-process corpus — so a schema drift
/// on a core bump is caught. Skipped when the bundled binary isn't present
/// (fresh checkout before fetch-cores), so CI without it stays green.
void main() {
  final cwd = Directory.current.path;
  final sb = File('$cwd${Platform.pathSeparator}core'
      '${Platform.pathSeparator}windows${Platform.pathSeparator}sing-box.exe');
  final rs = Directory('$cwd${Platform.pathSeparator}core'
      '${Platform.pathSeparator}rule-sets');
  final hasCore = sb.existsSync();

  const env = {
    'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
    'ENABLE_DEPRECATED_GEOSITE': 'true',
    'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS': 'true',
    'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEMS': 'true',
    'ENABLE_DEPRECATED_DNS_RULE_ACTIONS': 'true',
    'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
  };

  setUpAll(() {
    if (rs.existsSync()) SingBoxConfig.ruleSetDir = rs.path;
  });

  // Returns null on success, else the first FATAL/ERROR line from the core.
  Future<String?> check(Map<String, dynamic> cfg, String name) async {
    final dir = Directory.systemTemp.createTempSync('sbcheck');
    try {
      final f = File('${dir.path}${Platform.pathSeparator}$name.json')
        ..writeAsStringSync(SingBoxConfig.encode(cfg));
      final r =
          await Process.run(sb.path, ['check', '-c', f.path], environment: env);
      if (r.exitCode == 0) return null;
      final out = '${r.stdout}${r.stderr}';
      return out.trim().isEmpty ? 'exit ${r.exitCode}' : out.trim();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  test('desyncOnly() passes real `sing-box check`', () async {
    expect(await check(SingBoxConfig.desyncOnly(), 'desync'), isNull);
  }, skip: hasCore ? false : 'sing-box.exe not bundled');

  test('m0Local() passes real `sing-box check`', () async {
    expect(await check(SingBoxConfig.m0Local(), 'm0'), isNull);
  }, skip: hasCore ? false : 'sing-box.exe not bundled');
}
