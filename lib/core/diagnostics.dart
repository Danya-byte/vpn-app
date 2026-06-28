import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'singbox_config.dart';

/// How a site is blocked on the raw network — pinpoints the censorship layer
/// (modelled on rkn-block-checker's DNS→TCP→TLS→HTTP probe), so the user sees
/// not just "blocked" but *how*, and whether the tunnel fixes it.
enum BlockVerdict {
  ok, // loaded normally
  dnsPoisoned, // system DNS disagrees with DoH (TSPU rewrite)
  tcpReset, // TCP refused/reset
  tlsDpi, // TCP ok but TLS handshake killed after ClientHello (SNI DPI)
  timeout, // no answer in time
  down, // nothing resolved/connected
}

class SiteResult {
  SiteResult({
    required this.name,
    required this.host,
    required this.blacklisted,
    required this.direct,
    this.tcpMs,
    this.tlsMs,
    this.dnsPoisoned = false,
    this.tunnelOk,
  });

  final String name;
  final String host;
  final bool blacklisted; // an RKN-restricted control (should fail direct in RF)
  final BlockVerdict direct; // verdict on the raw (un-tunnelled) network
  final int? tcpMs;
  final int? tlsMs;
  final bool dnsPoisoned;
  final bool? tunnelOk; // reachable THROUGH the tunnel (null = not tested)

  /// The headline: the VPN demonstrably fixes a site the raw network blocks.
  bool get tunnelRescued => direct != BlockVerdict.ok && tunnelOk == true;
}

/// One proxy server endpoint to stage-probe.
class ServerEndpoint {
  const ServerEndpoint(
      {required this.tag,
      required this.host,
      required this.port,
      required this.udp});
  final String tag;
  final String host;
  final int port;
  final bool udp; // QUIC/UDP (hysteria2 / tuic / wireguard) — no passive SYN probe
}

/// Where a connection to YOUR server breaks on the current network — the staged
/// verdict that turns "doesn't work on mobile" into a named layer.
enum ServerVerdict {
  reachableL4, // TCP to server:port OK — IP/port NOT blocked (proxy still needs a handshake)
  serverBlocked, // foreign reachable but this server's SYN was dropped → IP/port block
  whitelistCollapse, // no foreign reachable at all → state allowlist (mobile shutdown)
  udpInconclusive, // QUIC/UDP — can't passively confirm; mobile throttles UDP/443
  dnsInconclusive, // hostname resolved via the (interceptable) system resolver — a connect "success" may be the operator's blockpage, not the server
  offline, // the local network itself is down (Wi-Fi off / airplane) — not censorship
}

class ServerProbeResult {
  const ServerProbeResult({
    required this.endpoint,
    required this.controlReachable,
    required this.serverReachable,
    required this.verdict,
    this.tcpMs,
  });
  final ServerEndpoint endpoint;
  final bool controlReachable;
  final bool? serverReachable; // null = UDP / inconclusive
  final int? tcpMs;
  final ServerVerdict verdict;
}

/// Built-in connectivity / censorship diagnostics. Probes a curated set of
/// Russian control sites + RKN-restricted sites, DIRECT (raw sockets, which
/// ignore the system proxy) and THROUGH the tunnel, and reports per-layer
/// verdicts — an in-app, reproducible "is it actually working, and what's
/// blocked?" that no mainstream client offers.
class Diagnostics {
  // Controls that should work from inside RF even without a VPN.
  static const whitelist = <(String, String)>[
    ('Госуслуги', 'www.gosuslugi.ru'),
    ('Сбербанк', 'www.sberbank.ru'),
    ('Яндекс', 'ya.ru'),
    ('VK', 'vk.com'),
    ('Госуслуги DNS', 'gosuslugi.ru'),
  ];

  // RKN-restricted: should be blocked on the raw RF network, rescued by the VPN.
  static const blacklist = <(String, String)>[
    ('Instagram', 'www.instagram.com'),
    ('X (Twitter)', 'x.com'),
    ('YouTube', 'www.youtube.com'),
    ('Discord', 'discord.com'),
    ('Rutracker', 'rutracker.org'),
    ('LinkedIn', 'www.linkedin.com'),
    ('Proton', 'protonvpn.com'),
  ];

