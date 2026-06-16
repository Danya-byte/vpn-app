import 'dart:convert';

/// A proxy profile: either a single node (one sing-box outbound) or a full
/// sing-box config imported to run as-is.
class ParsedNode {
  ParsedNode({
    required this.tag,
    required this.outbound,
    this.config,
    this.source,
  });

  /// Display name and (for node profiles) the outbound's `tag`.
  final String tag;

  /// Ready-to-embed sing-box outbound (e.g. `{"type": "vless", ...}`).
  /// Empty for config profiles.
  final Map<String, dynamic> outbound;

  /// When set, this profile is a full sing-box config to run whole, not a node.
  final Map<String, dynamic>? config;

  /// Subscription URL this profile was imported from (for refresh), if any.
  final String? source;

  bool get isConfig => config != null;

  String get type => isConfig
      ? 'sing-box config'
      : (outbound['type']?.toString() ?? 'unknown');

  /// True if this profile disables TLS certificate validation where that's a real
  /// MITM hole — surfaced as a warning badge + a connect-consent so it's never
  /// silent. Scans a single node's outbound AND an imported config's
  /// `outbounds`/`endpoints`. Excludes ONLY Reality (it self-authenticates via the
  /// pinned key, so `insecure` is moot). Hysteria2/TUIC are NOT excluded: their
  /// password authenticates the CLIENT to the server, NOT the server to the
  /// client — so `tls.insecure` still turns off SERVER authentication and is
  /// MITM-able by an on-path attacker (= the ТСПУ operator). The auto-failover
  /// cascade keeps using them (its own list excludes QUIC); this only flags +
  /// gates a MANUAL connect.
  bool get insecure {
    bool risky(Object? o) {
      if (o is! Map) return false;
      final tls = o['tls'];
      return tls is Map && tls['insecure'] == true && tls['reality'] == null;
    }

    if (!isConfig) return risky(outbound);
    // A config hides TLS under outbounds and (WG/Tailscale) endpoints.
    for (final key in const ['outbounds', 'endpoints']) {
      for (final o in (config?[key] as List?) ?? const []) {
        if (risky(o)) return true;
      }
    }
    return false;
  }

  /// True if a TLS block PINS the server certificate (a non-empty `certificate`),
  /// so a self-signed / private-CA server is verified against THAT exact cert
  /// instead of blindly trusted — the secure alternative to [insecure] that
  /// sing-box honours (verified: hysteria2 + tuic accept an inline PEM with
  /// `insecure:false`). A pinned node sets `insecure:false`, so it never trips the
  /// [insecure] badge.
  bool get pinned {
    bool hasCert(Object? o) {
      if (o is! Map) return false;
      final tls = o['tls'];
      if (tls is! Map) return false;
      final c = tls['certificate'];
      return (c is String && c.trim().isNotEmpty) || (c is List && c.isNotEmpty);
    }

    if (!isConfig) return hasCert(outbound);
    for (final key in const ['outbounds', 'endpoints']) {
      for (final o in (config?[key] as List?) ?? const []) {
        if (hasCert(o)) return true;
      }
    }
    return false;
  }

  /// A STABLE per-server key for the insecure-MITM-consent memory — content-based,
  /// NOT the user-renameable / attacker-controlled display [tag]. A subscription
  /// that rotates the exit server behind the same name, or a re-import under a new
  /// tag, yields a DIFFERENT key → the consent is re-asked instead of silently
  /// inherited (audit #11). Simple nodes: `type://server:port` (port-hopping
  /// hysteria2 carries `server_ports` instead of `server_port` — include the range
  /// so two same-host pools don't collide into one consent). Configs: the sorted
  /// `server:port` set of the INSECURE outbounds only — keying on every server let
  /// the risky flag silently MOVE to another server in the same set without
  /// re-asking (the consent must track the MITM-able endpoint, not the roster).
  String get insecureKey {
    String portOf(Map o) {
      final p = o['server_port'];
      if (p != null) return '$p';
      final sp = o['server_ports'];
      if (sp is List && sp.isNotEmpty) return sp.map((e) => '$e').join('|');
      return '';
    }

    if (!isConfig) {
      return '${outbound['type'] ?? ''}://'
          '${outbound['server'] ?? ''}:${portOf(outbound)}';
    }
    bool risky(Map o) {
      final tls = o['tls'];
      return tls is Map && tls['insecure'] == true && tls['reality'] == null;
    }

    final servers = <String>{};
    for (final key in const ['outbounds', 'endpoints']) {
      for (final o in (config?[key] as List?) ?? const []) {
        if (o is Map && o['server'] != null && risky(o)) {
          servers.add('${o['server']}:${portOf(o)}');
        }
      }
    }
    final list = servers.toList()..sort();
    // No risky outbound carries a server (rare: e.g. insecure under an endpoint
    // shape we don't recognize) → fall back to a CONTENT hash, never the display
    // tag: the tag is user-renameable / attacker-controlled, which would let a
    // re-import inherit (or dodge) the consent by name alone.
    return list.isEmpty
        ? 'config:#${_fnv1a(jsonEncode(config))}'
        : 'config:${list.join(',')}';
  }

  // FNV-1a 32-bit over the canonical-ish JSON — deterministic across runs/VMs
  // (String.hashCode isn't guaranteed stable), no crypto dependency needed for a
  // consent-memory key.
  static int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }
}
