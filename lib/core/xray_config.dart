import 'dart:convert';

/// Converts a sing-box proxy outbound into a standalone xray-core config that
/// exposes a local SOCKS inbound. sing-box then dials xray-only transports
/// (XHTTP / SplitHTTP) through a `socks` outbound pointed at that inbound.
///
/// Built for VLESS / VMess / Trojan with Reality or TLS and XHTTP/WS/gRPC
/// transports — the cutting-edge stack xray-core leads on. The actual binary
/// is fetched separately; this is pure, unit-testable config generation.
class XrayConfig {
  /// Transports only xray-core can dial (sing-box can't).
  static const xrayTransports = {'xhttp', 'splithttp'};

  /// True if [outbound] uses a transport that needs the xray bridge.
  static bool needsXray(Map outbound) {
    // `is Map` guard, not `as Map?` — a hostile imported config can carry a
    // non-Map `transport` (string/list), and the cast would throw a CastError
    // that aborts the WHOLE connect instead of just skipping one bad node.
    final t = outbound['transport'];
    final tr = t is Map ? t['type']?.toString() : null;
    return tr != null && xrayTransports.contains(tr);
  }

  /// xray config proxying a local SOCKS inbound on [socksPort] through
  /// [outbound]. Returns null for protocols not supported by the bridge.
  static Map<String, dynamic>? fromOutbound(Map outbound, int socksPort) {
    final proxy = switch (outbound['type']?.toString()) {
      'vless' => _vless(outbound),
      'vmess' => _vmess(outbound),
      'trojan' => _trojan(outbound),
      _ => null,
    };
    if (proxy == null) return null;
    proxy['streamSettings'] = _stream(outbound);
    return {
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'listen': '127.0.0.1',
          'port': socksPort,
          'protocol': 'socks',
          'settings': {'udp': true},
        }
      ],
      'outbounds': [proxy],
    };
  }

  static Map<String, dynamic> _vless(Map o) => {
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': o['server'],
              'port': o['server_port'],
              'users': [
                {
                  'id': o['uuid'],
                  'encryption': 'none',
                  if (o['flow'] != null) 'flow': o['flow'],
                }
              ],
            }
          ],
        },
      };

  static Map<String, dynamic> _vmess(Map o) => {
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': o['server'],
              'port': o['server_port'],
              'users': [
                {'id': o['uuid'], 'security': o['security'] ?? 'auto'}
              ],
            }
          ],
        },
      };

  static Map<String, dynamic> _trojan(Map o) => {
        'protocol': 'trojan',
        'settings': {
          'servers': [
            {
              'address': o['server'],
              'port': o['server_port'],
              'password': o['password'],
            }
          ],
        },
      };

  /// Deep-strip control chars (\x00-\x1f) from every key and string value of the
  /// untrusted XHTTP `extra` blob. Numbers/bools pass through; nested maps/lists
  /// are walked. Keeps the server's legitimate sc*/xPadding/xmux tuning intact
  /// (none of it legitimately contains control bytes).
  static dynamic _sanitizeExtra(dynamic v) {
    String clean(String s) => s.replaceAll(RegExp(r'[\x00-\x1f]'), '');
    if (v is String) return clean(v);
    if (v is Map) {
      return {
        for (final e in v.entries) clean('${e.key}'): _sanitizeExtra(e.value),
      };
    }
    if (v is List) return v.map(_sanitizeExtra).toList();
    return v;
  }

  static Map<String, dynamic> _stream(Map o) {
    final stream = <String, dynamic>{'network': 'tcp'};

    final tr = o['transport'] is Map ? o['transport'] as Map : null;
    final trType = tr?['type']?.toString();
    if (trType == 'xhttp' || trType == 'splithttp') {
      stream['network'] = 'xhttp';
      final mode = tr!['mode']?.toString();
      final x = <String, dynamic>{};
      // Merge the server's XHTTP tuning blob FIRST (sc* split sizes / xPadding /
      // xmux — the sub-16KB-freeze levers under ТСПУ), then let the link's explicit
      // mode/path/host take precedence. We relay the server's chosen split rather
      // than forcing our own cap (which would just add overhead / cost throughput).
      final extra = tr['extra'];
      // The blob is UNTRUSTED (jsonDecode'd from a share-link param / imported
      // config): the upstream control-char scrub ran on the RAW string, so JSON
      // escapes (\r\n) materialize into real control bytes only here — sanitize
      // the decoded values too, or they reach xray's XHTTP wire headers.
      if (extra is Map) {
        x.addAll((_sanitizeExtra(extra) as Map).cast<String, dynamic>());
      }
      final mergedMode =
          (mode != null && mode.isNotEmpty) ? mode : '${x['mode'] ?? 'auto'}';
      // xray expects this exact string enum; a type-confused / out-of-enum value
      // from `extra` ({"mode":5}) fails `xray run -test` → the member is silently
      // pruned, turning a valid XHTTP node dead. Clamp to the enum.
      const modes = {'auto', 'packet-up', 'stream-up', 'stream-one'};
      x['mode'] = modes.contains(mergedMode) ? mergedMode : 'auto';
      if (tr['path'] != null) x['path'] = tr['path'];
      if (tr['host'] != null) x['host'] = tr['host'];
      stream['xhttpSettings'] = x;
    } else if (trType == 'ws') {
      stream['network'] = 'ws';
      final ws = <String, dynamic>{};
      if (tr!['path'] != null) ws['path'] = tr['path'];
      final h = tr['headers'] is Map ? tr['headers'] as Map : null;
      if (h != null && h['Host'] != null) ws['host'] = h['Host'];
      stream['wsSettings'] = ws;
    } else if (trType == 'grpc') {
      stream['network'] = 'grpc';
      stream['grpcSettings'] = {'serviceName': tr!['service_name'] ?? ''};
    }

    // Guard EVERY cast: a hostile/truncated import can carry e.g. `"tls":"yes"`,
    // and a raw `as Map?` throws a CastError that aborts the WHOLE connect (the
    // bridge call isn't in a try) — `is Map` degrades to "skip this field".
    final tls = o['tls'] is Map ? o['tls'] as Map : null;
    if (tls != null && tls['enabled'] == true) {
      final reality = tls['reality'] is Map ? tls['reality'] as Map : null;
      final sni = tls['server_name'];
      // 'randomized' is a synthetic ClientHello that can omit the X25519
      // key_share and break Reality (intermittent `tls: handshake failure`).
      // Force a real browser fingerprint — mirrors the sing-box-side normalize.
      final utls = tls['utls'] is Map ? tls['utls'] as Map : null;
      var fp = utls?['fingerprint']?.toString() ?? 'chrome';
      if (fp.isEmpty || fp == 'randomized') fp = 'chrome';
      if (reality != null && reality['enabled'] == true) {
        stream['security'] = 'reality';
        final r = <String, dynamic>{'fingerprint': fp};
        if (sni != null) r['serverName'] = sni;
        if (reality['public_key'] != null) r['publicKey'] = reality['public_key'];
        if (reality['short_id'] != null) r['shortId'] = reality['short_id'];
        stream['realitySettings'] = r;
      } else {
        stream['security'] = 'tls';
        final t = <String, dynamic>{'fingerprint': fp};
        if (sni != null) t['serverName'] = sni;
        if (tls['insecure'] == true) t['allowInsecure'] = true;
        stream['tlsSettings'] = t;
      }
    }
    return stream;
  }

  static String encode(Map<String, dynamic> cfg) =>
      const JsonEncoder.withIndent('  ').convert(cfg);
}
