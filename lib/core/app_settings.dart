import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_paths.dart';
import 'route_mode.dart';

/// How the tunnel is wired into the OS. User-facing labels/descriptions live in
/// l10n (vpnModeProxy/vpnModeTun/...), never as hardcoded strings here.
enum VpnMode {
  systemProxy,
  tun,
}

/// Real-browser uTLS fingerprints (NEVER the synthetic `randomized`, which omits
/// the X25519 key_share and breaks Reality). `random` rotates among real ones.
const tlsFingerprints = <String>[
  'chrome',
  'yandex', // Yandex Browser — Chromium-based, emits the chrome ClientHello
  'firefox',
  'safari',
  'edge',
  'ios',
  'random',
];

/// sing-box log verbosity, surfaced in the in-app log view: warn = quiet, info =
/// every connection, debug = everything. Default 'info' in debug builds, 'warn'
/// in release (so a shipped app is quiet unless the user opts into more).
const logLevels = <String>['warn', 'info', 'debug'];
const defaultLogLevel = kDebugMode ? 'info' : 'warn';

class AppSettings {
  const AppSettings({
    this.mode = RouteMode.smart,
    this.vpnMode = VpnMode.systemProxy,
    this.antiDpi = true, // RF-protective default: fragments plain-TLS, no-op for Reality/QUIC
    this.autoFailover = true, // RF default: auto-pick the fastest working node (no-op with <2 nodes)
    this.tlsFingerprint = 'chrome',
    this.mux = false,
    this.ech = false,
    this.autoAdapt = true, // detect ТСПУ blocking a live tunnel + auto-cycle anti-DPI
    this.connectOnLaunch = true, // resume the tunnel on launch if it was on at close
    this.killSwitchTun = false, // EXPERIMENTAL WFP fence for TUN — default OFF until battle-tested
    this.splitTunnelApps = const [], // process names routed DIRECT (bypass VPN) in TUN
    this.forceVpnApps = const [], // process names FORCED through the VPN (blocked apps)
    this.registerLinks = false, // OS handlers for vpn:// / sing-box:// / .json open-with
    this.launchAtStartup = false, // launch at login via HKCU Run (no admin)
    this.closeToTray = true, // closing the window hides to tray (tunnel keeps running)
    this.seenSetup = false, // first-run protection-mode choice shown yet?
    this.hy2UpMbps = 0, // Hysteria2 Brutal upload cap, Mbps (0 = let Hysteria2 auto-tune)
    this.hy2DownMbps = 0, // Hysteria2 Brutal download cap, Mbps (0 = auto)
    this.customDns = '', // custom DoH resolver; '' = the RF-safe default (Yandex)
    this.logLevel = defaultLogLevel,
    this.localeCode,
  });

  final RouteMode mode;
  final VpnMode vpnMode;
  final bool antiDpi; // fragment TLS ClientHello to defeat SNI-based DPI
  final bool autoFailover; // urltest over all nodes, pick fastest + fail over
  final String tlsFingerprint; // uTLS pool: chrome/firefox/safari/edge/ios/random
  final bool mux; // multiplex (h2mux) — one TLS conn carries many streams
  final bool ech; // Encrypted ClientHello (hides SNI; needs server support)
  final bool autoAdapt; // auto-cycle anti-DPI variants when ТСПУ blocks the tunnel
  final bool connectOnLaunch; // reconnect on startup if connected at last close
  final bool killSwitchTun; // WFP fail-closed fence while in TUN mode
  final List<String> splitTunnelApps; // process names → direct (TUN split-tunnel)
  final List<String> forceVpnApps; // process names → pinned through the VPN
  final bool registerLinks; // vpn:// / sing-box:// / .json OS handlers registered
  final bool launchAtStartup; // launch at login (HKCU Run)
  final bool closeToTray; // close → hide to tray instead of quitting
  final bool seenSetup; // has the first-run protection-mode choice been shown?
  final int hy2UpMbps; // Hysteria2 Brutal upload cap, Mbps (0 = auto)
  final int hy2DownMbps; // Hysteria2 Brutal download cap, Mbps (0 = auto)
  final String customDns; // custom DoH resolver ('' = RF-safe default)
  final String logLevel; // sing-box log verbosity (warn/info/debug)
  final String? localeCode; // 'en' | 'ru' | null = follow system

  Locale? get locale => localeCode == null ? null : Locale(localeCode!);

