import 'clash_api.dart';

/// PURE transport-cascade + watchdog decision logic, deliberately kept FREE of
/// the FFI-heavy [CoreController] (native admin / kill-switch) so it imports
/// cleanly into unit tests AND standalone `dart run` tools — and so the safety-
/// critical decisions (family classification, the dark-path order, the episode
/// reset) live in one small, fully-tested place a future refactor can't silently
/// break. The controller wires these to real I/O; everything here is I/O-free.

/// Resolve the LEAF node carrying traffic: the top switchable group (route final,
/// not nested, excluding GLOBAL) followed by each group's `now` down through
/// nested selectors/urltests until a real node. Shared by the Home label + the
/// proactive-degradation watchdog + the fp-no-op check.
String? resolveLeafFromGroups(List<ProxyGroup> groups) {
  if (groups.isEmpty) return null;
  final byName = {for (final g in groups) g.name: g};
  bool isGroup(ProxyGroup g) => g.type == 'Selector' || g.type == 'URLTest';
  final nested = <String>{};
  for (final g in groups) {
    if (isGroup(g)) nested.addAll(g.all);
  }
  ProxyGroup? top;
  for (final g in groups) {
    if (g.name == 'GLOBAL' || !isGroup(g) || nested.contains(g.name)) continue;
    top = g;
    if (g.type == 'Selector') break;
  }
  var tag = top?.now ?? top?.name;
  final seen = <String>{};
  while (tag != null &&
      byName[tag] != null &&
      isGroup(byName[tag]!) &&
      seen.add(tag)) {
    final g = byName[tag]!;
    tag = g.now ?? (g.all.isNotEmpty ? g.all.first : null);
  }
  return tag;
}

bool _typeIsQuic(String? t) =>
    t == 'Hysteria2' || t == 'Tuic' || t == 'Hysteria';

/// #6 — clear the dark-episode's tried-transport set THIS healthy tick? Only on
/// SUSTAINED recovery (≥3 consecutive healthy cycles, ~54 s), never the first, so
/// a family blocked early in a ТСПУ wave becomes re-eligible once the wave passes
/// instead of being skipped for the whole session. PURE (unit-tested).
bool watchdogShouldClearEpisode({
  required bool episodeActive,
  required int healthyStreak,
}) => episodeActive && healthyStreak >= 3;

/// What the dark-path watchdog decided to do — see [runDarkPath].
enum DarkAction {
  networkDownBail, // #1 gate: local network is down, not a tunnel block
  cascaded, // a restart-free transport hop broke through
  stopIpBlock, // every family dark at once → IP/server block (fp can't help)
  stopFpNoop, // surviving leaf is Reality/QUIC → fp/fragment/mux is a no-op
  stopExhausted, // every fp variant already tried
  fpEscalate, // restart with the next anti-block variant
}

/// The dark-path watchdog flow with ALL its I/O injected as thunks, so its
/// safety-critical ORDER is unit-tested WITHOUT a live tunnel (review: "extract
/// _tunnelHealthy/_directNetworkUp as seams so the state machine is testable —
/// that's the difference between 'works for me' and 'won't fail the user'").
/// Returns the action [CoreController._checkHealth] should execute. Guarantees,
/// in strict order:
///  1. the network gate runs FIRST and, when down, [tryHop] is NEVER invoked
///     (#1 — a downed Wi-Fi/captive portal must not trigger a cascade or an
///     fp-restart; the test asserts tryHop was not called);
///  2. a successful hop short-circuits before any fp logic;
///  3. an IP-block stop (every family dark) and an fp-no-op stop (Reality/QUIC)
///     both precede an fp-restart — so we never burn a restart that can't help.
Future<DarkAction> runDarkPath({
  required Future<bool> Function() networkUp,
  required Future<bool> Function() tryHop,
  required bool Function() allDark,
  required Future<String?> Function() leafFamily,
  required bool variantsExhausted,
}) async {
  if (!await networkUp()) {
    return DarkAction.networkDownBail; // #1 GATE, before the hop
  }
  if (await tryHop()) return DarkAction.cascaded;
  if (allDark()) {
    return DarkAction.stopIpBlock; // tryHop set this as a side effect
  }
  if (familyResistsFpCycling(await leafFamily())) return DarkAction.stopFpNoop;
  if (variantsExhausted) return DarkAction.stopExhausted;
  return DarkAction.fpEscalate;
}

