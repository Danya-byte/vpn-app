import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data' show BytesBuilder;

import 'proxy_node.dart';

/// What a decoded `vpn://share?d=…` bundle carries.
class ShareBundle {
  const ShareBundle({
    required this.nodes,
    this.settings,
    this.subUrl,
    this.autoUpdate = true,
    this.version = 1,
  });

  final List<ParsedNode> nodes;

  /// Sender's protection settings (a subset of AppSettings JSON) the recipient
  /// may CHOOSE to apply. Null = the sender shared nodes only.
  final Map<String, dynamic>? settings;

  /// Optional self-hosted subscription URL the recipient auto-refreshes from
  /// (e.g. an `sslip.io`-wrapped IP). Null = a static, one-time bundle.
  final String? subUrl;
  final bool autoUpdate;
  final int version;
}

/// The inverse of [ShareLink] parsing — turn profiles back into shareable links.
///
/// Two forms, chosen by the sharer:
///   • [encodeNode] / [encodeSubscription] → standard `vless://` / `trojan://` /
///     `hysteria2://` / `ss://` URIs that ANY client (v2rayN, Hiddify, Throne…)
///     can import. Interop, but carries no app settings.
///   • [encodeBundle] → our own `vpn://share?d=<base64url-json>` carrying the
///     full sing-box outbounds LOSSLESSLY plus the sender's protection settings
///     and an optional auto-updating subscription URL. Only our app reads it;
///     every other client ignores the unknown scheme.
///
/// Back-compat: the bundle is versioned and purely ADDITIVE — a newer sender's
/// extra fields are ignored by an older reader, and the standard URIs are the
/// stable de-facto format, so links shared today keep importing in any future
/// build (and old client builds keep working against today's links).
class ShareLinkEncoder {
  // ---------------------------------------------------------------- bundle ----

  static String encodeBundle({
    required List<ParsedNode> nodes,
    Map<String, dynamic>? settings,
    String? subUrl,
    bool autoUpdate = true,
  }) {
    final j = <String, dynamic>{
      'v': 1,
      'nodes': [
        for (final n in nodes)
          n.isConfig
              ? {'tag': n.tag, 'config': n.config}
              : {'tag': n.tag, 'outbound': n.outbound},
      ],
      if (settings != null && settings.isNotEmpty) 'settings': settings,
      if (subUrl != null && subUrl.trim().isNotEmpty) 'sub': subUrl.trim(),
      'auto': autoUpdate,
    };
    final raw = utf8.encode(jsonEncode(j));
    // gzip when it actually shrinks the payload. A whole-config bundle (repeated
    // keys + the RU-direct domain list + rule-sets) compresses several-fold, so a
    // 5 KB link drops to ~1.5 KB. A tiny single-node bundle doesn't benefit, so it
    // stays PLAIN JSON — smallest possible AND readable by older clients (which
    // can't gunzip). decodeBundle auto-detects which form a link is.
    final gz = gzip.encode(raw);
    final payload = gz.length < raw.length ? gz : raw;
    final b64 = base64Url.encode(payload).replaceAll('=', '');
    return 'vpn://share?d=$b64';
  }

