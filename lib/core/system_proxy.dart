import 'package:flutter/services.dart';

/// Points the Windows system proxy (WinINET) at the local sing-box inbound so
/// browsers and proxy-aware apps route through the tunnel while connected.
/// Native no-op on other platforms / in tests.
class SystemProxy {
  static const _ch = MethodChannel('app/system');

  /// Returns true if the proxy was actually applied. False = the native call ran
  /// but FAILED (e.g. a denied registry write) → the caller must fail-closed, not
  /// silently leave traffic going direct. A missing handler (tests / non-Windows)
  /// is NOT a failure.
  static Future<bool> set(String server) async {
    try {
      final ok = await _ch.invokeMethod<bool>('setProxy', {'server': server});
      return ok ?? true; // handler ran but didn't report → assume applied
    } on MissingPluginException {
      return true; // no native handler (tests / non-Windows) → not a failure
    } catch (_) {
      return false; // the native call FAILED → caller fails-closed
    }
  }

  static Future<void> clear() async {
    try {
      await _ch.invokeMethod('clearProxy');
    } catch (_) {}
  }

  /// Entering TUN mode: TUN captures every app transparently, so SUSPEND any
  /// leftover loopback system proxy — ours from a prior proxy-mode session, or
  /// another local VPN's (e.g. Hiddify on 127.0.0.1:12334). Left set, it hijacks
  /// proxy-aware apps (Chrome / Edge / Electron — the Claude desktop app) into a
  /// broken double-hop or a dead port. The native side backs up a user-set proxy
  /// so disconnect restores it (only if it's still alive). No-op when no proxy is
  /// set, and on non-Windows / in tests.
  static Future<void> clearForTun() async {
    try {
      await _ch.invokeMethod('clearProxyForTun');
    } catch (_) {}
  }
}
