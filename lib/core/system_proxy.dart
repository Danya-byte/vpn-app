import 'package:flutter/services.dart';

/// Points the Windows system proxy (WinINET) at the local sing-box inbound so
/// browsers and proxy-aware apps route through the tunnel while connected.
/// Native no-op on other platforms / in tests.
class SystemProxy {
  static const _ch = MethodChannel('app/system');

  static Future<void> set(String server) async {
    try {
      await _ch.invokeMethod('setProxy', {'server': server});
    } catch (_) {
      // no native handler (tests / non-Windows) — ignore
    }
  }

  static Future<void> clear() async {
    try {
      await _ch.invokeMethod('clearProxy');
    } catch (_) {}
  }
}