  /// Parse a `vpn://share?d=…` bundle. Returns null if it isn't one or is
  /// malformed (the caller then falls back to the standard parsers).
  static ShareBundle? decodeBundle(String link) {
    try {
      final u = Uri.parse(link.trim());
      if (u.scheme != 'vpn' || u.host != 'share') return null;
      final d = u.queryParameters['d'];
      if (d == null || d.isEmpty) return null;
      final bytes = base64Url.decode(_pad(d));
      // The link is fully UNTRUSTED (chat/QR/clipboard). Cap the compressed input
      // AND the decompressed output — an unbounded gunzip is a decompression bomb
      // (a few-KB crafted link inflates to GBs → OOM/UI freeze before jsonDecode
      // even runs). Real bundles are a few KB compressed / tens of KB decoded, so
      // these ceilings are generous. Same class of cap as the censorship-facts
      // 256KB body cap.
      if (bytes.length > _maxCompressed) return null;
      // Auto-detect gzip (magic 1f 8b) so a newer gzipped bundle AND an older
      // plain-JSON one (starts with '{' = 0x7b) both import — back-compat both ways.
      final jsonBytes =
          (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)
              ? _gunzipCapped(bytes, _maxDecompressed)
              : bytes;
      final j = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
      final nodes = <ParsedNode>[];
      for (final e in (j['nodes'] as List? ?? const [])) {
        if (e is! Map) continue;
        final tag = e['tag']?.toString() ?? 'node';
        if (e['config'] is Map) {
          nodes.add(ParsedNode(
              tag: tag,
              outbound: const {},
              config: (e['config'] as Map).cast<String, dynamic>()));
        } else if (e['outbound'] is Map) {
          nodes.add(ParsedNode(
              tag: tag,
              outbound: (e['outbound'] as Map).cast<String, dynamic>()));
        }
      }
      if (nodes.isEmpty) return null;
      // The sub URL feeds a RECURRING background fetch on the recipient (the
      // subscription auto-refresh) — clamp it to https here, at the trust
      // boundary: an attacker crafts the payload directly, so the sender-side
      // checks never ran. http would leak the fetch (and the recipient's IP→sub
      // association) to any on-path observer on every refresh tick.
      final subRaw = j['sub']?.toString();
      final sub = (subRaw != null &&
              (Uri.tryParse(subRaw)?.isScheme('https') ?? false))
          ? subRaw
          : null;
      return ShareBundle(
        nodes: nodes,
        settings: (j['settings'] as Map?)?.cast<String, dynamic>(),
        subUrl: sub,
        autoUpdate: j['auto'] as bool? ?? true,
        version: (j['v'] as num?)?.toInt() ?? 1,
      );
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------- standard URIs --------

  /// Standard share URIs for [nodes], EXTRACTING the proxy outbounds from any
  /// whole-config profile. A config has no single-URI form, but the servers
  /// INSIDE it (vless/trojan/hysteria2/ss) usually do — so "share for any client"
  /// on an imported config like `🌍 VPN` yields one standard link per real exit
  /// (selector/urltest/direct/block/dns and chained detours are skipped). Returns
  /// the flat list; empty when nothing is single-URI-representable.
  static List<String> nodeLinks(List<ParsedNode> nodes) {
    final out = <String>[];
    final seen = <String>{}; // a pool repeats one server across transports
    void addNode(ParsedNode n) {
      final link = encodeNode(n);
      if (link != null && seen.add(link)) out.add(link);
    }

    for (final n in nodes) {
      if (!n.isConfig) {
        addNode(n);
        continue;
      }
      for (final o in (n.config?['outbounds'] as List?) ?? const []) {
        if (o is! Map || o['server'] == null) continue;
        addNode(ParsedNode(
            tag: o['tag']?.toString() ?? n.tag,
            outbound: o.cast<String, dynamic>()));
      }
    }
    return out;
  }

  /// A whole pool as a base64 subscription body of standard links — the
  /// universal "share for any client" form. Extracts servers from whole configs.
  static String encodeSubscription(List<ParsedNode> nodes) =>
      base64.encode(utf8.encode(nodeLinks(nodes).join('\n')));

  /// A single node as a standard share URI, or null when it has no clean
  /// single-URI form (whole sing-box config, or an unsupported type).
  static String? encodeNode(ParsedNode n) {
    if (n.isConfig) return null;
    final ob = n.outbound;
    final server = ob['server']?.toString() ?? '';
    if (server.isEmpty) return null;
    final host = server.contains(':') ? '[$server]' : server; // v6 literal
    final port = ob['server_port'] ?? 443;
    final tag = Uri.encodeComponent(n.tag);
    switch (ob['type']?.toString()) {
      case 'vless':
        final q = _tlsTransportQuery(ob);
        final flow = ob['flow']?.toString();
        if (flow != null && flow.isNotEmpty) q['flow'] = flow;
        return 'vless://${ob['uuid'] ?? ''}@$host:$port?${_qs(q)}#$tag';
      case 'trojan':
        final q = _tlsTransportQuery(ob);
        final pw = Uri.encodeComponent(ob['password']?.toString() ?? '');
        return 'trojan://$pw@$host:$port?${_qs(q)}#$tag';
      case 'hysteria2':
        final q = <String, String>{};
        final tls = ob['tls'];
        if (tls is Map) {
          if (tls['server_name'] != null) q['sni'] = '${tls['server_name']}';
          if (tls['insecure'] == true) q['insecure'] = '1';
          if (tls['alpn'] is List) q['alpn'] = (tls['alpn'] as List).join(',');
        }
        final obfs = ob['obfs'];
        if (obfs is Map && obfs['type'] != null) {
          q['obfs'] = '${obfs['type']}';
          if (obfs['password'] != null) q['obfs-password'] = '${obfs['password']}';
        }
        var portPart = '$port';
        final sp = ob['server_ports'];
        if (sp is List && sp.isNotEmpty) {
          // share the hop range back as `mport` (range separator "-" not ":")
          q['mport'] = sp.map((e) => '$e'.replaceAll(':', '-')).join(',');
          portPart = '$port' == '443' ? '${sp.first}'.split(':').first : '$port';
        }
        final pw = Uri.encodeComponent(ob['password']?.toString() ?? '');
        return 'hysteria2://$pw@$host:$portPart?${_qs(q)}#$tag';
      case 'shadowsocks':
        final method = ob['method']?.toString() ?? '';
        final pw = ob['password']?.toString() ?? '';
        final userinfo =
            base64Url.encode(utf8.encode('$method:$pw')).replaceAll('=', '');
        var q = '';
        if (ob['plugin'] != null) {
          final opts = ob['plugin_opts']?.toString() ?? '';
          final pv = opts.isEmpty ? '${ob['plugin']}' : '${ob['plugin']};$opts';
          q = '?plugin=${Uri.encodeQueryComponent(pv)}';
        }
        return 'ss://$userinfo@$host:$port$q#$tag';
      default:
        return null; // vmess/tuic/etc. — available via the bundle, not a URI
    }
  }

  /// Wrap a bare IP as an `sslip.io` hostname so a self-hosted subscription URL
  /// has a name for TLS/SNI (1.2.3.4 → 1-2-3-4.sslip.io). A non-IP host is
  /// returned unchanged. IPv6 uses sslip.io's dash form.
  static String sslipHost(String host) {
    final h = host.trim();
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h)) {
      return '${h.replaceAll('.', '-')}.sslip.io';
    }
    if (h.contains(':') && RegExp(r'^[0-9a-fA-F:]+$').hasMatch(h)) {
      return '${h.replaceAll(':', '-')}.sslip.io';
    }
    return h;
  }

