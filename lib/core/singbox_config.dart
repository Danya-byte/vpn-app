import 'dart:convert';

import 'proxy_node.dart';
import 'route_mode.dart';

/// Builds sing-box configs.
///
/// [m0Local] is a benign local config that proves the plumbing without TUN or a
/// remote server: a mixed (SOCKS+HTTP) inbound on 127.0.0.1:2080, a direct
/// outbound, and the Clash API for control/stats. Real profiles arrive in M1.
class SingBoxConfig {
  static const String clashHost = '127.0.0.1';
  static const int clashPort = 9090; // single source of truth (was a 3-file literal)
  static const String clashController = '$clashHost:$clashPort';
  static const String mixedListen = '127.0.0.1';
  static const int mixedPort = 2080;

  /// Random per-launch token guarding the Clash API. Without it, ANY local
  /// process — or a malicious web page via DNS-rebinding (the REST endpoints
  /// have no CORS) — can read `/connections` (every host you reach) and
  /// `PUT /proxies` (silently force your exit to an attacker's node). Set by
  /// the app at startup; empty in pure config tests (no secret emitted).
  static String clashSecret = '';

  static Map<String, dynamic> _clashApi() => {
        'external_controller': clashController,
        if (clashSecret.isNotEmpty) 'secret': clashSecret,
      };

  static Map<String, dynamic> m0Local() => {
        'log': {'level': logLevel, 'timestamp': true},
        'experimental': {
          'clash_api': _clashApi(),
        },
        'inbounds': [
          {
            'type': 'mixed',
            'tag': 'mixed-in',
            'listen': mixedListen,
            'listen_port': mixedPort,
          }
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
      };

  // Domains RF THROTTLES via SNI-DPI (reachable directly, just slowed) — where
  // splitting the TLS ClientHello defeats the throttle with NO server. Strictly
  // throttled services, NOT IP-blocked ones (those need a foreign exit, which
  // fragmentation can't conjure). Suffix match → covers all subdomains. Feed-
  // tunable (combination ②): the loader overwrites this from the signed-in-spirit
  // ТСПУ-fact feed so a new throttle wave is answered by a data push, not a build;
  // [CensorshipFacts.defaults] holds the baked copy this is initialised to.
  static List<String> desyncDomains = const [
    // YouTube
    'youtube.com', 'youtu.be', 'googlevideo.com', 'ytimg.com', 'ggpht.com',
    'youtube-nocookie.com', 'youtubei.googleapis.com',
    // Discord
    'discord.com', 'discordapp.com', 'discord.gg', 'discordapp.net',
    'discord.media',
  ];

  // Route rules that unblock the throttled domains DIRECT: force them off QUIC
  // (UDP/443 reject → browser falls back to TCP) so the TCP-only TLS-record
  // fragmentation applies and ТСПУ never sees the full SNI.
  static List<Map<String, dynamic>> _desyncRules() => [
        {
          'domain_suffix': desyncDomains,
          'network': 'udp',
          'port': 443,
          'action': 'reject',
        },
        {
          'domain_suffix': desyncDomains,
          'action': 'route',
          'outbound': 'direct',
          'tls_fragment': true,
        },
      ];

  /// "Unblock without a server": runs the core LOCALLY with no proxy. Everything
  /// goes DIRECT, but the throttled domains (YouTube/Discord) get their TLS
  /// ClientHello fragmented so DPI can't read the SNI to throttle them. The
  /// honest out-of-box win — defeats DPI THROTTLING (not IP blocks) with zero
  /// config, no foreign server. (sing-box 1.13.12 verified to support this.)
  static Map<String, dynamic> desyncOnly() => {
        'log': {'level': logLevel, 'timestamp': true},
        'experimental': {'clash_api': _clashApi()},
        'dns': {
          'servers': [
            {'type': 'https', 'tag': 'dns-direct', 'server': dnsServer},
          ],
          'final': 'dns-direct',
          'strategy': 'ipv4_only',
        },
        'inbounds': _baseInbounds(),
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'default_domain_resolver': {'server': 'dns-direct'},
          'rules': [
            {'action': 'sniff'},
            {'protocol': 'dns', 'action': 'hijack-dns'},
            ..._desyncRules(),
          ],
          'final': 'direct',
          'auto_detect_interface': true,
        },
      };

  // SagerNet RU rule-sets, fetched direct.
  static const String _geoipRu =
      'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs';
  static const String _geositeRu =
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs';
  static const String _geositeAds =
      'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs';

  // Native Telegram unblock (под капотом): RF blocks Telegram at the IP level and
  // throttles/blocks its UDP calls, so the fix is to force ALL Telegram traffic —
  // messaging (TCP) AND voice/video calls (UDP) — through the foreign tunnel.
  // Telegram's PUBLISHED DC + media CIDRs (core.telegram.org/resources/cidr.txt)
  // + its domains, matched on IP so MTProto (which dials raw DC IPs, no DNS) is
  // caught too. UDP coverage is what makes CALLS work — in TUN mode, where their
  // UDP is captured (system-proxy mode is TCP-only: messaging yes, calls no).
  static const List<String> _telegramDomains = [
    'telegram.org', 't.me', 'telegram.me', 'telega.im', 'tdesktop.com',
    'telegram-cdn.org', 'cdn-telegram.org', 'telesco.pe', 'comments.app',
  ];
  static const List<String> _telegramCidrs = [
    '91.108.4.0/22', '91.108.8.0/22', '91.108.12.0/22', '91.108.16.0/22',
    '91.108.20.0/22', '91.108.56.0/22', '95.161.64.0/20', '149.154.160.0/20',
    '91.105.192.0/23', '185.76.151.0/24',
    '2001:b28:f23c::/48', '2001:b28:f23d::/48', '2001:b28:f23f::/48',
    '2001:67c:4e8::/48', '2a0a:f280::/32',
  ];

  /// Pin Telegram to the foreign exit — set false to let it go direct. Default on
  /// (the whole point in RF). A plain static like [ruleSetDir]; the engine reads
  /// it, so `dart run` tooling gets the default without wiring a setting.
  static bool telegramUnblock = true;

