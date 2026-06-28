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
  /// Returns false if the native call threw, so a caller can surface a failure
  /// toast instead of a silent no-op.
  static Future<bool> openUrl(String url) async {
    try {
      await _ch.invokeMethod('openUrl', {'url': url});
      return true;
    } catch (_) {
      return false;
    }
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

  /// Push localized, state-aware labels for the tray context menu (the native
  /// menu just renders what we give it). [toggle] is "Connect" when off /
  /// "Disconnect" when on.
  static Future<void> setTrayLabels(
      {required String toggle,
      required String show,
      required String quit}) async {
    try {
      await _ch.invokeMethod(
          'setTrayLabels', {'toggle': toggle, 'show': show, 'quit': quit});
    } catch (_) {}
  }

  /// Bring the window back from the tray (e.g. to gate an insecure-node consent
  /// that can't be shown while hidden).
  static Future<void> showWindow() async {
    try {
      await _ch.invokeMethod('showWindow');
    } catch (_) {}
  }

  /// The tray icon's hover tooltip — reflects the live connection state.
  static Future<void> setTrayTooltip(String text) async {
    try {
      await _ch.invokeMethod('setTrayTooltip', {'text': text});
    } catch (_) {}
  }

  /// Pop a tray balloon notification. The native side shows it ONLY when the
  /// window is hidden (in the tray) — so it's the feedback the user gets when
  /// they connect/disconnect from the tray with the window closed, including the
  /// error text when a connect fails. Clicking the balloon opens the window.
  static Future<void> showTrayNotification(
      {required String title, required String message}) async {
    try {
      await _ch.invokeMethod(
          'showTrayNotification', {'title': title, 'message': message});
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
