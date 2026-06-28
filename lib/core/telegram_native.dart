import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core_paths.dart';

/// Drives the native Telegram core (`tgcore.exe`) — a local MTProto proxy that
/// bridges Telegram to its un-throttled web gateway over a uTLS-masked WebSocket
/// (the real, working serverless Telegram unblock, replacing the experimental
/// in-app WS bridge). FFI-free: pure Process management + stdout parsing, so the
/// provider can manage it independently of the sing-box tunnel.
///
/// The base bridge needs NO admin (a userspace 127.0.0.1 MTProxy + outbound
/// WSS). Only the optional WinDivert call-desync (`-calls`) needs elevation; it
/// reuses the WinDivert.dll/.sys that already sit beside winws in core/windows.
class TelegramNative {
  TelegramNative({this.onLog, this.onLink, this.onExit, this.port = 2443});

  final void Function(String line)? onLog;
  final void Function(String link)? onLink;
  final void Function()? onExit; // tgcore died (crash / external kill) — clear UI
  final int port;

  Process? _proc;
  bool _adopted = false; // a tgcore was already listening — we attached, didn't spawn
  Timer? _adoptWatch; // polls the port for an ADOPTED instance (no exitCode for it)
  String? proxyLink; // the dd tg://proxy?... link the user opens in Telegram

  bool get running => _proc != null || _adopted;

  void _log(String m) => onLog?.call(m);