  // ----------------------------------------------------------- internals ------

  static Map<String, String> _tlsTransportQuery(Map<String, dynamic> ob) {
    final q = <String, String>{};
    final tls = ob['tls'];
    if (tls is Map && tls['enabled'] == true) {
      final reality = tls['reality'];
      final isReality = reality is Map && reality['enabled'] != false;
      q['security'] = isReality ? 'reality' : 'tls';
      if (tls['server_name'] != null) q['sni'] = '${tls['server_name']}';
      final utls = tls['utls'];
      if (utls is Map && utls['fingerprint'] != null) {
        q['fp'] = '${utls['fingerprint']}';
      }
      if (tls['alpn'] is List) q['alpn'] = (tls['alpn'] as List).join(',');
      if (tls['insecure'] == true) q['insecure'] = '1';
      if (isReality) {
        if (reality['public_key'] != null) q['pbk'] = '${reality['public_key']}';
        if (reality['short_id'] != null) q['sid'] = '${reality['short_id']}';
      }
    } else {
      q['security'] = 'none';
    }
    final t = ob['transport'];
    if (t is Map) {
      final tt = t['type']?.toString();
      if (tt != null) q['type'] = tt;
      if (t['path'] != null) q['path'] = '${t['path']}';
      final headers = t['headers'];
      if (headers is Map && headers['Host'] != null) {
        q['host'] = '${headers['Host']}';
      } else if (t['host'] != null) {
        q['host'] = t['host'] is List ? (t['host'] as List).join(',') : '${t['host']}';
      }
      if (t['service_name'] != null) q['serviceName'] = '${t['service_name']}';
      if (t['mode'] != null) q['mode'] = '${t['mode']}';
    } else {
      q['type'] = 'tcp';
    }
    return q;
  }

  static String _qs(Map<String, String> q) => q.entries
      .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  static String _pad(String s) {
    final m = s.length % 4;
    return m == 0 ? s : s + '=' * (4 - m);
  }

  static const _maxCompressed = 512 * 1024; // raw d= payload ceiling
  static const _maxDecompressed = 4 * 1024 * 1024; // gunzipped JSON ceiling

  /// Gunzip with a hard output ceiling — the chunked decoder is aborted the
  /// moment the produced bytes exceed [cap], so a bomb can never materialize.
  /// Throws on overflow (decodeBundle's catch turns that into a null = reject).
  static List<int> _gunzipCapped(List<int> bytes, int cap) {
    final sink = _CappedByteSink(cap);
    final conv = gzip.decoder.startChunkedConversion(sink);
    conv.add(bytes);
    conv.close();
    return sink.bytes.takeBytes();
  }
}

class _CappedByteSink extends ByteConversionSink {
  _CappedByteSink(this.cap);
  final int cap;
  final BytesBuilder bytes = BytesBuilder();

  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > cap) {
      throw const FormatException('decompressed bundle exceeds cap');
    }
    bytes.add(chunk);
  }

  @override
  void close() {}
}
