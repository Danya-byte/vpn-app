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
}
