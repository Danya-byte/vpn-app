import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_controller.dart';
import 'profile_store.dart';
import 'proxy_node.dart';
import 'share_link.dart';
import 'sub_info.dart';

class ProfilesState {
  const ProfilesState(
      {this.nodes = const [], this.selected, this.subInfo = const {}});

  final List<ParsedNode> nodes;
  final String? selected;
  final Map<String, SubInfo> subInfo; // source URL -> usage/expiry

  /// The selected node, or the first one as a sensible default.
  ParsedNode? get selectedNode {
    for (final n in nodes) {
      if (n.tag == selected) return n;
    }
    return nodes.isNotEmpty ? nodes.first : null;
  }

  /// Subscription usage/expiry for [n]'s source, if any.
  SubInfo? infoFor(ParsedNode? n) =>
      n?.source == null ? null : subInfo[n!.source];

  ProfilesState copyWith({
    List<ParsedNode>? nodes,
    String? selected,
    Map<String, SubInfo>? subInfo,
  }) =>
      ProfilesState(
        nodes: nodes ?? this.nodes,
        selected: selected ?? this.selected,
        subInfo: subInfo ?? this.subInfo,
      );
}

/// Outcome of an import: how many profiles were parsed vs newly added, and the
/// tag to (re)select afterwards (set even when nothing new was added).
class ImportResult {
  const ImportResult({required this.parsed, required this.added, this.firstTag});

  final int parsed;
  final int added;
  final String? firstTag;

  bool get recognized => parsed > 0;
  bool get alreadyImported => parsed > 0 && added == 0;
}

final profilesProvider =
    NotifierProvider<ProfilesController, ProfilesState>(ProfilesController.new);

class ProfilesController extends Notifier<ProfilesState> {
  bool _disposed = false;
  Timer? _autoRefresh;

  @override
  ProfilesState build() {
    // A subscription fetch can outlive this notifier (sheet torn down mid-fetch);
    // writing `state` after dispose throws in Riverpod 3.x. Track it and bail.
    ref.onDispose(() {
      _disposed = true;
      _autoRefresh?.cancel();
    });
    final loaded = ProfileStore.load();
    // Auto-update subscriptions every 6h (Hiddify-style) so dead nodes get
    // swapped out + usage/expiry stays fresh, without the user lifting a finger.
    _autoRefresh = Timer.periodic(const Duration(hours: 6), (_) {
      if (!_disposed && state.nodes.any((n) => n.source != null)) {
        refreshSubscriptions();
      }
    });
    return ProfilesState(
        nodes: loaded.nodes,
        selected: loaded.selected,
        subInfo: loaded.subInfo);
  }

  void _persist() =>
      ProfileStore.save(state.nodes, state.selected, state.subInfo);

  /// The whole profile store as a JSON string — for the "export profiles" backup
  /// (re-importable through [importText], which recognises the shape).
  String exportJson() =>
      ProfileStore.encode(state.nodes, state.selected, state.subInfo);

  void _storeInfo(String url, SubInfo? info) {
    if (info == null || _disposed) return;
    state = state.copyWith(subInfo: {...state.subInfo, url: info});
  }

  /// Import links, a base64 subscription, or a whole sing-box config. De-dupes
  /// by content: re-importing the same profile adds nothing but still returns
  /// its tag, so callers can re-select and reconnect to it.
  ImportResult importText(String text,
      {bool selectFirst = false, String? source}) {
    // An exported store ({nodes:[…], selected, subInfo}) re-imports through the
    // same path — detect it first so the round-trip is LOSSLESS (selection +
    // subscription info restored, below), else parse links / a base64 sub / a
    // whole config.
    final t = text.trim();
    final store = t.startsWith('{') ? ProfileStore.decode(t) : null;
    final parsed = (store != null && store.nodes.isNotEmpty)
        ? store.nodes
        : ShareLink.parseSubscription(text);
    if (parsed.isEmpty) return const ImportResult(parsed: 0, added: 0);

    final nodes = [...state.nodes];
    final byContent = {for (final n in nodes) _contentKey(n): n.tag};
    final tags = {for (final n in nodes) n.tag};
    String? firstTag;
    var added = 0;
    for (final p in parsed) {
      final existing = byContent[_contentKey(p)];
      if (existing != null) {
        firstTag ??= existing; // already imported -> reuse its tag
        continue;
      }
      // New content: ensure a unique display tag.
      var tag = p.tag;
      var i = 2;
      while (tags.contains(tag)) {
        tag = '${p.tag} ($i)';
        i++;
      }
      final node = (tag == p.tag && source == null && p.source == null)
          ? p
          : ParsedNode(
              tag: tag,
              outbound: tag == p.tag
                  ? p.outbound
                  : {...p.outbound, if (p.outbound.isNotEmpty) 'tag': tag},
              config: p.config,
              source: source ?? p.source,
            );
      nodes.add(node);
      tags.add(tag);
      byContent[_contentKey(node)] = tag;
      firstTag ??= tag;
      added++;
    }

    // Guard the async path: if the provider was disposed while a subscription
    // fetch was in flight, don't touch state (it would throw).
    if (_disposed) {
      return ImportResult(
          parsed: parsed.length, added: added, firstTag: firstTag);
    }
    state = state.copyWith(
      nodes: nodes,
      // A re-imported backup restores its subscription info too (merge over any
      // existing) so the export round-trip is lossless.
      subInfo: (store != null && store.subInfo.isNotEmpty)
          ? {...state.subInfo, ...store.subInfo}
          : state.subInfo,
      // Restore the backup's saved selection — but only if that tag survived
      // de-dupe into the merged store (else fall through to the normal rule).
      // Auto-select otherwise ONLY when the caller explicitly asks (trusted
      // import) — NOT on an empty store: an untrusted deeplink/QR/drag import must
      // not become the active node without the preview-gate's consent (H2).
      // Trusted paths (in-app paste, server-gen) pass selectFirst:true;
      // applyImport selects explicitly after the gate.
      selected:
          (store?.selected != null && nodes.any((n) => n.tag == store!.selected))
              ? store!.selected
              : (selectFirst ? (firstTag ?? state.selected) : state.selected),
    );
    _persist();
    return ImportResult(parsed: parsed.length, added: added, firstTag: firstTag);
  }

