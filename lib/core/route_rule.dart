import 'dart:io' show InternetAddress, InternetAddressType;

/// A user-defined routing rule — "this destination → proxy / direct / block".
/// Competitor parity (Throne, Karing "custom rule groups", v2rayN routing,
/// Hiddify): all majors let the user force specific domains/IPs; we previously
/// only had smart/global. Emitted into the sing-box route.rules ABOVE the geo
/// rules (so a user rule wins) but BELOW DNS-hijack (so DNS still resolves) —
/// see [SingBoxConfig.applyCustomRules]. Kept FFI-free so tools/tests import it.
enum RuleField {
  domainSuffix, // matches the host and any sub-host (e.g. "openai.com")
  domain, // exact host only
  ipCidr, // an IP or CIDR (e.g. "1.2.3.4" or "10.0.0.0/8")
}

enum RuleAction {
  proxy, // force THROUGH the tunnel (route final)
  direct, // force OUTSIDE the tunnel
  block, // reject (drop)
}

class RouteRule {
  const RouteRule({
    required this.field,
    required this.value,
    required this.action,
  });

  final RuleField field;
  final String value;
  final RuleAction action;

  /// The sing-box `rule_set`/match KEY for [field].
  String get matchKey => switch (field) {
        RuleField.domainSuffix => 'domain_suffix',
        RuleField.domain => 'domain',
        RuleField.ipCidr => 'ip_cidr',
      };

  bool get isIp => field == RuleField.ipCidr;

  Map<String, dynamic> toJson() => {
        'field': field.name,
        'value': value,
        'action': action.name,
      };

  // ── Shared validation (single source of truth for the UI editor AND the
  // config emitter, so they can never disagree — a value the UI accepts is
  // exactly a value the core will accept, and vice-versa). ──────────────────

  /// Normalise a raw value: strip control chars + whitespace; lowercase a host
  /// (DNS is case-insensitive, and sing-box lowercases the SNIFFED host before
  /// matching, so an uppercase rule pattern would silently NEVER fire). IPs are
  /// left as-is (parsed case-insensitively).
  static String cleanValue(RuleField field, String raw) {
    // Strip control chars (injection guard) + trim the ends. Internal whitespace
    // is KEPT so a typo like "has space.com" FAILS validation (and the user is
    // told) instead of being silently mangled into a wrong host.
    final s = raw.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
    return field == RuleField.ipCidr ? s : s.toLowerCase();
  }

  static final RegExp _hostRe = RegExp(
      r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$');

  /// Is [raw] a usable value for [field]? Rejects what the core would FATAL on
  /// (a typo'd CIDR like `1.2.3.4/33` or `1.2.3`, a bad IPv6) or silently never
  /// match (a wildcard `*.x`, a URL `https://x`, a bare label `localhost`). The
  /// IP path parses with [InternetAddress] + a real prefix range — the old loose
  /// regex let `/33`, `1.2.3`, `999.999.999.999`, `deadbeef` through.
  static bool isValidValue(RuleField field, String raw) {
    final s = cleanValue(field, raw);
    if (s.isEmpty) return false;
    if (field == RuleField.ipCidr) {
      final slash = s.indexOf('/');
      final host = slash < 0 ? s : s.substring(0, slash);
      if (!_validIp(host)) return false;
      if (slash < 0) return true;
      // The prefix bits must be CANONICAL the way Go's netip.ParsePrefix demands:
      // no leading zero ("/01", "/00"), no sign, no whitespace ("/ 24"). Dart's
      // int.tryParse accepts all three, but each makes sing-box FATAL
      // ("bad bits after slash") and the whole tunnel fails to start — the same
      // class as the leading-zero octet, on the other side of the slash.
      final bits = s.substring(slash + 1);
      if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(bits)) return false;
      // tryParse, NOT parse: a canonical-looking but absurdly long digit run
      // ("/99999999999999999999") overflows int.parse into a FormatException,
      // which would escape through fromJson's lazy map at settings load and hit
      // the blanket catch → EVERY setting silently reset. Max valid is 3 digits.
      if (bits.length > 3) return false;
      final pfx = int.tryParse(bits);
      if (pfx == null) return false;
      final max = host.contains(':') ? 128 : 32;
      return pfx >= 0 && pfx <= max;
    }
    return s.length <= 253 && _hostRe.hasMatch(s);
  }

  // STRICT IP check — don't trust the platform parser's leniency (some accept
  // "1.2.3" as 1.2.0.3, which sing-box then FATALs on). IPv4 = exactly 4 octets
  // 0-255; IPv6 via the parser (which is strict for v6).
  static bool _validIp(String h) {
    if (h.contains(':')) {
      final a = InternetAddress.tryParse(h);
      return a != null && a.type == InternetAddressType.IPv6;
    }
    final parts = h.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      if (p.isEmpty || p.length > 3) return false;
      // DIGITS ONLY: int.tryParse accepts a leading sign ('+1', '-1') and the
      // platform would emit "+1.2.3.4" into ip_cidr, which Go's netip.ParseAddr
      // (sing-box) FATALs on — taking the whole tunnel down at startup.
      for (final c in p.codeUnits) {
        if (c < 0x30 || c > 0x39) return false;
      }
      // Reject leading-zero octets ("01", "00"): Go's netip.ParseAddr also FATALs
      // on them ("octet with leading zero").
      if (p.length > 1 && p[0] == '0') return false;
      final n = int.tryParse(p);
      if (n == null || n > 255) return false; // n >= 0 guaranteed (digits-only)
    }
    return true;
  }

  static RouteRule? fromJson(Object? j) {
    if (j is! Map) return null;
    // Explicit String guards on field/action (not just value): the .name ==
    // comparison happens to not throw on a non-String, but guard anyway so a
    // future switch to enum.byName() (which DOES throw) can't bubble a TypeError
    // through SettingsController.build() and reset every setting.
    final fn = j['field'], an = j['action'];
    if (fn is! String || an is! String) return null;
    final f = RuleField.values
        .where((e) => e.name == fn)
        .cast<RuleField?>()
        .firstWhere((_) => true, orElse: () => null);
    final a = RuleAction.values
        .where((e) => e.name == an)
        .cast<RuleAction?>()
        .firstWhere((_) => true, orElse: () => null);
    // NON-throwing on a non-String value: a corrupt / hand-edited / future-version
    // entry must yield null (this ONE rule is then dropped by the caller's
    // whereType) — NEVER a TypeError, which would bubble through
    // SettingsController.build()'s catch and silently RESET EVERY setting (the
    // store-wipe class this app fights). Normalise via cleanValue so a value
    // arriving from WebDAV restore / a synced settings.json matches what the
    // editor stores (case/whitespace) → dedup + display stay consistent.
    final raw = j['value'];
    if (f == null || a == null || raw is! String) return null;
    // VALIDATE, not just non-empty: applyCustomRules silently DROPS any value that
    // fails isValidValue (bad CIDR like 1.2.3.4/33, malformed host). Loading such a
    // value from a hand-edited settings.json or a WebDAV restore would show a chip
    // that never applies — a phantom block/force rule. Reject it here so load == emit
    // (and matches the editor's own input gate).
    if (!isValidValue(f, raw)) return null;
    return RouteRule(field: f, value: cleanValue(f, raw), action: a);
  }
}
