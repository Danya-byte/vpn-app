import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'singbox_config.dart';

/// Minimal client for sing-box's Clash API (status + live traffic).
class ClashApi {
  ClashApi({this.host = SingBoxConfig.clashHost, this.port = SingBoxConfig.clashPort});

  final String host;
  final int port;

  // ONE reusable client for all REST calls (was a fresh HttpClient per call —
  // these fire several times a second). Localhost connects are instant, so a
  // single short connect timeout is fine; per-request deadlines use `.timeout()`.
  // Never force-closed per call (that would kill the shared pool); it lives with
  // the provider and the process.
  late final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  Uri _http(String path) => Uri.parse('http://$host:$port$path');

  // The per-launch secret guarding the Clash API. Read live (not cached) so it
  // tracks whatever the core was started with.
  String get _secret => SingBoxConfig.clashSecret;

  void _auth(HttpClientRequest req) {
    if (_secret.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_secret');
    }
  }

  /// GET /version — also serves as a readiness probe. Returns null if the core
  /// is not reachable yet.
  Future<String?> version() async {
    try {
      final req = await _client.getUrl(_http('/version'));
      _auth(req);
      final resp = await req.close().timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['version']?.toString();
    } catch (_) {
      return null;
    }
  }

  /// GET /proxies/{tag}/delay — latency in ms (null if unreachable).
  Future<int?> delay(String proxyTag) async {
    try {
      final uri = _http('/proxies/${Uri.encodeComponent(proxyTag)}/delay')
          .replace(queryParameters: {
        'timeout': '5000',
        'url': 'http://www.gstatic.com/generate_204',
      });
      final req = await _client.getUrl(uri);
      _auth(req);
      final resp = await req.close().timeout(const Duration(seconds: 7));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      return (j['delay'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// The proxy's OWN last measured delay (from its `history`) — the number the
  /// urltest already computed over a warm connection, which is what other
  /// clients display. Avoids the cold Reality handshake a forced /delay incurs
  /// (≈2× RTT), the cause of our inflated 90–100 ms vs the field's ~40 ms.
  /// Null if there's no history yet (then the caller falls back to [delay]).
  Future<int?> lastDelay(String tag) async {
    try {
      final req =
          await _client.getUrl(_http('/proxies/${Uri.encodeComponent(tag)}'));
      _auth(req);
      final resp = await req.close().timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      final j = jsonDecode(await resp.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final hist = (j['history'] as List?) ?? const [];
      if (hist.isEmpty) return null;
      final d = (hist.last as Map?)?['delay'];
      final ms = (d as num?)?.toInt();
      return (ms != null && ms > 0) ? ms : null;
    } catch (_) {
      return null;
    }
  }

  /// GET /proxies — every proxy/group with its type, current pick and members.
  Future<List<ProxyGroup>> proxies() async {
    try {
      final req = await _client.getUrl(_http('/proxies'));
      _auth(req);
      final resp = await req.close().timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return const [];
      }
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final map = (j['proxies'] as Map?) ?? const {};
      final out = <ProxyGroup>[];
      for (final e in map.values) {
        if (e is! Map) continue;
        // Warm latency straight from this poll — every proxy carries its own
        // `history` (the urltest's last measurement), so per-member pings cost
        // ZERO extra calls. Null when never measured / last probe timed out.
        final hist = (e['history'] as List?) ?? const [];
        int? delay;
        if (hist.isNotEmpty) {
          final ms = ((hist.last as Map?)?['delay'] as num?)?.toInt();
          delay = (ms != null && ms > 0) ? ms : null;
        }
        out.add(ProxyGroup(
          name: e['name'].toString(),
          type: e['type'].toString(),
          now: e['now']?.toString(),
          all: ((e['all'] as List?) ?? const [])
              .map((x) => x.toString())
              .toList(),
          delay: delay,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// PUT /proxies/{group} {name} — switch a Selector's active member.
  Future<bool> selectProxy(String group, String name) async {
    try {
      final req =
          await _client.putUrl(_http('/proxies/${Uri.encodeComponent(group)}'));
      _auth(req);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'name': name})));
      final resp = await req.close().timeout(const Duration(seconds: 3));
      await resp.drain<void>();
      return resp.statusCode == 204 || resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Streams traffic samples (bytes/sec up & down) from ws://.../traffic.
  Stream<Traffic> traffic() async* {
    final ws = await WebSocket.connect('ws://$host:$port/traffic',
        headers: _secret.isEmpty
            ? null
            : {HttpHeaders.authorizationHeader: 'Bearer $_secret'});
    try {
      await for (final raw in ws) {
        if (raw is! String) continue;
        final j = jsonDecode(raw) as Map<String, dynamic>;
        yield Traffic(
          up: (j['up'] as num?)?.toInt() ?? 0,
          down: (j['down'] as num?)?.toInt() ?? 0,
        );
      }
    } finally {
      await ws.close();
    }
  }

  /// GET /connections — active connections snapshot.
  Future<ConnectionsSnapshot?> connections() async {
    try {
      final req = await _client.getUrl(_http('/connections'));
      _auth(req);
      final resp = await req.close().timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final conns = (((j['connections'] as List?) ?? const [])).map((e) {
        final m = (e['metadata'] as Map?) ?? const {};
        final host = (m['host'] as String?)?.isNotEmpty == true
            ? m['host'] as String
            : '${m['destinationIP'] ?? ''}:${m['destinationPort'] ?? ''}';
        final chain = (((e['chains'] as List?) ?? const []))
            .map((c) => c.toString())
            .toList()
            .reversed
            .join(' → ');
        return ClashConnection(
          host: host,
          network: (m['network'] ?? '').toString(),
          chain: chain,
          rule: (e['rule'] ?? '').toString(),
          upload: (e['upload'] as num?)?.toInt() ?? 0,
          download: (e['download'] as num?)?.toInt() ?? 0,
        );
      }).toList();
      return ConnectionsSnapshot(
        connections: conns,
        uploadTotal: (j['uploadTotal'] as num?)?.toInt() ?? 0,
        downloadTotal: (j['downloadTotal'] as num?)?.toInt() ?? 0,
        memory: (j['memory'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

class ClashConnection {
  const ClashConnection({
    required this.host,
    required this.network,
    required this.chain,
    required this.rule,
    required this.upload,
    required this.download,
  });

  final String host;
  final String network;
  final String chain;
  final String rule;
  final int upload;
  final int download;
}

class ConnectionsSnapshot {
  const ConnectionsSnapshot({
    required this.connections,
    required this.uploadTotal,
    required this.downloadTotal,
    required this.memory,
  });

  final List<ClashConnection> connections;
  final int uploadTotal;
  final int downloadTotal;
  final int memory;

  static const ConnectionsSnapshot empty = ConnectionsSnapshot(
    connections: [],
    uploadTotal: 0,
    downloadTotal: 0,
    memory: 0,
  );
}

class Traffic {
  const Traffic({required this.up, required this.down});

  final int up;
  final int down;

  static const Traffic zero = Traffic(up: 0, down: 0);
}

/// A Clash proxy group: its kind (Selector / URLTest / …), the member it's
/// currently using, and all selectable members.
class ProxyGroup {
  const ProxyGroup({
    required this.name,
    required this.type,
    required this.now,
    required this.all,
    this.delay,
    this.memberDelays = const {},
  });

  final String name;
  final String type;
  final String? now;
  final List<String> all;
  final int? delay; // warm last-measured latency (ms) from /proxies history
  // Warm latency of THIS group's members, keyed by member TAG (built from the same
  // /proxies poll that the leaf nodes also appear in — so the pool-health chip can
  // look up `memberDelays[memberTag]` instead of the group name, which is always
  // null for members). Empty until enriched by proxyGroupsProvider.
  final Map<String, int?> memberDelays;

  ProxyGroup withMemberDelays(Map<String, int?> d) => ProxyGroup(
      name: name, type: type, now: now, all: all, delay: delay, memberDelays: d);
}
