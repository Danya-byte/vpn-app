import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_paths.dart';
import 'desync_config.dart';
import 'route_mode.dart';
import 'route_rule.dart';

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

/// sing-box TUN network stack. gVisor (default) is the most compatible on
/// Windows; `system` uses the OS stack (lower overhead, less isolation);
/// `mixed` = system TCP + gVisor UDP. Changing off gVisor is advanced.
const tunStacks = <String>['gvisor', 'system', 'mixed'];

/// Multiplex carrier protocol (only used when [AppSettings.mux] is on). h2mux is
/// the broad default; smux/yamux suit some servers.
const muxProtocols = <String>['h2mux', 'smux', 'yamux'];

class AppSettings {
  const AppSettings({
    this.mode = RouteMode.smart,
    this.vpnMode = VpnMode.systemProxy,
    this.antiDpi = true, // RF-protective default: fragments plain-TLS, no-op for Reality/QUIC
    this.autoFailover = true, // RF default: auto-pick the fastest working node (no-op with <2 nodes)
    this.tlsFingerprint = 'chrome',
    this.mux = false,
    this.autoAdapt = true, // detect ТСПУ blocking a live tunnel + auto-cycle anti-DPI
    this.maxResistance = false, // "hard network" (mobile operator): force fragmentation + active survivor-cascade
    this.connectOnLaunch = true, // resume the tunnel on launch if it was on at close
    this.killSwitchTun = false, // EXPERIMENTAL WFP fence for TUN — default OFF until battle-tested
    this.fakeIpTun = false, // EXPERIMENTAL FakeIP DNS in TUN (faster first-load) — default OFF until on-device tested
    this.winwsDesync = false, // server-less WinDivert TLS-DPI bypass (winws.exe) — needs admin + the binary
    this.telegramNative = false, // native serverless Telegram (tgcore.exe local MTProxy → un-throttled web gateway, uTLS) — no admin for the bridge
    this.telegramNativeCalls = false, // tgcore WinDivert STUN-desync for Telegram calls — needs admin
    this.desyncStrategy = DesyncConfig.defaultStrategy, // winws desync method preset
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
    this.insecureAccepted = const {}, // node tags the user OK'd the MITM risk for
    this.customRules = const [], // user routing rules (domain/ip → proxy/direct/block)
    this.webdavUrl = '', // WebDAV file URL for profile sync ('' = off)
    this.webdavUser = '',
    this.webdavPass = '',
    // Perf / advanced transport knobs (all conservative defaults = current behaviour).
    this.tunStack = 'gvisor', // sing-box TUN stack (gvisor/system/mixed)
    this.muxProtocol = 'h2mux', // multiplex carrier when mux is on
    this.muxStreams = 8, // multiplex max concurrent streams (1..256)
    this.muxPadding = false, // multiplex padding (obfuscate stream sizes)
    this.ecsSubnet = '', // EDNS Client Subnet for DNS ('' = off)
    this.ech = false, // Encrypted ClientHello on non-Reality TLS (needs server support)
    this.tcpFastOpen = false, // TCP Fast Open on dial — advanced (breaks anytls / some RF paths)
    this.mptcp = false, // Multipath TCP on dial — advanced
    this.localeCode,
  });

