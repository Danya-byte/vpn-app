import 'dart:convert';
import 'dart:io';

import 'core_paths.dart';

/// A generated "your own node" bundle: the server config, the matching client
/// share-link, and a one-paste VPS setup script.
class ServerBundle {
  ServerBundle({
    required this.serverConfig,
    required this.clientLinks,
    required this.setupScript,
    required this.publicKey,
  });

  final Map<String, dynamic> serverConfig;
  final List<String> clientLinks; // [Reality (TCP), Hysteria2 (QUIC)]
  final String setupScript;
  final String publicKey;

  String get clientLink => clientLinks.first;
  String get allLinks => clientLinks.join('\n');

  String get serverConfigJson =>
      const JsonEncoder.withIndent('  ').convert(serverConfig);
}

/// A generated two-hop "domestic-relay fronting" bundle: a RU-cloud relay
/// (Reality fronting a big-RU SNI) the client connects to, which forwards to a
/// foreign exit. The observed connection is RU-IP↔RU-SNI; the relay→exit hop is
/// ordinary cloud traffic — operator-proof against ТСПУ. The client runs ONE
/// chained config (exit dialed THROUGH the relay via sing-box `detour`).
class RelayChainBundle {
  RelayChainBundle({
    required this.clientConfig,
    required this.relayServerConfig,
    required this.exitServerConfig,
    required this.relaySetupScript,
    required this.exitSetupScript,
  });

  final Map<String, dynamic> clientConfig; // import as ONE config profile
  final Map<String, dynamic> relayServerConfig;
  final Map<String, dynamic> exitServerConfig;
  final String relaySetupScript; // run on the RU relay VPS
  final String exitSetupScript; // run on the foreign exit VPS

  String get clientConfigJson =>
      const JsonEncoder.withIndent('  ').convert(clientConfig);
}

/// Generates a matched VLESS + Reality server out of the box — what no
/// mainstream GUI does (they only consume configs). The user only needs a bare
/// VPS: a clean IP that isn't on RKN lists, fronted by a real allowlisted SNI
/// (Reality), so it's operator-proof. This is the "x1000 from the box" idea.
class ServerGen {
  /// Real, big, TLS-1.3 + HTTP/2 sites that stay reachable in RF and are NOT
  /// Cloudflare/Apple-fronted (which get blocked / subnet-blocked) — the Reality
  /// handshake masquerades as one of these. dl.google.com is the strongest (it
  /// encrypts handshake messages after ServerHello). Ideal future: pick the SNI
  /// by the server's own ASN/region so SNI↔ASN can't be flagged (audit C2).
  static const stealSnis = <String>[
    'dl.google.com',
    'www.microsoft.com',
    'www.bing.com',
    'www.nvidia.com',
    'cdn.jsdelivr.net',
  ];

  /// Big Russian sites for the DOMESTIC-RELAY front: when the relay sits on a
  /// RU-cloud IP, fronting a RU SNI makes the client↔relay leg look like plain
  /// domestic traffic (RU-IP ↔ RU-SNI), which ТСПУ has no SNI/ASN-mismatch
  /// reason to flag. They serve TLS 1.3 and stay up inside RF.
  static const ruFrontSnis = <String>[
    'dzen.ru',
    'vk.com',
    'gosuslugi.ru',
    'mail.ru',
  ];

  /// Build the bundle from explicit material (pure → unit-testable).
  static ServerBundle buildReality({
    required String serverIp,
    required String uuid,
    required String privateKey,
    required String publicKey,
    required String shortId,
    String hy2Password = '',
    String obfsPassword = '',
    String sni = 'dl.google.com',
    int port = 443,
    int hy2Port = 8443,
    String name = 'My Node',
  }) {
    final hy2 = hy2Password.isNotEmpty;
    final serverConfig = <String, dynamic>{
      'log': {'level': 'info', 'timestamp': true},
      'inbounds': [
        {
          'type': 'vless',
          'tag': 'vless-in',
          'listen': '::',
          'listen_port': port,
          'users': [
            {'uuid': uuid, 'flow': 'xtls-rprx-vision'}
          ],
          'tls': {
            'enabled': true,
            'server_name': sni,
            'reality': {
              'enabled': true,
              'handshake': {'server': sni, 'server_port': 443},
              'private_key': privateKey,
              'short_id': [shortId],
            },
          },
        },
        // A second, QUIC-based transport on the SAME box: if ТСПУ blocks the
        // TCP-Reality path, Hysteria2 (UDP/QUIC + Salamander obfs) survives, and
        // the client auto-fails-over between them.
        if (hy2)
          {
            'type': 'hysteria2',
            'tag': 'hy2-in',
            'listen': '::',
            'listen_port': hy2Port,
            'users': [
              {'password': hy2Password}
            ],
            'obfs': {'type': 'salamander', 'password': obfsPassword},
            'tls': {
              'enabled': true,
              'alpn': ['h3'],
              'certificate_path': '/etc/sing-box/cert.pem',
              'key_path': '/etc/sing-box/key.pem',
            },
          },
      ],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'}
      ],
    };

