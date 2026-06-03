/// Parsed `Subscription-Userinfo` HTTP header that proxy panels (Marzban, 3x-ui,
/// Hiddify, x-ui, …) return on a subscription URL — used/total traffic + expiry.
/// Example: `upload=1234; download=5678; total=107374182400; expire=1767139200`.
class SubInfo {
  const SubInfo({
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
  });

  final int upload; // bytes
  final int download; // bytes
  final int total; // bytes quota (0 = unlimited/unknown)
  final int expire; // unix seconds (0 = none)

  int get used => upload + download;
  int get remaining => total > 0 ? (total - used).clamp(0, total) : 0;
  bool get hasTraffic => total > 0;
  bool get hasExpiry => expire > 0;

  DateTime? get expiryDate =>
      expire > 0 ? DateTime.fromMillisecondsSinceEpoch(expire * 1000) : null;

  /// Whole days until expiry relative to [now] (negative if already expired).
  int? daysLeft(DateTime now) {
    final d = expiryDate;
    if (d == null) return null;
    return (d.difference(now).inHours / 24).ceil();
  }

  bool get isEmpty => total == 0 && expire == 0 && used == 0;

  static SubInfo? parse(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final m = <String, int>{};
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final k = part.substring(0, eq).trim().toLowerCase();
      final v = int.tryParse(part.substring(eq + 1).trim());
      if (v != null) m[k] = v;
    }
    if (m.isEmpty) return null;
    final info = SubInfo(
      upload: m['upload'] ?? 0,
      download: m['download'] ?? 0,
      total: m['total'] ?? 0,
      expire: m['expire'] ?? 0,
    );
    return info.isEmpty ? null : info;
  }

  Map<String, dynamic> toJson() =>
      {'upload': upload, 'download': download, 'total': total, 'expire': expire};

  static SubInfo fromJson(Map j) => SubInfo(
        upload: (j['upload'] as num?)?.toInt() ?? 0,
        download: (j['download'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        expire: (j['expire'] as num?)?.toInt() ?? 0,
      );
}
