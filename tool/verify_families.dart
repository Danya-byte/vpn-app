import 'dart:convert';
import 'dart:io';

import 'package:vpn_app/core/cascade.dart' show familiesFromConfig;
import 'package:vpn_app/core/singbox_config.dart';

/// Empirical check for review finding A: run the user's REAL stored config
/// through the exact runtime path (`fromConfig`) and show that the cascade's
/// refined family map distinguishes signatures the coarse Clash `type` merges
/// (Reality vs plain-TLS vs XHTTP). Prints ONLY node tags + family labels — no
/// server addresses, UUIDs, keys or passwords. build/ is gitignored.
///
///   dart run tool/verify_families.dart
void main(List<String> args) {
  final cwd = Directory.current.path;
  SingBoxConfig.ruleSetDir = '$cwd\\core\\rule-sets';

  // Optional: classify an already-processed sing-box config file directly (e.g.
  // build/_runtime.json that `verify_store.dart` wrote from the real profile).
  if (args.isNotEmpty) {
    final f = File(args.first);
    if (!f.existsSync()) {
      stderr.writeln('файл не найден: ${f.path}');
      exit(1);
    }
    final cfg = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final fams = familiesFromConfig(cfg);
    stdout.writeln('■ ${f.path} — ${fams.length} proxy-узлов, '
        '${fams.values.toSet().length} различимых семей:');
    final lines = fams.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final e in lines) {
      stdout.writeln('    ${e.value.padRight(16)}  ${e.key}');
    }
    return;
  }

  final base = Platform.environment['LOCALAPPDATA'];
  final store = File('$base\\vpn_app\\run\\profiles.json');
  if (!store.existsSync()) {
    stderr.writeln('профили не найдены: ${store.path}');
    exit(1);
  }
  final j = jsonDecode(store.readAsStringSync()) as Map<String, dynamic>;
  final nodes = (j['nodes'] as List).cast<Map<String, dynamic>>();

  // The "old" cascade keyed family on the raw Clash type; vless covers
  // Reality / plain-TLS / XHTTP-via-bridge alike → they'd all merge.
  String coarse(String fam) {
    final dash = fam.indexOf('-');
    return dash > 0 ? fam.substring(0, dash) : fam; // vless-reality → vless
  }

  var checked = 0;
  for (final node in nodes) {
    if (node['config'] == null) continue;
    checked++;
    final tag = node['tag'];
    final cfg = SingBoxConfig.fromConfig(
      (node['config'] as Map).cast<String, dynamic>(),
    );
    final fams = familiesFromConfig(cfg);
    if (fams.isEmpty) continue;

    // Group tags by the OLD coarse key; any bucket with >1 distinct refined
    // family is a pair the old cascade could NOT hop between but now can.
    final byCoarse = <String, Set<String>>{};
    fams.forEach((t, f) => byCoarse.putIfAbsent(coarse(f), () => {}).add(f));

    stdout.writeln(
      '\n■ профиль «$tag» — ${fams.length} proxy-узлов, '
      '${fams.values.toSet().length} различимых семей:',
    );
    final lines = fams.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final e in lines) {
      stdout.writeln('    ${e.value.padRight(16)}  ${e.key}');
    }
    final unmerged = byCoarse.entries.where((e) => e.value.length > 1);
    if (unmerged.isEmpty) {
      stdout.writeln(
        '  (одна семья на каждый Clash-тип — обогащение не меняет '
        'каскад здесь)',
      );
    } else {
      for (final e in unmerged) {
        stdout.writeln(
          '  ✓ финдинг A: «${e.key}» раньше сливался — теперь '
          'каскад различает ${e.value.join(' / ')} и прыгает между ними',
        );
      }
    }
  }
  if (checked == 0) {
    stdout.writeln('в сторе нет конфиг-профилей (только простые узлы).');
  }
}
