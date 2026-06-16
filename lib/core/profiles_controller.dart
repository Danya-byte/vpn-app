import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_controller.dart';
import 'latency_probe.dart';
import 'profile_store.dart';
import 'proxy_node.dart';
import 'share_link.dart';
import 'share_link_encoder.dart';
import 'sub_info.dart';

/// Outcome of [ProfilesController.pinCertificate].
enum PinResult { ok, badPem, multipleServers, noTarget }

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
  const ImportResult(
      {required this.parsed,
      required this.added,
      this.firstTag,
      this.addedTags = const []});

  final int parsed;
  final int added;
  final String? firstTag;
  // Tags of the NEWLY-added nodes, so a declined external import can be rolled
  // back (the node must not linger in the list after the user said no).
  final List<String> addedTags;

  bool get recognized => parsed > 0;
  bool get alreadyImported => parsed > 0 && added == 0;
}

final profilesProvider =
    NotifierProvider<ProfilesController, ProfilesState>(ProfilesController.new);

class ProfilesController extends Notifier<ProfilesState> {
  bool _disposed = false;
  Timer? _autoRefresh;
  Timer? _launchRefresh;

  // Is a tunnel currently up? Read (not watched) so this never makes profiles
  // depend on the core at build time (which would be a provider cycle — the core
  // already reads profiles). Safe from the post-build timer callbacks.
  bool _connected() => ref.read(coreControllerProvider).isOn;