  /// Probe every target, optionally also through the tunnel. [onResult] streams
  /// each result as it lands so the UI fills in progressively.
  ///
  /// Bounded concurrency (not all-at-once): blasting every probe in parallel made
  /// the tail (the foreign blacklist, checked THROUGH the tunnel) contend for the
  /// tunnel and time out → falsely reported `down`. The backstop here (22s) is
  /// deliberately ABOVE checkSite's worst-case internal budget (~19s) so a SLOW-
  /// but-working probe completes instead of being cut to `down`.
  static Future<List<SiteResult>> run({
    required bool throughTunnel,
    void Function(SiteResult)? onResult,
    int concurrency = 6,
  }) async {
    // Fresh blockpage memory PER RUN — the cross-host detector accumulates which
    // hosts share a system-resolved IP, and a CDN legitimately reusing one edge
    // IP across runs would otherwise creep past the ≥3 threshold and false-flag
    // poison on a later run.
    _disjointIpHosts.clear();
    final targets = [
      for (final w in whitelist) (w.$1, w.$2, false),
      for (final b in blacklist) (b.$1, b.$2, true),
    ];
    final results = List<SiteResult?>.filled(targets.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++; // synchronous on the single event loop → no race
        if (i >= targets.length) break;
        final t = targets[i];
        SiteResult r;
        try {
          r = await checkSite(t.$1, t.$2, t.$3, throughTunnel: throughTunnel)
              .timeout(const Duration(seconds: 22));
        } catch (_) {
          // Only a genuinely WEDGED probe (past the 22s backstop) lands here.
          r = SiteResult(
              name: t.$1, host: t.$2, blacklisted: t.$3, direct: BlockVerdict.down);
        }
        results[i] = r;
        onResult?.call(r);
      }
    }

