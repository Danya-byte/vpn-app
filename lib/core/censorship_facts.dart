import 'dart:convert';
import 'dart:io';

import 'core_paths.dart';
import 'singbox_config.dart';

/// "Live ТСПУ-fact feed" (combination ②): the anti-censorship knobs that ТСПУ
/// churns FASTER than our release cadence — the throttled-domain list, the
/// 16KB-freeze probe host/threshold — lifted out of hardcoded literals into an
/// app-updatable DATA document, so a blocking WAVE is answered by a data push,
/// not a new build.
///
/// Security posture (deliberately conservative — this is shipped to an at-risk
/// audience):
///  • DATA ONLY. The schema carries lists + scalars; it can NOT contain code,
///    credentials, outbounds, servers, routing, or any safety toggle. The
///    direct-dial whitelist-probe IPs stay BAKED in the controller (a feed must
///    never be able to make the app dial an attacker IP and leak the user's
///    address). The kill-switch / loopback-Clash / cert-validation invariants
///    are not feed-reachable.
///  • Fetched over cert-validated HTTPS THROUGH the tunnel (same path as
///    update_check) — the RF network can't MITM it, and a bad cert is rejected.
///  • Every field is HARD-CLAMPED on parse (type-checked, range-limited,
///    hostname/HTTPS-validated, size-capped) and falls back PER-FIELD to the
///    baked defaults, so even a fully-hostile feed can only nudge within safe
///    bounds — the worst case is suboptimal tuning, never a redirect or a leak.
///  • Monotonic version: a replayed/older document is ignored.
/// (A detached signature over the document is the next hardening step; with the
/// clamp + data-only schema the blast radius is already bounded without it.)
///
/// Pure model + [parse] → fully unit-tested. The engine reads [active] (a plain
/// static, so headless tools work with the baked defaults and no Riverpod).
class CensorshipFacts {
  const CensorshipFacts({
    required this.version,
    required this.updated,
    required this.desyncDomains,
    required this.freezeProbeUrl,
    required this.freezeThresholdKb,
  });

  final int version; // feed revision (monotonic; we never downgrade)
  final String updated; // ISO date, display-only
  final List<String> desyncDomains; // throttled-site suffixes for DPI-desync
  final String freezeProbeUrl; // ① bulk-probe target (HTTPS, dialed via proxy)
  final int freezeThresholdKb; // ① "bulk arrived" floor

  /// The baked defaults == exactly today's hardcoded behaviour, so the app is
  /// byte-identical with NO feed (offline / first run / fetch fails / no URL).
  static const CensorshipFacts defaults = CensorshipFacts(
    version: 0,
    updated: 'built-in',
    desyncDomains: [
      // YouTube
      'youtube.com', 'youtu.be', 'googlevideo.com', 'ytimg.com', 'ggpht.com',
      'youtube-nocookie.com', 'youtubei.googleapis.com',
      // Discord
      'discord.com', 'discordapp.com', 'discord.gg', 'discordapp.net',
      'discord.media',
    ],
    freezeProbeUrl: 'https://speed.cloudflare.com/__down?bytes=65536',
    freezeThresholdKb: 32,
  );

  /// The currently-active facts the engine reads. Starts at [defaults]; replaced
  /// by [apply] when a cached/fetched feed validates. A plain static so the pure
  /// config engine (and `dart run` tools) never depend on Riverpod.
  static CensorshipFacts active = defaults;

  static const int _maxDomains = 500;

  /// Push [facts] into the engine: become [active] AND mirror the desync list
  /// into [SingBoxConfig.desyncDomains] (the one place the config build reads).
  static void apply(CensorshipFacts facts) {
    active = facts;
    SingBoxConfig.desyncDomains = facts.desyncDomains;
  }

  static File _cacheFile() => File(
      '${CorePaths.runtimeDir().path}${Platform.pathSeparator}censorship_facts.json');

  /// Load the last-validated feed from disk + [apply] it. Synchronous +
  /// swallow-all, so it's safe to call once at startup (controller build) before
  /// the first connect — a missing/corrupt cache just leaves the baked defaults.
  static void loadCacheSync() {
    try {
      final f = _cacheFile();
      if (!f.existsSync()) return;
      final facts = parse(f.readAsStringSync());
      if (facts != null) apply(facts);
    } catch (_) {
      // corrupt cache → keep the baked defaults
    }
  }