  final RouteMode mode;
  final VpnMode vpnMode;
  final bool antiDpi; // fragment TLS ClientHello to defeat SNI-based DPI
  final bool autoFailover; // urltest over all nodes, pick fastest + fail over
  final String tlsFingerprint; // uTLS pool: chrome/firefox/safari/edge/ios/random
  final bool mux; // multiplex (h2mux) — one TLS conn carries many streams
  final bool autoAdapt; // auto-cycle anti-DPI variants when ТСПУ blocks the tunnel
  // "Hard network" mode (mobile operators block far harder than Wi-Fi): forces
  // TLS-fragment anti-DPI ON + the active survivor-preferring cascade ON,
  // regardless of the individual toggles. The hook the heavier resistance layers
  // (packet desync / domestic relay) will hang off once chosen by the diagnostic.
  final bool maxResistance;
  final bool connectOnLaunch; // reconnect on startup if connected at last close
  final bool killSwitchTun; // WFP fail-closed fence while in TUN mode
  final bool fakeIpTun; // FakeIP DNS in TUN — instant synthetic answers (faster first-load)
  // Server-less DPI bypass: run the zapret WinDivert sidecar (winws.exe) to
  // desync the outbound TLS ClientHello so ТСПУ can't match the SNI. Defeats
  // TLS-DPI where the IP is reachable; needs admin (kernel driver) + the binary.
  final bool winwsDesync;
  // Native serverless Telegram (tgcore.exe): a local MTProxy that bridges to the
  // un-throttled web gateway over uTLS-masked WebSocket. The real engine that
  // replaces the experimental WS bridge in the UI. Calls sub-toggle needs admin.
  final bool telegramNative;
  final bool telegramNativeCalls;
  final String desyncStrategy; // winws method preset (DesyncConfig.strategies key)
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
  // Node tags whose insecure (cert-validation-off) MITM risk the user has
  // already accepted, so the H5 consent is asked ONCE per node — not every
  // connect. Cleared per-tag never (a node stays trusted once OK'd).
  final Set<String> insecureAccepted;
  // User routing rules (domain/IP → proxy/direct/block) — competitor parity, win
  // over the geo/smart rules. Empty = pure smart/global behaviour as before.
  final List<RouteRule> customRules;
  // WebDAV profile sync (Karing-parity backup/sync to the user's own cloud). All
  // empty = feature off. The password is stored in settings.json in plaintext on
  // the user's own machine (same trust level as the proxy creds in the store).
  final String webdavUrl;
  final String webdavUser;
  final String webdavPass;
  final String tunStack; // sing-box TUN network stack: gvisor/system/mixed
  final String muxProtocol; // multiplex carrier protocol (mux on)
  final int muxStreams; // multiplex max concurrent streams
  final bool muxPadding; // multiplex padding (hide stream sizes)
  final String ecsSubnet; // EDNS Client Subnet (e.g. 1.2.3.0/24); '' = off
  final bool ech; // Encrypted ClientHello on non-Reality TLS (advanced)
  final bool tcpFastOpen; // TCP Fast Open on dial (advanced, off by default)
  final bool mptcp; // Multipath TCP on dial (advanced, off by default)
  final String? localeCode; // 'en' | 'ru' | null = follow system

  Locale? get locale => localeCode == null ? null : Locale(localeCode!);

  /// The protection-relevant subset to embed in a `vpn://share` bundle (DPI /
  /// desync + per-app routing + custom rules + transport knobs). Deliberately
  /// EXCLUDES personal/device state — WebDAV creds, locale, autostart, tray,
  /// accepted-insecure tags, hy2 bandwidth caps, custom DNS — so sharing a setup
  /// never leaks the sender's private config or hijacks the recipient's device.
  Map<String, dynamic> shareableSubset() => {
        'antiDpi': antiDpi,
        'autoAdapt': autoAdapt,
        'maxResistance': maxResistance,
        'autoFailover': autoFailover,
        'tlsFingerprint': tlsFingerprint,
        'mux': mux,
        'winwsDesync': winwsDesync,
        'telegramNative': telegramNative,
        'telegramNativeCalls': telegramNativeCalls,
        'desyncStrategy': desyncStrategy,
        'splitTunnelApps': splitTunnelApps,
        'forceVpnApps': forceVpnApps,
        'customRules': customRules.map((r) => r.toJson()).toList(),
        'ech': ech,
        'tcpFastOpen': tcpFastOpen,
        'mptcp': mptcp,
        'tunStack': tunStack,
        'muxProtocol': muxProtocol,
        'muxStreams': muxStreams,
        'muxPadding': muxPadding,
        'ecsSubnet': ecsSubnet,
      };