  /// Start (or adopt) tgcore on 127.0.0.1:[port], EXACTLY like the proven
  /// standalone `tgcore.exe -port 2443`: it reads the user's existing config
  /// dir (`%APPDATA%\tg-native\secrets.txt` + the captured fingerprint), so the
  /// link it serves carries the SAME secret already added to Telegram — no
  /// divergent file, no `-gen`, no extra flags. [calls] adds the WinDivert
  /// STUN-desync for voice/video (needs admin). Returns false only if the
  /// binary is missing or the launch itself failed.
  Future<bool> start({bool calls = false}) async {
    if (running) return true;
    final exe = CorePaths.tgCore();
    if (!File(exe).existsSync()) {
      _log('tgcore.exe is not bundled (core/windows/tgcore.exe) — cannot start');
      return false;
    }
    // If a tgcore/tg-native is already serving the port (the user's run.bat or
    // an autostart), attach to it instead of spawning a duplicate that would
    // die on the listen() conflict. The link comes from the shared config.
    if (await _portInUse(port)) {
      _adopted = true;
      _emitLink(_linkFromConfig());
      _log('tgcore already running on 127.0.0.1:$port — using it');
      // We get no exitCode for a process we didn't spawn, so POLL the port: when
      // the user's external tgcore stops listening, drop "Running" + the dead link
      // instead of showing green forever over a proxy that's gone.
      _adoptWatch?.cancel();
      _adoptWatch = Timer.periodic(const Duration(seconds: 5), (t) async {
        if (!_adopted) return t.cancel();
        if (!await _portInUse(port)) {
          t.cancel();
          _adopted = false;
          proxyLink = null;
          _log('adopted tgcore stopped listening on 127.0.0.1:$port');
          onExit?.call();
        }
      });
      return true;
    }
    proxyLink = null;
    try {
      // workingDirectory = the exe's folder so WinDivert.dll/.sys load for -calls.
      _proc = await Process.start(exe, ['-port', '$port', if (calls) '-calls'],
          workingDirectory: File(exe).parent.path);
    } catch (e) {
      _log('tgcore start failed: $e');
      return false;
    }
    // Register the PID with the shared orphan-reaper so closing the app reaps
    // tgcore too (it was surviving a full quit) — only for OUR spawn, never the
    // adopted path above (that's the user's own standalone, not ours to kill).
    CorePaths.recordPid('tgcore.exe', _proc!.pid);
    _proc!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
        _onLine,
        onError: (_) {});
    _proc!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
        _onLine,
        onError: (_) {});
    _proc!.exitCode.then((code) {
      _log('tgcore exited (code $code)');
      _proc = null;
      proxyLink = null;
      onExit?.call(); // tell the controller to drop "Running" + the dead link
    });
    // Seed the link from the shared config now; stdout will confirm it. This
    // keeps "Open in Telegram" correct even before the banner is parsed.
    _emitLink(_linkFromConfig());
    _log('tgcore starting on 127.0.0.1:$port (calls=$calls)');
    // Confirm it actually bound the port before reporting success — a bind race,
    // bad fingerprint or missing WinDivert (-calls) makes it exit immediately, and
    // we must NOT show "Running" over a proxy that isn't there.
    if (!await _awaitListening(port)) {
      _log('tgcore did not start listening on 127.0.0.1:$port');
      // Reap the spawned-but-not-listening process (bad fingerprint / missing
      // WinDivert for -calls) so it can't linger as a zombie the next enable
      // adopts via _portInUse and reports green "Running" over. Killing closes
      // its stdio streams, completing the listen subscriptions too.
      _proc?.kill();
      _proc = null;
      proxyLink = null;
      return false;
    }
    return true;
  }

  // Poll until the spawned tgcore accepts on its port (or it exits / times out).
  Future<bool> _awaitListening(int p) async {
    for (var i = 0; i < 12; i++) {
      if (_proc == null) return false; // already exited
      if (await _portInUse(p)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  void _emitLink(String? link) {
    if (link == null || proxyLink == link) return;
    proxyLink = link;
    onLink?.call(link);
  }

  // True if something already accepts connections on 127.0.0.1:[p].
  Future<bool> _portInUse(int p) async {
    try {
      final s = await Socket.connect('127.0.0.1', p,
          timeout: const Duration(milliseconds: 500));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  // Build the dd link straight from the shared secrets file the binary uses
  // (`%APPDATA%\tg-native\secrets.txt`), so the secret matches whatever tgcore
  // serves — our spawn OR an already-running one. Mirrors main.go's banner.
  String? _linkFromConfig() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return null;
    final sep = Platform.pathSeparator;
    final f = File('$appData${sep}tg-native${sep}secrets.txt');
    if (!f.existsSync()) return null;
    try {
      for (final line in f.readAsLinesSync()) {
        final s = line.trim().toLowerCase();
        if (RegExp(r'^[0-9a-f]{32}$').hasMatch(s)) {
          return 'tg://proxy?server=127.0.0.1&port=$port&secret=dd$s';
        }
      }
    } catch (_) {}
    return null;
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    _log(line);
    // The binary's banner prints the dd link (tg://proxy?...&secret=dd...) — the
    // authoritative one the user opens in Telegram to add the local MTProxy.
    final m = RegExp(r'tg://proxy\?\S*secret=dd\S+').firstMatch(line);
    if (m != null) _emitLink(m.group(0));
  }

  Future<void> stop() async {
    final p = _proc;
    final wasAdopted = _adopted;
    _adoptWatch?.cancel();
    _adoptWatch = null;
    _proc = null;
    _adopted = false;
    proxyLink = null;
    if (p == null) {
      // No process WE spawned. If we'd ADOPTED an external tgcore, OFF must still
      // mean "no local MTProxy" — so kill whoever LISTENS on the port, but ONLY if
      // that process is actually tgcore.exe (never an unrelated app on the port).
      if (wasAdopted) await _killTgcoreOnPort(port);
      return;
    }
    // Our own spawn: kill the whole TREE (a launcher child could hold the port)
    // while the PID is valid, then WAIT for exit + the socket to actually release
    // before reporting stop — kill() returns before the OS frees the port, which
    // let a quick re-enable ADOPT the still-dying instance and strand the port.
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/PID', '${p.pid}', '/T', '/F']);
      } catch (_) {}
    }
    p.kill(); // non-Windows path + belt-and-suspenders
    try {
      await p.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _waitPortReleased(port);
    _log('tgcore stopped (port ${await _portInUse(port) ? "STILL HELD" : "released"})');
  }

  // Kill the tgcore LISTENING on 127.0.0.1:[port], verified by image so we NEVER
  // kill an unrelated process that merely holds the port, then wait for release.
  Future<void> _killTgcoreOnPort(int port) async {
    if (!Platform.isWindows) return;
    final pid = await _pidOnPort(port);
    if (pid == null || !await _isTgcore(pid)) {
      _log('adopted: port $port holder is not tgcore (or already gone) — left as-is');
      return;
    }
    try {
      await Process.run('taskkill', ['/PID', '$pid', '/T', '/F']);
    } catch (_) {}
    await _waitPortReleased(port);
    _log('tgcore (adopted) killed — '
        'port ${await _portInUse(port) ? "STILL HELD" : "released"}');
  }

  // PID listening on 127.0.0.1:[port] (or 0.0.0.0:[port]). Locale-proof: we match
  // the numeric local address + the 0.0.0.0:0 foreign address of a LISTEN socket,
  // never the localized "LISTENING" word. Null if none / parse fails.
  Future<int?> _pidOnPort(int port) async {
    if (!Platform.isWindows) return null;
    try {
      final r = await Process.run('netstat', ['-ano']);
      for (final line in const LineSplitter().convert('${r.stdout}')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 5 || parts[0] != 'TCP') continue;
        if ((parts[1] == '127.0.0.1:$port' || parts[1] == '0.0.0.0:$port') &&
            parts[2] == '0.0.0.0:0') {
          return int.tryParse(parts.last);
        }
      }
    } catch (_) {}
    return null;
  }

  // True if [pid]'s image is tgcore.exe — the safety gate before any adopted kill.
  Future<bool> _isTgcore(int pid) async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run(
          'tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
      return '${r.stdout}'.toLowerCase().contains('"tgcore.exe"');
    } catch (_) {
      return false;
    }
  }

  // Poll until 127.0.0.1:[port] stops accepting (bounded ~2 s).
  Future<void> _waitPortReleased(int port) async {
    for (var i = 0; i < 20 && await _portInUse(port); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// One-time: capture YOUR real browser's TLS fingerprint so tgcore mimics it.
  /// Runs `tgcore -capture <capPort>`, asks [openBrowser] to open the localhost
  /// page (the binary captures the handshake), and waits for it to finish.
  /// Returns true on a successful capture.
  Future<bool> capture(
      {int capPort = 24461,
      required Future<void> Function(String url) openBrowser}) async {
    final exe = CorePaths.tgCore();
    if (!File(exe).existsSync()) return false;
    Process cap;
    try {
      cap = await Process.start(exe, ['-capture', '$capPort'],
          workingDirectory: File(exe).parent.path);
    } catch (e) {
      _log('capture start failed: $e');
      return false;
    }
    // Reap the capture tgcore on quit too — it can wait up to 90 s on the browser
    // handshake, and start() records its PID for exactly this reason. Without it a
    // quit during capture leaves an orphan holding capPort + a browser TLS session.
    CorePaths.recordPid('tgcore.exe', cap.pid);
    cap.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => _log('capture: $l'), onError: (_) {});
    cap.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => _log('capture: $l'), onError: (_) {});
    // Let it bind, then open the browser at the page it serves.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await openBrowser('https://localhost:$capPort');
    // It exits once it has grabbed the fingerprint; cap the wait.
    final code = await cap.exitCode.timeout(const Duration(seconds: 90),
        onTimeout: () {
      cap.kill();
      return -1;
    });
    _log(code == 0
        ? 'browser fingerprint captured — disguise now matches your browser'
        : 'fingerprint capture did not complete (code $code) — using the default');
    return code == 0;
  }
}
