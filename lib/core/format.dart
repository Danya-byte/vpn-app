String fmtRate(int bytesPerSec) {
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  double v = bytesPerSec.toDouble();
  int u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}

/// Clean a raw exception for display: strip the `SocketException:` /
/// `Exception:` type prefix and the `(OS Error: …, errno = …)` tail, then cap
/// the length — so a toast shows a human line, not `Instance of` noise. Language-
/// neutral (keeps whatever message the exception carries) so it fits any locale.
String friendlyError(Object e) {
  var s = e.toString().trim();
  s = s.replaceFirst(
      RegExp(r'^(Socket|Http|Timeout|Format|FileSystem)?Exception:?\s*'), '');
  s = s.replaceFirst(RegExp(r'\s*\(OS Error:.*$'), '').trim();
  if (s.isEmpty) return e.runtimeType.toString();
  return s.length <= 140 ? s : '${s.substring(0, 140)}…';
}

String fmtBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${units[u]}';
}
