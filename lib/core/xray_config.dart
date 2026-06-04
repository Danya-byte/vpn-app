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
    final tr = (outbound['transport'] as Map?)?['type']?.toString();
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

  static Map<String, dynamic> _stream(Map o) {
    final stream = <String, dynamic>{'network': 'tcp'};

    final tr = o['transport'] as Map?;
    final trType = tr?['type']?.toString();
    if (trType == 'xhttp' || trType == 'splithttp') {
      stream['network'] = 'xhttp';
      // Honor the link's xhttp `mode` (packet-up / stream-up / stream-one) — the
      // sub-16KB-freeze lever under ТСПУ — instead of always 'auto'.
      final mode = tr!['mode']?.toString();
      final x = <String, dynamic>{
        'mode': (mode != null && mode.isNotEmpty) ? mode : 'auto'
      };
      if (tr['path'] != null) x['path'] = tr['path'];
      if (tr['host'] != null) x['host'] = tr['host'];
      stream['xhttpSettings'] = x;
    } else if (trType == 'ws') {
      stream['network'] = 'ws';
      final ws = <String, dynamic>{};
      if (tr!['path'] != null) ws['path'] = tr['path'];
      final h = tr['headers'] as Map?;
      if (h != null && h['Host'] != null) ws['host'] = h['Host'];
      stream['wsSettings'] = ws;
    } else if (trType == 'grpc') {
      stream['network'] = 'grpc';
      stream['grpcSettings'] = {'serviceName': tr!['service_name'] ?? ''};
    }

    final tls = o['tls'] as Map?;
    if (tls != null && tls['enabled'] == true) {
      final reality = tls['reality'] as Map?;
      final sni = tls['server_name'];
      // 'randomized' is a synthetic ClientHello that can omit the X25519
      // key_share and break Reality (intermittent `tls: handshake failure`).
      // Force a real browser fingerprint — mirrors the sing-box-side normalize.
      var fp = (tls['utls'] as Map?)?['fingerprint']?.toString() ?? 'chrome';
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
