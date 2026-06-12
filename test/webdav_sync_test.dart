import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/webdav_sync.dart';

/// The WebDAV sync helpers are pure + unit-testable; the live PUT/GET needs the
/// user's own server (verified there), but the auth header + URL guard — the
/// parts a bug would silently break — are locked here.
void main() {
  test('basicAuth builds an RFC-7617 header', () {
    // base64("user:pass") == dXNlcjpwYXNz
    expect(WebDavSync.basicAuth('user', 'pass'), 'Basic dXNlcjpwYXNz');
  });

  test('validUrl requires HTTPS + a real file path + no embedded creds', () {
    expect(
        WebDavSync.validUrl('https://dav.example.com/vpn/profiles.json'), isTrue);
    // http is REJECTED — the bundle carries proxy creds; never upload them in
    // cleartext over a hostile network.
    expect(WebDavSync.validUrl('http://host/x'), isFalse);
    // userinfo in the URL silently ships creds to whatever host follows a typo.
    expect(WebDavSync.validUrl('https://user:pass@evil.com/x'), isFalse);
    expect(WebDavSync.validUrl('https://dav.example.com'), isFalse); // no path
    expect(WebDavSync.validUrl('https://dav.example.com/'), isFalse); // root only
    expect(WebDavSync.validUrl('ftp://host/x'), isFalse); // wrong scheme
    expect(WebDavSync.validUrl(''), isFalse);
    expect(WebDavSync.validUrl('not a url'), isFalse);
    // loopback / private / link-local literal hosts are rejected (no SSRF of the
    // credential bundle to an internal service from a hostile/restored URL).
    expect(WebDavSync.validUrl('https://127.0.0.1/x'), isFalse);
    expect(WebDavSync.validUrl('https://localhost/x'), isFalse);
    expect(WebDavSync.validUrl('https://[::1]/x'), isFalse);
    expect(WebDavSync.validUrl('https://192.168.1.10/x'), isFalse);
    expect(WebDavSync.validUrl('https://10.0.0.5/dav/p.json'), isFalse);
    expect(WebDavSync.validUrl('https://169.254.1.1/x'), isFalse);
    // SSRF-bypass vectors: IPv4-mapped IPv6, ULA, CGNAT, unspecified
    expect(WebDavSync.validUrl('https://[::ffff:127.0.0.1]/x'), isFalse);
    expect(WebDavSync.validUrl('https://[::ffff:10.0.0.1]/x'), isFalse);
    // IPv4-COMPATIBLE IPv6 (::a.b.c.d, no ::ffff:) — the audit-found bypass.
    expect(WebDavSync.validUrl('https://[::127.0.0.1]/x'), isFalse);
    expect(WebDavSync.validUrl('https://[::10.0.0.1]/x'), isFalse);
    expect(WebDavSync.validUrl('https://[::192.168.0.1]/x'), isFalse);
    expect(WebDavSync.validUrl('https://[fc00::1]/x'), isFalse); // ULA
    expect(WebDavSync.validUrl('https://[fd12::1]/x'), isFalse); // ULA
    expect(WebDavSync.validUrl('https://[::1]/x'), isFalse);
    expect(WebDavSync.validUrl('https://100.64.0.1/x'), isFalse); // CGNAT
    expect(WebDavSync.validUrl('https://0.0.0.0/x'), isFalse);
    // a normal public host (incl. global IPv6) with a path is still fine
    expect(WebDavSync.validUrl('https://1.2.3.4/dav/p.json'), isTrue);
    expect(WebDavSync.validUrl('https://[2606:4700::1111]/dav/p.json'), isTrue);
  });

  test('upload/download reject a bad URL before making a request', () async {
    expect(await WebDavSync.upload('nope', 'u', 'p', '{}'), 'bad URL');
    expect((await WebDavSync.download('nope', 'u', 'p')).error, 'bad URL');
  });
}
