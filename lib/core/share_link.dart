import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'proxy_node.dart';

/// Parses proxy share links and subscriptions into sing-box outbounds.
///
/// Supported schemes: vless, vmess, trojan, ss, hysteria2/hy2, hysteria(v1),
/// tuic, socks(5), anytls. Transport-only forms that belong to xray (xhttp/mkcp)
/// are bridged at runtime; ssr:// has no sing-box equivalent and is skipped.
class ShareLink {
  /// Parse a single link. Returns null if unsupported or malformed.
  static ParsedNode? parse(String raw) {
    final uri = raw.trim();
    if (uri.isEmpty) return null;
    try {
      if (uri.startsWith('vmess://')) return _vmess(uri);
      if (uri.startsWith('ss://')) return _ss(uri);
      final scheme = uri.split('://').first.toLowerCase();
      final u = Uri.parse(uri);
      switch (scheme) {
        case 'vless':
          return _vless(u);
        case 'trojan':
          return _trojan(u);
        case 'hysteria2':
        case 'hy2':
          return _hysteria2(u);
        case 'hysteria':
          return _hysteria(u);
        case 'tuic':
          return _tuic(u);
        case 'socks':
        case 'socks5':
          return _socks(u);
        case 'anytls':
          return _anytls(u);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Parse a subscription body: optionally base64, then one link per line.
  static List<ParsedNode> parseSubscription(String raw) {
    var text = raw.replaceAll('﻿', '').trim(); // strip BOM
    // Raw sing-box JSON config (any file extension): import the whole thing.
    if (text.startsWith('{') || text.contains('"outbounds"')) {
      final fromJson = _fromSingBoxJson(text);
      if (fromJson.isNotEmpty) return fromJson;
    }
    // Clash / Clash.Meta YAML subscription (a `proxies:` list).
    if (text.contains('proxies:')) {
      final clash = _fromClashYaml(text);
      if (clash.isNotEmpty) return clash;
    }
    // WireGuard .conf (INI with an [Interface] section) — the classic ".conf".
    if (text.toLowerCase().contains('[interface]')) {
      final wg = _fromWireguardConf(text);
      if (wg.isNotEmpty) return wg;
    }
    // A base64 subscription body decodes to a list of links.
    if (!text.contains('://')) {
      try {
        text = utf8.decode(base64.decode(_pad(text)));
      } catch (_) {
        // not base64 — fall through
      }
    }
    // Pull every proxy link out of the text wherever it sits — handles plain
    // lists, CRLF, trailing junk, or links embedded in some other format.
    final nodes = <ParsedNode>[];
    final seen = <String>{};
    for (final m in _linkRe.allMatches(text)) {
      final link = m.group(0)!;
      if (!seen.add(link)) continue;
      final n = parse(link);
      if (n != null) nodes.add(n);
    }
    return nodes;
  }

  static final RegExp _linkRe = RegExp(
    r'''(?:vless|vmess|trojan|ss|hysteria2|hy2|hysteria|tuic|socks5?|anytls)://[^\s"'<>]+''',
    caseSensitive: false,
  );

  /// Extracts proxy outbounds from a raw sing-box JSON config.
  static List<ParsedNode> _fromSingBoxJson(String text) {
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (j['outbounds'] is! List) return const [];
      // Import the whole config as ONE profile (keep routing/groups/DNS intact).
      final name =
          (j['route'] as Map?)?['final']?.toString() ?? 'sing-box config';
      return [ParsedNode(tag: name, outbound: const {}, config: j)];
    } catch (_) {
      return const [];
    }
  }

  // --- WireGuard .conf -----------------------------------------------------

  /// Parse a standard WireGuard `.conf` (INI) into a sing-box wireguard
  /// ENDPOINT, wrapped as a one-profile config. sing-box 1.13 removed the
  /// wireguard *outbound*, so it must be an `endpoints[]` entry.
  static List<ParsedNode> _fromWireguardConf(String text) {
    final iface = <String, String>{};
    final peer = <String, String>{};
    Map<String, String>? cur;
    for (var line in text.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
      final low = line.toLowerCase();
      if (low == '[interface]') {
        cur = iface;
        continue;
      }
      if (low == '[peer]') {
        cur = peer;
        continue;
      }
      final eq = line.indexOf('=');
      if (eq < 0 || cur == null) continue;
      cur[line.substring(0, eq).trim().toLowerCase()] =
          line.substring(eq + 1).trim();
    }
    final priv = iface['privatekey'];
    final pub = peer['publickey'];
    final endpoint = peer['endpoint'];
    if (priv == null || pub == null || endpoint == null) return const [];
    final (host, port) = _hostPort(endpoint);
    List<String> csv(String? v, String fallback) => (v == null || v.isEmpty)
        ? [fallback]
        : v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final ep = <String, dynamic>{
      'type': 'wireguard',
      'tag': 'wg',
      'address': csv(iface['address'], '10.0.0.2/32'),
      'private_key': priv,
      'peers': [
        {
          'address': host,
          'port': port,
          'public_key': pub,
          'allowed_ips': csv(peer['allowedips'], '0.0.0.0/0'),
          if ((peer['presharedkey'] ?? '').isNotEmpty)
            'pre_shared_key': peer['presharedkey'],
        }
      ],
    };
    final mtu = int.tryParse(iface['mtu'] ?? '');
    if (mtu != null) ep['mtu'] = mtu;
    // AmneziaWG obfuscation params. The bundled SagerNet sing-box REJECTS them
    // ("unknown field jc"), so stash them under a non-standard `_amneziawg` key:
    // SingBoxConfig.fromConfig strips `_`-prefixed keys before the bundled core
    // sees them, but they survive in storage for a future AmneziaWG-capable core.
    const awgKeys = [
      'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', //
      'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5'
    ];
    final awg = <String, dynamic>{};
    for (final k in awgKeys) {
      final v = iface[k];
      if (v != null) awg[k] = int.tryParse(v) ?? v;
    }
    final isAwg = awg.isNotEmpty;
    if (isAwg) ep['_amneziawg'] = awg;
    final cfg = <String, dynamic>{
      'endpoints': [ep],
      'outbounds': [
        {'type': 'direct', 'tag': 'direct'},
      ],
      'route': {'final': 'wg'},
    };
    final name = isAwg ? 'AmneziaWG $host' : 'WireGuard $host';
    return [ParsedNode(tag: name, outbound: const {}, config: cfg)];
  }

  // --- Clash YAML ----------------------------------------------------------

  /// Convert a Clash/Clash.Meta YAML `proxies:` list to sing-box outbounds.
  static List<ParsedNode> _fromClashYaml(String text) {
    try {
      final doc = loadYaml(text);
      if (doc is! Map) return const [];
      final proxies = doc['proxies'];
      if (proxies is! List) return const [];
      final nodes = <ParsedNode>[];
      for (final p in proxies) {
        if (p is! Map) continue;
        final ob = _clashProxy(p);
        if (ob != null) nodes.add(ParsedNode(tag: ob['tag'] as String, outbound: ob));
      }
      return nodes;
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic>? _clashProxy(Map p) {
    String s(String k) => p[k]?.toString() ?? '';
    final port = int.tryParse(p['port']?.toString() ?? '') ?? 443;
    final name = s('name').isNotEmpty ? s('name') : '${s('server')}:$port';
    switch (s('type')) {
      case 'ss':
        return {
          'type': 'shadowsocks',
          'tag': name,
          'server': s('server'),
          'server_port': port,
          'method': s('cipher'),
          'password': s('password'),
        };
      case 'vmess':
        final ob = <String, dynamic>{
          'type': 'vmess',
          'tag': name,
          'server': s('server'),
          'server_port': port,
          'uuid': s('uuid'),
          'security': s('cipher').isNotEmpty ? s('cipher') : 'auto',
          'alter_id': int.tryParse(p['alterId']?.toString() ?? '0') ?? 0,
        };
        if (p['tls'] == true) ob['tls'] = _clashTls(p);
        final t = _clashTransport(p);
        if (t != null) ob['transport'] = t;
        return ob;
      case 'vless':
        final reality = p['reality-opts'] != null;
        if (reality) {
          final ro = p['reality-opts'];
          final pk = ro is Map ? ro['public-key']?.toString() : null;
          if (pk == null || pk.isEmpty) return null; // un-handshakeable
        }
        final ob = <String, dynamic>{
          'type': 'vless',
          'tag': name,
          'server': s('server'),
          'server_port': port,
          'uuid': s('uuid'),
        };
        if (s('flow').isNotEmpty) ob['flow'] = s('flow');
        if (p['tls'] == true || reality) {
          ob['tls'] = _clashTls(p, reality: reality);
        }
        final t = _clashTransport(p);
        if (t != null) ob['transport'] = t;
        return ob;
      case 'trojan':
        final ob = <String, dynamic>{
          'type': 'trojan',
          'tag': name,
          'server': s('server'),
          'server_port': port,
          'password': s('password'),
          'tls': _clashTls(p),
        };
        final t = _clashTransport(p);
        if (t != null) ob['transport'] = t;
        return ob;
      case 'hysteria2':
        final tls = <String, dynamic>{'enabled': true};
        if (s('sni').isNotEmpty) tls['server_name'] = s('sni');
        if (p['skip-cert-verify'] == true) tls['insecure'] = true;
        final ob = <String, dynamic>{
          'type': 'hysteria2',
          'tag': name,
          'server': s('server'),
          'server_port': port,
          'password': s('password'),
          'tls': tls,
        };
        if (s('obfs').isNotEmpty) {
          ob['obfs'] = {'type': s('obfs'), 'password': s('obfs-password')};
        }
        return ob;
      case 'tuic':
        final tls = <String, dynamic>{'enabled': true};
        if (s('sni').isNotEmpty) tls['server_name'] = s('sni');
        if (p['skip-cert-verify'] == true) tls['insecure'] = true;
        return {
          'type': 'tuic',
          'tag': name,
          'server': s('server'),
          'server_port': port,
          'uuid': s('uuid'),
          'password': s('password'),
          'tls': tls,
        };
      case 'socks5':
      case 'socks':
        return {
          'type': 'socks',
          'tag': name,
          'server': s('server'),
          'server_port': port,
          if (s('username').isNotEmpty) 'username': s('username'),
          if (s('password').isNotEmpty) 'password': s('password'),
        };
      default:
        return null; // unsupported clash proxy type
    }
  }

  static Map<String, dynamic> _clashTls(Map p, {bool reality = false}) {
    final tls = <String, dynamic>{'enabled': true};
    final sni = p['sni']?.toString() ?? p['servername']?.toString();
    if (sni != null && sni.isNotEmpty) tls['server_name'] = sni;
    if (p['skip-cert-verify'] == true) tls['insecure'] = true;
    final alpn = p['alpn'];
    if (alpn is List && alpn.isNotEmpty) {
      tls['alpn'] = alpn.map((e) => e.toString()).toList();
    }
    final fp = p['client-fingerprint']?.toString();
    tls['utls'] = {
      'enabled': true,
      'fingerprint': (fp != null && fp.isNotEmpty) ? fp : 'chrome',
    };
    if (reality) {
      final ro = p['reality-opts'];
      final r = <String, dynamic>{'enabled': true};
      if (ro is Map) {
        if (ro['public-key'] != null) r['public_key'] = ro['public-key'].toString();
        if (ro['short-id'] != null) r['short_id'] = ro['short-id'].toString();
      }
      tls['reality'] = r;
    }
    return tls;
  }

  static Map<String, dynamic>? _clashTransport(Map p) {
    switch (p['network']?.toString()) {
      case 'ws':
        final t = <String, dynamic>{'type': 'ws'};
        final wo = p['ws-opts'];
        if (wo is Map) {
          if (wo['path'] != null) t['path'] = wo['path'].toString();
          final h = wo['headers'];
          if (h is Map && h['Host'] != null) {
            t['headers'] = {'Host': h['Host'].toString()};
          }
        }
        return t;
      case 'grpc':
        final t = <String, dynamic>{'type': 'grpc'};
        final go = p['grpc-opts'];
        if (go is Map && go['grpc-service-name'] != null) {
          t['service_name'] = go['grpc-service-name'].toString();
        }
        return t;
      case 'http':
        return {'type': 'http'};
      default:
        return null; // tcp / unsupported transport
    }
  }

  // --- per-protocol parsers ------------------------------------------------

  static ParsedNode? _vless(Uri u) {
    final p = _clean(u.queryParameters);
    final security = p['security'] ?? 'none';
    // Reality without the server public key can never complete a handshake —
    // reject it instead of importing a node that silently fails to connect.
    if (security == 'reality' && (p['pbk'] == null || p['pbk']!.isEmpty)) {
      return null;
    }
    final name = _name(u, '${u.host}:${_port(u)}');
    final ob = <String, dynamic>{
      'type': 'vless',
      'tag': name,
      'server': u.host,
      'server_port': _port(u),
      'uuid': Uri.decodeComponent(u.userInfo),
    };
    final flow = p['flow'];
    if (flow != null && flow.isNotEmpty) ob['flow'] = flow;
    if (security == 'tls' || security == 'reality') {
      ob['tls'] = _tls(p, reality: security == 'reality');
    }
    final t = _transport(p);
    if (t != null) ob['transport'] = t;
    return ParsedNode(tag: name, outbound: ob);
  }

  static ParsedNode _vmess(String uri) {
    final j = jsonDecode(utf8.decode(base64.decode(_pad(uri.substring(8)))))
        as Map<String, dynamic>;
    final server = _c(j['add']?.toString() ?? '');
    final port = int.tryParse(j['port']?.toString() ?? '') ?? 443;
    final ps = _c(j['ps']?.toString() ?? '');
    final name = ps.isNotEmpty ? ps : '$server:$port';
    final ob = <String, dynamic>{
      'type': 'vmess',
      'tag': name,
      'server': server,
      'server_port': port,
      'uuid': _c(j['id']?.toString() ?? ''),
      'security': (j['scy']?.toString().isNotEmpty ?? false)
          ? j['scy'].toString()
          : 'auto',
      'alter_id': int.tryParse(j['aid']?.toString() ?? '0') ?? 0,
    };
    if ((j['tls']?.toString() ?? '') == 'tls') {
      ob['tls'] = _tls({
        if (j['sni'] != null) 'sni': j['sni'].toString(),
        if (j['host'] != null) 'host': j['host'].toString(),
        if (j['alpn'] != null) 'alpn': j['alpn'].toString(),
        if (j['fp'] != null) 'fp': j['fp'].toString(),
      });
    }
    final t = _transport({
      'type': j['net']?.toString() ?? 'tcp',
      if (j['path'] != null) 'path': j['path'].toString(),
      if (j['host'] != null) 'host': j['host'].toString(),
      if (j['serviceName'] != null) 'serviceName': j['serviceName'].toString(),
    });
    if (t != null) ob['transport'] = t;
    return ParsedNode(tag: name, outbound: ob);
  }

  static ParsedNode _trojan(Uri u) {
    final p = _clean(u.queryParameters);
    final name = _name(u, '${u.host}:${_port(u)}');
    final ob = <String, dynamic>{
      'type': 'trojan',
      'tag': name,
      'server': u.host,
      'server_port': _port(u),
      'password': Uri.decodeComponent(u.userInfo),
    };
    if ((p['security'] ?? 'tls') != 'none') ob['tls'] = _tls(p);
    final t = _transport(p);
    if (t != null) ob['transport'] = t;
    return ParsedNode(tag: name, outbound: ob);
  }

  static ParsedNode _ss(String uri) {
    var body = uri.substring(5);
    var name = '';
    final hash = body.indexOf('#');
    if (hash >= 0) {
      name = Uri.decodeComponent(body.substring(hash + 1));
      body = body.substring(0, hash);
    }
    final q = body.indexOf('?');
    var query = '';
    if (q >= 0) {
      query = body.substring(q + 1);
      body = body.substring(0, q);
    }
    // SIP002 URIs put a `/` before the query: `…@host:port/?plugin=…`. Strip it,
    // else `_hostPort` parses `port/` -> null -> wrong default :443.
    if (body.endsWith('/')) body = body.substring(0, body.length - 1);

    String method, password, host;
    int port;
    if (body.contains('@')) {
      final at = body.lastIndexOf('@');
      var user = body.substring(0, at);
      try {
        user = utf8.decode(base64.decode(_pad(user)));
      } catch (_) {
        user = Uri.decodeComponent(user);
      }
      final ci = user.indexOf(':');
      method = user.substring(0, ci);
      password = user.substring(ci + 1);
      (host, port) = _hostPort(body.substring(at + 1));
    } else {
      final decoded = utf8.decode(base64.decode(_pad(body)));
      final at = decoded.lastIndexOf('@');
      final user = decoded.substring(0, at);
      final ci = user.indexOf(':');
      method = user.substring(0, ci);
      password = user.substring(ci + 1);
      (host, port) = _hostPort(decoded.substring(at + 1));
    }
    if (name.isEmpty) name = '$host:$port';
    final ob = <String, dynamic>{
      'type': 'shadowsocks',
      'tag': name,
      'server': host,
      'server_port': port,
      'method': method,
      'password': password,
    };
    // SIP002 `?plugin=` (obfs-local / v2ray-plugin / shadow-tls) carries the
    // node's DPI evasion — preserve it instead of silently importing a bare,
    // easily-blocked Shadowsocks node. sing-box wants name + opts split on ';'.
    final plugin = _ssPlugin(query);
    if (plugin != null) {
      ob['plugin'] = plugin.$1;
      if (plugin.$2.isNotEmpty) ob['plugin_opts'] = plugin.$2;
    }
    return ParsedNode(tag: name, outbound: ob);
  }

  static (String, String)? _ssPlugin(String query) {
    if (query.isEmpty) return null;
    for (final pair in query.split('&')) {
      final eq = pair.indexOf('=');
      if (eq < 0 || pair.substring(0, eq) != 'plugin') continue;
      final raw = Uri.decodeComponent(pair.substring(eq + 1));
      final sc = raw.indexOf(';');
      final name = sc >= 0 ? raw.substring(0, sc) : raw;
      if (name.isEmpty) return null; // `plugin=` with no name -> no plugin
      return sc >= 0 ? (name, raw.substring(sc + 1)) : (name, '');
    }
    return null;
  }

  static ParsedNode _hysteria2(Uri u) {
    final p = _clean(u.queryParameters);
    final name = _name(u, '${u.host}:${_port(u)}');
    final tls = <String, dynamic>{'enabled': true};
    if ((p['sni'] ?? '').isNotEmpty) tls['server_name'] = p['sni'];
    if (p['insecure'] == '1') tls['insecure'] = true;
    if ((p['alpn'] ?? '').isNotEmpty) tls['alpn'] = _csv(p['alpn']!);
    final ob = <String, dynamic>{
      'type': 'hysteria2',
      'tag': name,
      'server': u.host,
      'server_port': _port(u),
      'password': Uri.decodeComponent(u.userInfo),
      'tls': tls,
    };
    final obfs = p['obfs'];
    if (obfs != null && obfs.isNotEmpty) {
      ob['obfs'] = {'type': obfs, 'password': p['obfs-password'] ?? ''};
    }
    return ParsedNode(tag: name, outbound: ob);
  }

  static ParsedNode _tuic(Uri u) {
    final p = _clean(u.queryParameters);
    final name = _name(u, '${u.host}:${_port(u)}');
    final ui = Uri.decodeComponent(u.userInfo);
    final ci = ui.indexOf(':');
    final tls = <String, dynamic>{'enabled': true};
    if ((p['sni'] ?? '').isNotEmpty) tls['server_name'] = p['sni'];
    if ((p['alpn'] ?? '').isNotEmpty) tls['alpn'] = _csv(p['alpn']!);
    if (p['allow_insecure'] == '1' || p['insecure'] == '1') {
      tls['insecure'] = true;
    }
    final ob = <String, dynamic>{
      'type': 'tuic',
      'tag': name,
      'server': u.host,
      'server_port': _port(u),
      'uuid': ci >= 0 ? ui.substring(0, ci) : ui,
      'password': ci >= 0 ? ui.substring(ci + 1) : '',
      'tls': tls,
    };
    if (p['congestion_control'] != null) {
      ob['congestion_control'] = p['congestion_control'];
    }
    if (p['udp_relay_mode'] != null) {
      ob['udp_relay_mode'] = p['udp_relay_mode'];
    }
    return ParsedNode(tag: name, outbound: ob);
  }

  // socks(5)://[user:pass@]host:port — a plain SOCKS proxy. sing-box native.
  static ParsedNode _socks(Uri u) {
    final port = u.hasPort ? u.port : 1080;
    final name = _name(u, '${u.host}:$port');
    final ui = Uri.decodeComponent(u.userInfo);
    final ci = ui.indexOf(':');
    final ob = <String, dynamic>{
      'type': 'socks',
      'tag': name,
      'server': u.host,
      'server_port': port,
      'version': '5',
    };
    if (ui.isNotEmpty) {
      ob['username'] = ci >= 0 ? ui.substring(0, ci) : ui;
      if (ci >= 0) ob['password'] = ui.substring(ci + 1);
    }
    return ParsedNode(tag: name, outbound: ob);
  }

  // anytls://password@host:port?sni=… — the newer AnyTLS wrapper (sing-box
  // native). A staple in fresh RF subs that we were silently dropping.
  static ParsedNode _anytls(Uri u) {
    final p = _clean(u.queryParameters);
    final name = _name(u, '${u.host}:${_port(u)}');
    final tls = <String, dynamic>{'enabled': true};
    final sni = p['sni'] ?? p['peer'] ?? p['host'];
    if ((sni ?? '').isNotEmpty) tls['server_name'] = sni;
    if (p['insecure'] == '1' || p['allowInsecure'] == '1') tls['insecure'] = true;
    if ((p['alpn'] ?? '').isNotEmpty) tls['alpn'] = _csv(p['alpn']!);
    return ParsedNode(
      tag: name,
      outbound: {
        'type': 'anytls',
        'tag': name,
        'server': u.host,
        'server_port': _port(u),
        'password': Uri.decodeComponent(u.userInfo),
        'tls': tls,
      },
    );
  }

  // hysteria://host:port?auth=…&upmbps=…&downmbps=…&obfs=… — Hysteria v1 (distinct
  // from hysteria2). sing-box has a native `hysteria` outbound.
  static ParsedNode _hysteria(Uri u) {
    final p = _clean(u.queryParameters);
    final name = _name(u, '${u.host}:${_port(u)}');
    final tls = <String, dynamic>{'enabled': true};
    final sni = p['peer'] ?? p['sni'];
    if ((sni ?? '').isNotEmpty) tls['server_name'] = sni;
    if (p['insecure'] == '1') tls['insecure'] = true;
    if ((p['alpn'] ?? '').isNotEmpty) tls['alpn'] = _csv(p['alpn']!);
    int mbps(String? v, int dflt) =>
        v == null ? dflt : (int.tryParse(v.replaceAll(RegExp(r'[^0-9]'), '')) ?? dflt);
    final ob = <String, dynamic>{
      'type': 'hysteria',
      'tag': name,
      'server': u.host,
      'server_port': _port(u),
      'up_mbps': mbps(p['upmbps'] ?? p['up'], 10),
      'down_mbps': mbps(p['downmbps'] ?? p['down'], 50),
      'tls': tls,
    };
    final auth = p['auth'] ??
        (u.userInfo.isNotEmpty ? Uri.decodeComponent(u.userInfo) : '');
    if (auth.isNotEmpty) ob['auth_str'] = auth;
    if ((p['obfs'] ?? '').isNotEmpty) ob['obfs'] = p['obfs'];
    return ParsedNode(tag: name, outbound: ob);
  }

  // --- shared builders -----------------------------------------------------

  static Map<String, dynamic> _tls(Map<String, String> p,
      {bool reality = false}) {
    p = _clean(p); // strip control chars from sni/host — covers the vmess path too
    final tls = <String, dynamic>{'enabled': true};
    final sni = p['sni'] ?? p['peer'] ?? p['host'];
    if (sni != null && sni.isNotEmpty) tls['server_name'] = sni;
    if ((p['alpn'] ?? '').isNotEmpty) tls['alpn'] = _csv(p['alpn']!);
    if (p['allowInsecure'] == '1' || p['insecure'] == '1') {
      tls['insecure'] = true;
    }
    // uTLS mimics a real browser ClientHello byte-for-byte. Reality REQUIRES a
    // concrete fingerprint — 'randomized' is synthetic and can omit the X25519
    // key_share, breaking the handshake. Respect the link's fp, default Chrome.
    final fp = p['fp'];
    tls['utls'] = {
      'enabled': true,
      'fingerprint': (fp != null && fp.isNotEmpty) ? fp : 'chrome',
    };
    if (reality) {
      final r = <String, dynamic>{'enabled': true};
      if (p['pbk'] != null) r['public_key'] = p['pbk'];
      if (p['sid'] != null) r['short_id'] = p['sid'];
      tls['reality'] = r;
    }
    return tls;
  }

  static Map<String, dynamic>? _transport(Map<String, String> p) {
    p = _clean(p); // strip CR/LF from path/host/Host — header-injection guard
    switch (p['type']) {
      case 'ws':
        final t = <String, dynamic>{'type': 'ws'};
        if ((p['path'] ?? '').isNotEmpty) t['path'] = p['path'];
        if ((p['host'] ?? '').isNotEmpty) {
          t['headers'] = {'Host': p['host']};
        }
        return t;
      case 'grpc':
        return {'type': 'grpc', 'service_name': p['serviceName'] ?? ''};
      case 'http':
        final t = <String, dynamic>{'type': 'http'};
        if ((p['path'] ?? '').isNotEmpty) t['path'] = p['path'];
        if ((p['host'] ?? '').isNotEmpty) t['host'] = _csv(p['host']!);
        return t;
      case 'httpupgrade':
        final t = <String, dynamic>{'type': 'httpupgrade'};
        if ((p['path'] ?? '').isNotEmpty) t['path'] = p['path'];
        if ((p['host'] ?? '').isNotEmpty) t['host'] = p['host'];
        return t;
      case 'xhttp':
      case 'splithttp':
        // xhttp/splithttp is xray-only. Emit it faithfully so the xray bridge
        // fires (core_controller._bridgeXray detects transport.type==xhttp).
        // Without this, a bare `vless://…&type=xhttp` link parsed as plain TCP,
        // imported green, passed preflight, and carried ZERO traffic — the
        // dominant 3x-ui/Marzban share format, silently dead.
        final t = <String, dynamic>{'type': 'xhttp'};
        if ((p['path'] ?? '').isNotEmpty) t['path'] = p['path'];
        if ((p['host'] ?? '').isNotEmpty) t['host'] = p['host'];
        if ((p['mode'] ?? '').isNotEmpty) t['mode'] = p['mode'];
        return t;
      default:
        return null; // tcp/none
    }
  }

  // --- helpers -------------------------------------------------------------

  // Strip control chars (CR/LF/NUL/...) from every decoded link param so a
  // crafted link (e.g. `?host=a%0d%0aInjected:x`) can't smuggle a newline into a
  // WS `Host` header / SNI / path — header-injection from untrusted share-links.
  static Map<String, String> _clean(Map<String, String> p) =>
      p.map((k, v) => MapEntry(k, _c(v)));

  // Strip control chars from a single string (display name, vmess host, ...).
  static String _c(String s) => s.replaceAll(RegExp(r'[\x00-\x1f]'), '');

  static int _port(Uri u) {
    if (!u.hasPort) return 443;
    final p = u.port;
    // Reject an out-of-range port (e.g. :99999): parse()'s try/catch turns this
    // into a null node, so the link is dropped instead of emitting an outbound
    // that can never connect (relying on the core to FATAL it later is fragile).
    if (p < 1 || p > 65535) throw const FormatException('port out of range');
    return p;
  }

  static int _vp(int? p) => (p != null && p >= 1 && p <= 65535) ? p : 443;

  static String _name(Uri u, String fallback) =>
      _c(u.fragment.isEmpty ? fallback : Uri.decodeComponent(u.fragment));

  static List<String> _csv(String s) =>
      s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static (String, int) _hostPort(String hp) {
    final s = hp.trim();
    // Bracketed IPv6 literal: [2001:db8::1]:51820 -> host without brackets.
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end > 0) {
        final host = s.substring(1, end);
        final rest = s.substring(end + 1);
        final colon = rest.indexOf(':');
        final port = colon >= 0 ? _vp(int.tryParse(rest.substring(colon + 1))) : 443;
        return (host, port);
      }
    }
    final i = s.lastIndexOf(':');
    if (i < 0) return (s, 443);
    // A bare IPv6 literal (multiple colons, no brackets) has no port — the last
    // colon is part of the address, not a separator.
    if (s.indexOf(':') != i) return (s, 443);
    return (s.substring(0, i), _vp(int.tryParse(s.substring(i + 1))));
  }

  static String _pad(String b64) {
    var s = b64.replaceAll('-', '+').replaceAll('_', '/').trim();
    final mod = s.length % 4;
    if (mod != 0) s += '=' * (4 - mod);
    return s;
  }
}
