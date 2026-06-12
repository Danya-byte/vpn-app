import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;

/// Resolves on-disk locations for the bundled core binaries and the writable
/// runtime directory (generated config + logs).
class CorePaths {
  /// A DEBUG build runs as an ISOLATED "dev instance": its own store sub-folder
  /// (`run_dev` not `run`) plus a distinct native mutex + window title, so a
  /// freshly-built dev copy can run ALONGSIDE an installed release build without
  /// fighting over the shared store / single-instance lock. Never true in tests
  /// (they pin [overrideRuntimeDir], which wins) or in a release build.
  static bool get _devInstance =>
      kDebugMode && Platform.environment['FLUTTER_TEST'] != 'true';

  static String get _runSubdir => _devInstance ? 'run_dev' : 'run';

  /// One-time convenience: copy the installed RELEASE build's profiles into the
  /// dev sandbox so a dev build has the user's real servers to test with, instead
  /// of starting empty. No-op in release/tests, and never overwrites an existing
  /// dev store. Settings/flags are NOT copied (so the dev build can't inherit a
  /// TUN/auto-connect state that would fight the running release client).
  static void seedDevInstanceFromRelease() {
    if (!_devInstance) return;
    try {
      final dev = runtimeDir(); // .../vpn_app/run_dev
      final sep = Platform.pathSeparator;
      final devProfiles = File('${dev.path}${sep}profiles.json');
      if (devProfiles.existsSync()) return; // already seeded / has its own
      final rel = File('${dev.parent.path}${sep}run${sep}profiles.json');
      if (rel.existsSync()) devProfiles.writeAsStringSync(rel.readAsStringSync());
    } catch (_) {}
  }
  /// Write [text] to [path] atomically: write a temp file, flush, then rename
  /// over the target (rename is atomic on NTFS). A crash/power-loss can no
  /// longer leave a truncated/half-written file that bricks the profile store.
  ///
  /// On Windows, `MoveFile` fails if another handle (antivirus, the search
  /// indexer, a backup agent) has the target open — even for read. Rather than
  /// let that bubble up and silently lose the save, fall back to an in-place
  /// write (which opens with sharing and usually succeeds).
  static void atomicWrite(String path, String text) {
    final tmp = File('$path.tmp');
    try {
      final raf = tmp.openSync(mode: FileMode.write);
      try {
        raf.writeStringSync(text);
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      tmp.renameSync(path); // atomic on NTFS
      return;
    } catch (_) {
      // temp write or rename failed (e.g. target locked) — fall through.
    }
    File(path).writeAsStringSync(text); // non-atomic fallback, never silent-loss
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
  }

  /// Absolute path to sing-box.exe, searching dev and bundled layouts.
  static String singBox() => _resolveBinary('sing-box.exe');

  /// Absolute path to xray.exe (the XHTTP/Reality-XTLS bridge core), if bundled.
  static String xray() => _resolveBinary('xray.exe');

  /// The AmneziaWG userspace bridge (wireproxy-amnezia) — fetched separately,
  /// like xray. Present → [CoreController._bridgeAmnezia] rides AmneziaWG.
  static String awg() => _resolveBinary('awg.exe');

  /// The zapret WinDivert desync sidecar (winws.exe) — fetched separately, like
  /// xray. Present + admin → [CoreController._spawnDesyncEngine] runs the
  /// server-less TLS-DPI bypass. (WinDivert.dll / WinDivert64.sys live beside it.)
  static String winws() => _resolveBinary('winws.exe');

  /// Absolute path to the bundled rule-sets dir (geoip-ru.srs, …). Bundled
  /// locally so startup never blocks on a (RF-blocked) github download.
  static String ruleSetsDir() {
    final candidates = <String>[
      // bundled: next to the app executable — checked FIRST so a planted
      // `core/` in an arbitrary CWD can never shadow the shipped rule-sets.
      _join([
        File(Platform.resolvedExecutable).parent.path,
        'core',
        'rule-sets',
      ]),
      // dev: `flutter run` from the project root
      _join([Directory.current.path, 'core', 'rule-sets']),
    ];
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      candidates.add(_join([dir.path, 'core', 'rule-sets']));
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    for (final c in candidates) {
      if (Directory(c).existsSync()) return c;
    }
    return candidates.first;
  }

  static String _resolveBinary(String name) {
    final candidates = <String>[
      // bundled: next to the app executable — checked FIRST. We spawn this as a
      // child process, so an attacker-planted `core\windows\<name>` in the
      // launch CWD must NEVER win over the binary shipped beside our exe.
      _join([
        File(Platform.resolvedExecutable).parent.path,
        'core',
        'windows',
        name,
      ]),
      // dev: `flutter run` from the project root
      _join([Directory.current.path, 'core', 'windows', name]),
    ];
    // walk up from CWD looking for core/windows/<name> (dev fallback only)
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      candidates.add(_join([dir.path, 'core', 'windows', name]));
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    // fall back to the first candidate (surfaces a clear error on launch)
    return candidates.first;
  }

  /// Writable dir for generated config + logs: %LOCALAPPDATA%\vpn_app\run
  /// Tests point this at a temp dir so a constructed [CoreController] never reads
  /// or writes the real %LOCALAPPDATA% store / flags (the "flutter test wiped my
  /// profiles" incident). Null in production.
  static String? overrideRuntimeDir;

  static Directory runtimeDir() {
    final ov = overrideRuntimeDir;
    if (ov != null) {
      final d = Directory(ov);
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    }
    // NOTE: an env-var redirect (VPN_APP_RUNTIME_DIR) was REMOVED here: nothing in
    // the app ever set it, and an ambient OS variable silently relocating the
    // security-critical store (profiles/settings/flags) — inherited even by the
    // elevated relaunch — is exactly the store-hijack class this app guards
    // against. Tests/tools isolate via [overrideRuntimeDir] instead.
    final bases = <String>[
      if (Platform.environment['LOCALAPPDATA'] != null)
        Platform.environment['LOCALAPPDATA']!,
      if (Platform.environment['TEMP'] != null) Platform.environment['TEMP']!,
      Directory.systemTemp.path,
    ];
    // Try each writable base in turn; a locked-down/kiosk box may deny the first.
    for (final base in bases) {
      try {
        final dir = Directory(_join([base, 'vpn_app', _runSubdir]));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        return dir;
      } catch (_) {
        // try the next base
      }
    }
    // Last resort: a unique temp dir (better than throwing out of a UI handler).
    return Directory.systemTemp.createTempSync('vpn_app_run');
  }

  static String configFile() => _join([runtimeDir().path, 'config.run.json']);

  static String _join(List<String> parts) => parts.join(Platform.pathSeparator);
}