/// Does the active leaf's FAMILY make fingerprint/fragment/mux cycling pointless?
/// Reality pins the chrome uTLS ClientHello (no rotation), and QUIC families
/// (Hysteria2/TUIC/Hysteria) carry no uTLS and no TCP-TLS record to fragment — so
/// an fp-escalation restart is wasted there (review: fold the rotation argument
/// into the reactive branch too). PURE.
bool familyResistsFpCycling(String? family) =>
    family != null &&
    (family.endsWith('-reality') ||
        family == 'hysteria2' ||
        family == 'hysteria' ||
        family == 'tuic');

/// Classify each proxy outbound by its true anti-DPI FAMILY (signature) — keyed
/// by tag (== Clash proxy name) — because the Clash API's raw `type` is too
/// coarse for the cascade's "a DIFFERENT transport" test (review finding A):
///  • VLESS+Reality and plain VLESS+TLS are BOTH Clash-type `Vless`, yet Reality
///    is a wholly different signature — the cascade must be willing to hop
///    between them, which keying on raw type forbids.
///  • XHTTP only shows up as `Socks` because we bridge it through xray (its tag
///    survives, the type becomes socks at the API). That's a load-bearing
///    accident: classify from the REAL outbound (this MUST be computed BEFORE
///    [CoreController._bridgeXray] rewrites XHTTP→socks) so a future native XHTTP
///    — or a bridge retag — never silently merges XHTTP with Reality.
/// Selectors/urltests/direct/block/dns are skipped (not proxy leaves). Pass the
/// result into [planCascade] as `families`; null there falls back to raw type.
Map<String, String> familiesFromConfig(Map<String, dynamic> cfg) {
  final out = <String, String>{};
  void classify(dynamic o) {
    if (o is! Map) return;
    final tag = o['tag']?.toString();
    if (tag == null || tag.isEmpty) return;
    final type = (o['type'] ?? '').toString().toLowerCase();
    String? fam;
    switch (type) {
      case 'vless':
      case 'vmess':
      case 'trojan':
        final tls = o['tls'];
        final reality = tls is Map ? tls['reality'] : null;
        final hasReality = reality is Map && reality['enabled'] != false;
        final tr = o['transport'];
        final trType = (tr is Map
            ? tr['type']?.toString().toLowerCase()
            : null);
        if (hasReality) {
          fam = '$type-reality';
        } else if (trType != null && trType.isNotEmpty) {
          fam = '$type-$trType'; // xhttp / ws / grpc / httpupgrade / http
        } else {
          fam = '$type-tls';
        }
      case 'hysteria2':
      case 'hysteria':
      case 'tuic':
      case 'shadowtls':
      case 'anytls':
      case 'shadowsocks':
      case 'socks':
      case 'http':
      case 'wireguard':
        fam = type; // already a distinct family on its own
      default:
        fam = null; // selector/urltest/direct/block/dns/etc — not a proxy leaf
    }
    if (fam != null) out[tag] = fam;
  }

  for (final o in (cfg['outbounds'] as List?) ?? const []) {
    classify(o);
  }
  for (final e in (cfg['endpoints'] as List?) ?? const []) {
    classify(e); // wireguard lives under endpoints in sing-box ≥1.12
  }
  return out;
}

/// Leaf tags whose outbound disables TLS cert validation where that is a real
/// MITM hole (tls.insecure, NO Reality; hysteria2/tuic excluded — they auth the
/// server by PSK beyond the cert). The auto-failover pool AND the unattended
/// watchdog cascade must NEVER silently route through one (H5) — the user only
/// reaches it via an explicit, consent-gated manual connect. Mirrors
/// ParsedNode.insecure for raw cfg outbounds; pass into [planCascade] as
/// `insecure`.
Set<String> insecureTagsFromConfig(Map<String, dynamic> cfg) {
  final out = <String>{};
  void scan(dynamic o) {
    if (o is! Map) return;
    final tag = o['tag']?.toString();
    if (tag == null || tag.isEmpty) return;
    final type = o['type']?.toString();
    if (type == 'hysteria2' || type == 'tuic') return;
    final tls = o['tls'];
    if (tls is Map && tls['insecure'] == true && tls['reality'] == null) {
      out.add(tag);
    }
  }

  for (final o in (cfg['outbounds'] as List?) ?? const []) {
    scan(o);
  }
  for (final e in (cfg['endpoints'] as List?) ?? const []) {
    scan(e);
  }
  return out;
}

