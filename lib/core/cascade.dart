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
  whitelistMode, // RU reachable but ALL foreign IPs dark → state-allowlist collapse
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
///  2. the whitelist gate runs next: RU answers but EVERY foreign IP is dark →
///     the mobile network collapsed to the state IP/SNI allowlist, so no foreign
///     exit is physically reachable — hopping transports/fp is futile, stop and
///     inform WITHOUT calling [tryHop] (the test asserts tryHop was not called);
///  3. a successful hop short-circuits before any fp logic;
///  4. an IP-block stop (every family dark) and an fp-no-op stop (Reality/QUIC)
///     both precede an fp-restart — so we never burn a restart that can't help.
Future<DarkAction> runDarkPath({
  required Future<bool> Function() networkUp,
  required Future<bool> Function() foreignReachable,
  required Future<bool> Function() tryHop,
  required bool Function() allDark,
  required Future<String?> Function() leafFamily,
  required bool variantsExhausted,
}) async {
  if (!await networkUp()) {
    return DarkAction.networkDownBail; // #1 GATE, before the hop
  }
  // Whitelist-mode gate, BEFORE the cascade: a raw foreign reach (not a <16KB
  // 204, which the 16KB-freeze can let through) — when every foreign control IP
  // is dark while RU is up, the network fell back to the allowlist and cascading
  // is physically futile.
  if (!await foreignReachable()) return DarkAction.whitelistMode;
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

/// RF-2026 survivability TIER of a transport family (higher = more likely to get
/// through ТСПУ). Verified intel (deep-research 2026-06-04): the censor now blocks
/// plain VLESS / SOCKS5 / L2TP by signature (Dec-2025) and plain WireGuard ~100%
/// by its fixed 148-byte handshake; the survivors are transport-OBFUSCATED —
/// XHTTP-split request/response pairs and QUIC (Hysteria2/TUIC) — plus Reality
/// (the inner VLESS is wrapped in a real-SNI TLS handshake, so the VLESS signature
/// is encrypted). Used as the PRIMARY ordering key in [planCascade] so a hop lands
/// on a survivor first. A PRIOR, not gospel: the live /delay probe still decides,
/// so even if Reality were degraded the cascade self-corrects. PURE.
///   3 = verified survivor   (reality / xhttp / hysteria2 / tuic / hysteria)
///   2 = obfuscated / wrapped (shadowtls / anytls / *-grpc / *-ws / *-httpupgrade / *-http)
///   1 = bare TLS incl. plain VLESS, now signature-targeted (vless/trojan/vmess-tls; unknown)
///   0 = detected-by-design   (plain shadowsocks / wireguard / socks / http-proxy)
int transportSurvivability(String? family) {
  if (family == null) return 1;
  final f = family.toLowerCase();
  if (f.endsWith('-reality') ||
      f.endsWith('-xhttp') ||
      f == 'hysteria2' ||
      f == 'tuic' ||
      f == 'hysteria') {
    return 3;
  }
  // Plain VLESS is Dec-2025 signature-blocked REGARDLESS of its TCP transport: a
  // ws / grpc / httpupgrade wrapper does NOT mask the VLESS signature the way
  // Reality does (only the -reality / -xhttp forms above survive). So vless-ws /
  // vless-grpc are NOT meaningfully more survivable than bare vless-tls — rank
  // them tier 1, not tier 2, so the cascade doesn't waste an episode hopping to an
  // equally-detectable VLESS form instead of jumping to Reality/XHTTP/QUIC.
  if (f.startsWith('vless-')) return 1;
  if (f == 'shadowtls' ||
      f == 'anytls' ||
      f == 'amneziawg' || // WireGuard with Amnezia DPI-evading obfuscation
      f == 'shadowsocks-plugin' || // SS behind an obfs / v2ray plugin
      f.endsWith('-grpc') ||
      f.endsWith('-ws') ||
      f.endsWith('-httpupgrade') ||
      f.endsWith('-http')) {
    return 2;
  }
  if (f == 'wireguard' || f == 'shadowsocks' || f == 'socks' || f == 'http') {
    return 0;
  }
  return 1; // bare TLS (incl. plain trojan/vmess-tls — also signature-adjacent)
}

/// True iff [family] rides a transport the 2025 16KB connection-FREEZE can't
/// policing: QUIC (Hysteria2/TUIC/Hysteria) is UDP — not the per-TCP-connection
/// byte counter the freeze uses — and XHTTP-split recycles each sub-16KB request
/// socket before it crosses the threshold. Reality+Vision on TCP-TLS (and plain
/// TLS) is freeze-VULNERABLE. Used as a freeze-context sub-rank in [planCascade]
/// so a freeze-driven hop prefers an immune transport within the same tier. PURE.
bool freezeImmune(String? family) {
  if (family == null) return false;
  final f = family.toLowerCase();
  return f == 'hysteria2' ||
      f == 'tuic' ||
      f == 'hysteria' ||
      f.endsWith('-xhttp');
}

/// True iff [family] is a plain VLESS that ISN'T wrapped in Reality/XHTTP (the
/// only VLESS forms that survive the Dec-2025 signature block).
bool _isBareVless(String f) =>
    f.startsWith('vless-') && !f.endsWith('-reality') && !f.endsWith('-xhttp');

/// True for transports the censor now blocks WHOLESALE in RF — used to NUDGE the
/// user toward a survivor when their ACTIVE node rides one. Includes plain
/// VLESS+TLS: VLESS is one of the three signature-blocked protocols, so only its
/// Reality/XHTTP-wrapped forms are expected to survive. PURE.
bool transportWidelyBlocked(String? family) {
  if (family == null) return false;
  final f = family.toLowerCase();
  // tier-0 (detected by design: plain WG/SS/SOCKS/HTTP) OR any plain VLESS that
  // isn't Reality/XHTTP-wrapped (vless-tls / vless-ws / vless-grpc / …).
  return transportSurvivability(f) == 0 || _isBareVless(f);
}

/// What the 16KB-freeze watch decided — see [decideFreeze].
enum FreezeAction {
  none, // bulk flows (or not yet debounced) — hold
  hop, // sustained freeze → hop to a transport the volume-rule doesn't policed
}

/// The 2025+ "connection-freeze" (net4people/bbs #490/#546): any single TCP
/// connection to a FOREIGN datacenter IP carrying TLS 1.3 is silently stalled
/// once it crosses ~16KB / ~25 packets — degrading even VLESS+Reality+Vision on
/// :443. It HIDES as a healthy tunnel because a tiny generate_204 (<16KB) still
/// passes; only a real >16KB transfer stalls. So it is judged in the watchdog's
/// HEALTHY branch from a periodic bulk-through-proxy probe — never the dark path.
/// Decision is PURE (unit-tested); the controller owns the counters + the I/O.
///  • bulk flows  → [none] (genuinely healthy).
///  • bulk stalls (after [freezeFails] ≥ 2, debounce vs a one-off blip) → [hop]
///    to a DIFFERENT transport. Battle-tested correction (against a live
///    Reality+Vision server, 2026-06): "reshape the SAME node freeze-safe"
///    (strip xtls-rprx-vision flow + mux) is REJECTED by a Reality server that
///    mandates the flow — it would turn a throttle into a full outage. The fix
///    that actually defeats the volumetric rule is to LEAVE the long TCP-TLS
///    stream: XHTTP splits into sub-16KB request/response pairs, and QUIC
///    (Hysteria2/TUIC) isn't a TCP-TLS connection at all. The cascade's
///    [planCascade] already orders candidates by L4 diversity, so the hop lands
///    on exactly those.
FreezeAction decideFreeze({
  required bool bulkOk,
  required int freezeFails,
}) {
  if (bulkOk) return FreezeAction.none;
  if (freezeFails < 2) return FreezeAction.none;
  return FreezeAction.hop;
}

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
/// True iff a wireguard outbound/endpoint carries AmneziaWG obfuscation — stashed
/// under `_amneziawg`, or inlined as the jc/jmin/s1-4/h1-4 knobs. PURE.
bool _hasAmnezia(Map o) {
  if (o['_amneziawg'] != null) return true;
  for (final k in const ['jc', 'jmin', 'jmax', 's1', 's2', 'h1', 'h2', 'h3', 'h4']) {
    if (o[k] != null) return true;
  }
  return false;
}

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
      case 'socks':
      case 'http':
        fam = type; // already a distinct family on its own
      case 'shadowsocks':
        // An obfs / v2ray-plugin masks the Shadowsocks signature → NOT the plain,
        // tier-0 form the censor detects by design (so don't false-flag it blocked).
        final plugin = (o['plugin'] ?? '').toString();
        fam = plugin.isNotEmpty ? 'shadowsocks-plugin' : 'shadowsocks';
      case 'wireguard':
        // AmneziaWG obfuscation (jc/jmin/s1-4/h1-4, stashed under _amneziawg) is
        // DPI-evading — NOT the plain fixed-148-byte-handshake WireGuard the censor
        // drops ~100%. Classify it apart so it isn't warned as "widely blocked".
        fam = _hasAmnezia(o) ? 'amneziawg' : 'wireguard';
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
/// `insecure`. For a USER-driven manual switch use [mitmTagsFromConfig] instead —
/// it does NOT excuse hy2/tuic.
Set<String> insecureTagsFromConfig(Map<String, dynamic> cfg) =>
    _tlsInsecureTags(cfg, excuseQuicPsk: true);

/// Like [insecureTagsFromConfig] but ALSO flags hysteria2/tuic whose `tls.insecure`
/// is set. hy2/tuic auth the server by PSK, so the UNATTENDED cascade tolerates
/// them — but a USER-initiated manual switch (Policies "test & pick fastest", a
/// member tap) must still raise the H5 MITM consent: `tls.insecure` means no cert
/// check, an on-path MITM hole the PSK doesn't close. Mirrors ParsedNode.insecure
/// (proxy_node.dart), which flags hy2/tuic. Use this at the UI guard sites; keep
/// [insecureTagsFromConfig] for the auto-failover pool.
Set<String> mitmTagsFromConfig(Map<String, dynamic> cfg) =>
    _tlsInsecureTags(cfg, excuseQuicPsk: false);

Set<String> _tlsInsecureTags(Map<String, dynamic> cfg,
    {required bool excuseQuicPsk}) {
  final out = <String>{};
  void scan(dynamic o) {
    if (o is! Map) return;
    final tag = o['tag']?.toString();
    if (tag == null || tag.isEmpty) return;
    final type = o['type']?.toString();
    if (excuseQuicPsk && (type == 'hysteria2' || type == 'tuic')) return;
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
  bool freezeContext = false,
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
        // PRIMARY: most RF-2026-survivable family first (XHTTP/QUIC/Reality over
        // a now-signature-blocked plain VLESS/SS/WG) — hop toward what gets
        // through, per the Dec-2025 intel. SECONDARY: a different physical layer
        // than the current leaf (TCP↔QUIC), so a TCP wave is answered by QUIC.
        final sa = transportSurvivability(familyOf(a));
        final sb = transportSurvivability(familyOf(b));
        if (sa != sb) return sb.compareTo(sa);
        // Under a 16KB-freeze, break a same-tier tie toward a freeze-IMMUNE
        // transport (QUIC / XHTTP) so the hop doesn't land on an equally-frozen
        // Reality+Vision TCP-TLS leaf — the exact transport the freeze degrades.
        if (freezeContext) {
          final fa = freezeImmune(familyOf(a)) ? 0 : 1;
          final fb = freezeImmune(familyOf(b)) ? 0 : 1;
          if (fa != fb) return fa.compareTo(fb);
        }
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