  AppSettings copyWith({
    RouteMode? mode,
    VpnMode? vpnMode,
    bool? antiDpi,
    bool? autoFailover,
    String? tlsFingerprint,
    bool? mux,
    bool? ech,
    bool? autoAdapt,
    bool? connectOnLaunch,
    bool? killSwitchTun,
    List<String>? splitTunnelApps,
    List<String>? forceVpnApps,
    bool? registerLinks,
    bool? launchAtStartup,
    bool? closeToTray,
    bool? seenSetup,
    int? hy2UpMbps,
    int? hy2DownMbps,
    String? customDns,
    String? logLevel,
    String? localeCode,
    bool clearLocale = false,
  }) =>
      AppSettings(
        mode: mode ?? this.mode,
        vpnMode: vpnMode ?? this.vpnMode,
        antiDpi: antiDpi ?? this.antiDpi,
        autoFailover: autoFailover ?? this.autoFailover,
        tlsFingerprint: tlsFingerprint ?? this.tlsFingerprint,
        mux: mux ?? this.mux,
        ech: ech ?? this.ech,
        autoAdapt: autoAdapt ?? this.autoAdapt,
        connectOnLaunch: connectOnLaunch ?? this.connectOnLaunch,
        killSwitchTun: killSwitchTun ?? this.killSwitchTun,
        splitTunnelApps: splitTunnelApps ?? this.splitTunnelApps,
        forceVpnApps: forceVpnApps ?? this.forceVpnApps,
        registerLinks: registerLinks ?? this.registerLinks,
        launchAtStartup: launchAtStartup ?? this.launchAtStartup,
        closeToTray: closeToTray ?? this.closeToTray,
        seenSetup: seenSetup ?? this.seenSetup,
        hy2UpMbps: hy2UpMbps ?? this.hy2UpMbps,
        hy2DownMbps: hy2DownMbps ?? this.hy2DownMbps,
        customDns: customDns ?? this.customDns,
        logLevel: logLevel ?? this.logLevel,
        localeCode: clearLocale ? null : (localeCode ?? this.localeCode),
      );
}

final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

class SettingsController extends Notifier<AppSettings> {
  /// Tests point this at a temp dir so they never touch the real user settings
  /// (mirrors [ProfileStore.overrideDir] — a widget test that flips a setting
  /// must not rewrite the real settings.json and, e.g., arm TUN mode).
  static String? overrideDir;

  File get _file => File(
      '${overrideDir ?? CorePaths.runtimeDir().path}${Platform.pathSeparator}settings.json');

  static T _enum<T extends Enum>(List<T> values, String? name, T fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback; // unknown/newer value -> default this one field, not all
  }

  @override
  AppSettings build() {
    try {
      if (_file.existsSync()) {
        final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
        return AppSettings(
          mode: _enum(RouteMode.values, j['mode'] as String?, RouteMode.smart),
          vpnMode: _enum(
              VpnMode.values, j['vpnMode'] as String?, VpnMode.systemProxy),
          antiDpi: j['antiDpi'] as bool? ?? true,
          autoFailover: j['autoFailover'] as bool? ?? true,
          tlsFingerprint: tlsFingerprints.contains(j['tlsFingerprint'])
              ? j['tlsFingerprint'] as String
              : 'chrome',
          mux: j['mux'] as bool? ?? false,
          ech: j['ech'] as bool? ?? false,
          autoAdapt: j['autoAdapt'] as bool? ?? true,
          connectOnLaunch: j['connectOnLaunch'] as bool? ?? true,
          killSwitchTun: j['killSwitchTun'] as bool? ?? false,
          splitTunnelApps:
              (j['splitTunnelApps'] as List?)?.map((e) => '$e').toList() ??
                  const [],
          forceVpnApps:
              (j['forceVpnApps'] as List?)?.map((e) => '$e').toList() ??
                  const [],
          registerLinks: j['registerLinks'] as bool? ?? false,
          launchAtStartup: j['launchAtStartup'] as bool? ?? false,
          closeToTray: j['closeToTray'] as bool? ?? true,
          seenSetup: j['seenSetup'] as bool? ?? false,
          hy2UpMbps: (j['hy2UpMbps'] as num?)?.toInt() ?? 0,
          hy2DownMbps: (j['hy2DownMbps'] as num?)?.toInt() ?? 0,
          customDns: j['customDns'] as String? ?? '',
          logLevel: logLevels.contains(j['logLevel'])
              ? j['logLevel'] as String
              : defaultLogLevel,
          localeCode: j['locale'] as String?,
        );
      }
    } catch (_) {
      // fall back to defaults
    }
    return const AppSettings();
  }