    final links = <String>[
      'vless://$uuid@$serverIp:$port'
          '?security=reality&sni=$sni&pbk=$publicKey&sid=$shortId'
          '&fp=chrome&flow=xtls-rprx-vision&type=tcp'
          '#${Uri.encodeComponent('$name · Reality')}',
      if (hy2)
        'hysteria2://$hy2Password@$serverIp:$hy2Port'
            '?obfs=salamander&obfs-password=$obfsPassword&insecure=1&sni=$sni'
            '#${Uri.encodeComponent('$name · Hysteria2')}',
    ];

    final cfgJson = const JsonEncoder.withIndent('  ').convert(serverConfig);
    return ServerBundle(
      serverConfig: serverConfig,
      clientLinks: links,
      setupScript: _setupScript(cfgJson, port, hy2Port, hy2),
      publicKey: publicKey,
    );
  }

  /// Generate fresh Reality material via the sing-box binary and build a bundle.
  static Future<ServerBundle?> reality({
    required String serverIp,
    String sni = 'dl.google.com',
    int port = 443,
    String name = 'My Node',
  }) async {
    final sb = CorePaths.singBox();
    if (!File(sb).existsSync()) return null;
    try {
      final kp = await _run(sb, ['generate', 'reality-keypair']);
      final priv = _grab(kp, 'PrivateKey:');
      final pub = _grab(kp, 'PublicKey:');
      final uuid = (await _run(sb, ['generate', 'uuid'])).trim();
      final sid = (await _run(sb, ['generate', 'rand', '8', '--hex'])).trim();
      final hy2 = (await _run(sb, ['generate', 'rand', '16', '--hex'])).trim();
      final obfs = (await _run(sb, ['generate', 'rand', '12', '--hex'])).trim();
      if (priv == null || pub == null || uuid.isEmpty || sid.isEmpty) {
        return null;
      }
      return buildReality(
        serverIp: serverIp,
        uuid: uuid,
        privateKey: priv,
        publicKey: pub,
        shortId: sid,
        hy2Password: hy2,
        obfsPassword: obfs,
        sni: sni,
        port: port,
        name: name,
      );
    } catch (_) {
      return null;
    }
  }

  /// Pure builder for a domestic-relay chain (testable). The client connects
  /// only to [relayIp] (Reality, RU-front SNI); the relay forwards to [exitIp].
  static RelayChainBundle buildRelayChain({
    required String relayIp,
    required String relayUuid,
    required String relayPriv,
    required String relayPub,
    required String relayShortId,
    required String exitIp,
    required String exitUuid,
    required String exitPriv,
    required String exitPub,
    required String exitShortId,
    String relaySni = 'dzen.ru',
    String exitSni = 'www.microsoft.com',
    int relayPort = 443,
    int exitPort = 443,
  }) {
    // Both ends are ordinary VLESS+Reality servers (decrypt + forward via
    // direct). The two-hop topology lives entirely in the CLIENT config's
    // `detour` — neither server needs to know about the other.
    final relayServer = _realityServer(
        uuid: relayUuid, priv: relayPriv, sid: relayShortId, sni: relaySni, port: relayPort);
    final exitServer = _realityServer(
        uuid: exitUuid, priv: exitPriv, sid: exitShortId, sni: exitSni, port: exitPort);

    final clientConfig = <String, dynamic>{
      'log': {'level': 'info', 'timestamp': true},
      'outbounds': [
        // The exit hop, dialed THROUGH the relay (detour). No Vision flow here —
        // it runs inside the relay tunnel where XTLS splicing doesn't apply.
        {
          'type': 'vless',
          'tag': 'exit',
          'server': exitIp,
          'server_port': exitPort,
          'uuid': exitUuid,
          'detour': 'relay',
          'tls': _clientReality(exitSni, exitPub, exitShortId),
        },
        // The relay front — the ONLY endpoint the client connects to directly.
        {
          'type': 'vless',
          'tag': 'relay',
          'server': relayIp,
          'server_port': relayPort,
          'uuid': relayUuid,
          'flow': 'xtls-rprx-vision',
          'tls': _clientReality(relaySni, relayPub, relayShortId),
        },
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'exit'},
    };

    String json(Map<String, dynamic> m) =>
        const JsonEncoder.withIndent('  ').convert(m);
    return RelayChainBundle(
      clientConfig: clientConfig,
      relayServerConfig: relayServer,
      exitServerConfig: exitServer,
      relaySetupScript: _setupScript(json(relayServer), relayPort, 0, false),
      exitSetupScript: _setupScript(json(exitServer), exitPort, 0, false),
    );
  }

  // A standalone VLESS+Reality server (inbound + direct outbound).
  static Map<String, dynamic> _realityServer({
    required String uuid,
    required String priv,
    required String sid,
    required String sni,
    required int port,
  }) =>
      {
        'log': {'level': 'info', 'timestamp': true},
        'inbounds': [
          {
            'type': 'vless',
            'tag': 'vless-in',
            'listen': '::',
            'listen_port': port,
            'users': [
              {'uuid': uuid, 'flow': 'xtls-rprx-vision'}
            ],
            'tls': {
              'enabled': true,
              'server_name': sni,
              'reality': {
                'enabled': true,
                'handshake': {'server': sni, 'server_port': 443},
                'private_key': priv,
                'short_id': [sid],
              },
            },
          },
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'}
        ],
      };

  static Map<String, dynamic> _clientReality(
          String sni, String pub, String sid) =>
      {
        'enabled': true,
        'server_name': sni,
        'utls': {'enabled': true, 'fingerprint': 'chrome'},
        'reality': {'enabled': true, 'public_key': pub, 'short_id': sid},
      };

  /// Generate fresh material for BOTH hops via the bundled core and build a
  /// domestic-relay chain. Returns null if core/keypair gen is unavailable.
  static Future<RelayChainBundle?> relayChain({
    required String relayIp,
    required String exitIp,
    String relaySni = 'dzen.ru',
    String exitSni = 'www.microsoft.com',
    int relayPort = 443,
    int exitPort = 443,
  }) async {
    final sb = CorePaths.singBox();
    if (!File(sb).existsSync()) return null;
    try {
      final m = await Future.wait([_material(sb), _material(sb)]);
      final relay = m[0], exit = m[1];
      if (relay == null || exit == null) return null;
      return buildRelayChain(
        relayIp: relayIp,
        relayUuid: relay.uuid,
        relayPriv: relay.priv,
        relayPub: relay.pub,
        relayShortId: relay.sid,
        exitIp: exitIp,
        exitUuid: exit.uuid,
        exitPriv: exit.priv,
        exitPub: exit.pub,
        exitShortId: exit.sid,
        relaySni: relaySni,
        exitSni: exitSni,
        relayPort: relayPort,
        exitPort: exitPort,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<_Material?> _material(String sb) async {
    final kp = await _run(sb, ['generate', 'reality-keypair']);
    final priv = _grab(kp, 'PrivateKey:');
    final pub = _grab(kp, 'PublicKey:');
    final uuid = (await _run(sb, ['generate', 'uuid'])).trim();
    final sid = (await _run(sb, ['generate', 'rand', '8', '--hex'])).trim();
    if (priv == null || pub == null || uuid.isEmpty || sid.isEmpty) return null;
    return _Material(uuid: uuid, priv: priv, pub: pub, sid: sid);
  }

  static Future<String> _run(String exe, List<String> args) async {
    final r = await Process.run(exe, args);
    return '${r.stdout}';
  }

  static String? _grab(String out, String prefix) {
    for (final line in const LineSplitter().convert(out)) {
      final t = line.trim();
      if (t.startsWith(prefix)) return t.substring(prefix.length).trim();
    }
    return null;
  }

  static String _setupScript(String cfgJson, int port, int hy2Port, bool hy2) {
    final cert = hy2
        ? 'openssl req -x509 -newkey rsa:2048 -nodes '
            '-keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem '
            '-days 3650 -subj "/CN=bing.com"\n'
        : '';
    final udp =
        hy2 ? 'command -v ufw >/dev/null && ufw allow $hy2Port/udp || true\n' : '';
    return '''
#!/usr/bin/env bash
# One-paste setup for a fresh Ubuntu/Debian VPS -> your own VLESS+Reality
# (+ Hysteria2) node. Run as root.
set -euo pipefail
curl -fsSL https://sing-box.app/deb-install.sh | bash
mkdir -p /etc/sing-box
${cert}cat > /etc/sing-box/config.json <<'SINGBOX_EOF'
$cfgJson
SINGBOX_EOF
command -v ufw >/dev/null && ufw allow $port/tcp || true
${udp}systemctl enable --now sing-box
systemctl restart sing-box
echo "Done. Import the client links shown in the app (Reality + Hysteria2)."
''';
  }
}

/// Fresh Reality material for one hop (keypair + uuid + short_id).
class _Material {
  _Material(
      {required this.uuid,
      required this.priv,
      required this.pub,
      required this.sid});
  final String uuid, priv, pub, sid;
}