  AppSettings copyWith({
    RouteMode? mode,
    VpnMode? vpnMode,
    bool? antiDpi,
    bool? autoFailover,
    String? tlsFingerprint,
    bool? mux,
    bool? autoAdapt,
    bool? maxResistance,
    bool? connectOnLaunch,
    bool? killSwitchTun,
    bool? fakeIpTun,
    bool? winwsDesync,
    bool? telegramNative,
    bool? telegramNativeCalls,
    String? desyncStrategy,
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
    Set<String>? insecureAccepted,
    List<RouteRule>? customRules,
    String? webdavUrl,
    String? webdavUser,
    String? webdavPass,
    String? tunStack,
    String? muxProtocol,
    int? muxStreams,
    bool? muxPadding,
    String? ecsSubnet,
    bool? ech,
    bool? tcpFastOpen,
    bool? mptcp,
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
        autoAdapt: autoAdapt ?? this.autoAdapt,
        maxResistance: maxResistance ?? this.maxResistance,
        connectOnLaunch: connectOnLaunch ?? this.connectOnLaunch,
        killSwitchTun: killSwitchTun ?? this.killSwitchTun,
        fakeIpTun: fakeIpTun ?? this.fakeIpTun,
        winwsDesync: winwsDesync ?? this.winwsDesync,
        telegramNative: telegramNative ?? this.telegramNative,
        telegramNativeCalls: telegramNativeCalls ?? this.telegramNativeCalls,
        desyncStrategy: desyncStrategy ?? this.desyncStrategy,
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
        insecureAccepted: insecureAccepted ?? this.insecureAccepted,
        customRules: customRules ?? this.customRules,
        webdavUrl: webdavUrl ?? this.webdavUrl,
        webdavUser: webdavUser ?? this.webdavUser,
        webdavPass: webdavPass ?? this.webdavPass,
        tunStack: tunStack ?? this.tunStack,
        muxProtocol: muxProtocol ?? this.muxProtocol,
        muxStreams: muxStreams ?? this.muxStreams,
        muxPadding: muxPadding ?? this.muxPadding,
        ecsSubnet: ecsSubnet ?? this.ecsSubnet,
        ech: ech ?? this.ech,
        tcpFastOpen: tcpFastOpen ?? this.tcpFastOpen,
        mptcp: mptcp ?? this.mptcp,
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
    // Promote a half-written `.tmp` (a previous atomicWrite blocked mid-rename)
    // before reading, so a locked-file save isn't silently lost on next launch.
    CorePaths.recoverOrphanTmp(_file.path);
    // ALSO recover a half-written `.bak.tmp`: the mirror is the corruption
    // fallback below, and a torn `.bak` save (its own atomicWrite blocked mid-
    // rename) would otherwise leave the mirror stale/missing exactly when needed.
    CorePaths.recoverOrphanTmp('${_file.path}.bak');
    return _load(_file) ??
        _load(File('${_file.path}.bak')) ??
        const AppSettings();
  }

  // Decode ONE settings file → null if missing / not a JSON object / unreadable,
  // so a corrupt main falls back to the .bak mirror (then defaults) instead of a
  // single torn write silently wiping every toggle (kill-switch, winws, creds).
  AppSettings? _load(File f) {
    try {
      if (!f.existsSync()) return null;
      final d = jsonDecode(f.readAsStringSync());
      if (d is Map) {
        final j = d.cast<String, dynamic>();
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
          autoAdapt: j['autoAdapt'] as bool? ?? true,
          maxResistance: j['maxResistance'] as bool? ?? false,
          connectOnLaunch: j['connectOnLaunch'] as bool? ?? true,
          killSwitchTun: j['killSwitchTun'] as bool? ?? false,
          fakeIpTun: j['fakeIpTun'] as bool? ?? false,
          winwsDesync: j['winwsDesync'] as bool? ?? false,
          telegramNative: j['telegramNative'] as bool? ?? false,
          telegramNativeCalls: j['telegramNativeCalls'] as bool? ?? false,
          desyncStrategy:
              DesyncConfig.isValidStrategy(j['desyncStrategy'] as String? ?? '')
                  ? j['desyncStrategy'] as String
                  : DesyncConfig.defaultStrategy,
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
          insecureAccepted:
              (j['insecureAccepted'] as List?)?.map((e) => '$e').toSet() ??
                  const {},
          customRules: (j['customRules'] as List?)
                  ?.map(RouteRule.fromJson)
                  .whereType<RouteRule>()
                  .toList() ??
              const [],
          webdavUrl: j['webdavUrl'] as String? ?? '',
          webdavUser: j['webdavUser'] as String? ?? '',
          webdavPass: j['webdavPass'] as String? ?? '',
          tunStack: tunStacks.contains(j['tunStack'])
              ? j['tunStack'] as String
              : 'gvisor',
          muxProtocol: muxProtocols.contains(j['muxProtocol'])
              ? j['muxProtocol'] as String
              : 'h2mux',
          muxStreams: ((j['muxStreams'] as num?)?.toInt() ?? 8).clamp(1, 256),
          muxPadding: j['muxPadding'] as bool? ?? false,
          ecsSubnet: j['ecsSubnet'] as String? ?? '',
          ech: j['ech'] as bool? ?? false,
          tcpFastOpen: j['tcpFastOpen'] as bool? ?? false,
          mptcp: j['mptcp'] as bool? ?? false,
          // Whitelist like tunStack/muxProtocol above — settings.json is hand-
          // editable + WebDAV-synced, so a stale/foreign code ('de', garbage)
          // must fall back to follow-system, not silently force English.
          localeCode:
              const ['en', 'ru'].contains(j['locale']) ? j['locale'] as String : null,
        );
      }
    } catch (_) {
      // unreadable / malformed → caller tries .bak, then defaults
    }
    return null;
  }

