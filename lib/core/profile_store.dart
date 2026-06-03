import 'dart:convert';
import 'dart:io';

import 'core_paths.dart';
import 'proxy_node.dart';
import 'sub_info.dart';

/// Persists the profile list + selection to %LOCALAPPDATA%\vpn_app\run\profiles.json.
class ProfileStore {
  /// Tests point this at a temp dir so they never touch the real user store.
  static String? overrideDir;

  static File get _file => File(
      '${overrideDir ?? CorePaths.runtimeDir().path}${Platform.pathSeparator}profiles.json');

  static ({
    List<ParsedNode> nodes,
    String? selected,
    Map<String, SubInfo> subInfo
  }) load() {
    try {
      final f = _file;
      if (!f.existsSync()) {
        return (nodes: <ParsedNode>[], selected: null, subInfo: const {});
      }
      return decode(f.readAsStringSync()) ??
          (nodes: <ParsedNode>[], selected: null, subInfo: const {});
    } catch (_) {
      return (nodes: <ParsedNode>[], selected: null, subInfo: const {});
    }
  }

  /// Parse a store-envelope JSON string into nodes + selection + subInfo, or null
  /// if [text] isn't the envelope ({nodes:[…]}) — so the import path can fall
  /// through to link/config parsing. Shared by [load] (on-disk) and the "import
  /// exported profiles" path so a backup round-trip is LOSSLESS (selection +
  /// subscription info survive, not just the node list). Each node parses in its
  /// OWN try: one hand-edited/corrupt entry must never discard the whole store
  /// (that re-creates the "no servers" incident).
  static ({
    List<ParsedNode> nodes,
    String? selected,
    Map<String, SubInfo> subInfo
  })? decode(String text) {
    final Object? j;
    try {
      j = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (j is! Map || j['nodes'] is! List) return null;
    final nodes = <ParsedNode>[];
    for (final e in (j['nodes'] as List)) {
      try {
        if (e is! Map) continue;
        final tag = e['tag'];
        final outbound = e['outbound'];
        if (tag is! String || outbound is! Map) continue;
        nodes.add(ParsedNode(
          tag: tag,
          outbound: outbound.cast<String, dynamic>(),
          config: (e['config'] as Map?)?.cast<String, dynamic>(),
          source: e['source'] as String?,
        ));
      } catch (_) {
        // skip just this bad node, keep the rest
      }
    }
    final subInfo = <String, SubInfo>{};
    final si = j['subInfo'];
    if (si is Map) {
      si.forEach((k, v) {
        if (v is Map) subInfo['$k'] = SubInfo.fromJson(v);
      });
    }
    return (nodes: nodes, selected: j['selected'] as String?, subInfo: subInfo);
  }

  /// Serialize the store to a JSON string (the on-disk format). Shared by [save]
  /// and the "export profiles" backup — re-importable via the normal import path,
  /// which recognises this `{nodes:[…]}` shape.
  static String encode(List<ParsedNode> nodes, String? selected,
      [Map<String, SubInfo> subInfo = const {}]) {
    final j = {
      'nodes': nodes
          .map((n) => {
                'tag': n.tag,
                'outbound': n.outbound,
                if (n.config != null) 'config': n.config,
                if (n.source != null) 'source': n.source,
              })
          .toList(),
      'selected': selected,
      if (subInfo.isNotEmpty)
        'subInfo': {for (final e in subInfo.entries) e.key: e.value.toJson()},
    };
    return const JsonEncoder.withIndent('  ').convert(j);
  }

  static void save(List<ParsedNode> nodes, String? selected,
      [Map<String, SubInfo> subInfo = const {}]) {
    try {
      // Atomic (temp+rename) so a crash mid-write can't truncate the store and
      // lose every profile; guarded so a write failure can't crash a UI handler.
      CorePaths.atomicWrite(_file.path, encode(nodes, selected, subInfo));
    } catch (_) {}
  }
}
