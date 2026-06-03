import 'dart:convert';
import 'dart:io';

import 'package:vpn_app/core/core_paths.dart';
import 'package:vpn_app/core/route_mode.dart';
import 'package:vpn_app/core/share_link.dart';
import 'package:vpn_app/core/singbox_config.dart';

// Dev helper.
//   dart run tool/gen.dart "<link>" [global|smart]  -> config for a share link
//   dart run tool/gen.dart "<path-to-config.json>"  -> processed full config
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
        'usage: dart run tool/gen.dart "<link|config.json>" [global|smart]');
    exit(2);
  }
  SingBoxConfig.ruleSetDir = CorePaths.ruleSetsDir();
  final input = args[0];
  final file = File(input);
  final tun = args.contains('tun');
  Map<String, dynamic> cfg;
  if (file.existsSync()) {
    cfg = SingBoxConfig.fromConfig(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
  } else {
    final node = ShareLink.parse(input);
    if (node == null) {
      stderr.writeln('parse failed');
      exit(1);
    }
    final mode = args.contains('global') ? RouteMode.global : RouteMode.smart;
    cfg = SingBoxConfig.fromNode(node, mode: mode, antiDpi: args.contains('frag'));
  }
  if (tun) cfg = SingBoxConfig.withTun(cfg);
  stdout.write(SingBoxConfig.encode(cfg));
}