  void _save() {
    try {
      final json = jsonEncode({
            'mode': state.mode.name,
            'vpnMode': state.vpnMode.name,
            'antiDpi': state.antiDpi,
            'autoFailover': state.autoFailover,
            'tlsFingerprint': state.tlsFingerprint,
            'mux': state.mux,
            'autoAdapt': state.autoAdapt,
            'maxResistance': state.maxResistance,
            'connectOnLaunch': state.connectOnLaunch,
            'killSwitchTun': state.killSwitchTun,
            'fakeIpTun': state.fakeIpTun,
            'winwsDesync': state.winwsDesync,
            'telegramNative': state.telegramNative,
            'telegramNativeCalls': state.telegramNativeCalls,
            'desyncStrategy': state.desyncStrategy,
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
            'insecureAccepted': state.insecureAccepted.toList(),
            'customRules': state.customRules.map((r) => r.toJson()).toList(),
            'webdavUrl': state.webdavUrl,
            'webdavUser': state.webdavUser,
            'webdavPass': state.webdavPass,
            'tunStack': state.tunStack,
            'muxProtocol': state.muxProtocol,
            'muxStreams': state.muxStreams,
            'muxPadding': state.muxPadding,
            'ecsSubnet': state.ecsSubnet,
            'ech': state.ech,
            'tcpFastOpen': state.tcpFastOpen,
            'mptcp': state.mptcp,
            'locale': state.localeCode,
          });
      CorePaths.atomicWrite(_file.path, json);
      // Mirror to a .bak (same content, separate file) so a later single-file
      // corruption of the main store is recoverable on next load.
      CorePaths.atomicWrite('${_file.path}.bak', json);
    } catch (_) {}
  }

  void setAutoAdapt(bool v) {
    state = state.copyWith(autoAdapt: v);
    _save();
  }

  void setMaxResistance(bool v) {
    state = state.copyWith(maxResistance: v);
    _save();
  }

  /// One-tap "make it work on a mobile operator": atomically turn on the three
  /// hard-network levers (force TLS fragmentation, keep the survivor-preferring
  /// cascade active, auto-cycle anti-DPI variants) in a SINGLE state change so the
  /// live tunnel restarts ONCE, not three times. Surfaced on the failure/whitelist
  /// surface and at the top of Settings — the operator case shouldn't be buried.
  /// Returns true if anything actually changed (so the caller can reconnect).
  bool enableHardNetwork() {
    final s = state;
    if (s.maxResistance && s.antiDpi && s.autoAdapt) return false;
    state = s.copyWith(maxResistance: true, antiDpi: true, autoAdapt: true);
    _save();
    return true;
  }

