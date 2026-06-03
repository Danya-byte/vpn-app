import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Windows elevation helpers over the native "app/system" channel.
class NativeAdmin {
  static const _ch = MethodChannel('app/system');

  /// Whether this process runs with an elevated (admin) token.
  static Future<bool> isElevated() async {
    try {
      return (await _ch.invokeMethod<bool>('isElevated')) ?? false;
    } catch (_) {
      return false; // non-Windows / tests
    }
  }

  /// Relaunch the app elevated (UAC) and exit the current instance.
  static Future<void> relaunchElevated() async {
    try {
      await _ch.invokeMethod('relaunchElevated');
    } catch (_) {}
  }

  /// Open a URL in the default browser (native ShellExecute, no plugin).
  static Future<void> openUrl(String url) async {
    try {
      await _ch.invokeMethod('openUrl', {'url': url});
    } catch (_) {}
  }

  /// Register / unregister `vpn://` + `sing-box://` URL handlers and the `.json`
  /// "Open with" entry (all HKCU, no admin) so an OS click actually fires the
  /// deeplink handler. Opt-in (Windows is last-installed-wins for schemes).
  static Future<void> registerLinkHandlers(bool on) async {
    try {
      await _ch.invokeMethod(
          on ? 'registerLinkHandlers' : 'unregisterLinkHandlers');
    } catch (_) {}
  }

  /// Launch at login via HKCU\…\Run (no admin). [minimized] starts in the tray.
  static Future<void> setAutostart(bool on, {bool minimized = true}) async {
    try {
      await _ch.invokeMethod('setAutostart', {'on': on, 'minimized': minimized});
    } catch (_) {}
  }

  /// Whether the HKCU Run entry currently exists (reflects the real registry).
  static Future<bool> isAutostart() async {
    try {
      return (await _ch.invokeMethod<bool>('isAutostart')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Close-to-tray: when on, closing the window HIDES it (the tunnel keeps
  /// running) instead of quitting. Pushed to the native runner on launch + change.
  static Future<void> setCloseToTray(bool on) async {
    try {
      await _ch.invokeMethod('setCloseToTray', {'on': on});
    } catch (_) {}
  }

  /// Engage the fail-closed TUN kill-switch (WFP fence: block all egress except
  /// the core processes + tunnel interface + loopback). [corePaths] must list
  /// EVERY core that dials out — sing-box AND each xray bridge — or the fence
  /// blacks out XHTTP/Reality-over-XHTTP (which connect as the xray process).
  /// Returns true ONLY if the fence is actually installed — callers treat false
  /// as "no protection".
  static Future<bool> fenceEngage(List<String> corePaths) async {
    try {
      return (await _ch
              .invokeMethod<bool>('fenceEngage', {'paths': corePaths})) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Remove the kill-switch fence (dynamic WFP session → filters drop).
  static Future<void> fenceDisengage() async {
    try {
      await _ch.invokeMethod('fenceDisengage');
    } catch (_) {}
  }
}

final isElevatedProvider = FutureProvider<bool>((ref) => NativeAdmin.isElevated());