  /// Parse a feed document, CLAMPING every field and falling back PER-FIELD to
  /// [defaults]. Returns null when the body isn't a JSON object or its version is
  /// not newer than [haveVersion] (a stale/replayed feed is a no-op). Never throws.
  static CensorshipFacts? parse(String body, {int haveVersion = -1}) {
    Object? j;
    try {
      j = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    final version = (j['version'] as num?)?.toInt() ?? 0;
    // Reject a stale/replayed feed AND an implausibly-large version: a poison
    // `version: 2147483647` would otherwise permanently brick the channel (no
    // future feed could beat it) and persist to the cache. The ceiling is high
    // enough to admit a date (YYYYMMDD) or epoch-millis versioning scheme (~year
    // 2100) yet still bounds an int32/int64-max poison. Self-healing: a
    // previously-cached poison is refused on load → baked defaults stand.
    if (version <= haveVersion || version > 4102444800000) return null;

    // desyncDomains: keep only plausible hostnames (suffix-match safe), dedupe,
    // cap size. Empty/garbage → fall back to the baked list.
    final domains = <String>[];
    final rawDomains = j['desyncDomains'];
    if (rawDomains is List) {
      for (final d in rawDomains) {
        final s = d?.toString().trim().toLowerCase() ?? '';
        if (_isHostname(s) && !domains.contains(s)) domains.add(s);
        if (domains.length >= _maxDomains) break;
      }
    }

    // freezeProbeUrl: HTTPS only (it's dialed through the proxy; http / non-URL
    // is rejected → keep the default).
    // freezeProbeUrl: HTTPS only (it's dialed through the proxy; http / non-URL
    // is rejected → keep the default).
    final rawUrl = j['freezeProbeUrl']?.toString() ?? '';
    var url = _isHttpsUrl(rawUrl) ? rawUrl : defaults.freezeProbeUrl;

    // threshold: clamp to a sane KB window AND to what the probe can actually
    // deliver — a threshold above the probe's `bytes=` payload makes the bulk-
    // probe NEVER satisfiable → a permanent false-freeze → endless transport hops.
    var kb = ((j['freezeThresholdKb'] as num?)?.toInt() ??
            defaults.freezeThresholdKb)
        .clamp(8, 256);
    final bytes =
        int.tryParse(Uri.tryParse(url)?.queryParameters['bytes'] ?? '');
    if (bytes != null && bytes > 0) {
      final payloadFloorKb = (bytes * 9 ~/ 10) ~/ 1024; // ~90% of payload, in KB
      if (payloadFloorKb < 8) {
        // The probe is too small to ever satisfy even the 8KB floor → unusable.
        // Fall back to the baked probe+threshold (a known-satisfiable pair) rather
        // than ship an unsatisfiable freeze test that hops transports forever.
        url = defaults.freezeProbeUrl;
        kb = defaults.freezeThresholdKb;
      } else if (kb > payloadFloorKb) {
        kb = payloadFloorKb; // never demand more than the probe can deliver
      }
    }

    // `updated` is display-only — strip control chars THEN cap length so a hostile
    // feed can't render a multi-KB blob (or newlines) in the version tile.
    final raw =
        (j['updated']?.toString() ?? '').replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    final updated = raw.isEmpty ? 'unknown' : (raw.length > 40 ? raw.substring(0, 40) : raw);
    return CensorshipFacts(
      version: version,
      updated: updated,
      desyncDomains: domains.isEmpty ? defaults.desyncDomains : domains,
      freezeProbeUrl: url,
      freezeThresholdKb: kb,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'updated': updated,
        'desyncDomains': desyncDomains,
        'freezeProbeUrl': freezeProbeUrl,
        'freezeThresholdKb': freezeThresholdKb,
      };

  /// Persist a validated feed to the disk cache (best-effort). Public so the
  /// Riverpod feed layer (FFI-bound) can write without reaching into privates —
  /// this pure model stays importable by `dart run` tools + unit tests.
  static void cache(CensorshipFacts facts) {
    try {
      _cacheFile().writeAsStringSync(jsonEncode(facts.toJson()));
    } catch (_) {
      // best-effort; the in-memory facts are already applied
    }
  }

  // A conservative hostname matcher (labels of [a-z0-9-], at least one dot) so a
  // feed can't smuggle a path/scheme/wildcard into a domain_suffix rule.
  static bool _isHostname(String s) =>
      s.isNotEmpty &&
      s.length <= 253 &&
      RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')
          .hasMatch(s);

  static bool _isHttpsUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null && u.isScheme('https') && u.host.isNotEmpty;
  }
}

/// Default feed location: the app's OWN repo (raw GitHub), fetched THROUGH the
/// tunnel — github-raw is blocked direct in RF but reachable once connected,
/// exactly like update_check. Empty disables the fetch. Until a facts file is
/// committed there it 404s → a harmless no-op (baked defaults stand).
const String kDefaultFactsFeedUrl =
    'https://raw.githubusercontent.com/Danya-byte/vpn-app/main/facts/censorship_facts.json';
