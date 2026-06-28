import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';
import 'native_admin.dart';
import 'telegram_native.dart';

/// UI-facing state of the native serverless Telegram engine (tgcore.exe).
class TgNativeState {
  const TgNativeState({
    this.running = false,
    this.proxyLink,
    this.capturing = false,
    this.fpCaptured = false,
    this.failed = false,
    this.log = const [],
  });

  final bool running;
  final String? proxyLink; // the tg://proxy?... link to open in Telegram
  final bool capturing; // a browser-fingerprint capture is in progress
  final bool fpCaptured; // a real browser fingerprint has been captured
  final bool failed; // start failed (binary missing) OR the engine died
  final List<String> log;

  TgNativeState copyWith({
    bool? running,
    Object? proxyLink = _unset,
    bool? capturing,
    bool? fpCaptured,
    bool? failed,
    List<String>? log,
  }) =>
      TgNativeState(
        running: running ?? this.running,
        proxyLink: proxyLink == _unset ? this.proxyLink : proxyLink as String?,
        capturing: capturing ?? this.capturing,
        fpCaptured: fpCaptured ?? this.fpCaptured,
        failed: failed ?? this.failed,
        log: log ?? this.log,
      );
  static const _unset = Object();
}

final telegramNativeProvider =
    NotifierProvider<TelegramNativeController, TgNativeState>(
        TelegramNativeController.new);

/// Starts/stops [TelegramNative] to follow the `telegramNative` setting. On the
/// FIRST enable it auto-captures the user's real browser fingerprint (opens a
/// localhost page in the default browser) so the disguise is "native" with no
/// manual command, then runs the local MTProxy. Independent of the VPN tunnel.
class TelegramNativeController extends Notifier<TgNativeState> {
  TelegramNative? _engine;
  bool _disposed = false;
  // Capped self-heal: respawn a crashed/killed tgcore while the toggle stays ON,
  // bounded so a genuinely broken binary can't spin in a tight loop. Reset on any
  // successful (re)start, mirroring winws's _desyncRespawns.
  int _respawns = 0;
  static const _maxRespawns = 3;

  @override
  TgNativeState build() {
    ref.onDispose(() {
      _disposed = true;
      _engine?.stop();
      _engine = null;
    });
    ref.listen(settingsProvider.select((s) => s.telegramNative), (_, next) {
      unawaited(_sync(next));
    });
    // Calls sub-toggle: restart the engine so the new -calls flag takes effect.
    ref.listen(settingsProvider.select((s) => s.telegramNativeCalls), (_, _) {
      if (ref.read(settingsProvider).telegramNative) {
        unawaited(_restart());
      }
    });
    unawaited(_sync(ref.read(settingsProvider).telegramNative));
    return TgNativeState(fpCaptured: _fingerprintExists());
  }

  void _set(TgNativeState s) {
    if (!_disposed) state = s;
  }

  void _appendLog(String line) {
    final l = [...state.log, line];
    if (l.length > 80) l.removeRange(0, l.length - 80);
    _set(state.copyWith(log: l));
  }

  // %APPDATA%\tg-native\fingerprint.bin — written by a successful -capture.
  bool _fingerprintExists() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) return false;
    final sep = Platform.pathSeparator;
    return File('$appData${sep}tg-native${sep}fingerprint.bin').existsSync();
  }

  Future<void> _opChain = Future<void>.value();
  Future<void> _sync(bool on) {
    _opChain = _opChain.then((_) => _syncImpl(on)).catchError((_) {});
    return _opChain;
  }

  Future<void> _restart() async {
    await _sync(false);
    await _sync(true);
  }

  Future<void> _syncImpl(bool on) async {
    if (on && _engine == null) {
      late final TelegramNative e;
      e = TelegramNative(
        onLog: _appendLog,
        onLink: (link) => _set(state.copyWith(proxyLink: link)),
        onExit: () => _onEngineExit(e),
      );
      _engine = e;
      final calls = ref.read(settingsProvider).telegramNativeCalls &&
          await NativeAdmin.isElevated();
      final ok = await e.start(calls: calls);
      if (!ok) {
        _engine = null;
        // Surface the failure (binary missing / immediate exit) instead of an
        // endless "checking…" spinner — the card shows an explicit error line.
        // CLEAR proxyLink: onLink already seeded it from secrets.txt BEFORE the
        // listen-check failed, and the UI keys "Running" off proxyLink != null —
        // a stale link would show a green "Open in Telegram" to a dead proxy.
        _set(state.copyWith(running: false, failed: true, proxyLink: null));
        return;
      }
      _respawns = 0; // a clean start refills the self-heal budget
      _set(state.copyWith(
          running: true, failed: false, fpCaptured: _fingerprintExists()));
      // First-ever enable with no captured fingerprint: grab it in the
      // BACKGROUND. The proxy already works on the built-in default, so a
      // stalled capture page never holds Telegram down; once a real
      // fingerprint lands we reload to adopt the browser-matched disguise.
      if (!_fingerprintExists()) {
        unawaited(_captureAndReload());
      }
    } else if (!on && _engine != null) {
      final e = _engine;
      _engine = null; // null FIRST so the onExit identity-guard no-ops this kill
      _respawns = 0; // an intentional stop clears the self-heal budget
      await e!.stop();
      _set(state.copyWith(running: false, proxyLink: null, failed: false));
    }
  }

  // tgcore died on its own (crash / external kill) — drop the green "Running"
  // status and the now-dead "Open in Telegram" link. Identity-guarded so a stale
  // exit from a replaced/stopped engine can't clobber a fresh one.
  void _onEngineExit(TelegramNative which) {
    if (!identical(_engine, which)) return;
    _engine = null;
    _set(state.copyWith(running: false, proxyLink: null, failed: true));
    // Self-heal a crash / AV-kill while the toggle is still ON — capped so a
    // genuinely broken binary can't spin in a respawn loop. A clean start resets
    // the budget, so independent later crashes still get fresh retries.
    if (_disposed ||
        !ref.read(settingsProvider).telegramNative ||
        _respawns >= _maxRespawns) {
      return;
    }
    _respawns++;
    Future.delayed(const Duration(seconds: 2), () {
      if (_disposed || _engine != null) return;
      if (ref.read(settingsProvider).telegramNative) unawaited(_sync(true));
    });
  }

  Future<void> _runCapture() async {
    _set(state.copyWith(capturing: true));
    final e = _engine ?? TelegramNative(onLog: _appendLog);
    final ok = await e.capture(openBrowser: (url) => NativeAdmin.openUrl(url));
    _set(state.copyWith(capturing: false, fpCaptured: ok || _fingerprintExists()));
  }

  /// Capture the browser fingerprint, then reload the engine (if one landed and
  /// the toggle is still on) so tgcore serves with the browser-matched disguise.
  Future<void> _captureAndReload() async {
    await _runCapture();
    if (_fingerprintExists() && ref.read(settingsProvider).telegramNative) {
      await _restart();
    }
  }

  /// Re-run the browser-fingerprint capture on demand, then reload.
  Future<void> recapture() => _captureAndReload();

  /// Open the proxy link in Telegram (the tg:// scheme adds the local MTProxy).
  Future<void> openInTelegram() async {
    final link = state.proxyLink;
    if (link != null) await NativeAdmin.openUrl(link);
  }
}
