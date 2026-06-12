import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'censorship_facts.dart';
import 'core_controller.dart';
import 'singbox_config.dart';

/// DEV-ONLY preview switch: force a fake "update available" so the Home banner and
/// the Settings → About row can be seen in a debug build without a real newer
/// release. Has NO effect in release (the kDebugMode guard). Set back to false
/// when done previewing.
const _debugForceUpdate = false;

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
  if (kDebugMode && _debugForceUpdate) {
    return const UpdateInfo(version: 'v1.0.4', url: _releasesPage);
  }
  final on = ref.watch(
      coreControllerProvider.select((s) => s.status == CoreStatus.running));
  if (!on) return null; // only meaningful with a working tunnel
  try {
    final tag = await _latestTag();
    // A non-null tag is AUTHORITATIVE: GitHub answered, so trust it and stop —
    // never let the (lower-trust) facts feed override a real "up to date". Only a
    // null tag (non-200 / missing tag_name, i.e. GitHub unreachable or unusable)
    // falls through to the feed fallback.
    if (tag != null) {
      return isNewerVersion(tag, _currentVersion)
          ? UpdateInfo(version: tag, url: _releasesPage)
          : null;
    }
  } catch (_) {
    // network/parse failure -> fall through to the feed fallback below
  }
  // Fallback when GitHub is blocked even through the tunnel: the data-only,
  // clamped facts feed still gets through and can carry the newest version.
  // NOTIFY ONLY — the user is sent to the signed release page; nothing is ever
  // auto-downloaded or run (that would be the MITM vector this app guards against).
  final feedV = CensorshipFacts.active.latestVersion;
  if (feedV.isNotEmpty && isNewerVersion(feedV, _currentVersion)) {
    return UpdateInfo(version: feedV, url: _releasesPage);
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
