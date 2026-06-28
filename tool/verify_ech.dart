// Verifies native ECH auto-discovery end-to-end:
//   1) pure parser against a captured Cloudflare DoH response (deterministic),
//   2) LIVE DoH fetch for known ECH-publishing hosts,
//   3) feeds the discovered ECHConfigList into a real sing-box client config and
//      runs `sing-box check` — proving the format our core accepts.
//
//   dart run tool/verify_ech.dart
import 'dart:convert';
import 'dart:io';

import 'package:vpn_app/core/ech_discovery.dart';

final _sb = '${Directory.current.path}/core/windows/sing-box.exe';

// A captured crypto.cloudflare.com HTTPS-RR DoH JSON (generic \# form).
const _captured =
    '{"Status":0,"Answer":[{"name":"crypto.cloudflare.com","type":65,"TTL":300,'
    '"data":"\\\\# 133 00 01 00 00 01 00 03 02 68 32 00 04 00 08 a2 9f 87 4f a2 '
    '9f 88 4f 00 05 00 47 00 45 fe 0d 00 41 4a 00 20 00 20 e0 a2 02 ca c8 29 14 '
    '7f fd a4 69 20 40 f2 a5 48 60 03 b4 82 8a 21 96 20 2a 4b 0b a5 41 ce 2d 73 '
    '00 04 00 01 00 01 00 12 63 6c 6f 75 64 66 6c 61 72 65 2d 65 63 68 2e 63 6f '
    '6d 00 00 00 06 00 20 26 06 47 00 00 07 00 00 00 00 00 00 a2 9f 87 4f 26 06 '
    '47 00 00 07 00 00 00 00 00 00 a2 9f 88 4f"}]}';

Future<void> main() async {
  var ok = 0, fail = 0;
  void check(String name, bool pass, [String extra = '']) {
    stdout.writeln('${pass ? "  OK  " : " FAIL "} $name${extra.isEmpty ? "" : "  ($extra)"}');
    pass ? ok++ : fail++;
  }

  // 1) Pure parse of the captured response.
  final parsed = EchDiscovery.echFromDohJson(_captured);
  check('parse captured crypto.cloudflare.com', parsed != null && parsed.isNotEmpty,
      parsed == null ? 'null' : '${parsed.length} b64 chars');
  if (parsed != null) {
    // The ECHConfigList must carry the public_name "cloudflare-ech.com".
    final bytes = base64.decode(parsed);
    final txt = String.fromCharCodes(bytes.where((b) => b >= 32 && b < 127));
    check('public_name embedded = cloudflare-ech.com',
        txt.contains('cloudflare-ech.com'), 'cover SNI shown on the wire');
  }

  // 2) Live DoH discovery + 3) sing-box check on each.
  for (final host in ['crypto.cloudflare.com', 'cloudflare-ech.com']) {
    final b64 = await EchDiscovery.fetchEchConfig(host);
    check('live discover $host', b64 != null && b64.isNotEmpty,
        b64 == null ? 'no ECH / unreachable' : 'got config');
    if (b64 == null) continue;
    final cfg = {
      'log': {'level': 'error'},
      'inbounds': [
        {'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 2080}
      ],
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'v',
          'server': '1.2.3.4',
          'server_port': 443,
          'uuid': '00000000-0000-0000-0000-000000000000',
          'tls': {
            'enabled': true,
            'server_name': host,
            'utls': {'enabled': true, 'fingerprint': 'chrome'},
            'ech': {'enabled': true, 'config': EchDiscovery.echConfigPem(b64)},
          },
        }
      ],
    };
    final f = File('${Directory.systemTemp.path}/ech_verify_${host.hashCode}.json');
    f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg));
    final r = await Process.run(_sb, ['check', '-c', f.path]);
    check('sing-box check ($host + discovered ECH)', r.exitCode == 0,
        r.exitCode == 0 ? 'exit 0' : '${r.stderr}'.trim());
    try {
      f.deleteSync();
    } catch (_) {}
  }

  stdout.writeln('\n$ok passed, $fail failed');
  if (fail > 0) exitCode = 1;
}
