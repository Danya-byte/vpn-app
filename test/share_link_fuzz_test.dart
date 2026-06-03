import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/share_link.dart';

/// Robustness: a hostile / malformed share link must NEVER throw out of the
/// parser. Import feeds it pasted / QR / deeplinked strings from UNTRUSTED
/// sources, so a thrown exception there is a crash on attacker input. The parser
/// must return null (unrecognized) or a best-effort node — never throw.
void main() {
  const hostile = [
    'ss://@host:443',
    'ss://bm9jb2xvbg@1.2.3.4:8388', // base64 "nocolon"
    'ss://justtext',
    'tuic://@1.2.3.4:443',
    'vless://@1.2.3.4:443',
    'hysteria2://@1.2.3.4:443',
    'ss://',
    'vmess://',
    'vmess://not-base64!!!',
    'vmess://eyJ2IjoiMiJ9', // truncated vmess json
    'socks://',
    'vless://',
    'http://not-a-proxy-link',
    '',
    '   ',
    '://///',
    'vless://@:',
  ];

  test('hostile / malformed links never throw (return null or a node)', () {
    for (final i in hostile) {
      expect(() => ShareLink.parse(i), returnsNormally,
          reason: 'parser threw on: "$i"');
    }
  });

  test('parseSubscription tolerates a blob of mixed garbage', () {
    expect(() => ShareLink.parseSubscription(hostile.join('\n')),
        returnsNormally);
    // A blob of pure garbage yields no usable nodes, but must not throw.
    expect(ShareLink.parseSubscription('garbage\nmore garbage\n!!!'), isEmpty);
  });
}
