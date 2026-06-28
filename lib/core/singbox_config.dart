import 'dart:convert';

import 'proxy_node.dart';
import 'route_mode.dart';
import 'route_rule.dart';

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
        'inbounds': _baseInbounds(), // single 127.0.0.1 mixed inbound (matches the system proxy)
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

  /// Advanced transport knobs the controller injects from AppSettings before each
  /// build (same static-injection pattern as [logLevel]/[dnsServer]). Defaults
  /// reproduce the prior hardcoded behaviour, so an untouched app is unchanged.
  static String tunStack = 'gvisor'; // sing-box TUN network stack
  static String muxProtocol = 'h2mux'; // multiplex carrier when mux is on
  static int muxStreams = 8; // multiplex max concurrent streams
  static bool muxPadding = false; // multiplex padding (hide stream sizes)
  static bool tcpFastOpen = false; // TCP Fast Open on TCP-dial outbounds (advanced)
  static bool mptcp = false; // Multipath TCP on TCP-dial outbounds (advanced)
  static String ecsSubnet = ''; // EDNS Client Subnet (e.g. 1.2.3.0/24); '' = off

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

  /// Domestic DNS carve-out: RU/ex-USSR TLDs resolve via the DIRECT resolver
  /// (off-tunnel, RU-reachable) instead of being dragged through the foreign exit
  /// — keeps RU DNS fast and reachable even when the tunnel exit stalls. Emitted
  /// ALWAYS (no rule-set needed), mirroring how Hiddify carves out `.ru`. ASCII
  /// suffixes only (an IDN like .рф is punycode on the wire, so a literal Cyrillic
  /// suffix would never match the sniffed SNI).
  static const List<String> ruDnsSuffixes = ['.ru', '.su'];

  /// Benign foreign control IPs the watchdog raw-dials to tell a real "whitelist
  /// mode" collapse (every foreign SYN dropped) from a mere node block. In TUN
  /// mode [withTun] routes these DIRECT so the dial bypasses auto_route capture
  /// and measures the PHYSICAL uplink — otherwise a dark tunnel eats the probe and
  /// the banner false-fires. Single source of truth, shared with CoreController.
  static const List<String> foreignProbeIps = [
    '8.8.8.8', // Google Public DNS
    '9.9.9.9', // Quad9
    '208.67.222.222', // OpenDNS
  ];

  /// FakeIP synthetic ranges (RFC 2544 v4 benchmarking block + a ULA v6 block — not
  /// private, not real routable traffic) for the opt-in TUN FakeIP DNS mode. The v6
  /// range pairs with v4 so an app's AAAA query also gets a synthetic answer (matching
  /// the imported-config fakeip path); RF has no working v6 so it's rarely exercised.
  static const String _fakeipRange = '198.18.0.0/15';
  static const String _fakeipRange6 = 'fc00::/18';

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
      bool ech = false,
      bool fakeip = false}) {
    final n = _prepare(node,
        antiDpi: antiDpi, fp: tlsFingerprint, mux: mux, ech: ech);
    return mode == RouteMode.smart
        ? _smart([n.outbound], n.tag, fakeip: fakeip)
        : _global([n.outbound], n.tag, fakeip: fakeip);
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
      bool ech = false,
      bool fakeip = false}) {
    final simple = nodes.where((n) => !n.isConfig).toList();
    if (simple.isEmpty) return m0Local();
    final prepared = simple
        .map((n) => _prepare(n,
            antiDpi: antiDpi, fp: tlsFingerprint, mux: mux, ech: ech))
        .toList();
    if (prepared.length == 1) {
      final n = prepared.first;
      return mode == RouteMode.smart
          ? _smart([n.outbound], n.tag, fakeip: fakeip)
          : _global([n.outbound], n.tag, fakeip: fakeip);
    }
    final proxies = <Map<String, dynamic>>[
      ...prepared.map((n) => n.outbound),
      {
        'type': 'urltest',
        'tag': autoTag,
        'outbounds': prepared.map((n) => n.tag).toList(),
        'url': 'https://www.gstatic.com/generate_204',
        'interval': '90s', // react faster to a fresh ТСПУ block wave
        'tolerance': 100, // hysteresis: don't re-pick on a tiny latency wobble
        // Keep live connections (Telegram's long-lived MTProto socket) pinned to
        // their member across a re-pick — only NEW connections move to the fastest.
        'interrupt_exist_connections': false,
      },
      {
        // Manual picker: defaults to Auto, but the user can pin one server in
        // the Policies tab (a URLTest alone can't be hand-selected).
        'type': 'selector',
        'tag': selectorTag,
        'outbounds': [autoTag, ...prepared.map((n) => n.tag)],
        'default': autoTag,
        // The restart-free cascade hop re-PUTs THIS selector — pin the flag false
        // (don't lean on sing-box's implicit default, per the stability directive)
        // so a routine hop never cuts the live Telegram socket on the member it
        // leaves.
        'interrupt_exist_connections': false,
      },
    ];
    return mode == RouteMode.smart
        ? _smart(proxies, selectorTag, fakeip: fakeip)
        : _global(proxies, selectorTag, fakeip: fakeip);
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
    _applyLevers(ob, antiDpi: antiDpi, fp: fp, mux: mux, ech: ech, ownNode: true);
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
      required bool ech,
      bool ownNode = false}) {
    final type = ob['type']?.toString();
    // VLESS UDP (QUIC / HTTP3 / DoQ / voice) needs xudp packet-encoding to carry
    // multi-destination UDP correctly. Without it XTLS-Vision falls back to a
    // legacy encoding that mishandles those flows → "connects but HTTP/3 sites
    // hang". The proven Hiddify config sets this on the identical node. ONLY for
    // OUR OWN generated nodes (ownNode) — never an IMPORTED full sing-box config,
    // where the author may have deliberately omitted it for an older server that
    // doesn't speak xudp (flipping it there would break a node that worked).
    if (ownNode && type == 'vless' && ob['packet_encoding'] == null) {
      ob['packet_encoding'] = 'xudp';
    }
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
        // Reality REQUIRES utls ENABLED — the X25519 key_share rides the uTLS
        // ClientHello, so an import carrying utls.enabled:false FATALs the core.
        // Force enabled:true ALWAYS; only normalize a missing/synthetic fp to
        // chrome, leaving a real author-chosen browser fp intact (auto-adapt must
        // not corrupt the handshake fingerprint of the Reality nodes it rescues).
        final cur = utls?['fingerprint']?.toString();
        final needsFp = cur == null ||
            cur.isEmpty ||
            cur == 'randomized' ||
            cur == 'random' ||
            cur == 'yandex';
        t['utls'] = {
          ...?utls,
          'enabled': true,
          'fingerprint': needsFp ? 'chrome' : cur,
        };
      } else {
        if (isTcpProxy && fp.isNotEmpty && fp != 'randomized') {
          final useFp = fp == 'yandex' ? 'chrome' : fp; // no literal 'yandex'
          t['utls'] = {...?utls, 'enabled': true, 'fingerprint': useFp};
        }
        if (ech) {
          // Floor: enable ECH so sing-box auto-resolves the ECHConfigList over
          // its OWN (in-tunnel) DNS — the path that still works in RF where the
          // pre-tunnel DoH the discovery pass uses (1.1.1.1/8.8.8.8) is dropped.
          // The discovery pass (core_controller._applyEchDiscovery) ADDS a
          // concrete config when a pre-tunnel lookup succeeds; a host that
          // publishes none is a cheap no-op DNS query, not a failed connect.
          final curEch = t['ech'];
          t['ech'] = {if (curEch is Map) ...curEch, 'enabled': true};
        }
        if (antiDpi && isTcpProxy) {
          t['fragment'] = true;
          t['fragment_fallback_delay'] = '500ms';
        }
      }
      ob['tls'] = t;
    }
    // Multiplex: TCP proxies only, NOT with XTLS-Vision flow (sing-box rejects
    // mux + vision together). Carrier/streams/padding come from the advanced
    // knobs (default h2mux/8/off = the prior hardcoded behaviour).
    if (mux && isTcpProxy && (ob['flow'] == null || '${ob['flow']}'.isEmpty)) {
      ob['multiplex'] = {
        'enabled': true,
        'protocol': muxProtocol,
        'max_streams': muxStreams,
        if (muxPadding) 'padding': true,
      };
    }
    // TCP Fast Open / Multipath TCP — advanced opt-in dial knobs (default OFF).
    // TFO is HONESTLY risky on a Windows-first RF client (it FATALs on `anytls`,
    // can silently dead-tunnel per sing-box #1903, and middleboxes drop SYN-with-
    // data on the RF paths we target) — so it is gated behind an explicit toggle +
    // UI warning and NEVER touches anytls/QUIC. MPTCP applies to TCP-dial proxies.
    const tcpDial = {
      'vless', 'vmess', 'trojan', 'shadowsocks', 'shadowtls', 'socks', 'http'
    };
    if (type != null && tcpDial.contains(type)) {
      if (tcpFastOpen) ob['tcp_fast_open'] = true;
      if (mptcp) ob['tcp_multi_path'] = true;
    }
  }

  // Local proxy on IPv4 loopback only. We set the Windows system proxy to the
  // IP literal 127.0.0.1:2080, so proxy-aware apps (incl. Chromium/Electron /
  // the Claude desktop app) connect over IPv4 — a ::1 listener bought nothing and
  // a 2nd inbound on ::1 would FATAL the whole core on a host with IPv6 disabled
  // (a hard regression vs IPv4-only). Loopback-only (never 0.0.0.0) → off the LAN.
  static List<Map<String, dynamic>> _baseInbounds() => [
        {
          'type': 'mixed',
          'tag': 'mixed-in',
          'listen': mixedListen,
          'listen_port': mixedPort,
        },
      ];

  static Map<String, dynamic> _global(
          List<Map<String, dynamic>> proxies, String tag,
          {bool fakeip = false}) =>
      {
        'log': {'level': logLevel, 'timestamp': true},
        'dns': {
          'servers': [
            // FakeIP (opt-in, TUN): answer the app INSTANTLY with a synthetic IP
            // (no DNS round-trip), then route by the remembered domain and let the
            // EXIT resolve the real IP. Cuts first-load latency; no DNS leak.
            if (fakeip)
              {
                'type': 'fakeip',
                'tag': 'dns-fake',
                'inet4_range': _fakeipRange,
                'inet6_range': _fakeipRange6,
              },
            // Foreign names resolve over the TUNNEL via UDP DNS to 8.8.8.8. UDP
            // datagrams are INDEPENDENT (matched by query-id) so a cold-start
            // burst of many lookups resolves in PARALLEL — unlike DoH/TCP-over-
            // tunnel, where queries pile onto ONE connection that head-of-line
            // STALLS (observed: 6–34s lookups while real data flowed at 160ms).
            // Our xudp packet-encoding carries the UDP; the tunnel hides it from
            // DPI. Paired with the persistent DNS cache below (Hiddify-style).
            {'type': 'udp', 'tag': 'dns-proxy', 'server': '8.8.8.8', 'detour': tag},
            // No `detour: direct` — a DNS server dials direct by default, and
            // 1.13 FATALs on "detour to an empty direct outbound".
            {'type': 'https', 'tag': 'dns-direct', 'server': dnsServer},
          ],
          'rules': [
            // RU/ex-USSR domains resolve via the DIRECT resolver (off-tunnel,
            // RU-reachable) so RU DNS stays fast even if the foreign exit stalls —
            // ALWAYS on, no rule-set needed. Foreign names still ride dns-proxy.
            {'domain_suffix': ruDnsSuffixes, 'server': 'dns-direct'},
            if (fakeip) {'query_type': ['A', 'AAAA'], 'server': 'dns-fake'},
          ],
          'final': 'dns-proxy',
          'strategy': 'ipv4_only', // RF has no working IPv6
          // Keep answers across the session AND reconnects (cache_file below) so a
          // restart doesn't re-pay the slow cold-resolve burst; independent_cache
          // stops the direct + tunnel resolvers poisoning each other. (Hiddify.)
          'independent_cache': true,
          'disable_expire': true,
        },
        'experimental': {
          'clash_api': _clashApi(),
          // Persist the DNS cache to disk so reconnects start WARM (Hiddify does
          // this). No path → sing-box writes cache.db in its working dir.
          'cache_file': {'enabled': true},
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
      List<Map<String, dynamic>> proxies, String tag,
      {bool fakeip = false}) {
    // Without the bundled rule-sets we can't geo-route — degrade to a SAFE
    // config (everything via proxy, only private IPs direct) rather than
    // reference a rule-set that isn't on disk (which FATALs the core).
    final useRuleSets = ruleSetsReady && ruleSetDir.isNotEmpty;
    // FakeIP is only SAFE alongside the geosite-ru DNS carve-out: without it the
    // fakeip catch-all also synthesises RU domains → gov/banks resolve to a fake
    // IP, route by domain out the FOREIGN exit and reverse-geo-block while the UI
    // says Connected. So engage FakeIP only when rule-sets are ready.
    final useFakeip = fakeip && useRuleSets;
    return {
      'log': {'level': logLevel, 'timestamp': true},
      'dns': {
        'servers': [
          // FakeIP (opt-in, TUN): instant synthetic answer → route by domain →
          // EXIT resolves the real IP. RU domains are excluded below (they get a
          // REAL direct answer so RU-direct routing still works on a real IP).
          if (useFakeip)
            {
              'type': 'fakeip',
              'tag': 'dns-fake',
              'inet4_range': _fakeipRange,
              'inet6_range': _fakeipRange6,
            },
          // Foreign DNS over the tunnel via UDP (independent datagrams resolve a
          // cold burst in PARALLEL; TCP/DoH-over-tunnel serialised them to 6–34s).
          // xudp carries it; tunnel hides it from DPI. (See _global.)
          {'type': 'udp', 'tag': 'dns-proxy', 'server': '8.8.8.8', 'detour': tag},
          {'type': 'https', 'tag': 'dns-direct', 'server': dnsServer},
        ],
        'rules': [
          // RU/ex-USSR by suffix → real DIRECT DNS (off-tunnel), ALWAYS — even with
          // no rule-set on disk — so RU DNS is fast and reachable. geosite-ru adds
          // the broader RU set when the bundled rule-sets are present.
          {'domain_suffix': ruDnsSuffixes, 'server': 'dns-direct'},
          if (useRuleSets) {'rule_set': 'geosite-ru', 'server': 'dns-direct'},
          // everything else → fakeip (foreign rides the proxy by domain). Gated on
          // useFakeip so it never runs without the RU carve-out above.
          if (useFakeip) {'query_type': ['A', 'AAAA'], 'server': 'dns-fake'},
        ],
        'final': 'dns-proxy',
        'strategy': 'ipv4_only',
        // Persistent + independent DNS cache so reconnects start warm (Hiddify).
        'independent_cache': true,
        'disable_expire': true,
      },
      'experimental': {
        'clash_api': _clashApi(),
        'cache_file': {'enabled': true},
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
      bool ruDirect = false,
      bool keepAmneziaMarker = false}) {
    // Deep copy so we never mutate the stored profile.
    final cfg = jsonDecode(jsonEncode(src)) as Map<String, dynamic>;

    // Strip our non-standard `_`-prefixed stash keys (e.g. `_amneziawg` on a
    // wireguard endpoint) — the bundled core FATALs on unknown fields. They stay
    // in the STORED profile for a future AmneziaWG-capable core.
    //
    // EXCEPTION: when [keepAmneziaMarker] (set only when the awg bridge binary is
    // present), KEEP `_amneziawg` so the controller can (a) classify the family as
    // 'amneziawg' not plain 'wireguard' and (b) actually fire `_bridgeAmnezia`,
    // which then REPLACES the endpoint with a `socks` outbound — so the bundled
    // core still never sees the marker. The bridge's keep-path re-strips it if the
    // bridge fails to spawn, so a stray marker can never reach the core.
    for (final e in (cfg['endpoints'] as List?) ?? const []) {
      if (e is Map) {
        e.removeWhere((k, _) =>
            k.toString().startsWith('_') &&
            !(keepAmneziaMarker && k == '_amneziawg'));
      }
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
          o.remove('idle_timeout'); // 1.13 requires interval <= idle_timeout
          o['interval'] = '90s'; // tighter probe for faster block detection
        }
        // FORCE off on BOTH selector AND urltest (the loop already skipped other
        // types), whatever the imported config had. The restart-free cascade hop
        // re-PUTs the SELECTOR, and a re-pick/hop with interrupt_exist_connections:
        // true CUTS every live connection on the old member — Telegram's long-lived
        // MTProto socket above all → constant reconnects on a flaky operator. With
        // it false, only NEW connections move; the existing socket rides undisturbed.
        o['interrupt_exist_connections'] = false;
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
      final droppedDns = <String>{};
      dns['servers'] = _migrateDnsServers(dns['servers'] as List?,
          dropped: dropped, fakeip: fakeipBlock, droppedDns: droppedDns);
      dns.remove('fakeip');
      var rules =
          _migrateRules(dns['rules'] as List?, const {}, const {}, forDns: true);
      if (droppedRs.isNotEmpty) {
        rules = _dropRuleSet(rules, droppedRs, forDns: true);
      }
      // A DNS rule whose `server:` action pointed at a dropped resolver (unknown
      // type) is now dangling -> drop it; repoint dns.final off a dropped server.
      if (droppedDns.isNotEmpty) {
        rules = rules
            .where((r) =>
                !(r is Map && droppedDns.contains(r['server']?.toString())))
            .toList();
        if (droppedDns.contains(dns['final']?.toString())) {
          // Don't let `final` fall through to the injected direct bootstrap (a
          // plaintext RU resolver that honors RKN poisoning) — repoint to a
          // surviving REAL resolver, preferring one detoured through the tunnel
          // (the "remote" role the dropped final likely had). Last resort: remove.
          String? pick;
          for (final s in (dns['servers'] as List).whereType<Map>()) {
            final t = s['tag']?.toString();
            if (t == null || t == 'dns-bootstrap') continue;
            pick ??= t;
            if (s['detour'] != null) {
              pick = t;
              break;
            }
          }
          if (pick != null) {
            dns['final'] = pick;
          } else {
            dns.remove('final');
          }
        }
        // Same for route.default_domain_resolver: a dropped target FATALs the core
        // ("default domain resolver not found"). Repoint to a direct resolver
        // (prefers IP/local), else remove (the block below re-adds one if needed).
        final ddr =
            (route?['default_domain_resolver'] as Map?)?['server']?.toString();
        if (ddr != null && droppedDns.contains(ddr)) {
          final tag = _directResolverTag(dns['servers'] as List?);
          if (tag != null) {
            route!['default_domain_resolver'] = {'server': tag};
          } else {
            route!.remove('default_domain_resolver');
          }
        }
      }
      dns['rules'] = rules;
      // RF networks have no reliable IPv6: force A-only for EVERY imported config
      // so the core never hands a dead AAAA to a dial ("unreachable network",
      // battle-confirmed). Even a config that explicitly requested prefer_ipv6 /
      // ipv6_only (a global-world default) is normalized — v4 always works in RF,
      // and the TUN still captures any v6 so nothing leaks. RF reality wins over
      // the author's assumption.
      dns['strategy'] = 'ipv4_only';
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

    // FakeIP is intentionally NOT applied to imported full configs. They bring their
    // own DNS + routing (often IP-based geoip-ru RU-direct, or a direct-only final),
    // and a fakeip catch-all forced onto arbitrary author routing BREAKS it: synthetic
    // 198.18.x answers defeat ip_cidr rules (RU-direct then sends sanctioned RU sites
    // out the foreign exit → reverse-geo-block), and a direct final blackholes every
    // foreign site while the app still shows "Connected". FakeIP stays on app-managed
    // nodes (fromNode/fromNodes) where we own the whole DNS+routing and the geosite-ru
    // carve-out is guaranteed safe.

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

  /// Drop every outbound whose tag is in [dead] and cascade-prune the result so
  /// the config stays loadable: scrub the dead tags from each selector/urltest
  /// member list, remove any group thereby left empty (its own tag is then dead
  /// too — repeated to a fixpoint, so nested pools cascade), strip a dangling
  /// `detour` (on an outbound, endpoint, OR dns server), and RE-PIN a now-dangling
  /// `route.final` to a surviving exit (never let it default to a direct leak).
  ///
  /// Mirrors the proven drop-cascade in [fromConfig], kept self-contained so the
  /// safety-critical import path is untouched. Used by the xray bridge: when xray
  /// REJECTS a member's generated config, leaving its original `type: xhttp`
  /// outbound would make sing-box FATAL and take EVERY node down — so the dead
  /// member is dropped instead and the surviving pool keeps working (the
  /// selector / watchdog cascade simply never see it).
  ///
  /// Returns true if a usable proxy survives — ≥1 real proxy outbound (or a
  /// wireguard/amnezia endpoint) remains AND `route.final`, if still pinned,
  /// resolves to an existing outbound/endpoint — so the caller may launch the
  /// pruned config. False means every exit died (e.g. a single XHTTP node xray
  /// rejected): the caller must surface a clear error rather than run a config
  /// that routes everything DIRECT (deanonymising fail-open) or silent-dead.
  /// PURE: mutates [cfg] and returns the verdict.
  static bool pruneDeadOutbounds(Map<String, dynamic> cfg, Set<String> dead) {
    if (dead.isEmpty) return true;
    const groupTypes = {'selector', 'urltest'};
    const nonProxy = {'direct', 'block', 'dns', 'selector', 'urltest'};
    final dropped = <String>{...dead};
    var kept = [...((cfg['outbounds'] as List?) ?? const [])];
    var changed = true;
    while (changed) {
      changed = false;
      for (final o in kept) {
        if (o is! Map || !groupTypes.contains(o['type'])) continue;
        final list = (o['outbounds'] as List?)
            ?.where((t) => !dropped.contains(t.toString()))
            .toList();
        if (list != null) o['outbounds'] = list;
        if (dropped.contains(o['default']?.toString())) o.remove('default');
        if ((o['outbounds'] as List?)?.isEmpty ?? false) {
          final tag = o['tag']?.toString();
          if (tag != null && dropped.add(tag)) changed = true;
        }
      }
    }
    kept = kept
        .where((o) => !(o is Map && dropped.contains(o['tag']?.toString())))
        .toList();
    cfg['outbounds'] = kept;
    final endpoints = (cfg['endpoints'] as List?) ?? const [];
    // A surviving exit to re-pin orphaned references onto — a group (resolves to
    // proxies) first, else a real proxy, else a WG/amnezia endpoint.
    String? firstTag(Iterable list, bool Function(Map) ok) {
      for (final o in list) {
        if (o is Map && ok(o)) {
          final t = o['tag']?.toString();
          if (t != null && t.isNotEmpty) return t;
        }
      }
      return null;
    }

    final repin = firstTag(kept, (o) => groupTypes.contains(o['type'])) ??
        firstTag(kept, (o) => !nonProxy.contains(o['type']?.toString())) ??
        firstTag(endpoints, (_) => true);
    // A surviving outbound/endpoint detouring through a dropped tag FATALs at
    // runtime even though `sing-box check` passes — strip the dangling detour
    // (the outbound then dials directly itself, which is its normal un-chained
    // form; re-routing a chained dialer through an arbitrary survivor would
    // silently change its path).
    void scrubDetour(List? list, {String? repinTo}) {
      for (final o in list ?? const []) {
        if (o is Map && dropped.contains(o['detour']?.toString())) {
          if (repinTo != null) {
            o['detour'] = repinTo;
          } else {
            o.remove('detour');
          }
        }
      }
    }

    scrubDetour(kept);
    scrubDetour(endpoints);
    // A dns.server whose `detour` pointed at a dropped tag is the SAME landmine:
    // `sing-box check` PASSES but the core FATALs at service-start ("outbound
    // detour not found"). Unlike a chained dialer, a DNS detour going DIRECT is a
    // real leak: the DoH queries exit the physical uplink (visible/blocked by the
    // ISP). RE-PIN it onto the surviving exit; strip only when nothing survives
    // (the launch then fails closed via the hasProxy verdict below).
    scrubDetour((cfg['dns'] as Map?)?['servers'] as List?, repinTo: repin);
    final route = cfg['route'];
    if (route is Map) {
      // RE-PIN route.final, never just drop: an ABSENT final defaults to the FIRST
      // outbound, which in an imported config could be `direct` ⇒ everything routes
      // direct (a fail-OPEN leak). If nothing survives, remove it and let the hasProxy
      // verdict below fail the launch (caller surfaces an error — never fails open).
      if (dropped.contains(route['final']?.toString())) {
        if (repin != null) {
          route['final'] = repin;
        } else {
          route.remove('final');
        }
      }
      // SAME landmine on route.rules: a rule whose `outbound` is a dropped tag — an
      // always-injected Telegram rule, or a force-VPN / custom rule pinned to a leaf
      // the xray bridge just failed — passes `sing-box check` yet FATALs the core at
      // service-start ("outbound not found"), taking the whole tunnel down. Re-pin
      // proxy-intent rules onto the survivor; drop them only if no exit survives (the
      // launch then fails closed via the hasProxy verdict below).
      final rules = route['rules'];
      if (rules is List) {
        final out = <dynamic>[];
        for (final r in rules) {
          if (r is Map && dropped.contains(r['outbound']?.toString())) {
            if (repin != null) {
              r['outbound'] = repin;
              out.add(r);
            }
            // else: no surviving exit to send it to → drop the rule entirely
          } else {
            out.add(r);
          }
        }
        route['rules'] = out;
      }
    }
    // Survivability: a real proxy (or a WG/amnezia endpoint, bridged later) must
    // remain. An unpinned route.final defaults to the first outbound, covered by
    // the proxy check; a still-pinned one must resolve to a surviving exit.
    final hasProxy = kept.any(
            (o) => o is Map && !nonProxy.contains(o['type']?.toString())) ||
        endpoints.isNotEmpty;
    if (!hasProxy) return false;
    final fin = route is Map ? route['final']?.toString() : null;
    if (fin != null &&
        !kept.any((o) => o is Map && o['tag']?.toString() == fin) &&
        !endpoints.any((e) => e is Map && e['tag']?.toString() == fin)) {
      return false;
    }
    return true;
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
    final rawRules = route['rules'];
    final rules = [...(rawRules is List ? rawRules : const [])];
    // Key-agnostic guard: if ANY existing rule mentions Telegram (via
    // domain_suffix / domain / domain_keyword / geosite / a DC CIDR) the author
    // already routes it — don't shadow their explicit intent (e.g. Telegram→direct).
    // The old guard only scanned domain_suffix/ip_cidr and missed those keys.
    bool mentionsTelegram(Map r) {
      // Scan ONLY the MATCH keys — what a rule TARGETS. Flattening every value
      // (incl. the outbound/action) made a destination GROUP named e.g.
      // 'TelegramSpeed' read as "author already routes Telegram", and a bare
      // 't.me' substring matched unrelated domains ('clien[t.me]nu',
      // 'prin[t.me]dia'). Both falsely skipped the Telegram pin.
      const matchKeys = {
        'domain', 'domain_suffix', 'domain_keyword', 'geosite', 'rule_set',
        'ip_cidr', 'source_ip_cidr',
      };
      for (final e in r.entries) {
        if (!matchKeys.contains(e.key)) continue;
        final vals = e.value is List ? e.value as List : [e.value];
        for (final raw in vals) {
          final s = '$raw'.toLowerCase().trim();
          // geosite/keyword 'telegram', domains telegram.org / t.me, and the DC
          // CIDRs — each anchored so a substring can't false-match.
          if (s == 'telegram' || s.contains('telegram')) return true;
          if (s == 't.me' || s.endsWith('.t.me')) return true;
          // IP prefixes anchored per token — '91.108.' must not match
          // '191.108.x.y/16'.
          if (s.startsWith('149.154.16') || s.startsWith('91.108.')) return true;
        }
      }
      return false;
    }
    if (rules.any((r) => r is Map && mentionsTelegram(r))) {
      return; // author already handles Telegram routing
    }

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
      } else if (forDns && ob != null) {
        // A DNS rule's `outbound` is a REMOVED matcher (sing-box 1.12), not an
        // action ref — it FATALs the core (the deprecated-shim env only tolerates
        // it on <=1.13). Drop it; the rule's `server:` action still applies, just
        // to a wider match. (Route rules KEEP `outbound` — there it's the action.)
        r.remove('outbound');
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
  // DNS server types the bundled sing-box (1.13) accepts. Anything else (e.g. a
  // legacy `rcode://success` / `reject://` block server) has no such type -> drop
  // it + scrub refs (DisallowUnknownFields would FATAL the whole config).
  static const _validDnsTypes = {
    'udp', 'tcp', 'tls', 'quic', 'https', 'h3', 'local', 'dhcp', 'fakeip',
    'hosts', 'tailscale'
  };
  // A server addressed by a HOSTNAME (these transport types) needs a
  // domain_resolver in 1.13 or the core FATALs "missing domain resolver".
  static const _resolvableDnsTypes = {'udp', 'tcp', 'tls', 'quic', 'https', 'h3'};

  static bool _isIpLiteral(String h) {
    if (h.contains(':')) return true; // IPv6 literal
    final p = h.split('.');
    return p.length == 4 &&
        p.every((x) {
          final n = int.tryParse(x);
          return n != null && n >= 0 && n <= 255;
        });
  }

  static List<dynamic> _migrateDnsServers(List? servers,
      {Set<String> dropped = const {}, Map? fakeip, Set<String>? droppedDns}) {
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
      // Already new-format (has `type`) -> validate the type, scrub a dead detour.
      if (m['type'] != null || m['address'] == null) {
        final t = m['type']?.toString();
        if (t != null && !_validDnsTypes.contains(t)) {
          if (m['tag'] != null) droppedDns?.add(m['tag'].toString());
          continue;
        }
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
        final type = (u?.scheme ?? 'udp').toLowerCase();
        if (!_validDnsTypes.contains(type)) {
          // Unknown DNS transport (rcode://, reject://, ...): no such server type
          // in 1.13. Drop it + scrub refs — a lost ad-block resolver just means
          // ads aren't DNS-blocked, NOT a rejected config.
          if (m['tag'] != null) droppedDns?.add(m['tag'].toString());
          continue;
        }
        n = {'type': type, 'server': u?.host ?? addr};
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

    // 1.13 needs every hostname-addressed DNS server to carry a domain_resolver.
    // Find a direct IP/local server to bootstrap from (resolves the DoH hostname
    // ONCE, pre-tunnel); inject a Yandex UDP:53 one if the config has only
    // hostname resolvers; then point each hostname server at it.
    final needsResolver = out.whereType<Map>().any((s) =>
        _resolvableDnsTypes.contains(s['type']) &&
        s['server'] is String &&
        !_isIpLiteral(s['server'] as String) &&
        s['domain_resolver'] == null);
    if (needsResolver) {
      String? boot;
      for (final s in out.whereType<Map>()) {
        final tag = s['tag']?.toString();
        if (tag == null) continue;
        if (s['type'] == 'local') {
          boot = tag;
          break;
        }
        if (s['detour'] == null &&
            s['server'] is String &&
            _isIpLiteral(s['server'] as String)) {
          boot ??= tag;
        }
      }
      if (boot == null) {
        boot = 'dns-bootstrap';
        out.insert(0, {'type': 'udp', 'server': '77.88.8.8', 'tag': boot});
      }
      for (final s in out.whereType<Map>()) {
        if (_resolvableDnsTypes.contains(s['type']) &&
            s['server'] is String &&
            !_isIpLiteral(s['server'] as String) &&
            s['domain_resolver'] == null &&
            s['tag']?.toString() != boot) {
          s['domain_resolver'] = {'server': boot};
        }
      }
    }
    return out;
  }

  // Pick a DNS server tag that resolves WITHOUT the tunnel (direct/local) for
  // route.default_domain_resolver — never one detoured through the proxy, which
  // would deadlock (can't resolve the server until the tunnel it needs is up).
  static String? _directResolverTag(List? servers) {
    String? firstTag, directTag;
    for (final s in servers ?? const []) {
      if (s is! Map) continue;
      final tag = s['tag']?.toString();
      if (tag == null || tag.isEmpty) continue;
      firstTag ??= tag;
      final type = s['type']?.toString();
      final detour = s['detour']?.toString();
      final isDirect = type == 'local' || detour == null || detour == 'direct';
      if (!isDirect) continue;
      // Prefer a resolver that itself needs no DNS (local / IP literal) so the
      // default resolver can't deadlock bootstrapping its own hostname.
      final srv = s['server']?.toString();
      if (type == 'local' || (srv != null && _isIpLiteral(srv))) return tag;
      directTag ??= tag;
    }
    return directTag ?? firstTag;
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
      // gVisor (default) is the most compatible on Windows; `system`/`mixed` are
      // advanced opt-ins (lower overhead, but rely on the OS stack). Validated to
      // one of the known values upstream in AppSettings.
      'stack': tunStack,
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
    // Resolve (or create) the DIRECT outbound tag ONCE — shared by the whitelist
    // probe rule and split-tunnel. Imported configs may name it differently or
    // (rarely) omit it, in which case referencing 'direct' would FATAL.
    String directTag = 'direct';
    {
      final outs = [...(cfg['outbounds'] as List? ?? const [])];
      String? found;
      for (final o in outs) {
        if (o is Map &&
            o['type'] == 'direct' &&
            (o['tag']?.toString().isNotEmpty ?? false)) {
          found = o['tag'].toString();
          break;
        }
      }
      if (found == null) {
        outs.add({'type': 'direct', 'tag': directTag});
        cfg['outbounds'] = outs;
      } else {
        directTag = found;
      }
    }

    final appRules = <dynamic>[];
    // #3 (user-reported: "whitelist mode activates constantly"): route the
    // watchdog's foreign-reachability probe IPs DIRECT. In TUN, auto_route
    // captures the controller's own raw dial too, so a dark tunnel swallows the
    // probe → the app concludes "all foreign dark" → false whitelist latch on
    // every blip. Direct, the probe measures the PHYSICAL uplink: reachable ⇒ a
    // node block (cascade/hop); all-dark ⇒ a genuine state-allowlist collapse.
    appRules.add({
      // SCOPED to our OWN process: only the watchdog's raw probe dial must escape the
      // tunnel to measure the physical uplink. Without this process_name guard the rule
      // routed EVERY app's traffic to these public-DNS IPs DIRECT — a DoH browser
      // (Chrome/Firefox pointed at 8.8.8.8 / 9.9.9.9 / 208.67.222.222) would leak its
      // real IP and all DNS past the tunnel in TUN, the "secure" mode. The process name
      // is BINARY_NAME from windows/CMakeLists.txt; if it can't be matched the probe is
      // merely tunnelled (a benign false-whitelist blip), never a silent leak.
      'process_name': const ['vpn_app.exe'],
      'ip_cidr': foreignProbeIps.map((ip) => '$ip/32').toList(),
      'outbound': directTag,
    });
    // Split-tunnel: route these processes DIRECT (bypass the VPN) — e.g. a game
    // for low latency.
    final apps = splitApps.where((a) => a.trim().isNotEmpty).toList();
    if (apps.isNotEmpty) {
      appRules.add({'process_name': apps, 'outbound': directTag});
    }
    // Force-through-VPN apps: pin them to the config's main VPN outbound (route
    // final), so a BLOCKED app (Discord, blocked games) is ALWAYS tunnelled —
    // routing it direct would just break it. Skip if the final is itself direct
    // (no-server / desync mode), where there is no VPN outbound to pin to.
    final pinned = forceApps.where((a) => a.trim().isNotEmpty).toList();
    final finalTag = route['final']?.toString();
    if (pinned.isNotEmpty && finalTag != null && finalTag != directTag) {
      appRules.add({'process_name': pinned, 'outbound': finalTag});
    }
    // Index past the leading sniff/hijack-dns block (from prepend OR already in
    // the imported rules), insert the app rules there — ahead of geo/proxy rules
    // so they still win, but behind DNS hijack so DNS resolves.
    final merged = [...prepend, ...rules];
    var at = 0;
    for (final r in merged) {
      if (r is Map && (r['action'] == 'sniff' || r['action'] == 'hijack-dns')) {
        at++;
      } else {
        break;
      }
    }
    merged.insertAll(at, appRules);
    // IPv6 fail-fast — appended LAST so it only catches v6 flows that matched no
    // earlier, more-specific rule (Telegram→tunnel, private→direct, geo-direct all
    // still win for v6 — the audit caught this shadowing the Telegram pin). Every
    // exit + the in-tunnel DNS are IPv4-only, so an unmatched v6 flow would
    // otherwise black-hole until the app's Happy-Eyeballs timeout; `reject` stays
    // fail-CLOSED (the ULA still captures v6, no leak) but returns at once → v4.
    if (!merged.any(
        (r) => r is Map && r['ip_version'] == 6 && r['action'] == 'reject')) {
      merged.add({'ip_version': 6, 'action': 'reject'});
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

  /// Inject the user's custom routing rules (domain/ip → proxy/direct/block) into
  /// route.rules — competitor parity (Throne / Karing / v2rayN / Hiddify all let
  /// the user force specific destinations; we only had smart/global). Placed
  /// AFTER the leading sniff/hijack-dns (so DNS still resolves) but BEFORE the
  /// geo/smart rules (so a user rule WINS). Each value is sanitised (control-char
  /// strip + a shape check) so a hostile/typo'd entry can't inject or FATAL the
  /// core; a "proxy" rule is dropped in no-server mode (nothing to proxy through).
  /// Applied uniformly by the controller to every built config (simple node,
  /// imported config, auto-pool), before [withTun]. PURE.
  static Map<String, dynamic> applyCustomRules(
      Map<String, dynamic> cfg, List<RouteRule> rules) {
    if (rules.isEmpty) return cfg;
    final route = (cfg['route'] as Map?)?.cast<String, dynamic>();
    if (route == null) return cfg;
    final ruleList = [...(route['rules'] as List? ?? const [])];

    // Resolve (or create) the direct tag; resolve the proxy = route.final.
    String directTag = 'direct';
    final outs = [...(cfg['outbounds'] as List? ?? const [])];
    String? foundDirect;
    for (final o in outs) {
      if (o is Map &&
          o['type'] == 'direct' &&
          (o['tag']?.toString().isNotEmpty ?? false)) {
        foundDirect = o['tag'].toString();
        break;
      }
    }
    if (foundDirect == null) {
      outs.add({'type': 'direct', 'tag': directTag});
      cfg['outbounds'] = outs;
    } else {
      directTag = foundDirect;
    }
    final finalTag = route['final']?.toString();

    final built = <dynamic>[];
    for (final r in rules) {
      // Validate with the SAME check the UI uses (RouteRule.isValidValue) so a
      // value the editor accepted always emits, and a typo never FATALs the core.
      if (!RouteRule.isValidValue(r.field, r.value)) continue;
      final value = RouteRule.cleanValue(r.field, r.value);
      final m = <String, dynamic>{
        r.matchKey: [value],
      };
      switch (r.action) {
        case RuleAction.block:
          m['action'] = 'reject';
        case RuleAction.direct:
          m['outbound'] = directTag;
        case RuleAction.proxy:
          if (finalTag == null || finalTag.isEmpty || finalTag == directTag) {
            continue; // no-server / desync mode — nothing to proxy through
          }
          m['outbound'] = finalTag;
      }
      built.add(m);
    }
    if (built.isEmpty) return cfg;

    var at = 0;
    for (final x in ruleList) {
      if (x is Map &&
          (x['action'] == 'sniff' ||
              x['action'] == 'hijack-dns' ||
              // Keep custom rules BELOW the watchdog's foreign-probe DIRECT rule, so
              // a user "public-DNS → proxy" rule (8.8.8.8 → proxy) can't pull the raw
              // uplink probe into the tunnel — which would mask a real node block as
              // a whitelist collapse. The probe rule must always win.
              _isForeignProbeRule(x))) {
        at++;
      } else {
        break;
      }
    }
    ruleList.insertAll(at, built);
    route['rules'] = ruleList;
    cfg['route'] = route;
    return cfg;
  }

  // The watchdog's raw foreign-uplink probe rule (scoped to our own process):
  // process_name == [vpn_app.exe] routing the baked control IPs DIRECT. Custom
  // rules must sort BELOW it so a user rule can never re-route the probe.
  static bool _isForeignProbeRule(Map x) {
    final pn = x['process_name'];
    return pn is List &&
        pn.length == 1 &&
        pn.first == 'vpn_app.exe' &&
        x['ip_cidr'] is List;
  }

  /// Stamp Brutal-style fixed bandwidth onto every hysteria2 outbound when the
  /// user has set their line speed. Hysteria2's congestion control holds
  /// throughput under loss/jitter (noisy RF links) when told the real up/down
  /// rate; 0 leaves it to Hysteria2's default auto-tune (field omitted). Safe
  /// no-op for every other protocol and when both are 0.
  /// Inject the user's EDNS Client Subnet into the DNS block — one choke point
  /// (like [tuneHysteria2]) covering every build path. No-op when unset. Lets the
  /// user pin geo-resolution to a chosen subnet for better CDN locality.
  static Map<String, dynamic> applyEcs(Map<String, dynamic> cfg) {
    // Defence-in-depth: emit only a VALID client_subnet. The setter already
    // rejects bad input, but a tool/test could set the static directly — and an
    // invalid subnet (typo / bad prefix) FATALs the core.
    if (ecsSubnet.isEmpty ||
        !RouteRule.isValidValue(RuleField.ipCidr, ecsSubnet)) {
      return cfg;
    }
    final dns = cfg['dns'];
    if (dns is Map) dns['client_subnet'] = ecsSubnet;
    return cfg;
  }

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
