import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics.dart';
import 'proxy_node.dart';

/// Pre-connect latency probe: measures a TCP-connect round-trip to each node's
/// `server:port` WITHOUT bringing the tunnel up, so the user can see which servers
/// are reachable + fast BEFORE choosing one. FFI-free (pure `dart:io` + the shared
/// DoH resolver) so tools + tests import it.
///
/// HONEST SCOPE: a TCP connect measures the path to the server's TCP port — for
/// TCP transports (VLESS / Reality / Trojan / VMess / Shadowsocks / XHTTP). It is
/// NOT meaningful for UDP transports (Hysteria2 / TUIC / WireGuard) — a TCP SYN to
/// a UDP-only port draws no SYN-ACK — so those are flagged [udp] and a failed probe
/// is shown as "UDP" (unmeasured), never as "blocked".
///
/// RF-SAFE: a node's `server` is often a HOSTNAME, and pre-connect the OS uses the
/// operator's (poisonable) resolver — a poisoned A record points at a ТСПУ
/// blockpage IP that answers a SYN in milliseconds, which would paint a DEAD server
/// fast+green. So a hostname is resolved via DoH first (1.1.1.1) and the probe
/// dials the RESOLVED IP; if DoH itself can't resolve (blocked too), the result is
/// marked UNVERIFIED rather than trusting the system resolver. A reachable TCP port
/// also doesn't prove the DPI lets the real handshake through — first-order signal,
/// not a connectivity oracle.
const _udpTransports = {'hysteria2', 'tuic', 'wireguard'};

bool isUdpTransport(String type) => _udpTransports.contains(type.toLowerCase());

({String host, int port, bool udp})? _endpointOf(Map o) {
  final type = o['type']?.toString() ?? '';
  var host = o['server']?.toString();
  var port = _portOf(o);
  // WireGuard / AmneziaWG endpoints carry the host under peers[].address, not a
  // top-level server (so they'd otherwise never get a chip).
  if ((host == null || host.isEmpty) && type == 'wireguard') {
    final peers = o['peers'];
    if (peers is List && peers.isNotEmpty && peers.first is Map) {
      final p = peers.first as Map;
      host = p['address']?.toString();
      port = p['port'] is int ? p['port'] as int : int.tryParse('${p['port']}');
    }
  }
  if (host == null || host.isEmpty || port == null) return null;
  return (host: host, port: port, udp: isUdpTransport(type));
}

const _proxyTypes = {
  'vless', 'vmess', 'trojan', 'hysteria2', 'tuic', 'shadowsocks',
  'shadowtls', 'anytls', 'socks', 'http', 'wireguard',
};

/// EVERY probeable `server:port` of [n] — one for a simple node, ALL proxy exits
/// for a config — so a multi-exit config is measured across all its servers and the
/// chip shows the BEST, not just the first listed exit. Empty when none can be
/// determined (a config whose exits are all chained/bridged with no direct server).
List<({String host, int port, bool udp})> nodeEndpoints(ParsedNode n) {
  if (!n.isConfig) {
    final e = _endpointOf(n.outbound);
    return e == null ? const [] : [e];
  }
  final out = <({String host, int port, bool udp})>[];
  for (final key in const ['outbounds', 'endpoints']) {
    for (final o in (n.config?[key] as List?) ?? const []) {
      if (o is Map && _proxyTypes.contains(o['type']?.toString())) {
        final e = _endpointOf(o);
        if (e != null) out.add(e);
      }
    }
  }
  return out;
}

/// The single REPRESENTATIVE endpoint (for the chip's UDP label + back-compat):
/// prefer a measurable TCP exit, else the first UDP. Null when none.
({String host, int port, bool udp})? nodeEndpoint(ParsedNode n) {
  final eps = nodeEndpoints(n);
  for (final e in eps) {
    if (!e.udp) return e; // a measurable TCP exit
  }
  return eps.isEmpty ? null : eps.first;
}

int? _portOf(Map o) {
  final p = o['server_port'];
  if (p is int) return p;
  if (p is String) return int.tryParse(p);
  // Hysteria2 port-hopping carries server_ports (["443:8443", ...]) instead of a
  // single port — probe the first port of the first range.
  final sp = o['server_ports'];
  if (sp is List && sp.isNotEmpty) {
    final first = sp.first.toString().split(RegExp(r'[:\-]')).first;
    return int.tryParse(first);
  }
  return null;
}

/// Measure one TCP connect-time to [host]:[port]. Returns the round-trip in
/// milliseconds, or null if the connection was refused, timed out, or failed.
/// [host] should be a literal IP (the caller resolves hostnames via DoH first). A
/// generous timeout — a slow-but-alive foreign server on a congested RF mobile
/// uplink must not be mislabelled "blocked" just for answering in >3s.
Future<int?> tcpPing(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 7),
}) async {
  // Best-of-2: a single cold-SYN loss on a jittery RF-mobile uplink must NOT paint a
  // working Reality/VLESS server red "blocked". The retry uses a shorter budget (the
  // first attempt already established the path is reachable-but-slow). A genuinely
  // dead/blocked server fails BOTH → null → red.
  for (var attempt = 0; attempt < 2; attempt++) {
    final ms = await _connectOnce(
        host, port, attempt == 0 ? timeout : const Duration(seconds: 4));
    if (ms != null) return ms;
  }
  return null;
}