    await Future.wait(
      List.generate(concurrency.clamp(1, targets.length), (_) => worker()),
    );
    return results.whereType<SiteResult>().toList();
  }

  static Future<SiteResult> checkSite(String name, String host, bool black,
      {required bool throughTunnel}) async {
    final dnsPoisoned = await _dnsPoisoned(host);
    final tcp = await _time(() => Socket.connect(host, 443,
        timeout: const Duration(seconds: 4)).then((s) => s.destroy()));
    int? tlsMs;
    BlockVerdict verdict;
    if (!tcp.ok) {
      verdict = tcp.timedOut ? BlockVerdict.timeout : BlockVerdict.tcpReset;
    } else {
      // Do NOT blanket-accept the cert: a TLS-MITM blockpage (the operator
      // terminates TLS with its own cert) is the STRONGEST DPI signal — accepting
      // any cert made it read as a clean handshake. We keep the connection alive
      // through onBadCertificate (so a slow/odd cert doesn't itself read as a
      // reset) but RECORD whether it validated, then treat an invalid/mismatched
      // peer cert as interception → tlsDpi, same as a killed handshake.
      var certTrusted = true;
      final tls = await _time(() => SecureSocket.connect(host, 443,
              timeout: const Duration(seconds: 4),
              onBadCertificate: (_) {
                certTrusted = false; // cert doesn't chain/match host → MITM
                return true;
              })
          .then((s) => s.destroy()));
      tlsMs = tls.ms;
      // TCP ok but TLS handshake killed = classic SNI-based DPI; TLS completed but
      // the peer cert is forged/mismatched = a TLS-MITM blockpage — both are DPI.
      verdict = (tls.ok && certTrusted)
          ? (dnsPoisoned ? BlockVerdict.dnsPoisoned : BlockVerdict.ok)
          : BlockVerdict.tlsDpi;
    }
    if (verdict == BlockVerdict.ok && dnsPoisoned) {
      verdict = BlockVerdict.dnsPoisoned;
    }
    bool? tunnelOk;
    if (throughTunnel) tunnelOk = await _reachableViaTunnel(host);
    return SiteResult(
      name: name,
      host: host,
      blacklisted: black,
      direct: verdict,
      tcpMs: tcp.ms,
      tlsMs: tlsMs,
      dnsPoisoned: dnsPoisoned,
      tunnelOk: tunnelOk,
    );
  }

  // System resolver (ISP, interceptable) vs Cloudflare DoH (bypasses it). If the
  // IPv4 sets are completely disjoint → transparent DNS rewriting by TSPU.
  static Future<bool> _dnsPoisoned(String host) async {
    try {
      // System lookup + DoH run CONCURRENTLY (was sequential ≈7s, which ate into
      // the per-site budget and pushed slow probes over the backstop → false down).
      final sysF = InternetAddress.lookup(host, type: InternetAddressType.IPv4)
          .timeout(const Duration(seconds: 3))
          .then((l) => l.map((a) => a.address).toSet())
          .catchError((_) => <String>{});
      final dohF = _doh(host);
      final sys = await sysF;
      final doh = await dohF;
      if (sys.isEmpty || doh.isEmpty) return false; // can't tell
      // STRONG signal #1: the system resolver hands back a stub / sinkhole
      // (0.0.0.0, loopback, private) that DoH does not — the classic ТСПУ DNS
      // redirect. Plain "disjoint IPv4 sets" is NOT proof: big geo-balanced CDNs
      // (Google/Cloudflare/Akamai/Fastly) legitimately return wholly different
      // edge IPs to the local resolver vs 1.1.1.1's location, so the old
      // intersection().isEmpty check over-reported normal CDN behaviour as poison.
      if (sys.any(_looksLikeStub) && !doh.any(_looksLikeStub)) return true;
      // STRONG signal #2: the PUBLIC-blockpage mode (Rostelecom/MTS) — the ISP
      // resolver rewrites MANY different blocked hosts to ONE routable blockpage
      // IP. One disjoint answer is normal CDN behaviour; the SAME system-returned
      // IP showing up for ≥3 DIFFERENT probed hosts (each disagreeing with DoH)
      // is not — distinct real sites virtually never share one exact IP across a
      // whole diagnostic run. The stub check above can't see this mode (the
      // blockpage IP is public), which left it undetected.
      if (sys.intersection(doh).isEmpty) {
        for (final ip in sys) {
          final hosts = _disjointIpHosts.putIfAbsent(ip, () => <String>{})
            ..add(host);
          if (hosts.length >= 3) return true;
        }
      } else {
        // Resolvers agree → any old disjoint markers for this host are stale.
        for (final hosts in _disjointIpHosts.values) {
          hosts.remove(host);
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // Cross-host blockpage memory: system-resolved IP → the probed hosts it was
  // returned for while DISAGREEING with DoH. Bounded by the diagnostic site list.
  static final Map<String, Set<String>> _disjointIpHosts = {};

  // A DNS answer that looks like a censorship stub/sinkhole rather than a real
  // host: 0.0.0.0, loopback, link-local, or an RFC-1918 private address.
  static bool _looksLikeStub(String ip) {
    final a = InternetAddress.tryParse(ip);
    if (a == null) return false;
    if (a.isLoopback || a.isLinkLocal) return true;
    if (a.type != InternetAddressType.IPv4) return false;
    final b = a.rawAddress;
    return b[0] == 0 ||
        b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  /// Public DoH (DNS-over-HTTPS → 1.1.1.1) resolver, reused by the pre-connect
  /// latency probe so it never trusts the operator's poisonable system resolver.
  static Future<Set<String>> doh(String host) => _doh(host);

  // DoH resolvers tried IN ORDER (the dns-JSON API). All are IP-LITERAL — a
  // hostname resolver (dns.google) would need DNS to bootstrap, the very thing
  // that's blocked — and each provider's cert carries that IP as a SAN, so TLS
  // still verifies. 1.1.1.1 is the most-blocked in RF, so the cascade falls
  // through to Google / the secondaries until one answers.
  // NOTE: only Cloudflare + Google serve the dns-JSON API on IP literals — Quad9
  // (the old :5053 entries) is RFC-8484 wireformat ONLY and returned no JSON, so
  // it was a dead cascade step; dropped. Multiple IPs per provider keep some
  // redundancy. (Adding a non-big-tech step would need wireformat parsing.)
  static const _dohEndpoints = [
    'https://1.1.1.1/dns-query', // Cloudflare
    'https://8.8.8.8/resolve', // Google
    'https://8.8.4.4/resolve', // Google secondary
    'https://1.0.0.1/dns-query', // Cloudflare secondary
  ];

  static Future<Set<String>> _doh(String host) async {
    // RACE all resolvers in PARALLEL — return the FIRST non-empty answer, so a
    // blocked resolver (1.1.1.1 is the most-blocked in RF) never serially delays the
    // rest. Worst case (all 5 blocked) is ONE ~3-4s round, not 5×3s ≈ 15s — which
    // would spin the latency chip + eat the diagnostic's per-site 22s budget.
    final completer = Completer<Set<String>>();
    var pending = _dohEndpoints.length;
    for (final base in _dohEndpoints) {
      _dohOne(base, host).then((ips) {
        pending--;
        if (ips.isNotEmpty) {
          if (!completer.isCompleted) completer.complete(ips);
        } else if (pending == 0 && !completer.isCompleted) {
          completer.complete(<String>{});
        }
      });
    }
    return completer.future;
  }

  static Future<Set<String>> _dohOne(String base, String host) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client
          .getUrl(Uri.parse('$base?name=$host&type=A&ct=application/dns-json'));
      req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
      final resp = await req.close().timeout(const Duration(seconds: 4));
      if (resp.statusCode != 200) return {};
      final j = jsonDecode(await resp.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final ans = (j['Answer'] as List?) ?? const [];
      return ans
          .map((a) => (a as Map)['data']?.toString() ?? '')
          .where((d) => RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(d))
          .toSet();
    } catch (_) {
      return {};
    } finally {
      client.close(force: true);
    }
  }

  // Reachable through the local proxy (HTTP CONNECT tunnels HTTPS). ANY HTTP
  // status — 2xx/3xx/4xx AND 5xx — means the tunnel DELIVERED the request to the
  // real host, which is the "VPN reaches a blocked site" headline. A genuine
  // block is a connect failure / timeout / RST, which throws and is caught below
  // as false. (followRedirects is off so a 3xx is the server's own answer.)
  static Future<bool> _reachableViaTunnel(String host) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);
    client.badCertificateCallback = (_, _, _) => true;
    client.findProxy = (_) =>
        'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
    try {
      final req = await client.getUrl(Uri.parse('https://$host/'));
      req.followRedirects = false;
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final code = resp.statusCode;
      // ANY HTTP response means the tunnel DELIVERED the request to the real host
      // — that's "reachable". The RKN control hosts this probes (x.com / discord
      // / instagram) answer 401/403/404, and an upstream/CDN edge can answer
      // 502/503, through a fully-working tunnel; gating on 2xx/3xx (or excluding
      // 5xx) made the "VPN demonstrably reaches a blocked site" headline vanish
      // for the exact sites it exists to show. A genuine block is a connect
      // failure/timeout/RST → caught below → false.
      return code >= 200 && code < 600;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ── Server-connect diagnostic ("works on Wi-Fi, not on mobile") ──────────
  // The site probes above answer "is a SITE blocked"; this answers the OTHER
  // question — "why won't MY VPN server connect here?" — by staging the layers a
  // mobile operator blocks at, the way you'd read a tcpdump but from the client:
  //   • foreign reachable AT ALL?      no  → state WHITELIST collapse (mobile)
  //   • this server's IP:port reachable (raw L4, bypassing the tunnel)?
  //         no  → its IP or PORT is blocked on this network
  //         yes → L3/L4 is fine; if the VPN still won't connect it's PROTOCOL-
  //               level DPI (the handshake is killed) — exactly the mobile case
  //               for plain VLESS / Reality. Note: a raw TCP connect to a real
  //               host SUCCEEDS even if the proxy is dead, so "reachable" only
  //               rules OUT an IP/port block; it never confirms the proxy itself.
  //   • UDP/QUIC (Hysteria2/TUIC/WireGuard) can't be passively SYN-probed, and
  //     mobile networks throttle UDP/443 hard — reported as inconclusive.

  /// A proxy server endpoint to probe, pulled from a node/config.
  static List<ServerEndpoint> endpointsOf(Map<String, dynamic> cfg) {
    const udpTypes = {'hysteria2', 'hysteria', 'tuic', 'wireguard'};
    final out = <ServerEndpoint>[];
    void addOutbound(dynamic o) {
      if (o is! Map) return;
      final type = o['type']?.toString();
      final host = o['server']?.toString();
      final port = (o['server_port'] as num?)?.toInt();
      if (host == null || host.isEmpty || port == null) return;
      out.add(ServerEndpoint(
        tag: (o['tag']?.toString().isNotEmpty ?? false) ? o['tag'].toString() : host,
        host: host,
        port: port,
        udp: udpTypes.contains(type),
      ));
    }

    // WireGuard endpoints carry the host under peers[].address, not `server`.
    void addEndpoint(dynamic e) {
      if (e is! Map) return;
      final peers = e['peers'] as List?;
      final peer = (peers != null && peers.isNotEmpty) ? peers.first : null;
      if (peer is! Map) return;
      final host = peer['address']?.toString();
      final port = (peer['port'] as num?)?.toInt();
      if (host == null || host.isEmpty || port == null) return;
      out.add(ServerEndpoint(
          tag: e['tag']?.toString() ?? host, host: host, port: port, udp: true));
    }

    for (final o in (cfg['outbounds'] as List?) ?? const []) {
      addOutbound(o);
    }
    for (final e in (cfg['endpoints'] as List?) ?? const []) {
      addEndpoint(e);
    }
    // De-dup by host:port (a pool often repeats one server across transports).
    // TCP entries first: when the same host:port is exposed over a TCP transport
    // (vless) AND a UDP one (hysteria2), keep the TCP probe — it yields a real
    // reachable/blocked verdict where UDP is inconclusive. The old key appended
    // `:udp`, so the same socket produced two divergent rows.
    final ordered = [...out]..sort((a, b) => (a.udp ? 1 : 0) - (b.udp ? 1 : 0));
    final seen = <String>{};
    return ordered.where((e) => seen.add('${e.host}:${e.port}')).toList();
  }

  /// Stage-probe ONE server endpoint, raw (bypassing the tunnel). [controlUp] is
  /// the shared "is any foreign IP reachable" result (computed once per run).
  static Future<ServerProbeResult> probeServer(
      ServerEndpoint ep, bool controlUp,
      {bool localUp = true}) async {
    bool? reachable;
    int? ms;
    var resolverTrusted = true;
    if (!ep.udp) {
      // Resolve a hostname via DoH and dial the LITERAL IP — never the captured
      // system resolver: in TUN a FakeIP 198.18.x answer (or a ТСПУ-poisoned A
      // record even in proxy mode) would make us probe a synthetic / wrong target
      // and report a meaningless verdict. An IP host dials as-is; a DoH miss falls
      // back to the host name (best-effort).
      var dial = ep.host;
      if (InternetAddress.tryParse(ep.host) == null) {
        final ips = await _doh(ep.host);
        if (ips.isNotEmpty) {
          dial = ips.first;
        } else {
          // DoH miss (1.1.1.1 blocked/poisoned — the censored case): dialing the
          // hostname resolves via the SYSTEM resolver, whose answer may be the
          // operator's public blockpage — a connect "success" then proves nothing.
          // Probe anyway (a refusal/timeout is still meaningful) but downgrade a
          // success to dnsInconclusive instead of claiming reachableL4.
          resolverTrusted = false;
        }
      }
      // 8s (under the controller's 9s wrapper): a slow-but-ALIVE server on a
      // congested mobile uplink shouldn't be mislabelled "IP/PORT BLOCKED" just
      // because it didn't answer in 5s — only a genuine SYN-drop still times out.
      final t = await _time(() => Socket.connect(dial, ep.port,
          timeout: const Duration(seconds: 8)).then((s) => s.destroy()));
      reachable = t.ok;
      ms = t.ms;
    }
    return ServerProbeResult(
      endpoint: ep,
      controlReachable: controlUp,
      serverReachable: reachable,
      tcpMs: ms,
      verdict: verdictFor(
          controlUp: controlUp,
          udp: ep.udp,
          reachable: reachable,
          localUp: localUp,
          resolverTrusted: resolverTrusted),
    );
  }

  /// The staged verdict — PURE, so the layer logic is unit-tested without sockets.
  static ServerVerdict verdictFor(
      {required bool controlUp,
      required bool udp,
      bool? reachable,
      bool localUp = true,
      bool resolverTrusted = true}) {
    // No local network at all (Wi-Fi off / airplane) → an OFFLINE state, NOT a
    // censorship verdict. Without this, a downed adapter looked like "the state
    // collapsed the network to a whitelist" — a scary RF-specific false alarm.
    if (!localUp) return ServerVerdict.offline;
    // The SERVER answering a raw dial is the STRONGEST signal — stronger than the
    // baked control IPs being blocked (an operator can null-route 8.8.8.8:443 yet
    // leave the user's own server reachable). So prefer reachableL4 over whitelist.
    // UNLESS the dial resolved via the interceptable system resolver (DoH miss):
    // then "connected" may be the operator's blockpage answering, not the server.
    if (reachable == true) {
      return resolverTrusted
          ? ServerVerdict.reachableL4
          : ServerVerdict.dnsInconclusive;
    }
    if (!controlUp) return ServerVerdict.whitelistCollapse;
    if (udp) return ServerVerdict.udpInconclusive;
    return ServerVerdict.serverBlocked;
  }

  /// Is ANY foreign control IP reachable by a raw dial (whitelist gate), and is
  /// the local network even up? Runs once, shared across the per-server probes.
  static Future<({bool foreign, bool localUp})> probeNetwork() async {
    // Returns (ok, timedOut): a timeout means "no answer in budget" (slow link),
    // which is NOT proof the host/network is down — distinguish it from an active
    // refusal/reset so a slow uplink doesn't fabricate a false OFFLINE verdict.
    Future<({bool ok, bool timedOut})> tcp(String h, int p) async {
      // Socket.connect's OWN timeout throws a SocketException, NOT a
      // TimeoutException — so the redundant outer `.timeout(4s)` only produced a
      // TimeoutException when it won a coin-flip race against the inner timer,
      // and a real connect-timeout usually fell into catch(_) misclassified as a
      // reset (timedOut:false). Classify by elapsed instead, like _time below.
      final sw = Stopwatch()..start();
      try {
        final s =
            await Socket.connect(h, p, timeout: const Duration(seconds: 4));
        s.destroy();
        return (ok: true, timedOut: false);
      } on TimeoutException {
        return (ok: false, timedOut: true);
      } catch (_) {
        return (ok: false, timedOut: sw.elapsedMilliseconds >= 3800);
      }
    }

    // localUp = ANY domestic host reachable, not a single one: tying it to just
    // ya.ru let one flapping/overloaded host read as "network down" and mask a
    // REAL whitelist collapse as a benign offline state. These big RU sites stay
    // reachable even under a state IP-allowlist, so any hit = the link is up.
    const ruHosts = ['ya.ru', 'vk.com', 'mail.ru', 'gosuslugi.ru'];
    final localResults = await Future.wait([for (final h in ruHosts) tcp(h, 443)]);
    // The link is up if any host answered. But if NONE answered yet EVERY failure
    // was a TIMEOUT (no active reset/refusal at all), that's a slow link, not a
    // downed adapter — default localUp=true so a sluggish probe never fabricates a
    // scary OFFLINE / false whitelist-collapse verdict.
    final localUp = localResults.any((r) => r.ok) ||
        localResults.every((r) => r.timedOut);
    // Foreign probes run CONCURRENTLY, not one-after-another: the old sequential
    // loop spent up to len×4s (~12s) waiting on dead IPs in series before giving
    // up. any() resolves as soon as the first IP answers.
    final foreignResults = await Future.wait(
        [for (final ip in SingBoxConfig.foreignProbeIps) tcp(ip, 443)]);
    final foreign = foreignResults.any((r) => r.ok);
    return (foreign: foreign, localUp: localUp);
  }

  static Future<({bool ok, bool timedOut, int? ms})> _time(
      Future<void> Function() op) async {
    final sw = Stopwatch()..start();
    try {
      await op();
      return (ok: true, timedOut: false, ms: sw.elapsedMilliseconds);
    } on TimeoutException {
      return (ok: false, timedOut: true, ms: null);
    } catch (_) {
      // A SocketException right after connect (reset) vs a slow timeout: treat a
      // sub-4s failure as a reset, a near-4s one as a timeout.
      return (ok: false, timedOut: sw.elapsedMilliseconds >= 3800, ms: null);
    }
  }
}
