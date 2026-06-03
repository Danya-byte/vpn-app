// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

// Dev helper: remove leftover test nodes from the real profile store.
//   dart run tool/clean_store.dart
void main() {
  final base = Platform.environment['LOCALAPPDATA'] ??
      Platform.environment['TEMP'] ??
      Directory.systemTemp.path;
  final sep = Platform.pathSeparator;
  final f = File('$base${sep}vpn_app${sep}run${sep}profiles.json');
  if (!f.existsSync()) {
    print('no store at ${f.path}');
    return;
  }
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  const junk = {'Same', 'Same (2)', 'A', 'C'};
  final all = (j['nodes'] as List?) ?? [];
  final nodes =
      all.where((n) => !junk.contains((n as Map)['tag']?.toString())).toList();
  j['nodes'] = nodes;
  if (junk.contains(j['selected'])) {
    j['selected'] = nodes.isNotEmpty ? (nodes.first as Map)['tag'] : null;
  }
  f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(j));
  print('removed ${all.length - nodes.length} junk node(s); '
      '${nodes.length} left; selected=${j['selected']}');
}