  /// Absolute path to the bundled rule-sets dir; set by the app at startup so
  /// rule-sets load LOCALLY (no startup download — github is blocked in RF and
  /// a direct fetch deadlocks the core: "initialize cache-file: timeout").
  /// Empty → fall back to remote (used by headless tooling outside RF).
  static String ruleSetDir = '';

  /// Set false by the app at startup if the bundled `.srs` files aren't actually
  /// on disk (packaging miss / AV quarantine). Smart mode then degrades to a
  /// rule-set-free config instead of FATAL-ing on a missing local path — and we
  /// NEVER emit a remote (RF-blocked) rule-set in a shipping build.
  static bool ruleSetsReady = true;

  /// sing-box log verbosity for every config we build/import. Set by the app from
  /// the user's setting (default: 'info' in debug, 'warn' in release). Controls
  /// what the in-app log shows — 'warn' = quiet (warnings/errors), 'info' = every
  /// connection, 'debug' = everything.
  static String logLevel = 'warn';

  /// DoH resolver every generated config hijacks DNS to. Default is Yandex
  /// (`77.88.8.8`) — an always-reachable RU DoH endpoint, the safe RF default.
  /// The app overrides it from the user's "custom DNS" setting at connect time;
  /// an empty setting keeps this default. Kept as a DoH server (type:https) so a
  /// custom value is still DPI-resistant — picking a plain blocked resolver would
  /// just break resolution, hence the default stays a known-good one.
  static String dnsServer = '77.88.8.8';

  static Map<String, dynamic> _ruleSet(String tag, String remoteUrl) {
    if (ruleSetDir.isNotEmpty) {
      return {
        'type': 'local',
        'tag': tag,
        'format': 'binary',
        'path': '$ruleSetDir/$tag.srs',
      };
    }
    return {
      'type': 'remote',
      'tag': tag,
      'format': 'binary',
      'url': remoteUrl,
      'download_detour': 'direct',
    };
  }

  // Map a (possibly imported) rule-set tag to a bundled local .srs, or null.
  static String? _localRuleSetPath(String tag) {
    if (ruleSetDir.isEmpty) return null;
    final t = tag.toLowerCase();
    // Canonical SagerNet tags ONLY — the old substring match ('ru'/'ad') silently
    // rebound unrelated sets onto the wrong bundled DB: geosite-trust/cyrus/truba
    // (all contain "ru") → geosite-ru, spotify-ads → geosite-ads. An unknown
    // remote set now stays null → dropped (the safe default), never mis-routed.
    const map = <String, String>{
      'geoip-ru': 'geoip-ru',
      'geoip-category-ru': 'geoip-ru',
      'geosite-ru': 'geosite-ru',
      'geosite-category-ru': 'geosite-ru',
      'geosite-ads': 'geosite-ads',
      'geosite-category-ads': 'geosite-ads',
      'geosite-category-ads-all': 'geosite-ads',
    };
    final file = map[t];
    return file == null ? null : '$ruleSetDir/$file.srs';
  }

  // A route/DNS rule is "empty" (drop it after geoip/geosite stripping) ONLY if
  // it has nothing beyond these action/modifier keys. Any real matcher — or a
  // logical rule's nested `rules` — keeps it. Denylist on purpose: a matcher
  // WHITELIST silently dropped logical rules and every newer matcher sing-box
  // adds (source_port, process_path, wifi_bssid, network_type, auth_user, …).
  static const Set<String> _ruleActionKeys = {'outbound', 'action', 'invert'};
  // DNS rules carry their OWN action/modifier keys; `server` is the action (the
  // resolver to use), NOT a matcher. Without this, a rule scoped only to a
  // now-stripped geosite/geoip became `{server:'x'}` and survived as a MATCH-ALL
  // that silently hijacked every query (broke split-DNS / RU-direct).
  static const Set<String> _dnsRuleActionKeys = {
    'server',
    'action',
    'invert',
    'disable_cache',
    'rewrite_ttl',
    'client_subnet',
    'strategy',
    'disable_expire',
    'predefined',
  };
  static bool _ruleHasMatcher(Map r, {bool forDns = false}) {
    final actionKeys = forDns ? _dnsRuleActionKeys : _ruleActionKeys;
    return r.keys.any((k) => !actionKeys.contains(k));
  }

  /// Config routing through [node] in [mode] (local SOCKS/HTTP on :2080).
  /// [antiDpi] fragments the TLS ClientHello to defeat SNI-based DPI.
  static Map<String, dynamic> fromNode(ParsedNode node,
      {RouteMode mode = RouteMode.smart,
      bool antiDpi = false,
      String tlsFingerprint = 'chrome',
      bool mux = false,
      bool ech = false}) {
    final n = _prepare(node,
        antiDpi: antiDpi, fp: tlsFingerprint, mux: mux, ech: ech);
    return mode == RouteMode.smart
        ? _smart([n.outbound], n.tag)
        : _global([n.outbound], n.tag);
  }

  /// Tag of the auto-failover urltest group built by [fromNodes].
  static const String autoTag = '⚡ Auto';
  // The user-facing Selector wrapping the auto group + every node, so the
  // Policies tab lets you pick "Auto" (latency failover) OR a specific server.
  static const String selectorTag = '🌍 VPN';

  /// Combine every node into a latency-tested auto-failover group: the app
  /// picks the fastest working transport and fails over if one gets blocked —
  /// "combine for invulnerability". Config profiles are skipped (run whole).
  static Map<String, dynamic> fromNodes(List<ParsedNode> nodes,
      {RouteMode mode = RouteMode.smart,
      bool antiDpi = false,
      String tlsFingerprint = 'chrome',
      bool mux = false,
      bool ech = false}) {
    final simple = nodes.where((n) => !n.isConfig).toList();
    if (simple.isEmpty) return m0Local();
    final prepared = simple
        .map((n) => _prepare(n,
            antiDpi: antiDpi, fp: tlsFingerprint, mux: mux, ech: ech))
        .toList();
    if (prepared.length == 1) {
      final n = prepared.first;
      return mode == RouteMode.smart
          ? _smart([n.outbound], n.tag)
          : _global([n.outbound], n.tag);
    }
    final proxies = <Map<String, dynamic>>[
      ...prepared.map((n) => n.outbound),
      {
        'type': 'urltest',
        'tag': autoTag,
        'outbounds': prepared.map((n) => n.tag).toList(),
        'url': 'https://www.gstatic.com/generate_204',
        'interval': '90s', // react faster to a fresh ТСПУ block wave
        'tolerance': 50,
      },
      {
        // Manual picker: defaults to Auto, but the user can pin one server in
        // the Policies tab (a URLTest alone can't be hand-selected).
        'type': 'selector',
        'tag': selectorTag,
        'outbounds': [autoTag, ...prepared.map((n) => n.tag)],
        'default': autoTag,
      },
    ];
    return mode == RouteMode.smart
        ? _smart(proxies, selectorTag)
        : _global(proxies, selectorTag);
  }

