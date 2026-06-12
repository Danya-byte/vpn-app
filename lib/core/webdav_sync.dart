import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

/// Minimal WebDAV client for backing up / syncing the profile bundle to the
/// user's own cloud (Nextcloud, Koofr, box.com, any WebDAV host) — competitor
/// parity (Karing's iCloud/WebDAV sync) AND a direct guard against the
/// config-loss the user already hit once. A profile bundle is just a JSON string
/// ([ProfilesController.exportJson]); upload = HTTP PUT, restore = HTTP GET, both
/// with Basic auth. No third-party dep — plain dart:io.
class WebDavSync {
  /// RFC-7617 Basic credentials header value. Pure — unit-tested.
  static String basicAuth(String user, String pass) =>
      'Basic ${base64.encode(utf8.encode('$user:$pass'))}';

  /// A usable WebDAV file URL must be **https** with a path (so we PUT to a file,
  /// not a bare host) and carry NO embedded userinfo. https is mandatory because
  /// the uploaded bundle contains the user's proxy credentials (server IPs, UUIDs,
  /// Reality keys, passwords) plus the Basic-auth password — sending those over
  /// cleartext http on a hostile RF network would hand the censor everything this
  /// app protects. Embedded `user:pass@host` is rejected: creds belong in the
  /// Basic-auth header, and userinfo silently ships them to whatever host follows
  /// a typo. Pure — unit-tested so an insecure/typo'd URL is caught before any
  /// request leaves.
  static bool validUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null ||
        u.scheme != 'https' ||
        u.userInfo.isNotEmpty ||
        u.host.isEmpty ||
        u.path.isEmpty ||
        u.path == '/') {
      return false;
    }
    return !_isLocalOrPrivateHost(u.host); // no SSRF to a loopback/internal host
  }

  // Reject obvious loopback / private / link-local LITERAL hosts so a hostile or
  // typo'd (or restored) URL can't POST the credential bundle to an internal
  // service. A domain name isn't resolved here (too costly + DNS-dependent) — it's
  // trusted as user-entered, but a raw internal IP is screened.
  static bool _isLocalOrPrivateHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    final lit = h.startsWith('[') && h.endsWith(']')
        ? h.substring(1, h.length - 1)
        : h;
    final ip = InternetAddress.tryParse(lit);
    if (ip == null) return false; // a hostname — allowed
    if (ip.isLoopback || ip.isLinkLocal || ip.isMulticast) return true;
    var b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv6 && b.length == 16) {
      // Screen the embedded v4 of BOTH ::ffff:a.b.c.d (IPv4-mapped) AND
      // ::a.b.c.d (IPv4-compatible, e.g. ::127.0.0.1) — the latter otherwise
      // slipped through the ULA check (its b[0] is 0) and leaked the whole
      // credential bundle to a loopback/internal service.
      final first10Zero = b.sublist(0, 10).every((x) => x == 0);
      final mapped = first10Zero && b[10] == 0xff && b[11] == 0xff;
      final compat = first10Zero &&
          b[10] == 0 &&
          b[11] == 0 &&
          b.sublist(12).any((x) => x != 0);
      if (mapped || compat) {
        b = b.sublist(12);
      } else {
        if (b.every((x) => x == 0)) return true; // :: unspecified
        return (b[0] & 0xfe) == 0xfc; // ULA fc00::/7 (private IPv6)
      }
    }
    if (b.length == 4) {
      return b[0] == 0 || // 0.0.0.0/8 (can resolve to loopback)
          b[0] == 10 ||
          b[0] == 127 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168) ||
          (b[0] == 169 && b[1] == 254) ||
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127); // CGNAT 100.64/10
    }
    return false;
  }

  static HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 5);

  /// PUT [body] to [url]. Returns null on success, else a short error string.
  static Future<String?> upload(
      String url, String user, String pass, String body) async {
    if (!validUrl(url)) return 'bad URL';
    final client = _client();
    try {
      final req = await client.putUrl(Uri.parse(url.trim()));
      req.maxRedirects = 0; // defense-in-depth if followRedirects is ever flipped
      // NEVER follow a redirect: HttpClient would re-send the Authorization
      // (Basic-auth) header to the new target — incl. an http:// downgrade — which
      // would leak the password + the whole credential bundle. A 3xx becomes a
      // plain error instead.
      req.followRedirects = false;
      req.headers.set(HttpHeaders.authorizationHeader, basicAuth(user, pass));
      req.headers.contentType = ContentType.json;
      final bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      await resp.drain<void>();
      if (resp.statusCode >= 200 && resp.statusCode < 300) return null;
      if (resp.statusCode == 401 || resp.statusCode == 403) return 'auth failed';
      return 'HTTP ${resp.statusCode}';
    } on SocketException {
      return 'no connection';
    } catch (_) {
      // Generic — never interpolate the raw exception, whose message can embed the
      // WebDAV URL (and, on some redirect/handshake errors, credentials).
      return 'request failed';
    } finally {
      client.close(force: true);
    }
  }

  /// GET the bundle from [url]. Returns (body, null) on success, else (null, err).
  static Future<({String? body, String? error})> download(
      String url, String user, String pass) async {
    if (!validUrl(url)) return (body: null, error: 'bad URL');
    final client = _client();
    try {
      final req = await client.getUrl(Uri.parse(url.trim()));
      req.followRedirects = false; // don't resend Basic-auth to a redirect target
      req.maxRedirects = 0; // defense-in-depth if followRedirects is ever flipped
      req.headers.set(HttpHeaders.authorizationHeader, basicAuth(user, pass));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode == 404) {
        await resp.drain<void>();
        return (body: null, error: 'not found (upload first)');
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        await resp.drain<void>();
        return (body: null, error: 'auth failed');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.drain<void>();
        return (body: null, error: 'HTTP ${resp.statusCode}');
      }
      // Cap the body by SIZE, not chunk count: .take(2048) bounded the NUMBER of
      // chunks, but each decoded chunk is unbounded and .join() buffered everything
      // BEFORE the length check — a hostile server streaming multi-MB chunks could
      // spike memory first. Accumulate and abort the instant we cross the cap
      // (a profile bundle is KBs); returning from the await-for cancels the stream.
      const cap = 4 * 1024 * 1024;
      // Count RAW bytes before utf8 decoding — counting decoded code units let a
      // multi-byte body slip past the documented byte budget (a code unit can be
      // up to 3 raw bytes around the cap edge).
      final raw = BytesBuilder();
      await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
        if (raw.length + chunk.length > cap) {
          return (body: null, error: 'file too large');
        }
        raw.add(chunk);
      }
      return (body: utf8.decode(raw.takeBytes(), allowMalformed: true), error: null);
    } on SocketException {
      return (body: null, error: 'no connection');
    } catch (_) {
      return (body: null, error: 'request failed'); // never leak the raw exception/URL
    } finally {
      client.close(force: true);
    }
  }
}
