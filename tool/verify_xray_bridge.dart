// ignore_for_file: avoid_print
// Runtime verification of the xray-bridge VALIDATION gate against the REAL
// bundled xray binary — proves that a bridge config our code GENERATES is run
// through `xray run -test` before its outbound is trusted, so a config xray
// would reject becomes a clear error instead of a silent-dead socks outbound
// pointing at a port no xray ever bound (the gap behind this fix).
// Run: dart run tool/verify_xray_bridge.dart
import 'dart:io';

import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/singbox_config.dart';
import 'package:vpn_app/core/xray_config.dart';

late String xray;

// Mirrors CoreController._spawnXrayBridge's gate: write the generated bridge
// config, run `xray run -test`, return its exit code.
Future<int> testExit(Map<String, dynamic> xcfg, String name) async {
  final dir = Directory.systemTemp.createTempSync('vxb');
  try {
    final f = File('${dir.path}${Platform.pathSeparator}$name.json')
      ..writeAsStringSync(XrayConfig.encode(xcfg));
    final r = await Process.run(xray, ['run', '-test', '-c', f.path]);
    return r.exitCode;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

int pass = 0, fail = 0;
void verdict(String name, bool ok, [String extra = '']) {
  (ok ? pass++ : fail++);
  print('  ${ok ? '✅' : '❌'} $name${extra.isEmpty ? '' : '  — $extra'}');
}

Future<void> main() async {
  final cwd = Directory.current.path;
  xray = '$cwd/core/windows/xray.exe';
  if (!File(xray).existsSync()) {
    print('xray.exe not bundled — cannot run real validation');
    exit(2);
  }

  // 1) HAPPY PATH: a well-formed XHTTP node → bridge config xray accepts (exit 0).
  final good = ShareLink.parse(
      'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443'
      '?security=tls&sni=a.com&type=xhttp&mode=auto&path=%2Fx#good')!;
  final goodX = XrayConfig.fromOutbound(good.outbound, 24100)!;
  final goodExit = await testExit(goodX, 'good');
  verdict('well-formed XHTTP bridge → xray accepts (exit 0)', goodExit == 0,
      'exit=$goodExit');

  // 2) THE GAP: a wrong-typed XHTTP `extra` (scMaxEachPostBytes as a STRING) is
  // valid JSON so it survives parse + is relayed verbatim — but xray REJECTS it.
  // The fire-and-forget bridge would have rewritten this to a socks outbound on a
  // dead port (silent-dead). The gate must see a non-zero exit instead.
  final bad = ShareLink.parse(
      'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443'
      '?security=tls&sni=a.com&type=xhttp'
      '&extra=${Uri.encodeQueryComponent('{"scMaxEachPostBytes":"x"}')}#bad')!;
  final badX = XrayConfig.fromOutbound(bad.outbound, 24101);
  if (badX == null) {
    verdict('wrong-typed extra produced a bridge config', false, 'fromOutbound null');
  } else {
    final badExit = await testExit(badX, 'bad');
    verdict('wrong-typed XHTTP extra → xray rejects (exit != 0)', badExit != 0,
        'exit=$badExit');
  }

  // 3) POOL-SAFETY: a 2-node pool where one member is the rejected XHTTP. Dropping
  // it must keep the other node + a resolvable route.final (the rest stays up).
  final poolSurvives = SingBoxConfig.pruneDeadOutbounds(<String, dynamic>{
    'outbounds': [
      {'type': 'vless', 'tag': 'reality', 'tls': {'reality': {'enabled': true}}},
      {'type': 'vless', 'tag': 'xh', 'transport': {'type': 'xhttp'}},
      {'type': 'selector', 'tag': 'select', 'outbounds': ['reality', 'xh']},
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {'final': 'select'},
  }, {'xh'});
  verdict('multi-node pool survives dropping the rejected member', poolSurvives);

  // 4) ...and a single rejected XHTTP node leaves NO exit → caller must error
  // (never run a config that would route everything direct).
  final soloSurvives = SingBoxConfig.pruneDeadOutbounds(<String, dynamic>{
    'outbounds': [
      {'type': 'vless', 'tag': 'xh', 'transport': {'type': 'xhttp'}},
      {'type': 'direct', 'tag': 'direct'},
    ],
    'route': {'final': 'xh'},
  }, {'xh'});
  verdict('single rejected XHTTP node → no survivor (clean error)', !soloSurvives);

  print('\n$pass passed, $fail failed');
  exit(fail == 0 ? 0 : 1);
}