  // Apply the opt-in anti-DPI layer to a node (on a deep copy): a real-browser
  // uTLS fingerprint (pool), optional multiplex, optional ECH, and — when
  // [antiDpi] — TLS ClientHello fragmentation. Reality keeps its own SNI masking
  // (no fragment/ECH; chrome stays its safest fingerprint).
  static ParsedNode _prepare(ParsedNode node,
      {required bool antiDpi,
      required String fp,
      required bool mux,
      required bool ech}) {
    if (node.outbound.isEmpty) return node; // config profile, nothing to tweak
    final ob = jsonDecode(jsonEncode(node.outbound)) as Map<String, dynamic>;
    _applyLevers(ob, antiDpi: antiDpi, fp: fp, mux: mux, ech: ech);
    return ParsedNode(tag: node.tag, outbound: ob, config: node.config);
  }

  // Apply the anti-DPI levers to ONE outbound map, IN PLACE. Shared by _prepare
  // (app-generated nodes) and fromConfig (imported full configs) so both paths
  // behave identically — previously fromConfig had a divergent fingerprint-only
  // loop that ignored antiDpi/mux/ech and could corrupt Reality.
  //   • Reality: guarantee a valid real-browser uTLS fp but NEVER overwrite the
  //     author's pick with firefox/safari/edge/random (corrupts the handshake —
  //     memory: "uTLS fp = chrome not randomized"); never fragment/ECH it (it
  //     already masks the SNI).
  //   • Non-Reality TCP-TLS (vless/vmess/trojan): set the resolved fp,
  //     SYNTHESIZING utls when the import had none (else a bare Go-stdlib
  //     ClientHello is trivially fingerprintable); optional fragment.
  //   • Non-Reality TLS (any type): optional ECH.
  //   • Multiplex: TCP proxies without XTLS-Vision flow.
  static void _applyLevers(Map<String, dynamic> ob,
      {required bool antiDpi,
      required String fp,
      required bool mux,
      required bool ech}) {
    final type = ob['type']?.toString();
    final isTcpProxy = type == 'vless' || type == 'vmess' || type == 'trojan';
    final tls = ob['tls'];
    if (tls is Map && tls['enabled'] == true) {
      final t = tls.cast<String, dynamic>();
      // Reality only when actually enabled — a `{reality:{enabled:false}}` block
      // is plain TLS (matches familiesFromConfig, so fp-handling agrees with the
      // cascade's family classification).
      final reality = t['reality'];
      final isReality = reality is Map && reality['enabled'] != false;
      final utls = (t['utls'] as Map?)?.cast<String, dynamic>();
      if (isReality) {
        // Only normalize a missing/synthetic Reality fp to chrome; leave a real
        // author-chosen browser fp intact. Auto-adapt must not corrupt the very
        // handshake fingerprint of the Reality nodes it's trying to rescue.
        final cur = utls?['fingerprint']?.toString();
        if (cur == null ||
            cur.isEmpty ||
            cur == 'randomized' ||
            cur == 'random' ||
            cur == 'yandex') {
          t['utls'] = {...?utls, 'enabled': true, 'fingerprint': 'chrome'};
        }
      } else {
        if (isTcpProxy && fp.isNotEmpty && fp != 'randomized') {
          final useFp = fp == 'yandex' ? 'chrome' : fp; // no literal 'yandex'
          t['utls'] = {...?utls, 'enabled': true, 'fingerprint': useFp};
        }
        if (ech) t['ech'] = {'enabled': true};
        if (antiDpi && isTcpProxy) {
          t['fragment'] = true;
          t['fragment_fallback_delay'] = '500ms';
        }
      }
      ob['tls'] = t;
    }
    // Multiplex (h2mux): TCP proxies only, NOT with XTLS-Vision flow (sing-box
    // rejects mux + vision together).
    if (mux && isTcpProxy && (ob['flow'] == null || '${ob['flow']}'.isEmpty)) {
      ob['multiplex'] = {'enabled': true, 'protocol': 'h2mux', 'max_streams': 8};
    }
  }

  static List<Map<String, dynamic>> _baseInbounds() => [
        {
          'type': 'mixed',
          'tag': 'mixed-in',
          'listen': mixedListen,
          'listen_port': mixedPort,
        }
      ];

  static Map<String, dynamic> _global(
          List<Map<String, dynamic>> proxies, String tag) =>
      {
        'log': {'level': logLevel, 'timestamp': true},
        'dns': {
          'servers': [
            {'type': 'https', 'tag': 'dns-proxy', 'server': '1.1.1.1', 'detour': tag},
            // No `detour: direct` — a DNS server dials direct by default, and
            // 1.13 FATALs on "detour to an empty direct outbound".
            {'type': 'https', 'tag': 'dns-direct', 'server': dnsServer},
          ],
          'final': 'dns-proxy',
          'strategy': 'ipv4_only', // RF has no working IPv6
        },
        'experimental': {
          'clash_api': _clashApi(),
        },
        'inbounds': _baseInbounds(),
        'outbounds': [
          ...proxies,
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'default_domain_resolver': {'server': 'dns-direct'},
          'rules': [
            {'action': 'sniff'},
            {'protocol': 'dns', 'action': 'hijack-dns'},
          ],
          'final': tag,
          'auto_detect_interface': true,
        },
      };

