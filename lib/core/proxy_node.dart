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

  /// True if this profile disables TLS certificate validation on a node where
  /// that's a real MITM hole — surfaced as a warning badge so it's never silent.
  /// Scans BOTH a single node's outbound AND an imported config's
  /// `outbounds`/`endpoints` (the audit caught configs slipping through).
  /// Excludes:
  ///  - Reality (self-authenticates via the pinned key — `insecure` is moot), and
  ///  - Hysteria2 / TUIC (authenticate the server via password/PSK beyond the
  ///    cert, and self-signed is their norm — badging them just cries wolf).
  bool get insecure {
    bool risky(Object? o) {
      if (o is! Map) return false;
      final type = o['type']?.toString();
      if (type == 'hysteria2' || type == 'tuic') return false;
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
}
