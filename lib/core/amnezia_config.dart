/// AmneziaWG bridge — our anti-DPI SUPERSTRUCTURE for a transport neither
/// sing-box nor xray can dial.
///
/// AmneziaWG = WireGuard + obfuscation (junk packets `Jc/Jmin/Jmax`, magic-header
/// sizes `S1..S4`, header values `H1..H4`, init junk `I1..I5`). The bundled
/// SagerNet sing-box does PLAIN WireGuard only, so an AmneziaWG server/ТСПУ drops
/// its handshake (battle-confirmed: `handshake did not complete, retrying`
/// forever). xray can't either. So we BRIDGE it, exactly as XHTTP rides xray:
///
///   sing-box  ──socks──▶  awg bridge (userspace AmneziaWG)  ──obfs WG──▶  server
///
/// [ShareLink] already imports an AmneziaWG `.conf` and stashes the obfs params
/// under the endpoint's `_amneziawg` key (the bundled core never sees them).
/// This class turns that endpoint into a `wireproxy`-style config the bridge
/// binary reads: a standard `[Interface]`/`[Peer]` plus the Amnezia params and a
/// `[Socks5]` listener. The controller then spawns the bridge and rewrites the
/// endpoint into a plain `socks` outbound on that port — so AmneziaWG "just
/// works" inside the sing-box JSON, only in our app.
///
/// The `awg` bridge binary is fetched separately (like xray); this is pure,
/// unit-testable config generation — no I/O, no FFI.
class AmneziaConfig {
  /// AmneziaWG params stored lowercase by [ShareLink] → the canonical casing the
  /// AmneziaVPN `.conf` / wireproxy-amnezia fork expects, in emit order.
  static const Map<String, String> _params = {
    'jc': 'Jc', 'jmin': 'Jmin', 'jmax': 'Jmax',
    's1': 'S1', 's2': 'S2', 's3': 'S3', 's4': 'S4',
    'h1': 'H1', 'h2': 'H2', 'h3': 'H3', 'h4': 'H4',
    'i1': 'I1', 'i2': 'I2', 'i3': 'I3', 'i4': 'I4', 'i5': 'I5',
  };

  /// True if [endpoint] is a WireGuard endpoint carrying AmneziaWG obfuscation
  /// params (so it MUST go through the bridge, not the plain-WG core).
  static bool needsAmnezia(Map endpoint) {
    if (endpoint['type'] != 'wireguard') return false;
    final awg = endpoint['_amneziawg'];
    return awg is Map && awg.isNotEmpty;
  }

  /// A `wireproxy`-format config (INI): `[Interface]` (WG keys + Amnezia params),
  /// `[Peer]`, and a `[Socks5]` listener on [socksPort]. Returns null if the
  /// endpoint is missing essentials (no private key / peer).
  static String? fromEndpoint(Map endpoint, int socksPort) {
    final priv = endpoint['private_key']?.toString();
    final peers = endpoint['peers'];
    if (priv == null || priv.isEmpty || peers is! List || peers.isEmpty) {
      return null;
    }
    final peer = peers.first;
    if (peer is! Map) return null;
    final pub = peer['public_key']?.toString();
    final server = peer['address']?.toString();
    final port = peer['port'];
    if (pub == null || server == null || port == null) return null;

    final address = (endpoint['address'] as List?)?.join(', ') ?? '10.0.0.2/32';
    final allowed = (peer['allowed_ips'] as List?)?.join(', ') ?? '0.0.0.0/0';
    final awg = (endpoint['_amneziawg'] as Map).cast<String, dynamic>();
    final psk = (peer['pre_shared_key'] ?? '').toString();

    final b = StringBuffer()
      ..writeln('[Interface]')
      ..writeln('PrivateKey = $priv')
      ..writeln('Address = $address');
    if (endpoint['mtu'] != null) b.writeln('MTU = ${endpoint['mtu']}');
    // Amnezia obfuscation params (only those present), canonical casing + order.
    _params.forEach((lower, canon) {
      if (awg[lower] != null) b.writeln('$canon = ${awg[lower]}');
    });
    b
      ..writeln()
      ..writeln('[Peer]')
      ..writeln('PublicKey = $pub');
    if (psk.isNotEmpty) b.writeln('PresharedKey = $psk');
    b
      ..writeln('Endpoint = $server:$port')
      ..writeln('AllowedIPs = $allowed')
      ..writeln()
      // wireproxy exposes the tunnel as a local SOCKS5 — what sing-box dials.
      ..writeln('[Socks5]')
      ..writeln('BindAddress = 127.0.0.1:$socksPort');
    return b.toString();
  }
}