Future<int?> _connectOnce(String host, int port, Duration timeout) async {
  final sw = Stopwatch()..start();
  Socket? sock;
  try {
    sock = await Socket.connect(host, port, timeout: timeout);
    sw.stop();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  } finally {
    sock?.destroy();
  }
}

/// Per-tag probe state: [results] maps a node tag to its last measured latency
/// (ms), or null when it was unreachable; [measuring] holds tags being probed
/// right now (spinner); [unverified] holds tags whose hostname could not be
/// safely resolved via DoH (shown as "?" — neither trusted-fast nor trusted-
/// blocked, because the operator resolver can't be trusted pre-connect).
class LatencyState {
  const LatencyState({
    this.results = const {},
    this.measuring = const {},
    this.unverified = const {},
  });

  final Map<String, int?> results;
  final Set<String> measuring;
  final Set<String> unverified;

  bool measured(String tag) => results.containsKey(tag);
  bool isMeasuring(String tag) => measuring.contains(tag);
  bool isUnverified(String tag) => unverified.contains(tag);

  LatencyState copyWith({
    Map<String, int?>? results,
    Set<String>? measuring,
    Set<String>? unverified,
  }) =>
      LatencyState(
        results: results ?? this.results,
        measuring: measuring ?? this.measuring,
        unverified: unverified ?? this.unverified,
      );
}

class LatencyProbe extends Notifier<LatencyState> {
  @override
  LatencyState build() => const LatencyState();

  /// Probe every node with a determinable endpoint, in a bounded-concurrency pool.
  /// A hostname is resolved over DoH first (never the poisonable system resolver);
  /// if DoH can't resolve it, the tag is marked unverified instead of dialing a
  /// possibly-poisoned IP. UDP transports are never dialed (a TCP probe can't
  /// measure them). [abort] (e.g. "is the tunnel now up?") is checked before each
  /// dial so an in-flight burst stops the moment a connect would start leaking the
  /// real IP around the tunnel. Results stream in as each probe completes.
  Future<void> measureAll(List<ParsedNode> nodes, {bool Function()? abort}) async {
    final targets = <String, List<({String host, int port, bool udp})>>{};
    for (final n in nodes) {
      final eps = nodeEndpoints(n);
      if (eps.isNotEmpty) targets[n.tag] = eps;
    }
    if (targets.isEmpty) return;
    state = state.copyWith(measuring: {...state.measuring, ...targets.keys});

    const maxConcurrent = 8;
    final queue = targets.entries.toList();
    var next = 0;
    // Each read-modify-write of `state` runs synchronously between awaits, so the
    // single-threaded event loop makes these concurrent updates lossless.
    Future<void> worker() async {
      while (next < queue.length) {
        final entry = queue[next++];
        final tag = entry.key;
        final eps = entry.value;
        // ABORT in-flight: if the tunnel came up mid-probe, stop dialing — a raw
        // TCP SYN would now leak the real IP around a system-proxy tunnel.
        if (abort?.call() ?? false) {
          state = state.copyWith(measuring: {...state.measuring}..remove(tag));
          continue;
        }
        // Probe EVERY TCP exit of this node/config; the chip shows the BEST (min) —
        // a multi-exit config reads its fastest REACHABLE server, not the first one.
        int? best;
        var anyTcp = false; // at least one non-UDP exit exists
        var anyResolved = false; // ...and at least one got an IP to dial
        for (final ep in eps) {
          // UDP can't be TCP-probed (handled by the chip's "UDP" label).
          if (ep.udp) continue;
          anyTcp = true;
          if (abort?.call() ?? false) break;
          String? ip;
          if (InternetAddress.tryParse(ep.host) != null) {
            ip = ep.host; // already a literal
          } else {
            final ips = await Diagnostics.doh(ep.host);
            if (ips.isNotEmpty) ip = ips.first;
          }
          if (ip != null) {
            anyResolved = true;
            final ms = await tcpPing(ip, ep.port);
            final b = best;
            if (ms != null && (b == null || ms < b)) best = ms;
          }
        }
        // Unverified only if there WERE TCP exits but DoH resolved NONE of them (a
        // poisonable result we won't trust). All-UDP → not unverified ("UDP" via the
        // chip's representative endpoint).
        final verified = !anyTcp || anyResolved;
        final measuring = {...state.measuring}..remove(tag);
        final unverified = {...state.unverified};
        if (verified) {
          unverified.remove(tag);
        } else {
          unverified.add(tag);
        }
        state = state.copyWith(
          results: {...state.results, tag: best},
          measuring: measuring,
          unverified: unverified,
        );
      }
    }

    await Future.wait([for (var i = 0; i < maxConcurrent; i++) worker()]);
  }

  void clear() => state = const LatencyState();

  /// Drop a tag's measurement — call when its node is deleted, so a later node that
  /// REUSES the same display tag doesn't inherit the deleted node's stale chip.
  void forget(String tag) {
    if (!state.results.containsKey(tag) &&
        !state.measuring.contains(tag) &&
        !state.unverified.contains(tag)) {
      return;
    }
    state = state.copyWith(
      results: {...state.results}..remove(tag),
      measuring: {...state.measuring}..remove(tag),
      unverified: {...state.unverified}..remove(tag),
    );
  }
}

final latencyProbeProvider =
    NotifierProvider<LatencyProbe, LatencyState>(LatencyProbe.new);
