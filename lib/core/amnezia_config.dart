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

    // The .conf is UNTRUSTED (imported from a link/QR/drop). REJECT on any
    // malformed structural field so a hostile value can't rebind the peer /
    // endpoint or inject INI structure (a second [Socks5] binding public, etc.):
    // keys must be base64, host must have no structural/space chars, port + CIDR
    // lists must be well-formed. (Amnezia I1-I5 junk params legitimately carry
    // `<...>` tokens, so those keep the CR/LF strip — without a newline a param
    // value can't open a new section/directive anyway.)
    if (!_okKey(priv) || !_okKey(pub)) return null;
    if (!_okHost(server)) return null;
    final portNum = port is num ? port.toInt() : int.tryParse('$port');
    if (portNum == null || portNum < 1 || portNum > 65535) return null;
    final psk = (peer['pre_shared_key'] ?? '').toString();
    if (psk.isNotEmpty && !_okKey(psk)) return null;
    final address =
        endpoint['address'] == null ? '10.0.0.2/32' : _cidrList(endpoint['address']);
    final allowed =
        peer['allowed_ips'] == null ? '0.0.0.0/0' : _cidrList(peer['allowed_ips']);
    if (address == null || allowed == null) return null; // present but malformed
    final awg =
        (endpoint['_amneziawg'] as Map?)?.cast<String, dynamic>() ?? const {};
    final mtu = endpoint['mtu'];
    final mtuNum = mtu is num ? mtu.toInt() : int.tryParse('${mtu ?? ''}');

    final b = StringBuffer()
      ..writeln('[Interface]')
      ..writeln('PrivateKey = $priv')
      ..writeln('Address = $address');
    if (mtuNum != null && mtuNum > 0) b.writeln('MTU = $mtuNum');
    // Amnezia obfuscation params (only those present), canonical casing + order.
    _params.forEach((lower, canon) {
      if (awg[lower] != null) b.writeln('$canon = ${_ini(awg[lower])}');
    });
    b
      ..writeln()
      ..writeln('[Peer]')
      ..writeln('PublicKey = $pub');
    if (psk.isNotEmpty) b.writeln('PresharedKey = $psk');
    // PersistentKeepalive: without it a bridged WG tunnel goes silent once the
    // peer's NAT mapping times out (no app traffic → no rekey → dead tunnel).
    // Honour the peer's interval; default to 25s (the WireGuard convention) when
    // absent — sing-box's `persistent_keepalive_interval` is in seconds.
    final ka = peer['persistent_keepalive_interval'];
    final kaNum = ka is num ? ka.toInt() : int.tryParse('${ka ?? ''}');
    b
      ..writeln('Endpoint = ${_bracket(server)}:$portNum')
      ..writeln('AllowedIPs = $allowed')
      // Honour an explicit value INCLUDING 0 (the author disabled keepalive on
      // purpose); default to 25s only when the field is absent/unparseable.
      // Clamp to WG's uint16 range so a huge value ("99999") can't be emitted
      // verbatim and make wireproxy reject the whole config.
      ..writeln(
          'PersistentKeepalive = ${kaNum != null && kaNum >= 0 ? kaNum.clamp(0, 65535) : 25}')
      ..writeln()
      // wireproxy exposes the tunnel as a local SOCKS5 — what sing-box dials.
      ..writeln('[Socks5]')
      ..writeln('BindAddress = 127.0.0.1:$socksPort');
    return b.toString();
  }

  static final _b64Re = RegExp(r'^[A-Za-z0-9+/=_-]+$'); // WG key (std + urlsafe)
  static final _hostRe = RegExp(r'^[A-Za-z0-9._\-:\[\]]+$'); // host(_ ok) / IPv4 / [IPv6]
  static bool _okKey(String v) =>
      v.isNotEmpty && v.length <= 128 && _b64Re.hasMatch(v);
  static bool _okHost(String v) =>
      v.isNotEmpty && v.length <= 255 && _hostRe.hasMatch(v);
  // Wrap a bare IPv6 literal in [...] for the wireproxy `Endpoint = host:port`.
  static String _bracket(String h) =>
      (h.contains(':') && !h.startsWith('[')) ? '[$h]' : h;
  // Validate + re-join an IP/CIDR list; null if any element is malformed.
  static String? _cidrList(Object? v) {
    if (v is! List || v.isEmpty) return null;
    final re = RegExp(r'^[0-9a-fA-F:.]+(/\d{1,3})?$');
    final parts = <String>[];
    for (final e in v) {
      final s = '$e'.trim();
      if (s.isEmpty || s.length > 64 || !re.hasMatch(s)) return null;
      parts.add(s);
    }
    return parts.join(', ');
  }

  // Last-resort line-injection guard for the free-form Amnezia params (I1-I5 may
  // carry `<...>` tokens, so they aren't strictly validated above).
  static String _ini(Object? v) => '$v'.replaceAll(RegExp(r'[\r\n]'), '');
}