  Future<({String body, SubInfo? info})> _fetch(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      // A blocked/expired sub in RF often returns an HTML error or captive
      // portal (200 with markup) or a 4xx/5xx — don't parse that as a node list.
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(url));
      }
      // Standard panel header: used/total traffic + expiry (Marzban/3x-ui/…).
      final info = SubInfo.parse(resp.headers.value('subscription-userinfo'));
      final body = await resp.transform(utf8.decoder).join();
      final head = body.trimLeft().toLowerCase();
      if (head.startsWith('<!doctype') || head.startsWith('<html')) {
        throw const HttpException('subscription returned HTML, not a node list');
      }
      return (body: body, info: info);
    } finally {
      client.close(force: true);
    }
  }

  /// Fetch a subscription URL and import it (tagging nodes with their source so
  /// they can be refreshed later). Throws on network failure.
  Future<ImportResult> importSubscriptionUrl(String url) async {
    final f = await _fetch(url);
    _storeInfo(url, f.info);
    return importText(f.body, source: url);
  }

  /// Re-fetch every subscription the current profiles came from and import
  /// fresh nodes (content-dedup keeps existing ones). Skips unreachable sources.
  Future<ImportResult> refreshSubscriptions() async {
    final sources =
        state.nodes.map((n) => n.source).whereType<String>().toSet();
    var parsed = 0, added = 0;
    String? firstTag;
    for (final url in sources) {
      try {
        final f = await _fetch(url);
        _storeInfo(url, f.info);
        final r = importText(f.body, source: url);
        parsed += r.parsed;
        added += r.added;
        firstTag ??= r.firstTag;
      } catch (_) {
        // skip an unreachable / failed source
      }
    }
    return ImportResult(parsed: parsed, added: added, firstTag: firstTag);
  }

  void select(String tag) {
    if (state.selected == tag) return; // no change
    state = state.copyWith(selected: tag);
    _persist();
    // Apply the new selection to the LIVE tunnel — otherwise the user switches
    // profile but traffic keeps flowing through the old one ("doesn't
    // reconnect"). Seamless: restart() keeps the proxy pinned (fails closed).
    if (ref.read(coreControllerProvider).isOn) {
      ref.read(coreControllerProvider.notifier).restart(reason: 'select node');
    }
  }

  void remove(String tag) {
    // Was traffic currently flowing through the node being deleted?
    final removingActive = state.selectedNode?.tag == tag;
    final nodes = state.nodes.where((n) => n.tag != tag).toList();
    final selected = state.selected == tag
        ? (nodes.isNotEmpty ? nodes.first.tag : null)
        : state.selected;
    state = ProfilesState(nodes: nodes, selected: selected);
    _persist();
    // Don't keep tunnelling through a profile the user just deleted: switch the
    // live core to the new selection, or stop it if nothing is left.
    if (removingActive && ref.read(coreControllerProvider).isOn) {
      final ctl = ref.read(coreControllerProvider.notifier);
      nodes.isEmpty ? ctl.stop() : ctl.restart(reason: 'remove node');
    }
  }

  void clear() {
    state = const ProfilesState();
    _persist();
  }

  /// Identity of a profile by content (ignoring its display tag), so the same
  /// node/config imported twice is recognized as a duplicate. Keys are sorted
  /// recursively first: JSON map order isn't canonical, so a subscription that
  /// returns the same node with keys in a different order must still dedupe
  /// (else every refresh re-adds it as "Name (2)", "(3)", … unbounded).
  String _contentKey(ParsedNode n) {
    if (n.config != null) return jsonEncode(_canonical(n.config));
    final ob = {...n.outbound}..remove('tag');
    return jsonEncode(_canonical(ob));
  }

  static dynamic _canonical(dynamic v) {
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _canonical(v[k])};
    }
    if (v is List) return v.map(_canonical).toList();
    return v;
  }
}
