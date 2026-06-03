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
      final tls = await _time(() => SecureSocket.connect(host, 443,
              timeout: const Duration(seconds: 4),
              onBadCertificate: (_) => true)
          .then((s) => s.destroy()));
      tlsMs = tls.ms;
      // TCP ok but TLS handshake killed = classic SNI-based DPI.
      verdict = tls.ok
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
      return sys.intersection(doh).isEmpty; // disjoint = rewritten
    } catch (_) {
      return false;
    }
  }

  static Future<Set<String>> _doh(String host) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(
          Uri.parse('https://1.1.1.1/dns-query?name=$host&type=A'));
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

  // Reachable through the local proxy (HTTP CONNECT tunnels HTTPS). Any HTTP
  // status back = the VPN carried the request.
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
      return resp.statusCode > 0;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
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
