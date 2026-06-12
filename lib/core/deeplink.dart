import 'dart:io';

/// Set from `main(args)` when the app is COLD-launched with a deeplink / file
/// (e.g. clicking a `vpn://…` link, or "Open with" on a config). RootScaffold
/// consumes it on the first frame, then clears it. Warm-start forwarding (a
/// second launch while already running) IS implemented natively via WM_COPYDATA
/// (main.cpp → flutter_window → the `deeplink` method channel → RootScaffold).
String? pendingLaunchImport;

final _bareLink = RegExp(
  r'^(vless|vmess|trojan|ss|hysteria2|hy2|hysteria|tuic|socks5?|anytls)://',
  caseSensitive: false,
);

/// Given a launch/deeplink argument, return the importable payload — a proxy
/// link, a subscription URL, or a local file path — or null if it isn't an
/// import (a runner flag, or unrelated). Unwraps the common wrapper schemes used
/// to share configs in RF Telegram: `vpn://`, `clash://install-config?url=`,
/// `hiddify://import/…`.
String? importablePayload(String arg) {
  final a = arg.trim();
  if (a.isEmpty || a.startsWith('--')) return null; // a runner flag, not import
  final lower = a.toLowerCase();

  // Our own share bundle: return it WHOLE so the importer's decodeBundle sees the
  // full `vpn://share?d=…`. The generic url-unwrap below would strip the scheme
  // (no `?url=` param) and corrupt it.
  if (lower.startsWith('vpn://share')) return a;

  // Wrapper schemes that EMBED a sub-URL or link. `sing-box://import-remote-
  // profile?url=…` is the real de-facto scheme panels (3x-ui / Marzban) emit, so
  // we register that — not a guess.
  for (final scheme in const [
    'vpn://',
    'clash://',
    'hiddify://',
    'sing-box://',
  ]) {
    if (!lower.startsWith(scheme)) continue;
    final u = Uri.tryParse(a);
    final q = u?.queryParameters['url']; // ?url=<enc> form (clash/hiddify)
    if (q != null && q.trim().isNotEmpty) return q.trim();
    // path/opaque form: scheme://<payload> (a link or a url, possibly encoded).
    var rest = a.substring(scheme.length);
    final slash = rest.indexOf('/'); // hiddify://import/<payload>
    if (lower.startsWith('hiddify://') && slash >= 0) {
      rest = rest.substring(slash + 1);
    }
    if (rest.isEmpty) return null;
    // If the embedded payload is ALREADY a complete link/URL, its own percent-
    // encoding (in the tag/query/password) belongs to it — decoding here would
    // double-decode and corrupt a literal `%`. Only decode an opaque blob.
    final restLow = rest.toLowerCase();
    final looksComplete = _bareLink.hasMatch(restLow) ||
        restLow.startsWith('http://') ||
        restLow.startsWith('https://');
    if (!looksComplete) {
      try {
        rest = Uri.decodeComponent(rest);
      } catch (_) {}
    }
    final v = rest.trim();
    if (v.isEmpty) return null;
    // An unwrapped wrapper payload is NEVER a local file path: a crafted
    // `hiddify://import/C:\Users\me\secret.txt` would otherwise flow into the
    // caller's file branch and read an arbitrary local file. Legit payloads here
    // are links or base64 blobs (which never name an existing path) — reject
    // anything that does.
    if (!v.contains('://') &&
        v.contains(RegExp(r'[\\/]')) &&
        File(v).existsSync()) {
      return null;
    }
    return v;
  }

  // A bare proxy link or a subscription URL → import directly.
  if (_bareLink.hasMatch(lower) ||
      lower.startsWith('http://') ||
      lower.startsWith('https://')) {
    return a;
  }

  // A local file path (drag a .json onto the exe, or "Open with").
  if (a.contains(RegExp(r'[\\/]')) && File(a).existsSync()) return a;
  return null;
}

/// Pick the first importable payload out of the process's launch arguments.
String? launchImportFromArgs(List<String> args) {
  for (final a in args) {
    final p = importablePayload(a);
    if (p != null) return p;
  }
  return null;
}
