import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_controller.dart';
import 'singbox_config.dart';

/// A newer release than the running build.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.url});
  final String version;
  final String url;
}

const _currentVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
const _releasesApi =
    'https://api.github.com/repos/Danya-byte/vpn-app/releases/latest';
const _releasesPage = 'https://github.com/Danya-byte/vpn-app/releases/latest';

/// Checks GitHub for a newer release — **through the tunnel** when connected,
/// since github is blocked on the direct path in RF (so a stale-build user only
/// learns about a fix once they're connected, which is exactly when they can
/// download it). Returns null when up to date, disconnected, or unreachable.
final updateProvider = FutureProvider<UpdateInfo?>((ref) async {
  final on = ref.watch(
      coreControllerProvider.select((s) => s.status == CoreStatus.running));
  if (!on) return null; // only meaningful with a working tunnel
  try {
    final tag = await _latestTag();
    if (tag != null && isNewerVersion(tag, _currentVersion)) {
      return UpdateInfo(version: tag, url: _releasesPage);
    }
  } catch (_) {
    // network/parse failure -> treat as "no update info"
  }
  return null;
});

Future<String?> _latestTag() async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..findProxy = (_) =>
        'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
  try {
    final req = await client.getUrl(Uri.parse(_releasesApi));
    req.headers.set(HttpHeaders.userAgentHeader, 'vpn-app');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final j = jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    return j['tag_name']?.toString();
  } finally {
    client.close(force: true);
  }
}

/// True if dotted version [a] is newer than [b] (ignoring a leading `v` and any
/// `+build`/`-pre` suffix). Pure + unit-tested.
bool isNewerVersion(String a, String b) {
  List<int> parse(String s) => s
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split(RegExp(r'[+-]')) // drop build/pre-release metadata (semver: ignored)
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final pa = parse(a), pb = parse(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