  void _save() {
    try {
      CorePaths.atomicWrite(
          _file.path,
          jsonEncode({
            'mode': state.mode.name,
            'vpnMode': state.vpnMode.name,
            'antiDpi': state.antiDpi,
            'autoFailover': state.autoFailover,
            'tlsFingerprint': state.tlsFingerprint,
            'mux': state.mux,
            'ech': state.ech,
            'autoAdapt': state.autoAdapt,
            'connectOnLaunch': state.connectOnLaunch,
            'killSwitchTun': state.killSwitchTun,
            'splitTunnelApps': state.splitTunnelApps,
            'forceVpnApps': state.forceVpnApps,
            'registerLinks': state.registerLinks,
            'launchAtStartup': state.launchAtStartup,
            'closeToTray': state.closeToTray,
            'seenSetup': state.seenSetup,
            'hy2UpMbps': state.hy2UpMbps,
            'hy2DownMbps': state.hy2DownMbps,
            'customDns': state.customDns,
            'logLevel': state.logLevel,
            'locale': state.localeCode,
          }));
    } catch (_) {}
  }

  void setAutoAdapt(bool v) {
    state = state.copyWith(autoAdapt: v);
    _save();
  }

  void setConnectOnLaunch(bool v) {
    state = state.copyWith(connectOnLaunch: v);
    _save();
  }

  void setKillSwitchTun(bool v) {
    state = state.copyWith(killSwitchTun: v);
    _save();
  }

  /// Hysteria2 Brutal bandwidth caps (Mbps). Clamped to >= 0; 0 means "let
  /// Hysteria2 auto-tune" (the field is then omitted from the outbound).
  void setHy2Bandwidth({int? up, int? down}) {
    state = state.copyWith(
      hy2UpMbps: up == null ? null : (up < 0 ? 0 : up),
      hy2DownMbps: down == null ? null : (down < 0 ? 0 : down),
    );
    _save();
  }

  /// Custom DoH resolver. Trimmed; '' restores the RF-safe default at connect.
  void setCustomDns(String v) {
    state = state.copyWith(customDns: v.trim());
    _save();
  }

  // The OS-side effect (registry write) is done by the caller via NativeAdmin —
  // these just persist the user's choice.
  void setRegisterLinks(bool v) {
    state = state.copyWith(registerLinks: v);
    _save();
  }

  void setLaunchAtStartup(bool v) {
    state = state.copyWith(launchAtStartup: v);
    _save();
  }

  void setCloseToTray(bool v) {
    state = state.copyWith(closeToTray: v);
    _save();
  }

  void setSplitTunnelApps(List<String> v) {
    state = state.copyWith(splitTunnelApps: v);
    _save();
  }

  void setForceVpnApps(List<String> v) {
    state = state.copyWith(forceVpnApps: v);
    _save();
  }

  void setTlsFingerprint(String fp) {
    state = state.copyWith(tlsFingerprint: fp);
    _save();
  }

  void setMux(bool v) {
    state = state.copyWith(mux: v);
    _save();
  }

  void setLogLevel(String v) {
    state = state.copyWith(logLevel: v);
    _save();
  }

  void setEch(bool v) {
    state = state.copyWith(ech: v);
    _save();
  }

  void setMode(RouteMode m) {
    state = state.copyWith(mode: m);
    _save();
  }

  void setVpnMode(VpnMode m) {
    state = state.copyWith(vpnMode: m);
    _save();
  }

  /// First-run setup: record the user's protection-mode choice and never show the
  /// chooser again. Deliberately does NOT enable the experimental WFP kill-switch
  /// — that stays a conscious opt-in until it's leak-tested on real hardware.
  void completeSetup(VpnMode m) {
    state = state.copyWith(vpnMode: m, seenSetup: true);
    _save();
  }

  void setAntiDpi(bool v) {
    state = state.copyWith(antiDpi: v);
    _save();
  }

  void setAutoFailover(bool v) {
    state = state.copyWith(autoFailover: v);
    _save();
  }

  void setLocale(String? code) {
    state = code == null
        ? state.copyWith(clearLocale: true)
        : state.copyWith(localeCode: code);
    _save();
  }
}