  // RU + private -> direct, rest -> proxy; split DNS (RU direct, foreign tunnelled).
  static Map<String, dynamic> _smart(
      List<Map<String, dynamic>> proxies, String tag) {
    // Without the bundled rule-sets we can't geo-route — degrade to a SAFE
    // config (everything via proxy, only private IPs direct) rather than
    // reference a rule-set that isn't on disk (which FATALs the core).
    final useRuleSets = ruleSetsReady && ruleSetDir.isNotEmpty;
    return {
      'log': {'level': logLevel, 'timestamp': true},
      'dns': {
        'servers': [
          {'type': 'https', 'tag': 'dns-proxy', 'server': '1.1.1.1', 'detour': tag},
          {'type': 'https', 'tag': 'dns-direct', 'server': dnsServer},
        ],
        if (useRuleSets)
          'rules': [
            {'rule_set': 'geosite-ru', 'server': 'dns-direct'},
          ],
        'final': 'dns-proxy',
        'strategy': 'ipv4_only',
      },
      'experimental': {
        'clash_api': _clashApi(),
      },
      'inbounds': _baseInbounds(),
      'outbounds': [
        ...proxies,
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {
        'default_domain_resolver': {'server': 'dns-direct'},
        'rules': [
          {'action': 'sniff'},
          {'protocol': 'dns', 'action': 'hijack-dns'},
          if (useRuleSets) {'rule_set': 'geosite-ads', 'action': 'reject'},
          // Native Telegram unblock: msgs (TCP) + calls (UDP) → the proxy exit,
          // BEFORE the private/RU-direct rules so Telegram always rides the tunnel.
          if (telegramUnblock)
            {'domain_suffix': _telegramDomains, 'outbound': tag},
          if (telegramUnblock) {'ip_cidr': _telegramCidrs, 'outbound': tag},
          {'ip_is_private': true, 'outbound': 'direct'},
          if (useRuleSets)
            {
              'rule_set': ['geoip-ru', 'geosite-ru'],
              'outbound': 'direct',
            },
        ],
        if (useRuleSets)
          'rule_set': [
            _ruleSet('geosite-ads', _geositeAds),
            _ruleSet('geoip-ru', _geoipRu),
            _ruleSet('geosite-ru', _geositeRu),
          ],
        'final': tag,
        'auto_detect_interface': true,
      },
    };
  }

  /// Runs an imported full sing-box config, adapted for local no-admin use:
  /// drops xray-only transports (xhttp/mkcp), swaps any TUN inbound for a local
  /// mixed inbound, and injects the Clash API. Routing/groups/DNS are kept.
  static Map<String, dynamic> fromConfig(Map<String, dynamic> src,
      {bool keepXray = false,
      String? fingerprintOverride,
      bool antiDpi = false,
      bool mux = false,
      bool ech = false,
      bool ruDirect = false}) {
    // Deep copy so we never mutate the stored profile.
    final cfg = jsonDecode(jsonEncode(src)) as Map<String, dynamic>;

    // Strip our non-standard `_`-prefixed stash keys (e.g. `_amneziawg` on a
    // wireguard endpoint) — the bundled core FATALs on unknown fields. They stay
    // in the STORED profile for a future AmneziaWG-capable core.
    for (final e in (cfg['endpoints'] as List?) ?? const []) {
      if (e is Map) e.removeWhere((k, _) => k.toString().startsWith('_'));
    }
    const unsupportedTransport = {'xhttp', 'splithttp', 'mkcp', 'kcp'};
    // Every outbound TYPE the bundled core (sing-box 1.13 + xray bridge) can run,
    // plus the group types. A node whose type isn't here is a newer/unknown
    // protocol: sing-box uses DisallowUnknownFields, so leaving ONE in would
    // FATAL the WHOLE config (every valid node dies with it). Drop just the
    // unknown node and cascade-prune the groups instead — "any config keeps
    // working" must survive an upstream protocol we don't know yet.
    const knownOutbound = {
      'direct', 'block', 'dns', 'socks', 'http', 'shadowsocks', 'shadowsocksr',
      'vmess', 'vless', 'trojan', 'wireguard', 'hysteria', 'hysteria2', 'tuic',
      'shadowtls', 'anytls', 'tor', 'ssh', 'selector', 'urltest',
    };

    final dnsTags = <String>{};
    final blockTags = <String>{};
    final droppedTransport = <String>{};
    final kept = <dynamic>[];
    for (final o in (cfg['outbounds'] as List?) ?? const []) {
      if (o is Map) {
        final tag = o['tag']?.toString() ?? '';
        final type = o['type']?.toString();
        if (type == 'dns') {
          dnsTags.add(tag);
          continue;
        }
        if (type == 'block') {
          blockTags.add(tag);
          continue;
        }
        final tr = (o['transport'] as Map?)?['type']?.toString();
        // When the xray bridge is available, keep XHTTP outbounds — they're
        // rewritten to socks→xray later instead of being dropped.
        final xrayTr = tr == 'xhttp' || tr == 'splithttp';
        if (tr != null &&
            unsupportedTransport.contains(tr) &&
            !(keepXray && xrayTr)) {
          droppedTransport.add(tag);
          continue;
        }
        // Unknown/newer outbound type → drop just this one (the cascade prunes
        // its group membership) so a single future-protocol node can't FATAL all.
        if (type != null && !knownOutbound.contains(type)) {
          droppedTransport.add(tag);
          continue;
        }
      }
      kept.add(o);
    }
    final dropped = {...dnsTags, ...blockTags, ...droppedTransport};

    // Filter dropped members out of groups; iteratively remove any group left
    // empty (and cascade) so we never emit an unloadable "empty selector".
    var changed = true;
    while (changed) {
      changed = false;
      for (final o in kept) {
        if (o is! Map) continue;
        if (o['type'] != 'selector' && o['type'] != 'urltest') continue;
        final list = (o['outbounds'] as List?)
            ?.where((t) => !dropped.contains(t.toString()))
            .toList();
        if (list != null) o['outbounds'] = list;
        if (dropped.contains(o['default']?.toString())) o.remove('default');
        // 1.13 requires interval <= idle_timeout; drop idle_timeout to be safe.
        // Tighten the probe interval for faster ТСПУ-block detection.
        if (o['type'] == 'urltest') {
          o.remove('idle_timeout');
          o['interval'] = '90s';
        }
        if ((o['outbounds'] as List?)?.isEmpty ?? false) {
          final tag = o['tag']?.toString();
          if (tag != null && dropped.add(tag)) changed = true;
        }
      }
    }
    kept.removeWhere((o) =>
        o is Map &&
        (o['type'] == 'selector' || o['type'] == 'urltest') &&
        ((o['outbounds'] as List?)?.isEmpty ?? false));
    cfg['outbounds'] = kept;

    // A surviving outbound/endpoint that detours through a DROPPED tag FATALs at
    // runtime ("dependency[X] not found") — yet `sing-box check` PASSES, so the
    // preflight never catches it (the exact silent-never-connect class we fought
    // once). Strip the dangling detour so the node dials direct instead of dying
    // on launch. Hits chained/fronted configs (Vision-via-xhttp when xray is
    // absent, or a node detouring a legacy block/dns outbound). DNS-server
    // detours are scrubbed in _migrateDnsServers (same `dropped` set).
    void scrubDetour(List? list) {
      for (final o in list ?? const []) {
        if (o is Map && dropped.contains(o['detour']?.toString())) {
          o.remove('detour');
        }
      }
    }

    scrubDetour(kept);
    scrubDetour(cfg['endpoints'] as List?);

    // Apply the user's anti-DPI levers to every kept outbound via the SAME helper
    // the generated path uses — so an imported config honors Anti-DPI / Mux / ECH
    // / fingerprint instead of silently ignoring them (dead controls for the
    // user's actual usage). The helper guards Reality (never corrupts its
    // handshake fp) and synthesizes uTLS where a plain-TLS node had none.
    // `fingerprintOverride` carries the resolved fp (settings, or the auto-adapt
    // variant during escalation); default chrome.
    final fp = (fingerprintOverride == null || fingerprintOverride.isEmpty)
        ? 'chrome'
        : fingerprintOverride;
    for (final o in kept) {
      if (o is Map) {
        _applyLevers(o.cast<String, dynamic>(),
            antiDpi: antiDpi, fp: fp, mux: mux, ech: ech);
      }
    }

    // Migrate route + DNS rules to sing-box 1.13.
    final route = (cfg['route'] as Map?)?.cast<String, dynamic>();
    final dns = (cfg['dns'] as Map?)?.cast<String, dynamic>();

    // Localize bundled rule-sets; drop remote ones we can't bundle, so the core
    // never deadlocks on a (RF-blocked) startup download.
    final droppedRs = <String>{};
    if (route != null) {
      final keptRs = <dynamic>[];
      for (final r in (route['rule_set'] as List?) ?? const []) {
        if (r is Map && r['type'] == 'remote') {
          final tag = r['tag']?.toString() ?? '';
          final local = _localRuleSetPath(tag);
          if (local != null) {
            keptRs.add({
              'type': 'local',
              'tag': tag,
              'format': r['format'] ?? 'binary',
              'path': local,
            });
          } else {
            droppedRs.add(tag);
          }
        } else {
          keptRs.add(r);
        }
      }
      route['rule_set'] = keptRs;
    }

    if (route != null) {
      var rules = _migrateRules(route['rules'] as List?, dnsTags, blockTags);
      if (droppedRs.isNotEmpty) rules = _dropRuleSet(rules, droppedRs);
      route['rules'] = [
        {'action': 'sniff'},
        ...rules,
      ];
      if (dropped.contains(route['final']?.toString())) route.remove('final');
    }

    // Smart mode over an IMPORTED config: the config keeps its OWN routing, which
    // usually proxies everything → sanctioned RU sites (vtb/gov.ru) reverse-geo-
    // block the foreign exit. Inject a leading RU-geo + private-IP → direct rule
    // so domestic traffic stays domestic. Idempotent + dedup-safe + .srs-gated.
    if (ruDirect && route != null) _injectRuDirect(cfg, route);
    // Native Telegram unblock: pin Telegram (incl. UDP calls) to the imported
    // config's proxy exit, independent of mode/RU-direct. Bails when the config
    // already routes Telegram or has no proxy final.
    if (route != null) _injectTelegram(cfg, route);
    if (dns != null) {
      // Migrate legacy 1.11 `address:` servers to the typed 1.13 format so the
      // config is valid WITHOUT ENABLE_DEPRECATED_LEGACY_DNS_SERVERS — which
      // sing-box 1.14 removes entirely (a silent time-bomb on the next update).
      // Legacy fakeip lives in a top-level dns.fakeip block; migrate its ranges
      // onto the typed fakeip server, then drop the deprecated block (else the
      // core FATALs requiring ENABLE_DEPRECATED_LEGACY_DNS_FAKEIP_OPTIONS — the
      // same startup-deadlock class as the original "never connected in RF").
      final fakeipBlock = dns['fakeip'] as Map?;
      dns['servers'] = _migrateDnsServers(dns['servers'] as List?,
          dropped: dropped, fakeip: fakeipBlock);
      dns.remove('fakeip');
      var rules =
          _migrateRules(dns['rules'] as List?, const {}, const {}, forDns: true);
      if (droppedRs.isNotEmpty) {
        rules = _dropRuleSet(rules, droppedRs, forDns: true);
      }
      dns['rules'] = rules;
      // RF networks usually have no working IPv6: force A-only so we never hand a
      // dead AAAA to a dial ("unreachable network", battle-confirmed). HONOR only
      // an explicit IPv6-WANTING strategy (prefer_ipv6 / ipv6_only) so a
      // deliberately dual-stack or v6-only config still works; absent/ipv4/
      // prefer_ipv4 all normalize to ipv4_only.
      final s = dns['strategy']?.toString();
      if (s != 'prefer_ipv6' && s != 'ipv6_only') {
        dns['strategy'] = 'ipv4_only';
      }
      // 1.13 wants an explicit direct resolver for dial-field domains; without
      // it the core warns now and FATALs in 1.14. Point it at a direct server.
      if (route != null && route['default_domain_resolver'] == null) {
        final tag = _directResolverTag(dns['servers'] as List?);
        if (tag != null) route['default_domain_resolver'] = {'server': tag};
      }
    } else {
      // Config had no DNS block — synthesize a safe IPv4-only one + resolver.
      cfg['dns'] = {
        'servers': [
          {'type': 'https', 'tag': 'dns-direct', 'server': dnsServer},
        ],
        'final': 'dns-direct',
        'strategy': 'ipv4_only',
      };
      if (route != null) {
        route['default_domain_resolver'] = {'server': 'dns-direct'};
      }
    }

    // `services` are server/infra features (DERP relay, ssm-api, resolved). Drop
    // `resolved` — it FATALs off-Linux ("only supported on Linux") and on Linux
    // would fight our own TUN/DNS; an imported client profile never needs it.
    // Keep derp/ssm-api (cross-platform, no FATAL) for faithful passthrough.
    final services = (cfg['services'] as List?)
        ?.where((s) => !(s is Map && s['type'] == 'resolved'))
        .toList();
    if (services == null || services.isEmpty) {
      cfg.remove('services');
    } else {
      cfg['services'] = services;
    }

    cfg['inbounds'] = _baseInbounds();
    // Replace the imported log block with the app's safe default. A subscription
    // is semi-trusted, and a `log.output` (incl. a UNC share) would persist every
    // destination host/SNI the core dials — the exact data this tool protects.
    // The app already mirrors stdout into its in-memory ring buffer.
    cfg['log'] = {'level': logLevel, 'timestamp': true};
    // Allowlist `experimental`: rebuild the Clash API with OUR per-launch secret
    // (Happ-vuln protection), keep a cache_file (but never an author-chosen
    // on-disk `path`), and DROP everything else (v2ray_api/debug/…) so the
    // control-plane lockdown is intentional, not incidental on the build tags.
    final oldExp = (cfg['experimental'] as Map?)?.cast<String, dynamic>();
    final exp = <String, dynamic>{'clash_api': _clashApi()};
    final cache = (oldExp?['cache_file'] as Map?)?.cast<String, dynamic>();
    if (cache != null) {
      cache['enabled'] = true;
      cache.remove('path'); // never let a sub choose where we write on disk
      exp['cache_file'] = cache;
    }
    cfg['experimental'] = exp;
    return cfg;
  }

  // Pin Telegram (DC/relay CIDRs + domains, TCP AND UDP) to the PROXY exit so
  // messaging and CALLS ride the foreign tunnel — natively unblocking Telegram,
  // which RF IP-blocks (and whose UDP calls it blocks). Inserted BEFORE the
  // RU-direct/private rules so Telegram always wins over them; bails when there
  // is no proxy exit to pin to (no-server/desync modes — physics, can't help) or
  // when the config already routes Telegram (respect the author). Idempotent.
  static void _injectTelegram(
      Map<String, dynamic> cfg, Map<String, dynamic> route) {
    if (!telegramUnblock) return;
    final proxyTag = route['final']?.toString();
    if (proxyTag == null ||
        const {'direct', 'block', 'dns-out', 'dns'}.contains(proxyTag)) {
      return; // no foreign exit to pin Telegram to
    }
    final rules = [...(route['rules'] as List? ?? const [])];
    String join(dynamic v) => v is List ? v.join(',') : '${v ?? ''}';
    final already = rules.any((r) =>
        r is Map &&
        (join(r['ip_cidr']).contains('149.154.16') ||
            join(r['domain_suffix']).contains('t.me') ||
            join(r['domain_suffix']).contains('telegram')));
    if (already) return; // author already handles Telegram routing

    // Insert after leading sniff/hijack-dns so DNS still works, but BEFORE the
    // RU-direct / private / proxy-everything rules.
    var at = 0;
    for (final r in rules) {
      if (r is Map && (r['action'] == 'sniff' || r['action'] == 'hijack-dns')) {
        at++;
      } else {
        break;
      }
    }
    rules.insert(at, {'ip_cidr': _telegramCidrs, 'outbound': proxyTag});
    rules.insert(at, {'domain_suffix': _telegramDomains, 'outbound': proxyTag});
    route['rules'] = rules;
  }

  // Prepend a geoip-ru/geosite-ru + private-IP -> direct rule to an imported
  // config's route, so RU-domestic traffic bypasses the foreign exit (which
  // sanctioned RU sites geo-block). Safe by construction: needs bundled .srs;
  // ensures a `direct` outbound; idempotent (skips if already present); dedupes
  // rule-set tags (a duplicate tag FATALs the core); inserts AFTER sniff/dns so
  // DNS hijack still runs but BEFORE the config's proxy-everything rules.
  static void _injectRuDirect(
      Map<String, dynamic> cfg, Map<String, dynamic> route) {
    if (!(ruleSetsReady && ruleSetDir.isNotEmpty)) return;

    // Ensure a direct outbound exists to route RU traffic to.
    final outs = [...(cfg['outbounds'] as List? ?? const [])];
    String? directTag;
    for (final o in outs) {
      if (o is Map && o['type'] == 'direct') {
        directTag = o['tag']?.toString();
        break;
      }
    }
    if (directTag == null || directTag.isEmpty) {
      directTag = 'direct';
      outs.add({'type': 'direct', 'tag': directTag});
      cfg['outbounds'] = outs;
    }

    final rules = [...(route['rules'] as List? ?? const [])];
    // Respect the author's routing: bail if the config references RU geo
    // ANYWHERE (direct OR proxy), not just our own direct rule. A deliberate
    // geoip-ru/geosite-ru → proxy whitelist (or → direct) means they thought
    // about RU traffic — silently prepending our direct rule shadowed theirs.
    bool mentionsRuGeo(dynamic r) {
      if (r is! Map) return false;
      final rs = r['rule_set'];
      final tags = rs is List
          ? rs.map((e) => '$e')
          : (rs is String ? [rs] : const <String>[]);
      return tags.contains('geoip-ru') || tags.contains('geosite-ru');
    }

    if (rules.any(mentionsRuGeo)) return;

    // Insert after leading sniff/hijack-dns rules so it wins over the imported
    // (proxy-everything) rules but DNS hijack still runs.
    var at = 0;
    for (final r in rules) {
      if (r is Map && (r['action'] == 'sniff' || r['action'] == 'hijack-dns')) {
        at++;
      } else {
        break;
      }
    }
    rules.insert(
        at, {'rule_set': ['geoip-ru', 'geosite-ru'], 'outbound': directTag});
    if (!rules.any((r) => r is Map && r['ip_is_private'] == true)) {
      rules.insert(at, {'ip_is_private': true, 'outbound': directTag});
    }
    route['rules'] = rules;

    // Add the rule-set DEFINITIONS, deduped against existing tags.
    final rsDefs = [...(route['rule_set'] as List? ?? const [])];
    final have = rsDefs
        .whereType<Map>()
        .map((e) => e['tag']?.toString())
        .toSet();
    for (final tag in const ['geoip-ru', 'geosite-ru']) {
      if (!have.contains(tag)) {
        rsDefs.add(_ruleSet(tag, tag == 'geoip-ru' ? _geoipRu : _geositeRu));
      }
    }
    route['rule_set'] = rsDefs;
  }

  // Migrate a rule list to 1.13: removed-outbound refs -> actions; drop the
  // removed geoip/geosite database matchers (private geoip -> ip_is_private);
  // drop rules left with no matcher.
  static List<dynamic> _migrateRules(
      List? rules, Set<String> dnsTags, Set<String> blockTags,
      {bool forDns = false}) {
    final out = <dynamic>[];
    for (final r in rules ?? const []) {
      if (r is! Map) {
        out.add(r);
        continue;
      }
      final ob = r['outbound']?.toString();
      if (ob != null && dnsTags.contains(ob)) {
        r.remove('outbound');
        r['action'] = 'hijack-dns';
      } else if (ob != null && blockTags.contains(ob)) {
        r.remove('outbound');
        r['action'] = 'reject';
      }
      // Logical rule (and/or): migrate its nested rules too; drop it only if they
      // all disappear. (The old whitelist dropped logical rules outright.)
      if (r['type'] == 'logical' && r['rules'] is List) {
        r['rules'] =
            _migrateRules(r['rules'] as List, dnsTags, blockTags, forDns: forDns);
        if ((r['rules'] as List).isEmpty) continue;
      }
      final geoip = r['geoip'];
      if (geoip is List) {
        r.remove('geoip');
        if (geoip.map((e) => e.toString()).contains('private')) {
          r['ip_is_private'] = true;
        }
      }
      r.remove('geosite');
      if (!_ruleHasMatcher(r, forDns: forDns)) continue;
      out.add(r);
    }
    return out;
  }

  // Strip references to dropped rule-sets; drop rules left with no matcher.
  static List<dynamic> _dropRuleSet(List? rules, Set<String> dropped,
      {bool forDns = false}) {
    final out = <dynamic>[];
    for (final r in rules ?? const []) {
      if (r is! Map) {
        out.add(r);
        continue;
      }
      if (r['type'] == 'logical' && r['rules'] is List) {
        r['rules'] = _dropRuleSet(r['rules'] as List, dropped, forDns: forDns);
        if ((r['rules'] as List).isEmpty) continue;
      }
      final rs = r['rule_set'];
      if (rs is String && dropped.contains(rs)) {
        r.remove('rule_set');
      } else if (rs is List) {
        final kept = rs.where((t) => !dropped.contains(t.toString())).toList();
        if (kept.isEmpty) {
          r.remove('rule_set');
        } else {
          r['rule_set'] = kept;
        }
      }
      if (!_ruleHasMatcher(r, forDns: forDns)) continue;
      out.add(r);
    }
    return out;
  }

  // Convert legacy DNS servers (1.11 `address:` strings) to the typed 1.13
  // format: scheme -> type, host -> server; tag/detour preserved.
  // "https://1.1.1.1/dns-query" -> {type: https, server: 1.1.1.1}.
  // [dropped] = outbound tags removed by fromConfig: a server detouring through
  // one would dial a dead resolver (and if it's dns.final, ALL DNS dies after
  // connect) — strip the dangling detour. [fakeip] = the top-level dns.fakeip
  // block: a legacy `{address:'fakeip'}` server migrates to a typed fakeip
  // server pulling its ranges from there (else the core FATALs at startup).
  static List<dynamic> _migrateDnsServers(List? servers,
      {Set<String> dropped = const {}, Map? fakeip}) {
    final out = <dynamic>[];
    for (final s in servers ?? const []) {
      if (s is! Map) {
        out.add(s);
        continue;
      }
      final m = s.cast<String, dynamic>();
      final addrIsFakeip = m['address'] == 'fakeip' || m['server'] == 'fakeip';
      // Legacy fakeip server (pre-1.12 `{address:'fakeip'}`, or a 1.12 form that
      // dropped to the wrong type) -> typed {type:'fakeip', inet4/6_range}.
      if (m['type'] == 'fakeip' || addrIsFakeip) {
        final n = <String, dynamic>{
          'type': 'fakeip',
          'inet4_range': m['inet4_range'] ??
              fakeip?['inet4_range'] ??
              '198.18.0.0/15',
          'inet6_range':
              m['inet6_range'] ?? fakeip?['inet6_range'] ?? 'fc00::/18',
        };
        if (m['tag'] != null) n['tag'] = m['tag'];
        out.add(n);
        continue;
      }
      // Already new-format (has `type`) -> just scrub a dangling detour.
      if (m['type'] != null || m['address'] == null) {
        if (dropped.contains(m['detour']?.toString())) m.remove('detour');
        out.add(m);
        continue;
      }
      final addr = m['address'].toString();
      Map<String, dynamic> n;
      if (addr == 'local') {
        n = {'type': 'local'};
      } else if (addr == 'dhcp://auto' || addr == 'dhcp') {
        n = {'type': 'dhcp'};
      } else if (addr.contains('://')) {
        final u = Uri.tryParse(addr);
        // h3/https/tls/quic/tcp/udp each map to a sing-box DNS server type.
        n = {'type': (u?.scheme ?? 'udp').toLowerCase(), 'server': u?.host ?? addr};
        if (u != null && u.hasPort) n['server_port'] = u.port;
      } else {
        // Bare IP/host -> plain UDP on :53.
        n = {'type': 'udp', 'server': addr};
      }
      if (m['tag'] != null) n['tag'] = m['tag'];
      // A DNS server dials direct by default, so 1.13 REJECTS `detour: direct`
      // ("detour to an empty direct outbound makes no sense"). Keep only a real
      // detour (e.g. through the tunnel) that still EXISTS after the drop pass.
      final detour = m['detour'];
      if (detour != null &&
          detour != 'direct' &&
          !dropped.contains(detour.toString())) {
        n['detour'] = detour;
      }
      if (m['client_subnet'] != null) n['client_subnet'] = m['client_subnet'];
      out.add(n);
    }
    return out;
  }

  // Pick a DNS server tag that resolves WITHOUT the tunnel (direct/local) for
  // route.default_domain_resolver — never one detoured through the proxy, which
  // would deadlock (can't resolve the server until the tunnel it needs is up).
  static String? _directResolverTag(List? servers) {
    String? firstTag;
    for (final s in servers ?? const []) {
      if (s is! Map) continue;
      final tag = s['tag']?.toString();
      if (tag == null || tag.isEmpty) continue;
      firstTag ??= tag;
      final type = s['type']?.toString();
      final detour = s['detour']?.toString();
      if (type == 'local' || detour == null || detour == 'direct') return tag;
    }
    return firstTag;
  }

  /// Adds a system-wide TUN inbound (captures all OS traffic). Needs admin for
  /// auto_route. Ensures sniffing + DNS hijack + a resolver so domain routing
  /// and DNS work for every app. Keeps the mixed inbound for proxy-aware apps.
  static Map<String, dynamic> withTun(Map<String, dynamic> cfg,
      {List<String> splitApps = const [], List<String> forceApps = const []}) {
    final inbounds = [...(cfg['inbounds'] as List? ?? const [])];
    inbounds.add({
      'type': 'tun',
      'tag': 'tun-in',
      'interface_name': 'tun0', // deterministic name so the WFP fence finds its LUID
      // Capture BOTH families. An IPv4-only TUN leaves the system's IPv6 routed
      // straight out the physical NIC — a real egress leak whenever the
      // kill-switch is OFF (the default). The IPv6 ULA makes auto_route install a
      // ::/0 route so v6 is pulled into the tunnel too; with ipv4_only DNS almost
      // nothing resolves AAAA, and any stray v6 fails CLOSED through the proxy
      // instead of leaking direct.
      'address': ['172.18.0.1/30', 'fdfe:dcba:9876::1/126'],
      'auto_route': true,
      'strict_route': true,
      'stack': 'gvisor',
      'mtu': 9000,
    });
    cfg['inbounds'] = inbounds;

    final route = Map<String, dynamic>.from(
        (cfg['route'] as Map?)?.cast<String, dynamic>() ?? {});
    route['auto_detect_interface'] = true;
    final rules = [...(route['rules'] as List? ?? const [])];
    final prepend = <dynamic>[];
    if (!rules.any((r) => r is Map && r['action'] == 'sniff')) {
      prepend.add({'action': 'sniff'});
    }
    if (!rules.any((r) => r is Map && r['action'] == 'hijack-dns')) {
      prepend.add({'protocol': 'dns', 'action': 'hijack-dns'});
    }
    // Per-app process_name rules — collected here, then inserted AFTER the
    // leading sniff/hijack-dns (NOT before). DNS must be hijacked first: if a
    // process rule precedes hijack-dns, a forced app's UDP/53 matches it and is
    // sent raw to a TCP-only Vision node, so its DNS silently dies.
    final appRules = <dynamic>[];
    // Split-tunnel: route these processes DIRECT (bypass the VPN) — e.g. a game
    // for low latency.
    final apps = splitApps.where((a) => a.trim().isNotEmpty).toList();
    if (apps.isNotEmpty) {
      final outs = [...(cfg['outbounds'] as List? ?? const [])];
      String? directTag;
      for (final o in outs) {
        if (o is Map && o['type'] == 'direct') {
          directTag = o['tag']?.toString();
          break;
        }
      }
      if (directTag == null || directTag.isEmpty) {
        directTag = 'direct';
        outs.add({'type': 'direct', 'tag': directTag});
        cfg['outbounds'] = outs;
      }
      appRules.add({'process_name': apps, 'outbound': directTag});
    }
    // Force-through-VPN apps: pin them to the config's main VPN outbound (route
    // final), so a BLOCKED app (Discord, blocked games) is ALWAYS tunnelled —
    // routing it direct would just break it. Skip if the final is itself direct
    // (no-server / desync mode), where there is no VPN outbound to pin to.
    final pinned = forceApps.where((a) => a.trim().isNotEmpty).toList();
    final finalTag = route['final']?.toString();
    if (pinned.isNotEmpty && finalTag != null && finalTag != 'direct') {
      appRules.add({'process_name': pinned, 'outbound': finalTag});
    }
    final merged = [...prepend, ...rules];
    if (appRules.isNotEmpty) {
      // Index past the leading sniff/hijack-dns block (from prepend OR already in
      // the imported rules), insert the app rules there — ahead of geo/proxy
      // rules so they still win, but behind DNS hijack so DNS resolves.
      var at = 0;
      for (final r in merged) {
        if (r is Map && (r['action'] == 'sniff' || r['action'] == 'hijack-dns')) {
          at++;
        } else {
          break;
        }
      }
      merged.insertAll(at, appRules);
    }
    route['rules'] = merged;

    // Ensure hijacked DNS has somewhere to resolve.
    if (cfg['dns'] == null) {
      cfg['dns'] = {
        'servers': [
          {'type': 'https', 'tag': 'dns-direct', 'server': dnsServer},
        ],
        'final': 'dns-direct',
        'strategy': 'ipv4_only',
      };
      route['default_domain_resolver'] = {'server': 'dns-direct'};
    }
    cfg['route'] = route;
    return cfg;
  }

  /// Stamp Brutal-style fixed bandwidth onto every hysteria2 outbound when the
  /// user has set their line speed. Hysteria2's congestion control holds
  /// throughput under loss/jitter (noisy RF links) when told the real up/down
  /// rate; 0 leaves it to Hysteria2's default auto-tune (field omitted). Safe
  /// no-op for every other protocol and when both are 0.
  static Map<String, dynamic> tuneHysteria2(
      Map<String, dynamic> cfg, int upMbps, int downMbps) {
    if (upMbps <= 0 && downMbps <= 0) return cfg;
    final outs = cfg['outbounds'];
    if (outs is! List) return cfg;
    for (final o in outs) {
      if (o is Map && o['type'] == 'hysteria2') {
        if (upMbps > 0) o['up_mbps'] = upMbps;
        if (downMbps > 0) o['down_mbps'] = downMbps;
      }
    }
    return cfg;
  }

  static String encode(Map<String, dynamic> cfg) =>
      const JsonEncoder.withIndent('  ').convert(cfg);
}
