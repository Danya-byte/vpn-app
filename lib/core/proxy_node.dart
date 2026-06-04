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
}
