import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Native ECH (Encrypted ClientHello) auto-discovery.
///
/// For a destination that PUBLISHES an ECH config in DNS (every Cloudflare-
/// fronted host does), this fetches that config over DoH and returns the base64
/// ECHConfigList sing-box wants in `tls.ech.config`. Connecting with it puts the
/// REAL SNI inside an encrypted blob and leaves only the cover `public_name` on
/// the wire — the same masquerade Chrome/Firefox do natively, with zero user
/// setup, on our existing core (no bespoke binary).
///
/// HONEST SCOPE: this only helps when the node's `server_name` is a real host
/// that actually serves ECH (behind Cloudflare, or your own ECH endpoint). It
/// does NOT manufacture cover for a bare foreign VPS — there the outer SNI still
/// wouldn't resolve to the server IP (the same mismatch Reality handles its own
/// way), so we never apply discovered ECH to Reality nodes.
///
/// FFI-free + the parser is pure (no I/O) so tools/tests can import it.
class EchDiscovery {
  EchDiscovery._();

  /// IP-literal DoH resolvers (no chicken-and-egg DNS), raced. Only Cloudflare +
  /// Google serve the dns-JSON API used here, and Google's lives at `/resolve`
  /// (NOT `/dns-query`); Quad9 is wireformat-only, so it's omitted (it would just
  /// return null and never win the race). Kept in sync with Diagnostics._dohEndpoints.
  static const resolvers = <String>[
    'https://1.1.1.1/dns-query', // Cloudflare
    'https://8.8.8.8/resolve', // Google
    'https://1.0.0.1/dns-query', // Cloudflare secondary
  ];

  /// Best-effort fetch of [host]'s ECH config (base64 ECHConfigList) via DoH.
  /// Returns null on any failure/timeout/absence — NEVER throws, so a caller on
  /// the connect path can `await` it without risking the connection.
  static Future<String?> fetchEchConfig(String host,
      {Duration timeout = const Duration(seconds: 4)}) async {
    final h = host.trim();
    if (h.isEmpty || _isIpLiteral(h)) return null; // ECH is per-name, not per-IP
    final completer = Completer<String?>();
    var pending = resolvers.length;
    for (final r in resolvers) {
      unawaited(_queryOne(r, h, timeout).then((cfg) {
        if (cfg != null && cfg.isNotEmpty && !completer.isCompleted) {
          completer.complete(cfg);
        } else if (--pending == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }, onError: (_) {
        if (--pending == 0 && !completer.isCompleted) completer.complete(null);
      }));
    }
    // Hard ceiling so we never hang the connect path even if a resolver stalls.
    return completer.future
        .timeout(timeout + const Duration(seconds: 1), onTimeout: () => null);
  }

  static Future<String?> _queryOne(
      String resolver, String host, Duration timeout) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final uri = Uri.parse('$resolver?name=$host&type=HTTPS');
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set('accept', 'application/dns-json');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) return null;
      final body = await resp.transform(utf8.decoder).join().timeout(timeout);
      return echFromDohJson(body);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// Parse a DoH JSON response and return the base64 ECHConfigList, or null.
  /// Pure (no I/O) → unit-testable against captured responses.
  static String? echFromDohJson(String jsonBody) {
    Map<String, dynamic> j;
    try {
      final d = jsonDecode(jsonBody);
      if (d is! Map) return null;
      j = d.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
    final ans = j['Answer'];
    if (ans is! List) return null;
    for (final a in ans) {
      if (a is! Map) continue;
      if ((a['type'] as num?)?.toInt() != 65) continue; // HTTPS/SVCB RR
      final ech = echFromHttpsData(a['data']?.toString() ?? '');
      if (ech != null) return ech;
    }
    return null;
  }

  /// Extract the ECH (SvcParamKey 5) value from an HTTPS-RR `data` string in
  /// either the RFC-3597 generic form (`\# <len> <hex…>`, what Cloudflare DoH
  /// returns) or the presentation form (`… ech="base64" …`, what some resolvers
  /// return). Returns base64 of the ECHConfigList, or null.
  static String? echFromHttpsData(String data) {
    final t = data.trim();
    if (!t.startsWith(r'\#')) {
      // Anchor `ech=` to a SvcParam boundary (start / space / ; / ,) so it can't
      // match the tail of an unrelated key (e.g. `someech=`) or grab a wrong run.
      final pres =
          RegExp(r'(?:^|[\s;,])ech="?([A-Za-z0-9+/=]+)"?').firstMatch(t);
      if (pres != null) return pres.group(1);
      return null;
    }
    final bytes = _genericRdata(t);
    if (bytes == null) return null;
    return _echFromRdata(bytes);
  }

  // Decode the RFC-3597 generic RDATA form "\# <len> <hex bytes>" → byte list.
  static List<int>? _genericRdata(String data) {
    final parts = data.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return null; // need at least "\#" + length
    final declared = int.tryParse(parts[1]);
    final hex = parts.sublist(2).join();
    if (hex.isEmpty || hex.length.isOdd) return null;
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      out.add(b);
    }
    if (declared != null && declared != out.length) return null; // length sanity
    return out;
  }

  // Walk an HTTPS/SVCB RDATA and return base64 of the ECH (key=5) SvcParamValue.
  static String? _echFromRdata(List<int> rd) {
    var i = 0;
    if (rd.length < 3) return null;
    i += 2; // SvcPriority (u16)
    // TargetName: length-prefixed labels, terminated by a zero-length label.
    while (i < rd.length) {
      final l = rd[i];
      i += 1;
      if (l == 0) break;
      i += l;
      if (i > rd.length) return null;
    }
    // SvcParams: {key u16, len u16, value[len]} repeated, ascending key order.
    while (i + 4 <= rd.length) {
      final key = (rd[i] << 8) | rd[i + 1];
      final len = (rd[i + 2] << 8) | rd[i + 3];
      i += 4;
      if (i + len > rd.length) break;
      if (key == 5) return base64.encode(rd.sublist(i, i + len));
      i += len;
    }
    return null;
  }

  /// Wrap a base64 ECHConfigList in the PEM block sing-box accepts in
  /// `tls.ech.config`.
  static List<String> echConfigPem(String b64) =>
      ['-----BEGIN ECH CONFIGS-----', b64, '-----END ECH CONFIGS-----'];

  static bool _isIpLiteral(String h) =>
      RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(h) || h.contains(':');
}
