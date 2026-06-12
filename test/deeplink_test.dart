import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/deeplink.dart';

/// Deeplink payload extraction (#18) — unwrap the wrapper schemes used to share
/// configs in RF Telegram, pass through bare links, ignore runner flags.
void main() {
  const link =
      'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=reality&pbk=K&sid=ab#n';

  test('bare proxy links pass through untouched', () {
    expect(importablePayload(link), link);
    expect(importablePayload('hysteria2://pw@1.2.3.4:443#h'),
        'hysteria2://pw@1.2.3.4:443#h');
    expect(importablePayload('anytls://pw@1.2.3.4:443#a'),
        'anytls://pw@1.2.3.4:443#a');
  });

  test('subscription URLs pass through', () {
    expect(importablePayload('https://example.com/sub'),
        'https://example.com/sub');
  });

  test('vpn:// unwraps to the embedded link', () {
    expect(importablePayload('vpn://${Uri.encodeComponent(link)}'), link);
    expect(importablePayload('vpn://import?url=https%3A%2F%2Fe.com%2Fs'),
        'https://e.com/s');
  });

  test('vpn://share bundle is returned WHOLE (not scheme-stripped)', () {
    // The bundle carries its payload in `?d=`, not `?url=`; the generic unwrap
    // would strip the scheme and break decodeBundle, so it must pass untouched.
    const bundle = 'vpn://share?d=eyJ2IjoxLCJub2RlcyI6W119';
    expect(importablePayload(bundle), bundle);
  });

  test('clash://install-config?url= unwraps to the sub URL', () {
    expect(
      importablePayload('clash://install-config?url=https%3A%2F%2Fe.com%2Fsub'),
      'https://e.com/sub',
    );
  });

  test('hiddify://import/<payload> unwraps', () {
    expect(importablePayload('hiddify://import/${Uri.encodeComponent(link)}'),
        link);
    expect(
      importablePayload('hiddify://install-config?url=https%3A%2F%2Fe.com%2Fs'),
      'https://e.com/s',
    );
  });

  test('sing-box://import-remote-profile?url= unwraps (the real panel scheme)',
      () {
    expect(
      importablePayload(
          'sing-box://import-remote-profile?url=https%3A%2F%2Fe.com%2Fsub'),
      'https://e.com/sub',
    );
  });

  test('a wrapped COMPLETE link is not double-decoded (literal % survives)', () {
    // The embedded payload is already a full link, so its own %-encoding belongs
    // to it — decoding here would corrupt a literal `%xx` in the tag/password.
    const inner =
        'vless://11111111-1111-1111-1111-111111111111@1.2.3.4:443?security=reality#a%20b';
    expect(importablePayload('vpn://$inner'), inner); // %20 preserved, not → space
  });

  test('runner flags and junk are ignored', () {
    expect(importablePayload('--elevated-relaunch'), isNull);
    expect(importablePayload(''), isNull);
    expect(importablePayload('just some text'), isNull);
    expect(importablePayload('C:\\nonexistent\\nope.json'), isNull); // no file
  });

  test('launchImportFromArgs picks the first importable arg', () {
    expect(
      launchImportFromArgs(['--elevated-relaunch', 'noise', link]),
      link,
    );
    expect(launchImportFromArgs(['--flag', 'plain']), isNull);
  });
}