/// The result of planning a transport-cascade hop — PURE (no I/O) so it's unit
/// testable. Given the live proxy groups + the families already tried this dark
/// episode, it picks the top switchable Selector (route final), resolves the
/// current active leaf + its transport family, and orders the untried-family
/// candidates by PHYSICAL-LAYER diversity (a different L4 first, so a TCP wave is
/// answered by QUIC — not another TCP). Candidates may be leaf nodes OR sub-
/// GROUPS (single-transport pools — finding B): PUT-ing a urltest pool on the
/// PARENT selector is allowed, so `Selector[Reality-pool, Hy2-pool]` cascades.
class CascadePlan {
  const CascadePlan({
    this.selector,
    this.leaf,
    this.leafType,
    this.candidates = const [],
    this.probeTargets = const {},
  });
  final String? selector; // the Selector we can PUT (null → nothing to cascade)
  final String? leaf; // current active leaf node
  final String?
  leafType; // its FAMILY (refined where known, else raw Clash type)
  final List<String>
  candidates; // untried-family members (nodes OR pools), ordered
  final Map<String, String>
  probeTargets; // candidate → leaf node to /delay (pools)

  /// What to actually run a /delay against for [candidate]: a pool's leaf node
  /// (delay on a bare node is universally supported), else the candidate itself.
  String probeFor(String candidate) => probeTargets[candidate] ?? candidate;
}

CascadePlan planCascade(
  List<ProxyGroup> groups,
  Set<String> tried, {
  Map<String, String>? families,
  Set<String>? insecure,
}) {
  if (groups.isEmpty) return const CascadePlan();
  final byName = {for (final g in groups) g.name: g};
  bool isGroup(ProxyGroup g) => g.type == 'Selector' || g.type == 'URLTest';
  // Drill a (possibly group) member down to the real leaf node it resolves to.
  String? leafOf(String? tag) {
    final seen = <String>{};
    while (tag != null &&
        byName[tag] != null &&
        isGroup(byName[tag]!) &&
        seen.add(tag)) {
      final g = byName[tag]!;
      tag = g.now ?? (g.all.isNotEmpty ? g.all.first : null);
    }
    return tag;
  }

  // The anti-DPI FAMILY of a member: refined from the config where we have it,
  // else the raw Clash type of the leaf it resolves to (finding A).
  String? familyOf(String tag) {
    final leaf = leafOf(tag);
    if (leaf == null) return null;
    return families?[leaf] ?? byName[leaf]?.type;
  }

  // The leaf's RAW Clash type — the physical layer (TCP↔QUIC), used for ordering
  // only, independent of the refined signature family.
  String? rawTypeOf(String tag) {
    final leaf = leafOf(tag);
    return leaf != null ? byName[leaf]?.type : null;
  }

  final nested = <String>{};
  for (final g in groups) {
    if (isGroup(g)) nested.addAll(g.all);
  }
  ProxyGroup? sel;
  for (final g in groups) {
    if (g.name == 'GLOBAL' || g.type != 'Selector' || nested.contains(g.name)) {
      continue;
    }
    sel = g;
    break;
  }
  if (sel == null || sel.all.length < 2) return const CascadePlan();
  final selNow = sel.now;
  final members = sel.all;
  final leaf = leafOf(selNow);
  final leafFamily = leaf != null
      ? (families?[leaf] ?? byName[leaf]?.type)
      : null;
  final curQuic = _typeIsQuic(leaf != null ? byName[leaf]?.type : null);
  final cands =
      members.where((m) {
        if (m == selNow) return false; // never the member we're already on
        // NEVER auto-hop onto a cert-unvalidated (MITM-able) node — that is the
        // exact silent interception the H5 consent gate blocks on a manual
        // connect; the unattended cascade must honour it too.
        final lf = leafOf(m);
        if (lf != null && (insecure?.contains(lf) ?? false)) return false;
        final f = familyOf(m);
        if (f == null) return false; // unresolvable / not a proxy
        return f !=
                leafFamily && // a DIFFERENT family than the (dark) current one
            !tried.contains(f); // not already tried this episode
      }).toList()..sort((a, b) {
        // a different physical layer than the current leaf comes first (TCP↔QUIC).
        final da = _typeIsQuic(rawTypeOf(a)) != curQuic ? 0 : 1;
        final db = _typeIsQuic(rawTypeOf(b)) != curQuic ? 0 : 1;
        return da.compareTo(db);
      });
  // A pool candidate is PUT by group name but probed at its leaf node.
  final probes = <String, String>{};
  for (final m in cands) {
    final g = byName[m];
    if (g != null && isGroup(g)) {
      final t = leafOf(m);
      if (t != null && t != m) probes[m] = t;
    }
  }
  return CascadePlan(
    selector: sel.name,
    leaf: leaf,
    leafType: leafFamily,
    candidates: cands,
    probeTargets: probes,
  );
}