  @override
  ProfilesState build() {
    // A subscription fetch can outlive this notifier (sheet torn down mid-fetch);
    // writing `state` after dispose throws in Riverpod 3.x. Track it and bail.
    ref.onDispose(() {
      _disposed = true;
      _autoRefresh?.cancel();
      _launchRefresh?.cancel();
    });
    final loaded = ProfileStore.load();
    // Auto-update subscriptions every 6h (Hiddify-style) so dead nodes get
    // swapped out + usage/expiry stays fresh, without the user lifting a finger.
    // GATED on a live tunnel: in RF the subscription host is reachable only THROUGH
    // the tunnel, so a fetch while disconnected just fails + wastes a request.
    _autoRefresh = Timer.periodic(const Duration(hours: 6), (_) {
      if (!_disposed && state.nodes.any((n) => n.source != null) && _connected()) {
        refreshSubscriptions();
      }
    });
    // Also refresh once shortly after launch IF a tunnel is already up (resume-on-
    // launch), so you open the app to fresh servers instead of waiting up to 6h.
    // The source-node check runs FIRST so a sub-less store never reads the core.
    _launchRefresh = Timer(const Duration(seconds: 12), () {
      if (!_disposed && state.nodes.any((n) => n.source != null) && _connected()) {
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
    // Our own `vpn://share` bundle pasted as TEXT (manual paste dialog / clipboard
    // button): ShareLink.parseSubscription below doesn't know the scheme and would
    // report "nothing recognized" — the exact bug a user hit pasting a share link.
    // Decode it here so EVERY importText caller handles bundles. (The richer
    // preview + apply-settings flow stays in importDroppedContent for drops/
    // deeplinks; a manual paste just imports the nodes.)
    if (t.startsWith('vpn://share')) {
      final bundle = ShareLinkEncoder.decodeBundle(t);
      if (bundle != null) {
        // Honor the bundle's own auto-update subscription URL (same as the
        // drag/deeplink route does) — else a PASTED share imports the same nodes
        // but they silently never refresh. Sender SETTINGS stay paste-dropped by
        // design: applying them is never silent and needs the consent dialog,
        // which lives on the importDroppedContent route.
        return importNodes(bundle.nodes,
            selectFirst: selectFirst,
            source: source ?? (bundle.autoUpdate ? bundle.subUrl : null));
      }
    }
    final store = t.startsWith('{') ? ProfileStore.decode(t) : null;
    final parsed = (store != null && store.nodes.isNotEmpty)
        ? store.nodes
        : ShareLink.parseSubscription(text);
    if (parsed.isEmpty) return const ImportResult(parsed: 0, added: 0);

    final nodes = [...state.nodes];
    final byContent = {for (final n in nodes) _contentKey(n): n.tag};
    final tags = {for (final n in nodes) n.tag};
    String? firstTag;
    final addedTags = <String>[];
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
      addedTags.add(tag);
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
    return ImportResult(
        parsed: parsed.length,
        added: added,
        firstTag: firstTag,
        addedTags: addedTags);
  }

  /// Add already-parsed nodes (e.g. from a decoded `vpn://share` bundle) — same
  /// content-dedup, unique-tag and persist as [importText], but for ParsedNodes
  /// that don't need re-parsing. [selectFirst] only auto-selects on a trusted
  /// path; an untrusted bundle leaves selection to the preview gate (H2). When
  /// [source] is set the nodes are tagged with it so the 6-hourly refresh keeps
  /// them fresh.
  ImportResult importNodes(List<ParsedNode> parsed,
      {bool selectFirst = false, String? source}) {
    if (parsed.isEmpty) return const ImportResult(parsed: 0, added: 0);
    final nodes = [...state.nodes];
    final byContent = {for (final n in nodes) _contentKey(n): n.tag};
    final tags = {for (final n in nodes) n.tag};
    String? firstTag;
    final addedTags = <String>[];
    var added = 0;
    for (final p in parsed) {
      final existing = byContent[_contentKey(p)];
      if (existing != null) {
        firstTag ??= existing;
        continue;
      }
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
      addedTags.add(tag);
      added++;
    }
    if (_disposed) {
      return ImportResult(
          parsed: parsed.length, added: added, firstTag: firstTag);
    }
    state = state.copyWith(
      nodes: nodes,
      selected: selectFirst ? (firstTag ?? state.selected) : state.selected,
    );
    _persist();
    return ImportResult(
        parsed: parsed.length,
        added: added,
        firstTag: firstTag,
        addedTags: addedTags);
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

  /// Rename a profile (display name + its outbound tag). No-op if the new name is
  /// empty, unchanged, or already used by another profile. Renaming a NON-active
  /// profile is purely cosmetic (no reconnect). Renaming the LIVE-active profile
  /// does a brief restart — the running config still carries the OLD outbound tag,
  /// and the latency / active-server readouts now watch the NEW selected tag, so
  /// without a restart they'd 404 against the core and blank out. Matches the
  /// select/remove behaviour (which also restart on an active change).
  /// Returns false when nothing was renamed (empty/unchanged name, name already
  /// taken, node gone) so the dialog can SAY so instead of silently closing.
  bool rename(String oldTag, String newTag) {
    final name = newTag.trim();
    if (name.isEmpty || name == oldTag) return false;
    if (state.nodes.any((n) => n.tag == name)) return false; // name taken
    final renamingActive = state.selectedNode?.tag == oldTag;
    var found = false;
    final nodes = state.nodes.map((n) {
      if (n.tag != oldTag) return n;
      found = true;
      final ob = {...n.outbound};
      if (ob.containsKey('tag')) ob['tag'] = name;
      return ParsedNode(
          tag: name, outbound: ob, config: n.config, source: n.source);
    }).toList();
    if (!found) return false;
    state = state.copyWith(
        nodes: nodes,
        selected: state.selected == oldTag ? name : state.selected);
    _persist();
    if (renamingActive && ref.read(coreControllerProvider).isOn) {
      ref.read(coreControllerProvider.notifier).restart(reason: 'rename node');
    }
    return true;
  }

  static bool _isInsecure(Map o) {
    final tls = o['tls'];
    return tls is Map && tls['insecure'] == true && tls['reality'] == null;
  }

  /// Validate a PEM CERTIFICATE block: ORDERED BEGIN..END markers whose body
  /// base64-decodes to a non-trivial DER. Returns the clean BEGIN..END lines, or
  /// null — so a marker-only / garbled-body paste is NEVER written into the TLS
  /// block (which would FATAL the core on the next start, tearing down the tunnel).
  static List<String>? _validatePemCertificate(String pem) {
    final lines = pem
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final begin = lines.indexWhere((l) => l.contains('BEGIN CERTIFICATE'));
    final end = lines.indexWhere((l) => l.contains('END CERTIFICATE'));
    if (begin < 0 || end <= begin) return null;
    try {
      final der = base64.decode(lines.sublist(begin + 1, end).join());
      if (der.length < 100) return null; // too small to be a real X.509 cert
    } catch (_) {
      return null; // body isn't valid base64
    }
    return lines.sublist(begin, end + 1);
  }

  /// Pin a server certificate (PEM) onto [tag] so the client trusts ONLY that cert
  /// and `insecure` (no verification — an on-path MITM hole) can be turned off.
  /// Verified for hysteria2/tuic (sing-box honours an inline cert). A config with
  /// MORE THAN ONE insecure server is REFUSED ([PinResult.multipleServers]) — one
  /// pasted cert can't be correct for several distinct self-signed exits, and
  /// silently pinning it onto all of them would break the others AND hide their
  /// MITM badge. Restarts the live tunnel if the pinned node is the active one.
  PinResult pinCertificate(String tag, String pem) {
    final lines = _validatePemCertificate(pem);
    if (lines == null) return PinResult.badPem;

    ParsedNode? target;
    for (final n in state.nodes) {
      if (n.tag == tag) {
        target = n;
        break;
      }
    }
    if (target == null) return PinResult.noTarget;

    if (target.isConfig) {
      final insecure = <Map>[];
      for (final key in const ['outbounds', 'endpoints']) {
        for (final o in (target.config?[key] as List?) ?? const []) {
          if (o is Map && _isInsecure(o)) insecure.add(o);
        }
      }
      if (insecure.isEmpty) return PinResult.noTarget;
      if (insecure.length > 1) return PinResult.multipleServers;
    } else if (!_isInsecure(target.outbound)) {
      return PinResult.noTarget;
    }

    void pinTls(Map o) {
      final tls = o['tls'] as Map;
      tls['certificate'] = lines;
      tls['insecure'] = false; // trust the pinned cert, not "trust anything"
    }

    final pinningActive = state.selectedNode?.tag == tag;
    final nodes = state.nodes.map((n) {
      if (n.tag != tag) return n;
      if (n.config != null) {
        final cfg = jsonDecode(jsonEncode(n.config)) as Map<String, dynamic>;
        for (final key in const ['outbounds', 'endpoints']) {
          for (final o in (cfg[key] as List?) ?? const []) {
            if (o is Map && _isInsecure(o)) pinTls(o);
          }
        }
        return ParsedNode(
            tag: n.tag, outbound: n.outbound, config: cfg, source: n.source);
      }
      final ob = jsonDecode(jsonEncode(n.outbound)) as Map<String, dynamic>;
      pinTls(ob);
      return ParsedNode(
          tag: n.tag, outbound: ob, config: n.config, source: n.source);
    }).toList();
    state = state.copyWith(nodes: nodes);
    _persist();
    if (pinningActive && ref.read(coreControllerProvider).isOn) {
      ref
          .read(coreControllerProvider.notifier)
          .restart(reason: 'pin certificate');
    }
    return PinResult.ok;
  }

  /// Reverse a cert pin: drop `tls.certificate` and restore `insecure:true` on the
  /// pinned outbound(s). A WRONG-but-structurally-valid pasted cert would brick the
  /// node (handshake fails) WHILE hiding its MITM badge, with no other way back —
  /// this makes it recoverable in-app (then re-pin the correct cert). Restarts the
  /// live tunnel if the node is active. Returns false if the node isn't pinned.
  bool unpinCertificate(String tag) {
    ParsedNode? target;
    for (final n in state.nodes) {
      if (n.tag == tag) {
        target = n;
        break;
      }
    }
    if (target == null || !target.pinned) return false;

    void unpinTls(Map o) {
      final tls = o['tls'];
      if (tls is Map && tls['certificate'] != null) {
        tls.remove('certificate');
        tls['insecure'] = true; // back to the flagged + consent-gated state
      }
    }

    final active = state.selectedNode?.tag == tag;
    final nodes = state.nodes.map((n) {
      if (n.tag != tag) return n;
      if (n.config != null) {
        final cfg = jsonDecode(jsonEncode(n.config)) as Map<String, dynamic>;
        for (final key in const ['outbounds', 'endpoints']) {
          for (final o in (cfg[key] as List?) ?? const []) {
            if (o is Map) unpinTls(o);
          }
        }
        return ParsedNode(
            tag: n.tag, outbound: n.outbound, config: cfg, source: n.source);
      }
      final ob = jsonDecode(jsonEncode(n.outbound)) as Map<String, dynamic>;
      unpinTls(ob);
      return ParsedNode(
          tag: n.tag, outbound: ob, config: n.config, source: n.source);
    }).toList();
    state = state.copyWith(nodes: nodes);
    _persist();
    if (active && ref.read(coreControllerProvider).isOn) {
      ref
          .read(coreControllerProvider.notifier)
          .restart(reason: 'unpin certificate');
    }
    return true;
  }

  void remove(String tag) {
    // Drop any stale latency chip for this tag — else a later node that reuses the
    // same display name would inherit the deleted node's measurement.
    ref.read(latencyProbeProvider.notifier).forget(tag);
    // Was traffic currently flowing through the node being deleted?
    final removingActive = state.selectedNode?.tag == tag;
    final nodes = state.nodes.where((n) => n.tag != tag).toList();
    final selected = state.selected == tag
        ? (nodes.isNotEmpty ? nodes.first.tag : null)
        : state.selected;
    state = ProfilesState(nodes: nodes, selected: selected);
    // Removing the LAST node is a deliberate empty — drop the backup so it isn't
    // resurrected on the next launch (else [ProfileStore.load] would recover it).
    if (nodes.isEmpty) {
      ProfileStore.save(state.nodes, state.selected, state.subInfo, true);
    } else {
      _persist();
    }
    // Don't keep tunnelling through a profile the user just deleted: switch the
    // live core to the new selection, or stop it if nothing is left.
    if (removingActive && ref.read(coreControllerProvider).isOn) {
      final ctl = ref.read(coreControllerProvider.notifier);
      nodes.isEmpty ? ctl.stop() : ctl.restart(reason: 'remove node');
    }
  }

  void clear() {
    state = const ProfilesState();
    // Deliberate wipe → drop the recovery backup too (else load() restores it).
    ProfileStore.save(state.nodes, state.selected, state.subInfo, true);
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