  void setConnectOnLaunch(bool v) {
    state = state.copyWith(connectOnLaunch: v);
    _save();
  }

  void setKillSwitchTun(bool v) {
    state = state.copyWith(killSwitchTun: v);
    _save();
  }

  void setFakeIpTun(bool v) {
    state = state.copyWith(fakeIpTun: v);
    _save();
  }

  /// Server-less WinDivert DPI bypass (winws sidecar). The core controller picks
  /// this up on the next (re)connect — toggling it live restarts the core.
  void setWinwsDesync(bool v) {
    state = state.copyWith(winwsDesync: v);
    _save();
  }

  /// Native serverless Telegram engine (tgcore.exe). The native controller
  /// watches this and starts/stops the local MTProxy.
  void setTelegramNative(bool v) {
    state = state.copyWith(telegramNative: v);
    _save();
  }

  /// tgcore WinDivert STUN-desync for Telegram calls (needs admin).
  void setTelegramNativeCalls(bool v) {
    state = state.copyWith(telegramNativeCalls: v);
    _save();
  }

  void setDesyncStrategy(String v) {
    if (!DesyncConfig.isValidStrategy(v)) return;
    state = state.copyWith(desyncStrategy: v);
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

  void setTunStack(String v) {
    if (!tunStacks.contains(v)) return;
    state = state.copyWith(tunStack: v);
    _save();
  }

  void setMuxProtocol(String v) {
    if (!muxProtocols.contains(v)) return;
    state = state.copyWith(muxProtocol: v);
    _save();
  }

  void setMuxStreams(int v) {
    state = state.copyWith(muxStreams: v.clamp(1, 256));
    _save();
  }

  void setMuxPadding(bool v) {
    state = state.copyWith(muxPadding: v);
    _save();
  }

  /// EDNS Client Subnet for DNS (e.g. "1.2.3.0/24"); '' = off. A non-empty value
  /// MUST be a valid IP/CIDR — an invalid one (a typo like "300.1.1.0/24" or a
  /// bad prefix) makes the core FATAL and bounce the live tunnel, so it's rejected
  /// here and never reaches the config (the UI shows the error). Reuses the same
  /// strict validator as the custom-rule editor.
  void setEcsSubnet(String v) {
    final t = v.trim();
    if (t.isNotEmpty && !RouteRule.isValidValue(RuleField.ipCidr, t)) return;
    state = state.copyWith(ecsSubnet: t);
    _save();
  }

  void setEch(bool v) {
    state = state.copyWith(ech: v);
    _save();
  }

  void setTcpFastOpen(bool v) {
    state = state.copyWith(tcpFastOpen: v);
    _save();
  }

  void setMptcp(bool v) {
    state = state.copyWith(mptcp: v);
    _save();
  }

  void setLogLevel(String v) {
    state = state.copyWith(logLevel: v);
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

  /// Remember the user accepted the insecure (cert-validation-off, MITM-able)
  /// risk for node [tag], so the H5 consent is asked ONCE per node instead of on
  /// every connect (the user's #4 complaint). Purely UX state — never restarts
  /// the tunnel, so it's deliberately excluded from the config-change watcher.
  void acceptInsecure(String tag) {
    if (tag.isEmpty || state.insecureAccepted.contains(tag)) return;
    state = state.copyWith(insecureAccepted: {...state.insecureAccepted, tag});
    _save();
  }

  /// Replace the user's custom routing rules (the Settings editor commits the
  /// whole list). A config-affecting change → the controller's watcher restarts
  /// a live tunnel to apply it.
  void setCustomRules(List<RouteRule> rules) {
    state = state.copyWith(customRules: rules);
    _save();
  }

  /// Apply a protection-settings subset shared by another user (from a
  /// `vpn://share` bundle). Only the keys present are honoured and each is
  /// validated; everything absent keeps the recipient's own value, and personal
  /// state (creds, mode, vpnMode) is never touched. A config-affecting change →
  /// the controller's watcher restarts a live tunnel to apply it.
  void applyShared(Map<String, dynamic> j) {
    // The bundle is UNTRUSTED (decoded from a `vpn://share` link). A type-confused
    // field (muxStreams as the string "8", antiDpi as 1, splitTunnelApps as "x")
    // used to throw an uncaught TypeError mid-apply, leaving the import dead-ended
    // with the nodes already added. Coerce every field: a wrong type yields null =
    // keep the recipient's own value, never throw. Mirrors RouteRule.fromJson.
    bool? boolOf(dynamic v) => v is bool ? v : null;
    num? numOf(dynamic v) => v is num ? v : null;
    String? strOf(dynamic v) => v is String ? v : null;
    // An EMPTY shared list means "this field wasn't set", NOT "clear yours" —
    // return null (no-change) so importing a bundle with empty/absent lists never
    // silently erases the recipient's split-tunnel / force-VPN / custom rules.
    List<String>? listOf(dynamic v) =>
        v is List && v.isNotEmpty ? v.map((e) => '$e').toList() : null;
    String? validFp(dynamic v) => tlsFingerprints.contains(v) ? v as String : null;
    final msRaw = numOf(j['muxStreams'])?.toInt();
    final ms = msRaw == null ? null : (msRaw < 1 ? 1 : (msRaw > 256 ? 256 : msRaw));
    // A shared ECS subnet must validate (a bad one would FATAL the recipient's
    // core); an invalid value falls through to null = keep the recipient's own.
    final esRaw = strOf(j['ecsSubnet'])?.trim();
    final es = esRaw == null
        ? null
        : (esRaw.isEmpty || RouteRule.isValidValue(RuleField.ipCidr, esRaw)
            ? esRaw
            : null);
    final crRaw = j['customRules'];
    // Same no-wipe rule for custom rules: an empty list OR a list where every
    // entry fails to parse ⇒ null (keep the recipient's rules), not [].
    final crList = crRaw is List
        ? crRaw.map(RouteRule.fromJson).whereType<RouteRule>().toList()
        : null;
    state = state.copyWith(
      antiDpi: boolOf(j['antiDpi']),
      autoAdapt: boolOf(j['autoAdapt']),
      maxResistance: boolOf(j['maxResistance']),
      autoFailover: boolOf(j['autoFailover']),
      tlsFingerprint: validFp(j['tlsFingerprint']),
      mux: boolOf(j['mux']),
      winwsDesync: boolOf(j['winwsDesync']),
      telegramNative: boolOf(j['telegramNative']),
      telegramNativeCalls: boolOf(j['telegramNativeCalls']),
      desyncStrategy:
          DesyncConfig.isValidStrategy(strOf(j['desyncStrategy']) ?? '')
              ? strOf(j['desyncStrategy'])
              : null,
      splitTunnelApps: listOf(j['splitTunnelApps']),
      forceVpnApps: listOf(j['forceVpnApps']),
      customRules: (crList != null && crList.isNotEmpty) ? crList : null,
      ech: boolOf(j['ech']),
      tcpFastOpen: boolOf(j['tcpFastOpen']),
      mptcp: boolOf(j['mptcp']),
      tunStack: tunStacks.contains(j['tunStack']) ? j['tunStack'] as String : null,
      muxProtocol:
          muxProtocols.contains(j['muxProtocol']) ? j['muxProtocol'] as String : null,
      muxStreams: ms,
      muxPadding: boolOf(j['muxPadding']),
      ecsSubnet: es,
    );
    _save();
  }

  /// WebDAV sync credentials (profile backup/sync to the user's own cloud).
  void setWebdav({String? url, String? user, String? pass}) {
    state = state.copyWith(
      webdavUrl: url?.trim() ?? state.webdavUrl,
      // Trim user/pass too: a pasted credential with a trailing space/newline
      // (common from copy) would otherwise be sent verbatim → a confusing 401.
      webdavUser: user?.trim() ?? state.webdavUser,
      webdavPass: pass?.trim() ?? state.webdavPass,
    );
    _save();
  }
}
