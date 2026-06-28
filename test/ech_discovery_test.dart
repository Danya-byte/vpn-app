import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/ech_discovery.dart';

void main() {
  // A real crypto.cloudflare.com HTTPS-RR DoH JSON (Cloudflare generic \# form).
  const cryptoCf =
      '{"Status":0,"Answer":[{"name":"crypto.cloudflare.com","type":65,"TTL":300,'
      '"data":"\\\\# 133 00 01 00 00 01 00 03 02 68 32 00 04 00 08 a2 9f 87 4f a2 '
      '9f 88 4f 00 05 00 47 00 45 fe 0d 00 41 4a 00 20 00 20 e0 a2 02 ca c8 29 14 '
      '7f fd a4 69 20 40 f2 a5 48 60 03 b4 82 8a 21 96 20 2a 4b 0b a5 41 ce 2d 73 '
      '00 04 00 01 00 01 00 12 63 6c 6f 75 64 66 6c 61 72 65 2d 65 63 68 2e 63 6f '
      '6d 00 00 00 06 00 20 26 06 47 00 00 07 00 00 00 00 00 00 a2 9f 87 4f 26 06 '
      '47 00 00 07 00 00 00 00 00 00 a2 9f 88 4f"}]}';

  group('EchDiscovery.echFromDohJson', () {
    test('parses a real Cloudflare HTTPS-RR and embeds the public_name', () {
      final ech = EchDiscovery.echFromDohJson(cryptoCf);
      expect(ech, isNotNull);
      final bytes = base64.decode(ech!);
      final printable =
          String.fromCharCodes(bytes.where((b) => b >= 32 && b < 127));
      // The cover (public) name is carried inside the ECHConfigList.
      expect(printable, contains('cloudflare-ech.com'));
      // ECHConfigList framing: first u16 = length of the rest.
      final declared = (bytes[0] << 8) | bytes[1];
      expect(declared, bytes.length - 2);
    });

    test('null when there is no HTTPS answer', () {
      expect(EchDiscovery.echFromDohJson('{"Status":0,"Answer":[]}'), isNull);
      expect(EchDiscovery.echFromDohJson('{"Status":3}'), isNull);
    });

    test('null for an A-record answer (type != 65)', () {
      const a =
          '{"Answer":[{"name":"x","type":1,"data":"1.2.3.4"}]}';
      expect(EchDiscovery.echFromDohJson(a), isNull);
    });

    test('null when the HTTPS RR carries no ECH param', () {
      // SvcPriority=1, root target, only alpn(key1) — no key 5.
      const noEch =
          '{"Answer":[{"type":65,"data":"\\\\# 7 00 01 00 00 01 00 03"}]}';
      expect(EchDiscovery.echFromDohJson(noEch), isNull);
    });

    test('handles the presentation form ech="..."', () {
      const pres =
          '{"Answer":[{"type":65,"data":"1 . alpn=h2 ech=\\"AEX+DQAB\\" ipv4hint=1.2.3.4"}]}';
      expect(EchDiscovery.echFromDohJson(pres), 'AEX+DQAB');
    });

    test('null on malformed / non-JSON', () {
      expect(EchDiscovery.echFromDohJson('not json'), isNull);
      expect(EchDiscovery.echFromDohJson('{"Answer":[{"type":65,"data":"\\\\# 4 zz zz"}]}'),
          isNull);
    });
  });

  group('EchDiscovery.echConfigPem', () {
    test('wraps base64 in the sing-box PEM block', () {
      final pem = EchDiscovery.echConfigPem('AAAA');
      expect(pem.first, '-----BEGIN ECH CONFIGS-----');
      expect(pem[1], 'AAAA');
      expect(pem.last, '-----END ECH CONFIGS-----');
    });
  });

  group('EchDiscovery.fetchEchConfig guards (no network)', () {
    test('empty host returns null without a query', () async {
      expect(await EchDiscovery.fetchEchConfig(''), isNull);
    });
    test('IP literal returns null without a query (ECH is per-name)', () async {
      expect(await EchDiscovery.fetchEchConfig('45.13.239.12'), isNull);
      expect(await EchDiscovery.fetchEchConfig('2001:db8::1'), isNull);
    });
  });
}
