import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'amnezia_config.dart';
import 'app_settings.dart';
import 'cascade.dart';
import 'censorship_facts.dart';
import 'censorship_facts_feed.dart';
import 'clash_api.dart';
import 'core_paths.dart';
import 'desync_config.dart';
import 'ech_discovery.dart';
import 'lifecycle.dart';
import 'native_admin.dart';
import 'profiles_controller.dart';
import 'route_mode.dart';
import 'route_rule.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';
import 'xray_config.dart';

enum CoreStatus { stopped, starting, running, stopping, error }

/// State of the server-less WinDivert DPI-desync sidecar (winws.exe).
enum DesyncEngineStatus {
  off, // the "DPI bypass without a server" toggle is off
  active, // winws is running and desyncing matched TLS-DPI traffic
  needsAdmin, // toggle on + binary present, but the app isn't elevated (WinDivert needs admin)
  missing, // toggle on, but winws.exe isn't installed (fetched separately, like xray)
}

/// A core error/status detail, localized in the UI (never a pre-baked string in
/// one language). [reconnecting] isn't fatal — it's the kill-switch failing
/// closed while it retries.
enum CoreError {
  coreMissing,
  tunNeedsAdmin,
  configRejected,
  writeFailed,
  launchFailed,
  noApi,
  reconnecting,
  gaveUp,
  portInUse,
  wireguardHandshake,
  killSwitchFailed,
  proxyFailed,
  xrayMissing,
}

/// Sentinel so [CoreState.copyWith] can tell "leave as-is" from "clear".
const Object _unset = Object();

class CoreState {
  const CoreState({
    this.status = CoreStatus.stopped,
    this.version,
    this.error,
    this.detail,
    this.logs = const [],
    this.fenceActive = false,
    this.whitelistMode = false,
    this.tunnelDark = false,
    this.desyncEngine = DesyncEngineStatus.off,
    this.swapping = false,
  });

  final CoreStatus status;
  final String? version;
  final CoreError? error; // localized by the UI
  final String? detail; // optional extra (path / core message)
  final List<String> logs;
  final bool fenceActive; // WFP TUN kill-switch fence currently up?
  // The mobile network collapsed to the state IP/SNI allowlist ("белый список"):
  // RU sites answer but no foreign exit is reachable. Non-fatal (we stay running,
  // fail-closed) — a Home banner explains it instead of churning the cascade.
  final bool whitelistMode;
  // Tunnel is technically up (process alive, Clash API answers) but carries NO
  // traffic right now — surfaced as "checking" so the UI never claims a solid
  // "Connected" during the watchdog's dark window before it acts.
  final bool tunnelDark;
  // Server-less WinDivert DPI-desync sidecar status — drives the Settings card
  // (active / needs-admin / engine-missing) + an "active" indicator. Independent
  // of the tunnel: it can be active with or without a selected node.
  //
  // It's a real field, NOT derived from `_winwsProc != null`, on purpose: two of
  // the four states (needsAdmin, missing) describe WHY there's no process, which a
  // bare handle can't express. The controller keeps it in sync at the (few)
  // teardown sites + _applyDesyncOnce, which all also reap the process.
  final DesyncEngineStatus desyncEngine;
  // A restart()/swap is in flight: the OLD core is being replaced while the system
  // proxy stays PINNED (traffic fails closed, never drops). The UI shows a calm
  // amber "Checking…" instead of the red "Connecting…" spinner so a node-switch /
  // network-change / settings-restart doesn't read as a full reconnect.
  final bool swapping;

  bool get isBusy =>
      status == CoreStatus.starting || status == CoreStatus.stopping;
  bool get isOn => status == CoreStatus.running;

  CoreState copyWith({
    CoreStatus? status,
    String? version,
    Object? error = _unset,
    Object? detail = _unset,
    List<String>? logs,
    bool? fenceActive,
    bool? whitelistMode,
    bool? tunnelDark,
    DesyncEngineStatus? desyncEngine,
    bool? swapping,
  }) {
    return CoreState(
      status: status ?? this.status,
      version: version ?? this.version,
      error: identical(error, _unset) ? this.error : error as CoreError?,
      detail: identical(detail, _unset) ? this.detail : detail as String?,
      logs: logs ?? this.logs,
      fenceActive: fenceActive ?? this.fenceActive,
      whitelistMode: whitelistMode ?? this.whitelistMode,
      tunnelDark: tunnelDark ?? this.tunnelDark,
      desyncEngine: desyncEngine ?? this.desyncEngine,
      swapping: swapping ?? this.swapping,
    );
  }
}

final clashApiProvider = Provider<ClashApi>((ref) => ClashApi());

/// The active bottom-nav tab (0=Home, 1=Activity, 2=Settings). Set by the nav so
/// the Activity-only pollers (connections / proxy groups) can PAUSE when that tab
/// isn't visible — they used to poll every 1.5–2 s regardless of what you're
/// looking at.
final navIndexProvider = StateProvider<int>((ref) => 0);

final coreControllerProvider = NotifierProvider<CoreController, CoreState>(
  CoreController.new,
);

/// Owns the sing-box child process lifecycle and exposes its state.
class CoreController extends Notifier<CoreState> {
  Process? _proc;
  static const int _maxLogLines = 500;

  Timer? _netDebounce;
  Timer?
  _settingsRestartDebounce; // coalesce live setting changes into 1 restart
  Timer? _hop;
  bool _hopping = false;
  bool _inHealthCheck =
      false; // re-entrancy guard: a slow probe pass can outlast
  // the 18s watchdog period, so a second tick must not double-hop.
  // Per-selector consecutive probe failures — a single failed /delay can be a
  // transient cold-handshake blip, so we require 2 in a row before hopping
  // (stops the "auto-hop churns every 20 s" the user saw).
  final Map<String, int> _hopFails = {};
  Timer? _reconnect;
  Timer? _watchdog; // auto-adapt: probe the live tunnel for ТСПУ blocking
  int _healthFails = 0;
  int _adaptStep = 0; // 0 = user settings; 1..N = escalating anti-block variant
  // Transport families (Clash types) already tried this "dark episode", so the
  // cascade hops Reality→Hy2→XHTTP→… once each instead of oscillating; cleared
  // when traffic flows again.
  final Set<String> _triedTransports = {};
  // Learned per-family SURVIVAL score (EWMA 0..1) — the cascade's network memory.
  // Survives restarts within a session (NOT cleared in restart(), unlike the
  // per-episode _triedTransports), so the app learns which transport family gets
  // through on THIS network and tries it FIRST within its survivability tier. Fed
  // to planCascade; updated on each hop outcome. In-memory for now (cross-launch
  // persistence is the next step).
  final Map<String, double> _transportScores = {};
  // tag → refined anti-DPI family of the LIVE config (Reality vs plain-TLS vs
  // XHTTP — distinctions the coarse Clash `type` erases), computed PRE-bridge so
  // XHTTP isn't mistaken for the `socks` the xray bridge turns it into. Feeds
  // planCascade so a hop lands on a genuinely different signature. Empty until
  // the first build.
  Map<String, String> _familyByTag = const {};
  // Tags of INSECURE (cert-validation-off, MITM-able) leaves in the live config,
  // so the auto-failover pool + the watchdog cascade never silently route through
  // one (H5). Computed pre-bridge alongside _familyByTag; empty until first build.
  Set<String> _insecureByTag = const {};
  // L3 proactive-hop: EMA baseline of the HEALTHY active-path RTT, a streak of
  // degraded samples, and a cooldown (cycles) after a proactive hop so a noisy
  // path can't churn. Conservative on purpose — moves only on SUSTAINED, SEVERE
  // latency blow-up (the "hop before you're fully caught" edge).
  double? _rttBaseline;
  int _degradeStreak = 0;
  int _proactiveCooldown = 0;
  int _healthyStreak =
      0; // consecutive healthy ticks — clear the cascade only on
  // SUSTAINED recovery (a family blocked early in an episode must be re-eligible
  // later when the wave moves), not on the first good tick.
  bool _allTransportsDark =
      false; // last cascade found EVERY family dark at once
  // → looks like an IP/server block, not a per-signature one (fp won't help).
  // 16KB connection-freeze episode (net4people #490/#546): the node passes a tiny
  // 204 but stalls real >16KB transfers. Detected by a periodic bulk-through-proxy
  // probe in the HEALTHY branch (the freeze hides as "healthy") and remedied by a
  // transport hop off the long TLS stream (battle-tested: reshaping a flow-
  // mandating Reality node breaks it). Counters reset on the next clean reconnect.
  int _freezeFails = 0; // consecutive bulk-stall detections (debounce)
  int _freezeTick = 0; // healthy-tick counter — bulk-probe every Nth (cost)
  // Whitelist-mode collapse latched (RU up, all foreign dark) — mirrors
  // state.whitelistMode so we only re-emit the banner/log on a transition.
  bool _whitelistMode = false;
  bool _adapting = false;
  bool _portConflict =
      false; // core couldn't bind 2080/9090 (another copy holds it)
  int _exitRetries = 0;
  int _wgHandshakeFails =
      0; // consecutive WireGuard handshakes that never landed
  bool _wgDead =
      false; // WG/AmneziaWG peer unreachable → surface a precise error
  DateTime?
  _settleUntil; // grace window after (re)start: ignore self-induced net churn
  bool _fenceActive = false; // WFP TUN kill-switch fence currently installed?
  // Set when the fence was requested (TUN + setting) but FAILED to install, so
  // _onExit refuses to run unprotected instead of a silent fail-open (BLOCK-on-fail).
  bool _fenceFailed = false;

  // Escalating anti-block variants tried (in order) when a live tunnel goes
  // dark — ТСПУ usually blocks ONE fingerprint/fragment signature, so cycling
  // them finds one that still gets through. fp rotates the uTLS ClientHello
  // (the only client lever for Reality); fragment/mux apply to plain TCP-TLS.
  static const List<({String fp, bool fragment, bool mux})> _adaptVariants = [
    (fp: 'random', fragment: true, mux: false),
    (fp: 'firefox', fragment: true, mux: false),
    (fp: 'safari', fragment: true, mux: true),
    (fp: 'edge', fragment: false, mux: false),
  ];
  bool _autoReconnect = false; // user intent: stay connected until Stop
  bool _restarting = false; // node-switch/network-change: keep failing CLOSED
  bool _proxyActive = false; // is the system proxy currently pointed at us?
  final List<Process> _xrayProcs = [];
  // The winws (WinDivert) desync sidecar, tracked SEPARATELY from the xray/awg
  // bridges so it can be hot-swapped (toggle / method change) WITHOUT tearing
  // down the tunnel — winws is independent of sing-box. Reaped in [_killXray]
  // (the single teardown choke point) so every stop/restart/dispose path covers it.
  Process? _winwsProc;
  Timer?
  _desyncReapplyDebounce; // collapse a burst of winws toggle/method changes
  bool _desyncBusy =
      false; // a spawn/reconcile is running — serialize (no overlap)
  bool _desyncPending =
      false; // a change arrived mid-spawn → loop once more after
  String?
  _lastDesyncSig; // method+hostlist winws is RUNNING with (skip no-op churn)
  // ② desync auto-escalation: when the active preset isn't unblocking a site,
  // [desyncEscalate] advances to the next preset + rotates the ④ decoy SNI and
  // re-applies. The override holds until the user changes the desync setting (then
  // reset). Triggered by a RELIABLE signal (the diagnostic / a user tap where the
  // user can SEE the page didn't open), NOT a fragile always-on canary that could
  // cycle away from a working preset.
  String? _desyncAutoStrategy;
  int _desyncDecoyIdx = 0;
  final Set<String> _desyncTried = {};
  int _desyncRespawns = 0; // capped self-heal counter for winws deaths
  Timer? _desyncHealthyTimer; // restores the budget once winws survives a while
  // Set by [_bridgeXray] when a member's bridge could NOT be brought up (xray
  // REJECTED its generated config / the spawn failed) AND the prune left no usable
  // exit — so start() surfaces a precise error instead of launching a config that
  // routes everything direct or silent-dead. Null when the bridge is healthy.
  String? _bridgeError;

  // Restore connectivity on a terminal failure ONLY if we weren't already
  // protecting traffic. If the proxy is live (a reconnect / network-change swap
  // whose new core failed), keep it CLOSED so nothing leaks direct onto a
  // hostile network — the user presses Stop to restore. Mirrors the kill-switch.
  Future<void> _failProxy() async {
    if (!_proxyActive) await SystemProxy.clear();
  }

  Future<void> _restoreProxy() async {
    await SystemProxy.clear();
    _proxyActive = false;
  }

  void _clearPids() {
    try {
      if (_pidFile.existsSync()) _pidFile.deleteSync();
    } catch (_) {}
  }

  // A marker that the tunnel was UP. Survives an unclean exit (crash / window
  // closed while connected), so the next launch knows to resume. Deleted only on
  // a deliberate Stop / give-up.
  File get _connectedFlag => File(
    '${CorePaths.runtimeDir().path}${Platform.pathSeparator}connected.flag',
  );
  void _writeConnectedFlag() {
    try {
      _connectedFlag.writeAsStringSync('1');
    } catch (_) {}
  }

  void _clearConnectedFlag() {
    try {
      if (_connectedFlag.existsSync()) _connectedFlag.deleteSync();
    } catch (_) {}
  }

  // ── ① learned transport memory: persist the per-family survival scores across
  // launches (a small JSON in the runtime dir) so the cascade KEEPS what it learned
  // about this install's networks. Best-effort: a read/write failure just falls
  // back to in-memory / the baked survivability priors.
  File? _scoresFileCache;
  File get _scoresFile => _scoresFileCache ??= File(
        '${CorePaths.runtimeDir().path}${Platform.pathSeparator}transport_scores.json',
      );
  Future<void> _loadTransportScores() async {
    try {
      final f = _scoresFile;
      if (!await f.exists()) return;
      final m = jsonDecode(await f.readAsString());
      if (m is Map) {
        m.forEach((k, v) {
          final d = v is num ? v.toDouble() : double.tryParse('$v');
          if (d != null && d >= 0 && d <= 1) _transportScores['$k'] = d;
        });
      }
    } catch (_) {}
  }

  void _saveTransportScores() {
    // Fire-and-forget ASYNC write off the hot path — a transport hop is restart-free
    // (a selectProxy on the live selector), so persisting its score must add no
    // sync-I/O hitch to the painting isolate.
    try {
      unawaited(_scoresFile
          .writeAsString(jsonEncode(_transportScores))
          .catchError((_) => _scoresFile));
    } catch (_) {}
  }

  /// Record a dark-episode outcome into the learned memory + persist it: a hop's
  /// destination [family] survived, or the family it left went dark.
  void _recordTransport(String? family, bool survived) {
    if (family == null || family.isEmpty) return;
    _transportScores[family] =
        transportScoreAfter(_transportScores[family], survived);
    _saveTransportScores();
  }

  // Drop the WFP TUN fence on a DELIBERATE disconnect/give-up. NOT called on the
  // reconnect path — the fence must persist while the core is down so traffic
  // fails CLOSED, and is re-engaged (with the new tunnel LUID) on reconnect.
  void _disengageFence() {
    if (!_fenceActive) return;
    _fenceActive = false;
    state = state.copyWith(fenceActive: false);
    NativeAdmin.fenceDisengage();
  }

  @override
  CoreState build() {
    final rsDir = CorePaths.ruleSetsDir();
    SingBoxConfig.ruleSetDir = rsDir;
    unawaited(_loadTransportScores()); // ① restore learned memory (off the sync build path)
    // Smart mode references these by local path; if packaging missed them or AV
    // quarantined them, degrade to a rule-set-free config instead of FATAL-ing.
    SingBoxConfig.ruleSetsReady = const [
      'geoip-ru',
      'geosite-ru',
      'geosite-ads',
    ].every((f) => File('$rsDir${Platform.pathSeparator}$f.srs').existsSync());
    SingBoxConfig.clashSecret = _randomSecret();
    // ②: apply the last-validated ТСПУ-fact feed (desync list, freeze probe) from
    // disk BEFORE the first connect; a missing/corrupt cache leaves baked defaults.
    CensorshipFacts.loadCacheSync();
    // #1 (user-reported: "switching proxy↔TUN does nothing"): a config-affecting
    // setting changed WHILE the tunnel is up must RE-APPLY live. Previously every
    // setter only mutated state + persisted, so the running core kept its old
    // config until a manual reconnect — flipping VPN mode, routing mode, anti-DPI,
    // the kill-switch or split-tunnel looked like a no-op. Debounced so dragging a
    // slider / typing a DNS / editing the app list coalesces into ONE restart.
    // ref.listen (not watch) → the callback fires without rebuilding the core.
    ref.listen<AppSettings>(settingsProvider, (prev, next) {
      if (prev == null) return;
      // winws desync is INDEPENDENT of the tunnel — it's a SERVER-LESS bypass the
      // user drives by a toggle, with NO profile and WITHOUT pressing Connect. So
      // reconcile it on every toggle / method change REGARDLESS of connection state.
      if (prev.winwsDesync != next.winwsDesync ||
          prev.desyncStrategy != next.desyncStrategy) {
        // The user drove the desync → clear any auto-escalation override + budget.
        _desyncAutoStrategy = null;
        _desyncTried.clear();
        _desyncDecoyIdx = 0;
        _scheduleDesyncReapply();
      }
      // A sing-box-config change only matters while a tunnel is actually up.
      if (state.isOn && _settingsAffectConfig(prev, next)) {
        _scheduleSettingsRestart();
      }
    });
    // A ТСПУ-fact feed push updates SingBoxConfig.desyncDomains (the winws hostlist
    // source). Re-apply the desync engine so a newly-throttled domain is covered
    // (version-gated → no churn on a no-op pull). Independent of the tunnel.
    ref.listen<CensorshipFacts>(censorshipFactsProvider, (prev, next) {
      if (prev?.version != next.version) _scheduleDesyncReapply();
    });
    // The winws desync toggle persists across launches — bring the sidecar up on
    // start if it's enabled (and we're elevated), so a server-less user gets the
    // bypass immediately without any Connect.
    // Guard against tests arming a real winws spawn from the persisted store
    // (same FLUTTER_TEST gate the resume block below uses).
    if (!Platform.environment.containsKey('FLUTTER_TEST') &&
        ref.read(settingsProvider).winwsDesync) {
      _scheduleDesyncReapply();
    }
    ref.onDispose(() {
      _proc?.kill();
      _killXray();
      _winwsProc
          ?.kill(); // winws is tunnel-independent — reaped here, not in _killXray
      _winwsProc = null;
      _netDebounce?.cancel();
      _settingsRestartDebounce?.cancel();
      _desyncReapplyDebounce?.cancel();
      _desyncHealthyTimer?.cancel();
      _hop?.cancel();
      _reconnect?.cancel();
      _watchdog?.cancel();
    });
    // Resume on launch: the flag survives an unclean exit (window closed while
    // connected), so if connect-on-launch is on + a node is selected, bring the
    // tunnel back — and clean up any orphan core / stale proxy in the process
    // (start() handles both). Hiddify-Windows still lacks this.
    // NEVER under `flutter test`: it would read the real runtime flag + store and
    // actually launch the VPN mid-test (tests must never touch the real store).
    final inTest = Platform.environment.containsKey('FLUTTER_TEST');
    if (!inTest && _connectedFlag.existsSync()) {
      Future.microtask(() {
        if (!state.isOn &&
            !state.isBusy &&
            ref.read(settingsProvider).connectOnLaunch &&
            ref.read(profilesProvider).selectedNode != null) {
          start();
        } else {
          // Resume disabled / no node: still reap the orphan the flag implies.
          _killOrphanCores();
        }
      });
    } else if (!inTest) {
      // Not resuming, but a previous run may have been HARD-killed (force-quit /
      // crash) before native teardown could reap its cores — clean any orphan so
      // it can't hold the local ports or keep tunnelling on this launch.
      Future.microtask(_killOrphanCores);
    }
    return const CoreState();
  }

  // Re-apply a live config change after a short debounce (coalesces a flurry of
  // edits — sliders, app-list edits — into ONE restart). If a swap is already in
  // flight, re-arm instead of dropping the change, so the latest settings always
  // win. No-op once disconnected.
  void _scheduleSettingsRestart() {
    _settingsRestartDebounce?.cancel();
    _settingsRestartDebounce = Timer(const Duration(milliseconds: 600), () {
      if (!state.isOn) return;
      if (_restarting) {
        _scheduleSettingsRestart(); // an in-flight swap owns the core — retry after
        return;
      }
      restart(reason: 'settings change');
    });
  }

  // Does the change between two settings snapshots alter the GENERATED sing-box
  // config (so a live tunnel must restart to honour it)? Only DISCRETE settings
  // (toggles, dropdowns, committed app/rule lists) trigger a live restart.
  // EXCLUDED so they never bounce the tunnel: UX/OS-only (locale, tray, autostart,
  // connect-on-launch, insecureAccepted, webdav*; autoAdapt is read live by the
  // watchdog), AND free-text/numeric fields edited per-keystroke (customDns, hy2
  // up/down) — a restart on a half-typed DoH/number would break resolution, so
  // they persist immediately but apply on the NEXT (re)connect.
  static bool _settingsAffectConfig(AppSettings a, AppSettings b) =>
      a.vpnMode != b.vpnMode ||
      a.mode != b.mode ||
      // maxResistance FORCES fragmentation on, so the EMITTED config only changes
      // when the effective fragmentation (antiDpi OR maxResistance) flips — toggling
      // maxResistance while antiDpi is already on is a no-op for the config (its
      // cascade-keeping effect is read live by the watchdog, like autoAdapt), so
      // don't bounce the tunnel for it.
      (a.antiDpi || a.maxResistance) != (b.antiDpi || b.maxResistance) ||
      a.mux != b.mux ||
      a.tlsFingerprint != b.tlsFingerprint ||
      a.killSwitchTun != b.killSwitchTun ||
      a.fakeIpTun != b.fakeIpTun ||
      // NOTE: winwsDesync / desyncStrategy are deliberately NOT here — they don't
      // touch the sing-box config, so they're hot-swapped via _reapplyDesync()
      // (no tunnel restart). Adding them here would needlessly blip the tunnel.
      a.autoFailover != b.autoFailover ||
      _rulesKey(a.customRules) != _rulesKey(b.customRules) ||
      // '|' is illegal in a Windows process name, so it can't false-merge two
      // different app lists into the same joined string the way ' ' or '' could.
      a.splitTunnelApps.join('|') != b.splitTunnelApps.join('|') ||
      a.forceVpnApps.join('|') != b.forceVpnApps.join('|') ||
      // Advanced transport knobs — each rebuilds the sing-box config.
      a.tunStack != b.tunStack ||
      a.muxProtocol != b.muxProtocol ||
      a.muxStreams != b.muxStreams ||
      a.muxPadding != b.muxPadding ||
      a.ech != b.ech ||
      a.tcpFastOpen != b.tcpFastOpen ||
      a.mptcp != b.mptcp ||
      a.ecsSubnet != b.ecsSubnet ||
      // A discrete dropdown that rewrites the emitted `log.level` — without this
      // the new verbosity only ever applied on the next manual reconnect.
      a.logLevel != b.logLevel;

  // Stable key for the custom-rules list so the watcher restarts only on a real
  // change (not on every settings save).
  static String _rulesKey(List<RouteRule> rules) =>
      rules.map((r) => '${r.field.name}:${r.value}:${r.action.name}').join('|');

  // 128-bit per-launch token for the Clash API (cryptographically random).
  static String _randomSecret() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  static final RegExp _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

  // Env that lets the core load imported configs still using pre-1.12 features
  // the migration couldn't fully rewrite. Shared by the pre-flight check + run.
  static const Map<String, String> _coreEnv = {
    'ENABLE_DEPRECATED_LEGACY_DNS_SERVERS': 'true',
    'ENABLE_DEPRECATED_GEOSITE': 'true',
    'ENABLE_DEPRECATED_SPECIAL_OUTBOUNDS': 'true',
    'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM':
        'true', // singular (core's name)
    'ENABLE_DEPRECATED_DNS_RULE_ACTIONS': 'true',
    'ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER': 'true',
    // fromConfig migrates legacy fakeip to the typed server; this is the
    // belt-and-suspenders so an unmigrated edge loads instead of FATAL.
    'ENABLE_DEPRECATED_LEGACY_DNS_FAKEIP_OPTIONS': 'true',
  };

  void _log(String raw) {
    final line = raw.replaceAll(_ansi, '');
    if (line.trim().isEmpty) return;
    // Lifecycle side effects, keyed off the PURE [classifyCoreLog] (ingestion
    // below is now separate — the audit flagged the two as coupled).
    switch (classifyCoreLog(line)) {
      case CoreLogSignal.portConflict:
        // Another copy / orphan holds 2080/9090 — not transient.
        _portConflict = true;
      case CoreLogSignal.wgHandshakeFail:
        // WireGuard/AmneziaWG silent-dead: API up (we'd say "connected") but the
        // Noise handshake never lands → ZERO traffic. sing-box speaks PLAIN WG
        // (no jc/jmin/s1-s4 obfs), so Amnezia/ТСПУ drop it; fp-cycling can't fix a
        // UDP handshake → catch in ~15 s + surface a precise reason.
        if (++_wgHandshakeFails >= 3 && !_wgDead && _autoReconnect) {
          _wgDead = true;
          _proc?.kill(); // _onExit's _wgDead branch surfaces the specific error
        }
      case CoreLogSignal.wgHandshakeOk:
        _wgHandshakeFails = 0; // a real handshake landed — peer is alive
      case CoreLogSignal.none:
        break;
    }
    _appendLog(line);
  }

  // App-level event into the same in-app log stream the user copies — so a
  // restart's REASON is visible (network-change / select / wake / reconnect),
  // turning an unexplained "reconnects constantly" into a readable trail.
  void _appLog(String msg) => _appendLog('· app: $msg');

  // Pure ingestion: append a line to the in-app log ring (capped), no side
  // effects — kept separate from the lifecycle detection in [_log].
  void _appendLog(String line) {
    final next = [...state.logs, line];
    if (next.length > _maxLogLines) {
      next.removeRange(0, next.length - _maxLogLines);
    }
    state = state.copyWith(logs: next);
  }

  Future<void> start() async {
    // A restart() bypasses the busy/on guard: it owns the swap and the old core
    // is already being torn down, so we must be allowed to bring the new one up.
    if (!_restarting && (state.isOn || state.isBusy)) return;
    _appLog(_restarting ? 'core start (after restart)' : 'core start');
    _autoReconnect = true;
    _portConflict = false;
    _wgDead = false;
    _wgHandshakeFails = 0;
    _desyncRespawns = 0; // fresh winws self-heal budget for this connect
    _bridgeError =
        null; // reset even when xray is absent (_bridgeXray won't run)
    state = state.copyWith(
      status: CoreStatus.starting,
      error: null,
      detail: null,
    );
    if (_proc == null) await _killOrphanCores();

    final exe = CorePaths.singBox();
    if (!File(exe).existsSync()) {
      _autoReconnect = false;
      await _failProxy();
      state = state.copyWith(
        status: CoreStatus.error,
        error: CoreError.coreMissing,
        detail: exe,
      );
      return;
    }

    final cfgPath = CorePaths.configFile();
    final profiles = ref.read(profilesProvider);
    final node = profiles.selectedNode;
    final settings = ref.read(settingsProvider);
    SingBoxConfig.logLevel = settings.logLevel; // user-chosen verbosity
    // Custom DoH resolver, or the RF-safe default (Yandex) when unset.
    SingBoxConfig.dnsServer = settings.customDns.isEmpty
        ? '77.88.8.8'
        : settings.customDns;
    // Advanced transport knobs (static injection, same pattern as logLevel/dns).
    SingBoxConfig.tunStack = settings.tunStack;
    SingBoxConfig.muxProtocol = settings.muxProtocol;
    SingBoxConfig.muxStreams = settings.muxStreams;
    SingBoxConfig.muxPadding = settings.muxPadding;
    SingBoxConfig.tcpFastOpen = settings.tcpFastOpen;
    SingBoxConfig.mptcp = settings.mptcp;
    SingBoxConfig.ecsSubnet = settings.ecsSubnet;
    final simpleNodes = profiles.nodes.where((n) => !n.isConfig).toList();
    // Auto-failover + the watchdog cascade run UNATTENDED — they must never
    // silently route through a cert-unvalidated (MITM-able) node. The auto pool
    // is SECURE nodes only; an insecure node is reachable solely via an explicit,
    // consent-gated manual connect (H5).
    final autoPool = simpleNodes.where((n) => !n.insecure).toList();
    final useAuto = settings.autoFailover && autoPool.length >= 2;
    final tunMode = settings.vpnMode == VpnMode.tun;
    final xrayAvailable = File(CorePaths.xray()).existsSync();
    final awgAvailable = File(CorePaths.awg()).existsSync();
    // An imported full-config that relies on XHTTP/splithttp needs the xray
    // bridge. If xray.exe is missing (AV-quarantined / packaging slip), fromConfig
    // would DROP those outbounds and silently route everything DIRECT (a fail-OPEN
    // deanonymisation) — refuse with a clear error instead of running unprotected.
    if (!xrayAvailable &&
        node != null &&
        node.isConfig &&
        (((node.config!['outbounds'] as List?) ?? const [])
            .whereType<Map>()
            .any(XrayConfig.needsXray))) {
      _autoReconnect = false;
      await _failProxy();
      state = state.copyWith(
        status: CoreStatus.error,
        error: CoreError.xrayMissing,
        detail: null,
      );
      return;
    }
    if (tunMode && !await NativeAdmin.isElevated()) {
      _autoReconnect = false;
      await _failProxy();
      state = state.copyWith(
        status: CoreStatus.error,
        error: CoreError.tunNeedsAdmin,
        detail: null,
      );
      return;
    }
    // Auto-adapt: while escalating (after the tunnel went dark), layer the
    // current anti-block variant on top of the user's settings.
    final variant = (_adaptStep > 0 && _adaptStep <= _adaptVariants.length)
        ? _adaptVariants[_adaptStep - 1]
        : null;
    final fp = variant?.fp ?? settings.tlsFingerprint;
    // Hard-network mode forces TLS-fragment anti-DPI ON — and it must WIN over an
    // imported node variant that pins fragment:false, else the toggle's promise
    // ("forces fragmentation regardless of the other switches") is a lie. So
    // maxResistance short-circuits BEFORE the variant override.
    final antiDpi = settings.maxResistance
        ? true
        : (variant?.fragment ?? settings.antiDpi);
    final mux = variant?.mux ?? settings.mux;
    var cfg = useAuto
        ? SingBoxConfig.fromNodes(
            autoPool,
            mode: settings.mode,
            antiDpi: antiDpi,
            tlsFingerprint: fp,
            mux: mux,
            ech: settings.ech,
            fakeip: tunMode && settings.fakeIpTun,
          )
        : node == null
        // No server selected → a minimal local config. The "unblock without a
        // server" desync mode was REMOVED: ТСПУ now reassembles TLS fragments,
        // so it didn't actually unblock anything in RF (user-confirmed).
        ? SingBoxConfig.m0Local()
        : node.isConfig
        ? SingBoxConfig.fromConfig(
            node.config!,
            keepXray: xrayAvailable,
            // Preserve the `_amneziawg` marker through the strip ONLY when the awg
            // bridge can consume it — else an imported AmneziaWG config is both
            // misclassified as plain (blocked) WireGuard AND never bridged.
            keepAmneziaMarker: awgAvailable,
            // resolved fp (settings or auto-adapt variant), NOT the raw
            // variant — else the user's fingerprint pick was ignored for
            // imported configs. Levers now apply to imports too.
            fingerprintOverride: fp,
            antiDpi: antiDpi,
            mux: mux,
            ech: settings.ech,
            ruDirect: settings.mode == RouteMode.smart,
          )
        : SingBoxConfig.fromNode(
            node,
            mode: settings.mode,
            antiDpi: antiDpi,
            tlsFingerprint: fp,
            mux: mux,
            ech: settings.ech,
            fakeip: tunMode && settings.fakeIpTun,
          );
    if (tunMode) {
      cfg = SingBoxConfig.withTun(
        cfg,
        splitApps: settings.splitTunnelApps,
        forceApps: settings.forceVpnApps,
      );
    }
    // User routing rules (domain/ip → proxy/direct/block) — applied AFTER withTun
    // so an explicit "force THIS domain → proxy/block" wins over a broad
    // split-tunnel "this app → direct" (which previously silently overrode the
    // user's more specific intent). Both sit below DNS-hijack so DNS still resolves.
    cfg = SingBoxConfig.applyCustomRules(cfg, settings.customRules);
    // Hysteria2 Brutal bandwidth caps (no-op unless the user set them AND a
    // hysteria2 outbound exists). One choke point covers every build path.
    cfg = SingBoxConfig.tuneHysteria2(
      cfg,
      settings.hy2UpMbps,
      settings.hy2DownMbps,
    );
    // EDNS Client Subnet (one choke point; no-op unless the user set a subnet).
    cfg = SingBoxConfig.applyEcs(cfg);
    // Native ECH masquerade (opt-in lever): discover each plain-TLS exit's
    // published ECH config over DoH and bake it in, so the real SNI rides
    // encrypted and only the cover public_name shows on the wire — what Chrome
    // does, on our core, no bespoke binary. Best-effort + fail-safe (a miss
    // leaves sing-box's own ECH resolution). BEFORE the xray bridge rewrites
    // XHTTP outbounds into `socks` (which would drop the tls block).
    if (settings.ech) _applyEchDiscovery(cfg); // applies from cache; warms in bg
    // Snapshot the TRUE per-outbound families for the cascade BEFORE the xray
    // bridge rewrites XHTTP outbounds into `socks` (which would otherwise erase
    // the XHTTP↔Reality distinction). See [familiesFromConfig].
    _familyByTag = familiesFromConfig(cfg);
    _insecureByTag = insecureTagsFromConfig(cfg);
    if (xrayAvailable) cfg = await _bridgeXray(cfg);
    if (awgAvailable) cfg = await _bridgeAmnezia(cfg);
    // The xray bridge couldn't bring up a member (xray rejected its config / the
    // spawn died) AND no usable exit survived the prune — e.g. a single XHTTP node.
    // Surface the precise reason instead of writing a config that would route
    // everything DIRECT (deanonymising) or sit silent-dead. Not transient, so
    // don't enter the auto-reconnect loop (mirrors the preflight-reject teardown).
    if (_bridgeError != null) {
      _autoReconnect = false;
      _killXray();
      _clearConnectedFlag();
      _disengageFence();
      await _failProxy();
      state = state.copyWith(
        status: CoreStatus.error,
        error: CoreError.configRejected,
        detail: 'xray bridge: $_bridgeError',
      );
      return;
    }
    try {
      File(cfgPath).writeAsStringSync(SingBoxConfig.encode(cfg));
    } catch (e) {
      _autoReconnect = false;
      await _failProxy();
      state = state.copyWith(
        status: CoreStatus.error,
        error: CoreError.writeFailed,
        detail: '$e',
      );
      return;
    }

    // Pre-flight: validate against the REAL core schema before launching. Turns
    // a cryptic crash + reconnect-spam into one precise message, and catches an
    // imported config the 1.13 migration couldn't fully rescue. A config error
    // isn't transient, so don't enter the auto-reconnect loop on it.
    final problem = await _preflightCheck(exe, cfgPath);
    if (problem != null) {
      _autoReconnect = false;
      _killXray();
      _clearConnectedFlag();
      _disengageFence(); // a bad config shouldn't auto-retry every launch
      await _failProxy(); // fail closed if a live tunnel was up; else restore
      state = state.copyWith(
        status: CoreStatus.error,
        error: CoreError.configRejected,
        detail: problem,
      );
      return;
    }

    // Strict re-check WITHOUT the deprecated-compat env. The config still RUNS
    // (1.13 accepts it), but if it only validates thanks to ENABLE_DEPRECATED_*,
    // it will hard-FATAL on sing-box 1.14 — warn now instead of shipping a
    // silent time-bomb. Non-blocking.
    final legacy = await _preflightCheck(exe, cfgPath, env: const {});
    if (legacy != null) {
      _log(
        'warning: config relies on deprecated sing-box features '
        '(will break on 1.14): $legacy',
      );
    }

    try {
      _proc = await Process.start(
        exe,
        ['run', '-c', cfgPath],
        workingDirectory: CorePaths.runtimeDir().path,
        environment: _coreEnv,
      );
      _recordPid('sing-box.exe', _proc!.pid);
    } catch (e) {
      _autoReconnect = false;
      _killXray(); // sing-box spawn threw AFTER the xray bridges started → reap them
      await _failProxy();
      state = state.copyWith(
        status: CoreStatus.error,
        error: CoreError.launchFailed,
        detail: '$e',
      );
      return;
    }

    const decoder = Utf8Decoder(allowMalformed: true);
    _proc!.stdout
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(_log);
    _proc!.stderr
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(_log);
    final spawned = _proc!;
    unawaited(spawned.exitCode.then((code) => _onExit(code, spawned)));

    // Readiness probe: poll the Clash API until the core answers.
    final api = ref.read(clashApiProvider);
    String? version;
    for (var i = 0; i < 30; i++) {
      if (_proc == null) return; // stopped while starting
      version = await api.version();
      if (version != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    if (version == null) {
      _autoReconnect = false;
      _proc?.kill();
      _proc = null;
      _killXray(); // identity-guarded _onExit won't reap once _proc is nulled
      await _failProxy();
      state = state.copyWith(
        status: CoreStatus.error,
        error: CoreError.noApi,
        detail: null,
      );
      return;
    }

    // A user Stop may have landed while we were starting (e.g. during a restart
    // swap, where this start() bypassed the busy guard). Honor it — don't bring
    // the tunnel up behind their back. Restore the proxy (they want out).
    if (!_autoReconnect) {
      _proc?.kill();
      _proc = null;
      _killXray(); // identity-guarded _onExit early-returns once _proc is nulled
      await _restoreProxy();
      state = state.copyWith(
        status: CoreStatus.stopped,
        error: null,
        detail: null,
      );
      return;
    }

    // System-proxy mode points browsers/proxy-aware apps at the local inbound;
    // TUN already captures everything, so no proxy is needed there. Set the flag
    // BEFORE the await so a racing stop()/death sees a consistent _proxyActive.
    if (!tunMode) {
      _proxyActive = true;
      final proxyOk = await SystemProxy.set(
        '${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}',
      );
      if (!proxyOk) {
        // The system proxy didn't actually apply (e.g. a denied registry write):
        // in proxy mode the user would be UNPROTECTED (apps go direct) while the
        // UI claims "connected". Fail CLOSED — tear the core down + surface it.
        _proxyActive = false;
        _autoReconnect = false;
        _proc?.kill();
        _proc = null;
        _killXray();
        await _failProxy();
        state = state.copyWith(
          status: CoreStatus.error,
          error: CoreError.proxyFailed,
          detail: null,
        );
        return;
      }
    } else {
      // Entering TUN: TUN captures every app transparently, so SUSPEND any system
      // proxy. clearForTun handles BOTH cases: our own 127.0.0.1:2080 from a prior
      // proxy-mode session (a live proxy→TUN switch — _proxyActive was true), AND
      // a leftover loopback proxy from ANOTHER local VPN on a FRESH TUN start —
      // e.g. Hiddify on 127.0.0.1:12334, which otherwise hijacks proxy-aware apps
      // (Chrome / Edge / Electron — the Claude desktop app) into a broken double-
      // hop or a dead port. The user's own proxy is backed up and restored
      // (liveness-checked) on disconnect. No-op when no proxy is set.
      _proxyActive = false;
      await SystemProxy.clearForTun();
    }

    // Re-check intent AFTER the proxy-set await: a user Stop — or an unexpected
    // core death — can land in that gap. Committing to `running` here would
    // leave a zombie (running with no process) that the next network change
    // silently reconnects, defeating the Stop.
    if (!_autoReconnect) {
      _proc?.kill();
      _proc = null;
      _killXray(); // identity-guarded _onExit early-returns once _proc is nulled
      await _restoreProxy();
      state = state.copyWith(
        status: CoreStatus.stopped,
        error: null,
        detail: null,
      );
      return;
    }
    if (_proc == null) return; // died during start → _onExit already handled it

    // TUN kill-switch: engage the WFP fence BEFORE declaring "running", so there
    // is never a green/connected moment without the fence up (closes the
    // first-connect leak window). Re-engaged each connect (the tunnel LUID changes
    // per session). Fail-safe: if it can't install, refuse to run unprotected.
    _fenceActive = false;
    if (tunMode && settings.killSwitchTun) {
      // Permit EVERY core that makes its OWN outbound — sing-box AND the xray
      // bridge — or the fence blacks out XHTTP / Reality-over-XHTTP, which dial
      // out as the xray process (H1). One path per binary; the WFP app-id
      // condition matches by image, so it covers all xray bridge processes.
      final paths = fencePermitPaths(
        exe,
        CorePaths.xray(),
        xrayAvailable: xrayAvailable,
        awgExe: CorePaths.awg(),
        awgAvailable: awgAvailable,
      );
      // tun0 can lag the core's start, so the native engage may miss the LUID on
      // the first try. RETRY here (off the UI thread — each await yields), instead
      // of Sleep-blocking the native platform thread, before giving up.
      var ok = false;
      for (var i = 0; i < 10 && !ok; i++) {
        if (_proc == null || !_autoReconnect) return; // died/stopped mid-retry
        ok = await NativeAdmin.fenceEngage(paths);
        if (!ok) await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      _fenceActive = ok;
      if (!ok) {
        // BLOCK-on-fail: the user EXPLICITLY enabled the kill-switch. Running TUN
        // unprotected would be a silent fail-OPEN — refuse. _proc?.kill() routes
        // through the identity-guarded _onExit (the _fenceFailed flag → a clear
        // error); clear _restarting so restart() can't relaunch into the failure.
        _log(
          'kill-switch: WFP fence could NOT install — refusing to run unprotected',
        );
        _fenceFailed = true;
        _autoReconnect = false;
        _restarting = false;
        // Clear any stale green fence-state from a prior session so the error
        // screen doesn't show a redundant "unblock" prompt (the fence is NOT up).
        if (state.fenceActive) state = state.copyWith(fenceActive: false);
        _proc?.kill();
        return;
      }
      _log('kill-switch: TUN fence engaged (fail-closed)');
    }
    // Reflect the real fence state even if we bail below: if the core died during
    // the engage await, the WFP fence is physically up, so the Home chip mustn't
    // flicker off through the reconnect window.
    if (_fenceActive && state.fenceActive != true) {
      state = state.copyWith(fenceActive: true);
    }
    // The core may have died (or a Stop landed) DURING the fence-engage await —
    // _onExit already set the right state; don't overwrite it with "running".
    if (_proc == null || !_autoReconnect) return;

    state = state.copyWith(
      status: CoreStatus.running,
      version: version,
      error: null,
      detail: null,
      whitelistMode: false, // fresh (re)connect — re-detect from clean
      tunnelDark: false,
      fenceActive: _fenceActive,
    );
    _whitelistMode = false;
    _exitRetries = 0;
    _healthFails = 0;
    // ②: refresh the ТСПУ-fact feed THROUGH the now-live tunnel (github-raw is
    // blocked direct in RF). Fire-and-forget; applies to the NEXT build. A newer
    // doc updates the desync list / freeze probe with no app release.
    Future.microtask(
      () => ref.read(censorshipFactsProvider.notifier).refresh(),
    );
    // Bringing a TUN up reshuffles routes/adapters → a burst of addr-change
    // events for ~10s. Ignore them so we don't restart the tunnel for its OWN
    // setup churn (the "reconnects every few seconds right after connect" storm).
    _settleUntil = DateTime.now().add(const Duration(seconds: 12));
    // Mark "was connected" for resume-on-launch — but ONLY for a real server.
    // A no-server mode (m0Local) has nothing to resume TO, so flagging it would
    // auto-"reconnect" into a confusing "no VPN" state next launch.
    if (node != null || useAuto) _writeConnectedFlag();
    _startHop();
    _startWatchdog();
    // NOTE: winws desync is NOT started here. It's a tunnel-INDEPENDENT,
    // toggle-driven server-less service (managed by the settingsProvider listener
    // + the on-launch reconcile in build()), so connecting/disconnecting leaves it
    // exactly as the toggle dictates — the user can run the bypass with no profile.
  }

  /// Spawn the zapret/WinDivert desync sidecar (winws.exe) when the "DPI bypass
  /// without a server" toggle is on. It rewrites the outbound TLS ClientHello on
  /// any DIRECT :80/:443 egress (the browser's own socket OR sing-box's direct
  /// outbound) so ТСПУ can't match the SNI — a SERVER-LESS bypass of the TLS-DPI
  /// block class. Pure-additive: no config/proxy change, reaped with the bridges.
  ///
  /// Sets [CoreState.desyncEngine] so the UI can show active / needs-admin /
  /// engine-missing. WinDivert loads a kernel driver → needs admin; absent the
  /// binary (fetched separately, like xray) it's a clean no-op, not a failure.
  ///
  /// SERIALIZED so two reconciles never overlap: the start-of-connect call and a
  /// live hot-swap can genuinely race, and a call arriving mid-spawn just sets
  /// [_desyncPending] so the in-flight one loops once more with the freshest
  /// settings (no leaked process). NOTE: rapid UI bursts (slider/method taps) are
  /// collapsed earlier by the 400ms debounce in [_scheduleDesyncReapply] — this
  /// loop handles genuine overlap, NOT de-bouncing (don't remove the debounce).
  Future<void> _spawnDesyncEngine() async {
    if (_desyncBusy) {
      _desyncPending = true; // the active call will pick the new settings up
      return;
    }
    _desyncBusy = true;
    try {
      do {
        _desyncPending = false;
        await _applyDesyncOnce();
      } while (_desyncPending);
    } finally {
      _desyncBusy = false;
    }
  }

  /// One reconcile against the CURRENT settings. Only ever called (serialized) from
  /// [_spawnDesyncEngine]. No-ops if winws is already running with the exact same
  /// effective config (method + hostlist) — so a feed version bump or a same-value
  /// settings emit doesn't needlessly churn the WinDivert driver.
  Future<void> _applyDesyncOnce() async {
    final settings = ref.read(
      settingsProvider,
    ); // freshest, never a stale snapshot
    // ②/④ Use the auto-escalated preset + rotated decoy SNI when set, else the
    // user's chosen preset (with the baked gosuslugi.ru decoy).
    final strat = _desyncAutoStrategy ?? settings.desyncStrategy;
    final decoy = _desyncAutoStrategy != null
        ? decoySnis[_desyncDecoyIdx % decoySnis.length]
        : null;
    final sniOn = settings.winwsDesync;
    final hostlist = sniOn
        ? DesyncConfig.hostlistContent([
            ...DesyncConfig.defaultHosts,
            ...SingBoxConfig.desyncDomains,
          ])
        : '';
    // Signature of the desired live state. If winws is already up with this exact
    // config, there's nothing to do — skip the kill+respawn churn.
    final desiredSig =
        sniOn ? 'sni=$sniOn|$strat${decoy ?? ''}$hostlist' : 'off';
    if (_winwsProc != null && desiredSig == _lastDesyncSig) return;
    // Drop any running winws and WAIT for it to exit, so its exclusive WinDivert
    // handle is released before a replacement binds — otherwise a method swap
    // intermittently fails to bind the callout (a brief two-process overlap).
    final old = _winwsProc;
    _winwsProc = null;
    if (old != null) {
      old.kill();
      var exited = true;
      await old.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          exited = false;
          return -1;
        },
      );
      if (!exited) {
        // Old winws ignored the kill — proceeding could briefly overlap two
        // engines on the exclusive WinDivert handle (rare: kill() is
        // TerminateProcess on Windows, normally immediate). Log for diagnosis.
        _log(
          'desync: previous winws slow to exit — replacement may briefly overlap',
        );
      }
    }
    if (!sniOn) {
      _lastDesyncSig = 'off';
      if (state.desyncEngine != DesyncEngineStatus.off) {
        state = state.copyWith(desyncEngine: DesyncEngineStatus.off);
      }
      return;
    }
    final exe = CorePaths.winws();
    if (!File(exe).existsSync()) {
      _lastDesyncSig = null; // not running → re-try on the next reconcile
      _log(
        'desync: winws.exe not installed — server-less DPI bypass unavailable',
      );
      state = state.copyWith(desyncEngine: DesyncEngineStatus.missing);
      return;
    }
    if (!await NativeAdmin.isElevated()) {
      _lastDesyncSig = null; // re-try once elevated
      _log(
        'desync: WinDivert needs admin — relaunch elevated to enable bypass',
      );
      state = state.copyWith(desyncEngine: DesyncEngineStatus.needsAdmin);
      return;
    }
    try {
      final dir = CorePaths.runtimeDir().path;
      final hostlistPath = '$dir${Platform.pathSeparator}desync_hostlist.txt';
      // Old winws has already fully exited (awaited above), so this write can't
      // race a reader.
      File(hostlistPath).writeAsStringSync(hostlist);
      // fake-QUIC decoy ships beside winws.exe (fetched together). Present → use as
      // the fake payload (QUIC/443 HTTP-3 block); absent → no payload-less QUIC fake
      // that could break HTTP-3, so the SNI/QUIC block stays gated on the .bin.
      final coreDir = File(exe).parent.path;
      final quicBin = '$coreDir${Platform.pathSeparator}quic_initial.bin';
      final quic = File(quicBin).existsSync() ? quicBin : null;
      final args = DesyncConfig.winwsArgs(
        hostlistPath: hostlistPath,
        strategy: strat,
        quicPayloadPath: quic,
        decoySni: decoy,
        sni: sniOn,
      );
      final p = await Process.start(exe, args, workingDirectory: dir);
      // The toggle may have been switched OFF during the spawn await → reap the
      // process we just started (don't leave a winws the user just disabled).
      // Gated on the TOGGLE, not the tunnel — winws runs independent of Connect.
      final fresh = ref.read(settingsProvider);
      if (!fresh.winwsDesync) {
        p.kill();
        _lastDesyncSig = 'off';
        if (state.desyncEngine != DesyncEngineStatus.off) {
          state = state.copyWith(desyncEngine: DesyncEngineStatus.off);
        }
        return;
      }
      _winwsProc = p;
      _lastDesyncSig = desiredSig;
      _recordPid('winws.exe', p.pid);
      _drainStdio(
        p,
        'winws',
      ); // chatty cygwin build — drain so the pipe can't block
      // Observe a SELF-exit (driver conflict / AV kill / crash): flip the card off
      // "active" so the status never lies, AND self-heal by respawning if it should
      // still be running (capped per connect). Identity-guarded so a deliberate kill
      // (teardown / hot-swap, which nulls or replaces _winwsProc) is ignored.
      unawaited(
        p.exitCode.then((_) {
          if (!identical(_winwsProc, p)) return;
          _winwsProc = null;
          _lastDesyncSig = null;
          if (state.desyncEngine == DesyncEngineStatus.active) {
            state = state.copyWith(desyncEngine: DesyncEngineStatus.off);
          }
          _log('desync: winws exited unexpectedly');
          // Self-heal if either toggle is still ON (tunnel-independent), capped.
          final s = ref.read(settingsProvider);
          if (s.winwsDesync && _desyncRespawns < 5) {
            _desyncRespawns++;
            _scheduleDesyncReapply(); // bring it back after a transient AV/driver kill
          }
        }),
      );
      _log('desync: winws engaged ('
          '${sniOn ? strat : 'sni-off'}'
          '${decoy != null ? ', decoy $decoy' : ''})');
      state = state.copyWith(desyncEngine: DesyncEngineStatus.active);
      // A spawn that SURVIVES a while isn't a crash-loop → restore the self-heal
      // budget, so a later transient AV/driver kill can still recover even for a
      // server-less user who never presses Connect (start() is the only other
      // reset point). Identity-guarded to this exact process.
      _desyncHealthyTimer?.cancel();
      _desyncHealthyTimer = Timer(const Duration(seconds: 60), () {
        if (identical(_winwsProc, p)) _desyncRespawns = 0;
      });
    } catch (e) {
      _lastDesyncSig = null;
      _log('desync: winws failed to start: $e');
      state = state.copyWith(desyncEngine: DesyncEngineStatus.off);
    }
  }

  /// ② Advance the server-less desync to its NEXT preset + rotate the ④ decoy SNI,
  /// then re-apply — for when the current preset isn't unblocking a site. The
  /// reliable trigger is the diagnostic / a user tap (the user can SEE the page
  /// didn't open), NOT a fragile always-on canary that could cycle off a working
  /// preset. Returns false when every preset is exhausted (a genuine block the
  /// desync can't fix), bounding the WinDivert churn to one pass through the presets.
  bool desyncEscalate() {
    final s = ref.read(settingsProvider);
    if (!s.winwsDesync) return false;
    _desyncTried.add(_desyncAutoStrategy ?? s.desyncStrategy);
    final next = DesyncConfig.nextStrategy(_desyncTried);
    if (next == null) return false; // exhausted — leave the user on their preset
    _desyncAutoStrategy = next;
    _desyncDecoyIdx++;
    _log('desync: escalating to preset "$next" (current not unblocking the site)');
    _scheduleDesyncReapply();
    return true;
  }

  /// Drain a child process's stdout/stderr to the log so a full OS pipe buffer can
  /// never block it (a real hang risk for a long-lived, chatty child). Shared.
  void _drainStdio(Process p, String prefix) {
    const decoder = Utf8Decoder(allowMalformed: true);
    p.stdout
        .transform(decoder)
        .transform(const LineSplitter())
        .listen((l) => _log('$prefix: $l'), onError: (_) {});
    p.stderr
        .transform(decoder)
        .transform(const LineSplitter())
        .listen((l) => _log('$prefix: $l'), onError: (_) {});
  }

  /// Reconcile the winws sidecar with the current toggle/method — DEBOUNCED (a
  /// burst of taps collapses to one) and serialized via [_spawnDesyncEngine]. NOT
  /// gated on the tunnel: winws is a server-less, toggle-driven bypass that runs
  /// with or without a connection / profile.
  void _scheduleDesyncReapply() {
    _desyncReapplyDebounce?.cancel();
    _desyncReapplyDebounce = Timer(
      const Duration(milliseconds: 400),
      _spawnDesyncEngine,
    );
  }

  /// Replace XHTTP outbounds with a `socks` outbound dialed by a per-outbound
  /// xray-core process — bridging transports sing-box can't do. Gated by the
  /// caller on the xray binary's presence.
  ///
  /// Each generated bridge config is VALIDATED with `xray run -test` BEFORE its
  /// outbound is rewritten to socks: an xray that REJECTS the config (a wrong-
  /// typed XHTTP `extra`, an unsupported param, an AV-quarantined / crashing
  /// binary) must never leave a socks outbound pointing at a dead 127.0.0.1 port
  /// — that node would be silently dead (the class this project fights hardest).
  /// A member we can't bring up is collected and, after the loop, DROPPED from the
  /// config — never left as `type: xhttp` (which would FATAL the whole core and
  /// take every other node down with it). If the prune leaves no usable exit,
  /// [_bridgeError] is set so start() surfaces a precise error instead of running.
  Future<Map<String, dynamic>> _bridgeXray(Map<String, dynamic> cfg) async {
    final outs = (cfg['outbounds'] as List?) ?? const [];
    var port = 24100;
    final dead = <String>{}; // tags whose bridge we could NOT bring up
    final reasons =
        <String>[]; // precise per-member reason, for the error detail
    for (var i = 0; i < outs.length; i++) {
      final o = outs[i];
      if (o is! Map || !XrayConfig.needsXray(o)) continue;
      final tag = o['tag']?.toString();
      final xcfg = XrayConfig.fromOutbound(o, port);
      // needsXray (an xhttp/splithttp transport) but the bridge can't build it
      // (a protocol it doesn't support) — can't leave `type: xhttp`, so drop it.
      if (xcfg == null) {
        if (tag != null) dead.add(tag);
        reasons.add(
          '${tag ?? '?'}: transport not supported by the xray bridge',
        );
        continue;
      }
      final path =
          '${CorePaths.runtimeDir().path}${Platform.pathSeparator}xray-$port.json';
      final problem = await _spawnXrayBridge(path, xcfg);
      if (problem != null) {
        if (tag != null) dead.add(tag);
        reasons.add('${tag ?? '?'}: $problem');
        continue; // do NOT rewrite to socks — handled by the prune below
      }
      outs[i] = {
        'type': 'socks',
        'tag': o['tag'],
        'server': '127.0.0.1',
        'server_port': port,
        'version': '5',
      };
      port++;
    }
    if (dead.isNotEmpty) {
      // Drop the un-bridgeable members + scrub them from any group; if a usable
      // exit survives, run the pruned pool (the cascade/selector hop past the dead
      // member), else flag a precise error so start() never launches a config that
      // routes everything direct or sits silent-dead.
      _log(
        'xray bridge: ${dead.length} member(s) failed — '
        '${reasons.join('; ')}',
      );
      if (!SingBoxConfig.pruneDeadOutbounds(cfg, dead)) {
        _bridgeError = reasons.join('; ');
      }
    }
    return cfg;
  }

  /// Write [xcfg] to [path], VALIDATE it with `xray run -test` (exit 0 = OK), then
  /// spawn the real bridge. Returns null on success, or a concise reason the
  /// bridge could not be brought up (config rejected / spawn failed) so the caller
  /// can drop the member instead of pointing a socks outbound at a dead port —
  /// turning a silent-dead node into a clear, actionable error.
  Future<String?> _spawnXrayBridge(
    String path,
    Map<String, dynamic> xcfg,
  ) async {
    try {
      File(path).writeAsStringSync(XrayConfig.encode(xcfg));
    } catch (e) {
      return 'could not write bridge config: $e';
    }
    // Deterministic pre-validation against the REAL xray schema. An exception here
    // (binary missing / AV-quarantined / unrunnable) means we CANNOT trust the
    // bridge — fail the member rather than risk a silent-dead socks outbound.
    try {
      // `run -test` is a fast config parse, but it sits in start()'s critical path
      // once per XHTTP member — cap it so a wedged xray (e.g. an AV filter driver
      // intercepting the exe) surfaces as a failed member instead of hanging the
      // whole connect forever. TimeoutException is caught below → member dropped.
      final r = await Process.run(
        CorePaths.xray(),
        ['run', '-test', '-c', path],
        workingDirectory: CorePaths.runtimeDir().path,
      ).timeout(const Duration(seconds: 15));
      if (r.exitCode != 0) return _firstXrayError('${r.stderr}\n${r.stdout}');
    } catch (e) {
      return 'xray could not validate the bridge config: $e';
    }
    try {
      final p = await Process.start(CorePaths.xray(), [
        'run',
        '-c',
        path,
      ], workingDirectory: CorePaths.runtimeDir().path);
      _xrayProcs.add(p);
      _recordPid('xray.exe', p.pid);
      _drainStdio(
        p,
        'xray',
      ); // else a chatty bridge fills its pipe → silent-dead node
      return null;
    } catch (e) {
      return 'xray bridge failed to start: $e';
    }
  }

  // Pull the most specific message out of xray's chained
  // "Failed to start: a > b > root-cause" diagnostic (the last `>` segment is the
  // real reason); falls back to the first non-empty, non-banner line.
  static String _firstXrayError(String out) {
    final clean = out.replaceAll(_ansi, '');
    for (final line in const LineSplitter().convert(clean)) {
      if (line.contains('Failed to start') || line.contains('infra/conf')) {
        return line.split('>').last.trim();
      }
    }
    for (final line in const LineSplitter().convert(clean)) {
      final t = line.trim();
      if (t.isNotEmpty &&
          !t.startsWith('Xray ') &&
          !t.startsWith('A unified')) {
        return t;
      }
    }
    return 'invalid xray bridge config';
  }

  /// Replace AmneziaWG endpoints with a `socks` outbound dialed by an `awg`
  /// userspace bridge — the obfuscated WireGuard (jc/jmin/s1-s4/h1-h4) that
  /// neither sing-box nor xray can speak. Same pattern as [_bridgeXray]: write
  /// the bridge's wireproxy config, spawn it, and rewrite the endpoint into a
  /// plain socks outbound on its local SOCKS port. Gated by the caller on the
  /// awg binary's presence (absent → AmneziaWG stays detect-and-fail).
  Future<Map<String, dynamic>> _bridgeAmnezia(Map<String, dynamic> cfg) async {
    final eps = (cfg['endpoints'] as List?) ?? const [];
    if (eps.isEmpty) return cfg;
    cfg['outbounds'] ??= <dynamic>[];
    final outs = cfg['outbounds'] as List;
    var port = 24300;
    final keep = <dynamic>[];
    for (final e in eps) {
      if (e is! Map || !AmneziaConfig.needsAmnezia(e)) {
        keep.add(e);
        continue;
      }
      final ini = AmneziaConfig.fromEndpoint(e, port);
      if (ini == null) {
        keep.add(e);
        continue;
      }
      final path =
          '${CorePaths.runtimeDir().path}${Platform.pathSeparator}awg-$port.conf';
      try {
        File(path).writeAsStringSync(ini);
        final p = await Process.start(CorePaths.awg(), [
          '-c',
          path,
        ], workingDirectory: CorePaths.runtimeDir().path);
        _xrayProcs.add(p); // all bridge procs are reaped together
        _recordPid('awg.exe', p.pid);
        _drainStdio(
          p,
          'awg',
        ); // drain so a chatty bridge can't block on a full pipe
        // The endpoint now rides a plain socks proxy on 127.0.0.1:$port, so the
        // route `final`/rules that referenced its tag still resolve.
        outs.add({
          'type': 'socks',
          'tag': e['tag'] ?? 'wg',
          'server': '127.0.0.1',
          'server_port': port,
          'version': '5',
        });
        port++;
        // endpoint dropped (replaced by the socks outbound above)
      } catch (_) {
        keep.add(e); // bridge failed to start — leave it; the core reports it
      }
    }
    // Any endpoint we KEPT may still carry `_amneziawg` (preserved through
    // fromConfig so we could detect/bridge it, then the bridge failed or it was a
    // non-amnezia WG endpoint). The bundled core FATALs on unknown fields, so strip
    // every `_`-prefixed marker now that bridging is done.
    for (final e in keep) {
      if (e is Map) e.removeWhere((k, _) => k.toString().startsWith('_'));
    }
    if (keep.isEmpty) {
      cfg.remove('endpoints');
    } else {
      cfg['endpoints'] = keep;
    }
    return cfg;
  }

  void _killXray() {
    for (final p in _xrayProcs) {
      p.kill();
    }
    _xrayProcs.clear();
    // NOTE: winws is NOT reaped here. It's a tunnel-INDEPENDENT, toggle-driven
    // server-less sidecar — a tunnel stop/restart must NOT kill it (the user can be
    // running the bypass with no profile at all). It's reaped only on toggle-off
    // (_applyDesyncOnce) and on onDispose.
  }

  File get _pidFile =>
      File('${CorePaths.runtimeDir().path}${Platform.pathSeparator}core.pids');

  // Remember a spawned core's PID so the NEXT launch can reap only OUR orphans.
  void _recordPid(String image, int pid) {
    try {
      _pidFile.writeAsStringSync('$image\t$pid\n', mode: FileMode.append);
    } catch (_) {}
  }

  // Kill cores orphaned by a previous run/crash (they still hold the local
  // port). Scoped to the PIDs WE spawned and gated on the image name, so we
  // never nuke another VPN client's sing-box/xray (Hiddify/Throne bundle it too)
  // or a second instance — the old blanket `taskkill /IM` did exactly that.
  // Absolute path to a Windows\System32 tool so we never resolve `taskkill` /
  // `netstat` via PATH or the CWD — CreateProcess searches the working directory
  // first, so a planted taskkill.exe could otherwise run with our
  // process-killing intent. Falls back to the bare name only if SystemRoot is
  // somehow unset (then CreateProcess searches PATH as before).
  static String _sys32(String exe) {
    final root =
        Platform.environment['SystemRoot'] ?? Platform.environment['windir'];
    return (root == null || root.isEmpty) ? exe : '$root\\System32\\$exe';
  }

  Future<void> _killOrphanCores() async {
    if (!Platform.isWindows) return;
    // Reap the PIDs we recorded (if core.pids exists) — but then ALWAYS sweep the
    // ports below, because an orphan from a force-killed / crashed run may not be
    // in core.pids at all (a prior reap deletes it). The old `if (!exists) return`
    // skipped the port sweep entirely, so such an orphan held 2080/9090 forever.
    try {
      if (_pidFile.existsSync()) {
        final content = _pidFile.readAsStringSync();
        for (final line in const LineSplitter().convert(content)) {
          final parts = line.split('\t');
          if (parts.length != 2) continue;
          final image = parts[0];
          final pid = int.tryParse(parts[1]);
          if (pid == null) continue;
          try {
            // /FI "IMAGENAME eq ..." ensures we only kill if that PID is still one
            // of our cores (guards against PID reuse by an unrelated process).
            await Process.run(_sys32('taskkill.exe'), [
              '/F',
              '/PID',
              '$pid',
              '/FI',
              'IMAGENAME eq $image',
            ]);
          } catch (_) {}
        }
        _pidFile.deleteSync();
      }
    } catch (_) {}
    await _freeCorePorts(); // ALWAYS — netstat sweep catches unrecorded orphans
    await _killOrphanWinws(); // winws has no port + may have lost its pid-record
  }

  // winws is a kernel-callout sidecar with NO listening port, so [_freeCorePorts]
  // can't catch it, and a clean Stop removes its core.pids record BEFORE a slow /
  // ignored kill fully reaps it — so a previous run's winws can survive, holding
  // the exclusive WinDivert handle and desyncing live :80/:443 with a STALE
  // hostlist (which breaks the next launch). Reap any winws by image name,
  // EXCLUDING our own current one (so a resume that already brought the sidecar up
  // isn't killed). Only our app ships winws.exe under this name; the rare cost is
  // stopping another zapret/winws instance at our startup (acceptable vs. an
  // invisible orphan mangling the live :443).
  Future<void> _killOrphanWinws() async {
    if (!Platform.isWindows) return;
    final keep = _winwsProc?.pid ?? 0; // 0 matches no process → reaps all winws
    try {
      await Process.run(_sys32('taskkill.exe'), [
        '/F',
        '/IM',
        'winws.exe',
        '/FI',
        'PID ne $keep',
      ]);
    } catch (_) {}
  }

  // Belt-and-suspenders: if anything (a crash orphan, a second copy) still holds
  // our local ports, kill it — but ONLY if that PID is one of our core images,
  // so we never touch an unrelated process. (An ELEVATED holder can't be killed
  // from a non-elevated app — that surfaces as a clear "port in use" error.)
  Future<void> _freeCorePorts() async {
    if (!Platform.isWindows) return;
    final pids = <int>{};
    try {
      final r = await Process.run(_sys32('netstat.exe'), ['-ano', '-p', 'TCP']);
      for (final line in const LineSplitter().convert('${r.stdout}')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 5 || parts[3].toUpperCase() != 'LISTENING') continue;
        final local = parts[1];
        if (local.endsWith(':${SingBoxConfig.mixedPort}') ||
            local.endsWith(':${SingBoxConfig.clashPort}')) {
          final pid = int.tryParse(parts[4]);
          if (pid != null) pids.add(pid);
        }
      }
    } catch (_) {
      return;
    }
    for (final pid in pids) {
      for (final img in const ['sing-box.exe', 'xray.exe']) {
        try {
          await Process.run(_sys32('taskkill.exe'), [
            '/F',
            '/PID',
            '$pid',
            '/FI',
            'IMAGENAME eq $img',
          ]);
        } catch (_) {}
      }
    }
  }

  // Run `sing-box check` on the generated config. Returns null if valid, else a
  // concise reason. If check itself can't run, returns null (don't block).
  Future<String?> _preflightCheck(
    String exe,
    String cfgPath, {
    Map<String, String> env = _coreEnv,
  }) async {
    try {
      final r = await Process.run(
        exe,
        ['check', '-c', cfgPath],
        workingDirectory: CorePaths.runtimeDir().path,
        environment: env,
      );
      if (r.exitCode == 0) return null;
      return _firstFatal('${r.stderr}\n${r.stdout}');
    } catch (_) {
      return null;
    }
  }

  // Extract the human message from sing-box's `FATAL[0000] <msg>` (ANSI-stripped).
  String _firstFatal(String out) {
    final clean = out.replaceAll(_ansi, '');
    for (final line in const LineSplitter().convert(clean)) {
      if (line.contains('FATAL') || line.contains('ERROR')) {
        final i = line.indexOf('] ');
        return (i >= 0 ? line.substring(i + 2) : line).trim();
      }
    }
    return clean.trim().split('\n').first.trim();
  }

  /// User-initiated disconnect: tear down AND restore the real system proxy.
  Future<void> stop() async {
    _autoReconnect = false;
    _restarting = false; // cancels any in-flight restart's pending start()
    _adaptStep = 0; // user stop → next connect uses their own settings
    _healthFails = 0;
    _hop?.cancel();
    _reconnect?.cancel();
    _netDebounce?.cancel();
    _watchdog?.cancel();
    // Also cancel the live-apply debounces — else a settings/desync change armed
    // just before Stop fires after a quick reconnect and spuriously restarts /
    // hot-swaps the freshly-started tunnel.
    _settingsRestartDebounce?.cancel();
    _desyncReapplyDebounce?.cancel();
    final proc = _proc;
    if (proc == null) {
      await _restoreProxy();
      _killXray(); // bridges only — winws is tunnel-independent (see _killXray)
      _clearPids();
      _clearConnectedFlag();
      _disengageFence();
      state = state.copyWith(status: CoreStatus.stopped);
      return;
    }
    state = state.copyWith(status: CoreStatus.stopping);
    proc.kill();
    // _onExit (chained on exitCode) restores the proxy + sets `stopped`.
    await proc.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  }

  /// Switch/refresh the active node WITHOUT a fail-open gap. Unlike [stop], the
  /// system proxy stays pointed at the local port across the swap, so traffic
  /// fails CLOSED (blocked, never direct onto a hostile RF network) while the
  /// new core comes up. This is the common path on a Wi-Fi/Ethernet/wake change.
  Future<void> restart({
    bool keepAdapt = false,
    String reason = 'manual',
  }) async {
    if (_restarting) return; // a swap is already in flight
    _restarting = true;
    // Seamless: while we swap the core (proxy stays pinned, traffic fails closed),
    // show "Checking…" not the "Connecting…" spinner — but ONLY if we were already
    // connected, so a restart() used as a first connect still reads as Connecting.
    if (state.isOn) state = state.copyWith(swapping: true);
    _appLog('restart ($reason)');
    _exitRetries = 0; // user-initiated switch/import: fresh retry budget
    _hopFails.clear(); // fresh topology → fresh probe-fail counters
    _triedTransports.clear(); // fresh cascade
    _allTransportsDark = false;
    _healthyStreak = 0;
    _rttBaseline = null; // fresh path → fresh degradation baseline
    _degradeStreak = 0;
    _proactiveCooldown = 0;
    // A node switch / new network / fresh connect starts from the user's own
    // settings again; only the auto-adapt loop keeps its current variant. The
    // freeze debounce resets too so we re-detect from clean.
    if (!keepAdapt) {
      _adaptStep = 0;
      _freezeFails = 0;
    }
    try {
      _hop?.cancel();
      _reconnect?.cancel();
      final proc = _proc;
      if (proc != null) {
        proc.kill();
        await proc.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      }
      // Reap the OLD xray bridges deterministically — don't rely on the old
      // _onExit (a >5s teardown delays it past start(), and the identity guard
      // now ignores a stale exit). Idempotent if _onExit already cleared them.
      // (winws is NOT touched — it's tunnel-independent, driven by its toggle.)
      _killXray();
      // If the old core didn't exit within the timeout it's still holding ports
      // 2080/9090; null our handle so start()'s `_proc == null` orphan-sweep frees
      // them — else the new core hits `bind: address already in use` → a spurious,
      // terminal portInUse. The identity-guarded _onExit ignores the late exit.
      _proc = null;
      // _onExit saw _restarting and left the proxy pointed at the (now refused)
      // local port. Bring the new core up — unless a user stop() cancelled us.
      if (_restarting) {
        await start();
      }
    } finally {
      // Always reset, even if start() threw, so the flag can't get stuck true
      // (which would make a later normal start() bypass its busy guard).
      _restarting = false;
      // Clear the swap indicator — start() has settled the real status by now.
      if (state.swapping) state = state.copyWith(swapping: false);
    }
  }

  Future<void> _onExit(int code, [Process? proc]) async {
    // Identity guard: a SLOW old sing-box whose exitCode lands AFTER restart()'s
    // 5s timeout fired and start() already spawned a FRESH _proc + xray bridges
    // must NOT clobber the new session (null its _proc, kill its bridges). Ignore
    // a stale exit — restart() reaps the old bridges itself before start().
    if (proc != null && !identical(_proc, proc)) return;
    _proc = null;
    _hop?.cancel();
    _watchdog
        ?.cancel(); // stop probing a dead core (re-armed by the next start())
    _netDebounce?.cancel();
    _killXray();
    // The fail-closed contract lives in the unit-tested [decideExit] — this just
    // executes the outcome. exitRetries is passed AS IF this death is tallied
    // (only the gaveUp-vs-reconnect split uses it); the reconnect branch persists
    // the increment for the backoff.
    final d = decideExit(
      restarting: _restarting,
      stopping: state.status == CoreStatus.stopping,
      autoReconnect: _autoReconnect,
      portConflict: _portConflict,
      wgDead: _wgDead,
      exitRetries: _exitRetries + 1,
      fenceFailed: _fenceFailed,
      killSwitchActive: _fenceActive,
    );
    switch (d.outcome) {
      case ExitOutcome.restartingKeepClosed:
        // The swap owns the relaunch; the proxy stays at our port (fail CLOSED).
        return;
      case ExitOutcome.stopRestore:
        await _finishExit(
          d,
          CoreStatus.stopped,
        ); // deliberate stop — keep any detail
        return;
      case ExitOutcome.portInUse:
        // Not transient (another copy/orphan holds the port) — looping spams
        // FATALs. Stop, restore connectivity, tell the user.
        _portConflict = false;
        _autoReconnect = false;
        await _finishExit(
          d,
          CoreStatus.error,
          error: CoreError.portInUse,
          detail: null,
        );
        return;
      case ExitOutcome.wireguardDead:
        // Plain-WG dial to an Amnezia/blocked endpoint never handshook — futile
        // to retry. Nothing was ever protected (zero traffic), so restore + tell
        // the user to switch to Reality/Hysteria.
        _wgDead = false;
        _wgHandshakeFails = 0;
        _autoReconnect = false;
        await _finishExit(
          d,
          CoreStatus.error,
          error: CoreError.wireguardHandshake,
          detail: null,
        );
        return;
      case ExitOutcome.gaveUp:
        _autoReconnect = false;
        await _finishExit(
          d,
          CoreStatus.error,
          error: CoreError.gaveUp,
          detail: null,
        );
        return;
      case ExitOutcome.gaveUpFenced:
        // Kill-switch ON: give up but STAY fail-CLOSED (fence + proxy kept). The
        // unblock button (status==error && fenceActive) lets the user disconnect.
        _autoReconnect = false;
        await _finishExit(
          d,
          CoreStatus.error,
          error: CoreError.gaveUp,
          detail: null,
        );
        return;
      case ExitOutcome.killSwitchFailed:
        // Fence couldn't install + the user wanted the kill-switch → we refused to
        // run unprotected. Restore connectivity (nothing was protected) + a clear
        // error so they can fix it (run as admin / turn the kill-switch off).
        _fenceFailed = false;
        _autoReconnect = false;
        await _finishExit(
          d,
          CoreStatus.error,
          error: CoreError.killSwitchFailed,
          detail: null,
        );
        return;
      case ExitOutcome.reconnect:
        // Unexpected death: fail CLOSED (proxy NOT restored, fence stays up) and
        // retry with backoff so a block/crash never leaks during the gap.
        _exitRetries++;
        state = state.copyWith(
          status: CoreStatus.error,
          error: CoreError.reconnecting,
          detail: null,
        );
        _reconnect?.cancel();
        final secs = (2 * _exitRetries).clamp(2, 30);
        _reconnect = Timer(Duration(seconds: secs), () {
          if (_autoReconnect &&
              _proc == null &&
              state.status != CoreStatus.running) {
            start();
          }
        });
        return;
    }
  }

  // Common teardown for a deliberate stop / terminal exit: drop our proxy
  // pointer, optionally restore the user's real proxy + drop the fence (per the
  // [decideExit] flags), and clear the run markers. [error]/[detail] default to
  // "leave as-is" (a clean stop keeps them) — terminals pass explicit values.
  Future<void> _finishExit(
    ExitDecision d,
    CoreStatus status, {
    Object? error = _unset,
    Object? detail = _unset,
  }) async {
    // Only drop our proxy pointer when we actually restore the user's — a
    // fail-CLOSED give-up (gaveUpFenced) keeps the proxy at our dead local port
    // so proxy-aware apps stay blocked, not leaking direct. AWAIT the clear so a
    // user who closes the app right after a give-up isn't left on a dead local
    // proxy (the native OnDestroy/next-launch restore is the backstop).
    if (d.restoreProxy) {
      _proxyActive = false;
      await SystemProxy.clear();
    }
    _clearPids();
    _clearConnectedFlag();
    if (d.disengageFence) _disengageFence();
    // winws is tunnel-independent (toggle-driven) — a core exit does NOT touch its
    // status; leave desyncEngine as-is.
    state = state.copyWith(status: status, error: error, detail: detail);
  }

  // Tapping the button while CONNECTING (or disconnecting) cancels — a stuck
  // "Connecting…" the user can't abort is worse than a failed connect.
  Future<void> toggle() => (state.isOn || state.isBusy) ? stop() : start();

  /// A network change (Wi-Fi↔Ethernet, IP/route change): reconnect on the new
  /// path. Debounced, since a single change emits a burst of events.
  void onNetworkChanged() {
    // Only relevant while connected — an actual core death is handled by
    // _onExit's kill-switch + auto-reconnect.
    if (!state.isOn) return;
    _netDebounce?.cancel();
    _netDebounce = Timer(const Duration(seconds: 3), () async {
      if (!shouldActOnNetworkChange(
        isOn: state.isOn,
        restarting: _restarting,
      )) {
        return;
      }
      // Don't tear a freshly-built tunnel down for its OWN setup churn (TUN
      // creation fires a burst of addr changes).
      final settle = _settleUntil;
      if (settle != null && DateTime.now().isBefore(settle)) return;
      // sing-box's `auto_detect_interface` rebinds to the new default route
      // WITHOUT a restart, so a healthy core needs no intervention. Restarting a
      // live tunnel on every Wi-Fi/address blip is exactly what showed up as
      // "reconnect every few seconds" + lag/packet-loss. Only restart if the
      // core has actually stopped responding.
      final api = ref.read(clashApiProvider);
      if (await api.version() != null) return; // healthy — leave it alone
      // One transient loopback miss during network churn isn't a dead tunnel —
      // confirm with a second probe before a disruptive restart.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!state.isOn || _restarting) return;
      if (await api.version() != null) return;
      if (state.isOn) restart(reason: 'network-change');
    });
  }

  /// Wake-from-sleep liveness check. Windows usually restores the same adapter+IP
  /// on resume, so [onNetworkChanged] never fires and its API-only check would
  /// also pass (the sing-box process survived suspend) — yet the tunnel's TCP to
  /// the server died during sleep. So probe end-to-end THROUGH the tunnel and
  /// reconnect if it's silently dead. Runs regardless of the autoAdapt setting.
  Future<void> onResumed() async {
    if (!shouldProbeOnResume(
      isOn: state.isOn,
      restarting: _restarting,
      adapting: _adapting,
    )) {
      return;
    }
    // Let the NIC/DHCP settle after wake before judging the path.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!shouldProbeOnResume(
      isOn: state.isOn,
      restarting: _restarting,
      adapting: _adapting,
    )) {
      return;
    }
    final api = ref.read(clashApiProvider);
    if (await api.version() != null && await _tunnelHealthy()) return; // alive
    if (state.isOn && !_restarting) {
      restart(reason: 'wake'); // seamless, fail-closed
    }
  }

  /// Adaptive probe-and-hop: if the active member of a Selector group stops
  /// responding (ТСПУ blocked that transport), hop to a member that still
  /// works. URLTest groups already auto-pick by latency, so they're skipped.
  void _startHop() {
    _hop?.cancel();
    _hop = Timer.periodic(const Duration(seconds: 20), (_) => _probeHop());
  }

  Future<void> _probeHop() async {
    if (!state.isOn || _hopping) return;
    // SINGLE OWNER during a dark/degradation episode: the transport-cascade owns
    // switching, so auto-hop steps aside — otherwise the two loops race (a
    // double-switch, or auto-hop re-picking the node the cascade just abandoned).
    if (_adapting || _triedTransports.isNotEmpty || _proactiveCooldown > 0) {
      return;
    }
    _hopping = true;
    try {
      final api = ref.read(clashApiProvider);
      final groups = await api.proxies();
      // URLTest groups already do latency failover across their own members, so
      // a Selector pointing at one must NOT be hopped away — doing so fights the
      // urltest and produces the every-cycle churn (🌍 VPN → 🛡 Whitelist → …)
      // seen with half the server's nodes dead.
      final urltest = {
        for (final g in groups)
          if (g.type == 'URLTest') g.name,
      };
      for (final g in groups) {
        if (g.type != 'Selector' || g.all.length < 2) continue;
        final cur = g.now;
        if (cur == null || urltest.contains(cur)) {
          _hopFails.remove(g.name); // self-healing target — leave it alone
          continue;
        }
        // Current pick is a SPECIFIC node. A single failed probe can be a
        // transient cold-handshake; require 2 consecutive before hopping.
        if (await api.delay(cur) != null) {
          _hopFails.remove(g.name);
          continue;
        }
        final fails = (_hopFails[g.name] ?? 0) + 1;
        _hopFails[g.name] = fails;
        if (fails < 2) continue;
        // Hop to a working member — PREFER a URLTest sub-group (self-healing)
        // over a bare node, so we land on something resilient.
        final ordered = [
          ...g.all.where((m) => urltest.contains(m)),
          ...g.all.where((m) => !urltest.contains(m)),
        ];
        for (final m in ordered) {
          if (m == cur) continue;
          if (await api.delay(m) != null) {
            if (await api.selectProxy(g.name, m)) {
              _appLog('auto-hop: ${g.name} → $m (previous pick dead)');
              _hopFails.remove(g.name);
            }
            break;
          }
        }
      }
    } finally {
      _hopping = false;
    }
  }

  /// Transport-cascade hop: the active path is dark. Hop (restart-free) to a
  /// member of a DIFFERENT transport family than the current leaf — Reality→Hy2→
  /// XHTTP→TUIC — trying each family once per dark episode. Returns true if it
  /// switched to a responding different-transport node; false (→ fall back to
  /// fingerprint escalation) when no untried family answers.
  Future<bool> _tryTransportHop(
      {bool freeze = false, bool penaltyOnLeave = true}) async {
    final api = ref.read(clashApiProvider);
    final plan = planCascade(
      await api.proxies(),
      _triedTransports,
      families: _familyByTag,
      insecure: _insecureByTag,
      // A freeze-driven hop prefers a freeze-IMMUNE transport (QUIC/XHTTP) within
      // the same survivability tier — don't land on another frozen Reality+Vision.
      freezeContext: freeze,
      // Learned memory: within a tier, try the family that's been SURVIVING on this
      // network first.
      scores: _transportScores,
    );
    if (plan.selector == null) return false;
    if (plan.leafType != null) {
      _triedTransports.add(plan.leafType!); // dark family
    }
    // Probe the diversity-ordered candidates; count probed vs answered — if some
    // existed but NONE answered, every transport on the server is dark at once =
    // an IP/server block, not per-signature. The /delay probe runs a generate_204
    // THROUGH the candidate outbound (its own timeout covers a cold Reality/QUIC
    // handshake); a throttled-to-zero path that still passes this tiny check is
    // caught separately by the proactive-degradation RTT watch. A pool candidate
    // is probed at its leaf node (delay on a bare node is universally supported)
    // but SELECTED by its group name on the parent selector.
    var probed = 0, answered = 0;
    for (final m in plan.candidates) {
      probed++;
      if (await api.delay(plan.probeFor(m)) == null) continue;
      answered++;
      if (await api.selectProxy(plan.selector!, m)) {
        // LEARN: the family we hopped to answered (survived) → persisted, so next
        // launch the survivor leads its tier.
        _recordTransport(_familyByTag[plan.probeFor(m)], true);
        // ...but only PENALISE the family we left on a GENUINE block/dark hop. A
        // freeze hop (transport-agnostic 16KB volume rule) or a proactive-
        // DEGRADATION hop (the leaf JUST answered — it's slow, not blocked) leaves a
        // family that ISN'T proven dead, so don't teach the cascade to deprioritise
        // it (e.g. demote Reality, the strongest ТСПУ survivor, for a latency spike).
        if (penaltyOnLeave) _recordTransport(plan.leafType, false);
        _appLog(
          'transport-cascade: ${plan.selector} → $m '
          '(${plan.leafType ?? '?'} blocked → fresh family)',
        );
        _allTransportsDark = false;
        return true;
      }
    }
    _allTransportsDark = probed > 0 && answered == 0;
    return false;
  }

  /// Auto-adapt watchdog: while connected, periodically prove the tunnel still
  /// CARRIES traffic. If it goes dark (ТСПУ blocking it) AND the local network
  /// is up, escalate through anti-block variants until one breaks through —
  /// bounded, so a genuinely down/blocked node can't loop forever.
  void _startWatchdog() {
    _watchdog?.cancel();
    _lastDownloadTotal = 0; // fresh baseline: the core's byte counter restarted
    // Always run while connected: even with auto-adapt OFF the watchdog must keep
    // an HONEST liveness signal (tunnelDark + whitelist banner) so the UI never
    // shows green "Connected" on a silently-dead tunnel. Auto-adapt gates only the
    // REMEDIATION (cascade/hop/escalate), not detection (see _checkHealthBody).
    _watchdog = Timer.periodic(
      const Duration(seconds: 18),
      (_) => _checkHealth(),
    );
  }

  Future<void> _checkHealth() async {
    if (!state.isOn || _adapting || _restarting || _inHealthCheck) return;
    _inHealthCheck = true;
    try {
      await _checkHealthBody();
    } finally {
      _inHealthCheck = false;
    }
  }

  Future<void> _checkHealthBody() async {
    // Detection (tunnelDark / whitelist banner) ALWAYS runs; auto-adapt gates only
    // the remediation (episode-clear / freeze-hop / degradation-hop / cascade).
    final st = ref.read(settingsProvider);
    // Hard-network mode forces the active survivor-cascade ON even if auto-adapt
    // is off — on a mobile operator you want it hopping, not sitting dark.
    final adapt = st.autoAdapt || st.maxResistance;
    // A SINGLE synthetic gstatic probe can spuriously time out on a flaky operator
    // (the urltest's parallel probe-burst tripping a per-foreign-IP connection
    // throttle, or a slow probe host) EVEN WHILE real user traffic flows — which
    // would falsely read as "dark" and trigger needless cascade hops that cut live
    // connections (the "constant reconnects" report). So treat the tunnel as alive
    // if EITHER the probe passes OR it actually moved real DOWNLOAD bytes this tick
    // (download = bytes coming back = a working round-trip, not just local retries).
    final trafficMoved = await _downloadGrewSinceLastTick();
    if (trafficMoved || await _tunnelHealthy()) {
      _healthFails = 0;
      _healthyStreak++;
      _clearWhitelistMode(); // real traffic flows ⇒ not in whitelist collapse
      _setTunnelDark(false);
      if (!adapt) {
        return; // detection done; remediation below is auto-adapt's job
      }
      // Clear the cascade's tried-set only on SUSTAINED recovery (#6) — the rule
      // lives in the unit-tested [watchdogShouldClearEpisode], not inline here.
      if (watchdogShouldClearEpisode(
        episodeActive: _triedTransports.isNotEmpty,
        healthyStreak: _healthyStreak,
      )) {
        _triedTransports.clear();
        _allTransportsDark = false;
        _log('auto-adapt: holding — traffic flows (episode cleared)');
      }
      await _checkFreeze(); // L4: a 204 passes but does >16KB still flow?
      await _checkDegradation(); // L3: hop EARLY if the path is degrading
      return;
    }
    _healthFails++;
    _healthyStreak = 0; // a dark tick breaks the recovery streak
    // Debounce the UI dark flag by ONE tick: a single jittery probe-pair fail on a
    // flaky operator shouldn't flicker the headline green→amber→green on an
    // otherwise-fine (idle) tunnel. Flip only after 2 consecutive dark ticks (~36s);
    // the cascade/remediation below still waits for 3 (~54s). Active users never
    // reach here — `trafficMoved` short-circuits above on real download bytes.
    if (_healthFails >= 2) {
      _setTunnelDark(true); // honest UI even with auto-adapt OFF
    }
    if (_healthFails < 3) return; // ~54s of no traffic before acting
    _healthFails = 0;
    if (!adapt) {
      // Auto-adapt OFF → detect-only: still surface the whitelist banner (network
      // collapsed to RU-only) so the dark state is explained, but DON'T hop /
      // escalate / restart — that's auto-adapt's job.
      if (await _directNetworkUp() && !await _foreignNetworkUp()) {
        _latchWhitelistMode();
      }
      return;
    }
    // Decide the dark-path action through the unit-tested orchestrator — keeping
    // the safety-critical ORDER (network gate BEFORE the cascade; IP-block & fp-
    // no-op stops BEFORE an fp-restart) in one place a test locks. We only
    // EXECUTE the chosen action here.
    final action = await runDarkPath(
      networkUp: _directNetworkUp,
      foreignReachable: _foreignNetworkUp,
      tryHop: _tryTransportHop, // sets _allTransportsDark as a side effect
      allDark: () => _allTransportsDark,
      leafFamily: _currentLeafFamily,
      variantsExhausted: _adaptStep >= _adaptVariants.length,
    );
    switch (action) {
      case DarkAction.networkDownBail: // local net down — not a tunnel block
      case DarkAction
          .cascaded: // a transport hop broke through; give it a cycle
        _clearWhitelistMode(); // a working hop ⇒ foreign is reachable again
        return;
      case DarkAction.whitelistMode:
        // RU answers but every foreign IP is dark → mobile network fell back to
        // the state allowlist. Cascade/fp cycling is physically futile; stop and
        // inform (don't disconnect — we stay fail-closed).
        _latchWhitelistMode();
        return;
      case DarkAction.stopIpBlock:
        _log(
          'auto-adapt: ALL transports on this server are dark at once — looks '
          'like an IP/server block, not a signature block. fp-cycling won\'t '
          'help; rotate the server/relay. Leaving it to failover/kill-switch.',
        );
        return;
      case DarkAction.stopFpNoop:
        _log(
          'auto-adapt: the surviving path is Reality/QUIC — fingerprint / '
          'fragment cycling is a no-op there; leaving it to failover/kill-'
          'switch (rotate the server/relay).',
        );
        return;
      case DarkAction.stopExhausted:
        _log(
          'auto-adapt: tried every variant — node looks blocked/down; '
          'leaving it to failover/kill-switch',
        );
        return;
      case DarkAction.fpEscalate:
        break; // fall through to the escalating restart below
    }
    _adaptStep++;
    final v = _adaptVariants[_adaptStep - 1];
    _log(
      'auto-adapt: tunnel blocked → variant $_adaptStep '
      '(fp=${v.fp}, fragment=${v.fragment}, mux=${v.mux})',
    );
    _adapting = true;
    try {
      await restart(keepAdapt: true, reason: 'auto-adapt step $_adaptStep');
    } finally {
      _adapting = false;
    }
  }

  // L3 proactive hop: while the tunnel STILL carries traffic, watch the active
  // path's RTT. If it blows up severely and STAYS bad (sustained), hop to a
  // fresher transport BEFORE ТСПУ finishes killing it — "move before you're
  // caught". Conservative + cooled-down so a noisy path can't churn (the very
  // thing we just fixed). NOTE: thresholds need real-world tuning — can't be
  // battle-verified headless.
  Future<void> _checkDegradation() async {
    if (_proactiveCooldown > 0) {
      _proactiveCooldown--;
      return;
    }
    final api = ref.read(clashApiProvider);
    final leaf = resolveLeafFromGroups(await api.proxies());
    if (leaf == null) return;
    // A FRESH probe (not the warm history) — degradation detection needs the
    // current RTT; `lastDelay` can return a pre-degradation sample and mask it.
    final ms = await api.delay(leaf);
    if (ms == null) return; // couldn't measure this cycle
    final base = _rttBaseline;
    if (base == null) {
      _rttBaseline = ms.toDouble();
      return;
    }
    // Degraded = 3× the healthy baseline AND over 800 ms absolute (so tiny jitter
    // on an already-fast path never trips it).
    if (ms > base * 3 && ms > 800) {
      if (++_degradeStreak >= 3) {
        // ~54 s of sustained severe degradation → move while there's still time.
        // penaltyOnLeave:false — the leaf is slow, not blocked; don't score it dead.
        if (await _tryTransportHop(penaltyOnLeave: false)) {
          _appLog(
            'proactive: path degrading (${ms}ms vs ~${base.round()}ms '
            'baseline) → hopped transport early',
          );
          _rttBaseline = null; // the new path sets its own baseline
          _degradeStreak = 0;
          _proactiveCooldown = 12; // ~3.5 min before another proactive hop
        } else {
          _degradeStreak =
              0; // nowhere fresh to go — leave it to the dark-path loop
        }
      }
    } else {
      _degradeStreak = 0;
      _rttBaseline = base * 0.8 + ms * 0.2; // EMA on good samples only
    }
  }

  // L4 freeze watch: the 16KB foreign-IP connection-freeze (net4people #490/#546)
  // lets a tiny 204 through while stalling real >16KB transfers, so it HIDES as a
  // healthy tunnel. Pull a bulk payload THROUGH the proxy every Nth healthy tick
  // (cheap) and, on a debounced stall, reshape this SAME node freeze-safe (strip
  // Vision flow + mux) ONCE before handing off to a transport hop — the decision
  // order lives in the unit-tested [decideFreeze]. Steps aside during a cascade
  // episode (single owner). NOTE: like _checkDegradation, the bulk threshold
  // needs real-world tuning — can't be battle-verified headless.
  Future<void> _checkFreeze() async {
    if (_adapting || _restarting || _triedTransports.isNotEmpty) return;
    if (++_freezeTick % 3 != 0) return; // ~every 54s, not every 18s tick
    final bulkOk = await _bulkThroughOk();
    if (!state.isOn) return; // raced a stop while probing
    _freezeFails = bulkOk ? 0 : _freezeFails + 1;
    if (decideFreeze(bulkOk: bulkOk, freezeFails: _freezeFails) ==
        FreezeAction.none) {
      return;
    }
    _freezeFails = 0;
    // Battle-tested (live Reality+Vision server, 2026-06): a Reality server that
    // mandates xtls-rprx-vision REJECTS a stripped-flow client, so "reshape the
    // same node" turns a throttle into an outage. The remedy that works is to
    // LEAVE the long TCP-TLS stream — hop to XHTTP (sub-16KB request pairs) or
    // QUIC (Hysteria2/TUIC, not a TCP-TLS connection). planCascade already
    // orders by L4 diversity, so the hop lands there.
    _log(
      'auto-adapt: 16KB connection-freeze suspected (small probes pass, bulk '
      'transfer stalls) → hopping off the long TLS stream to XHTTP/QUIC',
    );
    if (!await _tryTransportHop(freeze: true, penaltyOnLeave: false)) {
      _log(
        'auto-adapt: freeze suspected but no alternative transport in the pool '
        '— a single Vision node can\'t be freeze-fixed client-side; import an '
        'XHTTP/Hysteria2 node or another server.',
      );
    }
  }

  // Per-session ECH discovery cache (host → base64 ECHConfigList, or null when
  // the host publishes none / DoH was unreachable). Keyed by server_name so a
  // reconnect or cascade rebuild never re-queries.
  final Map<String, String?> _echCache = {};

  // Native ECH masquerade: enrich each plain-TLS (non-Reality) exit that has a
  // server_name with its DNS-published ECH config, so the real SNI is encrypted
  // and only the cover public_name is observable — the masquerade SpeedTop's
  // vpnclirpc gets from BoringSSL+ECH, here on our own core. Reality is skipped
  // (it masks its own SNI); a node already carrying an ech.config is left as-is.
  // Fail-safe: any miss leaves the node exactly as built (sing-box may still do
  // its own ECH-from-DNS via `enabled:true`).
  void _applyEchDiscovery(Map<String, dynamic> cfg) {
    final tlsTargets = <Map<String, dynamic>>[];
    for (final o in [
      ...?(cfg['outbounds'] as List?)?.whereType<Map>(),
      ...?(cfg['endpoints'] as List?)?.whereType<Map>(),
    ]) {
      final tls = o['tls'];
      if (tls is! Map || tls['enabled'] != true) continue;
      final reality = tls['reality'];
      if (reality is Map && reality['enabled'] != false) continue; // own masking
      final ech = tls['ech'];
      if (ech is Map && ech['config'] != null) continue; // carried already
      final sni = tls['server_name']?.toString() ?? '';
      if (sni.isEmpty) continue;
      tlsTargets.add(tls.cast<String, dynamic>());
    }
    if (tlsTargets.isEmpty) return;
    // Apply whatever is ALREADY cached — synchronous, no DoH, never blocks connect.
    for (final t in tlsTargets) {
      final b64 = _echCache[t['server_name'].toString()];
      if (b64 == null || b64.isEmpty) continue;
      final cur = t['ech'];
      t['ech'] = {
        if (cur is Map) ...cur,
        'enabled': true,
        'config': EchDiscovery.echConfigPem(b64),
      };
      _log('ECH: ${t['server_name']} → encrypted SNI behind a cover public_name');
    }
    // Warm the cache in the BACKGROUND for hosts not yet tried — the discovery
    // must NEVER stall the connect (the pre-tunnel DoH hangs ~5s in RF where it's
    // blocked) and NEVER re-leak an already-tried host's server_name. A failed
    // lookup is cached as null (= tried) so it isn't re-queried every connect;
    // meanwhile sing-box's own `enabled:true` ECH still resolves in-tunnel, and a
    // real config kicks in on the next connect once a background lookup lands.
    final toWarm = {for (final t in tlsTargets) t['server_name'].toString()}
        .where((h) => !_echCache.containsKey(h))
        .toList();
    if (toWarm.isNotEmpty) unawaited(_warmEch(toWarm));
  }

  Future<void> _warmEch(List<String> hosts) async {
    for (final h in hosts) {
      if (_echCache.containsKey(h)) continue;
      try {
        final c = await EchDiscovery.fetchEchConfig(h);
        _echCache[h] = (c != null && c.isNotEmpty) ? c : null; // cache negative too
      } catch (_) {
        _echCache[h] = null; // tried (DoH error) → don't repeat this session
      }
    }
  }

  // Pull a bulk payload THROUGH the proxy to expose a 16KB connection-freeze a
  // tiny 204 can't see. Full body in time ⇒ healthy; a mid-stream STALL (started,
  // then no data) ⇒ frozen. A hard error is inconclusive (could be the target) ⇒
  // treated as OK so a transient miss never false-flags a freeze. The probe host
  // + "arrived" threshold come from the ТСПУ-fact feed (②), defaulting baked.
  Future<bool> _bulkThroughOk() async {
    final facts = CensorshipFacts.active;
    // ONE freeze floor for both branches — the success check and the stall
    // signature must agree, else a feed threshold <16 leaves a stall between the
    // (lower) threshold and a hardcoded 16KB undetected while reporting healthy.
    final floor = facts.freezeThresholdKb * 1024;
    const stallWindow = Duration(
      seconds: 6,
    ); // no new bytes this long = stalled
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (_) =>
          'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
    var got = 0;
    try {
      final req = await client.getUrl(Uri.parse(facts.freezeProbeUrl));
      final resp = await req.close().timeout(const Duration(seconds: 9));
      // Per-EVENT inactivity timeout: a steadily-arriving (even slow) stream keeps
      // resetting it, so a slow-but-working link is NOT mistaken for a freeze;
      // only a genuine STALL (no bytes for stallWindow) trips it.
      await for (final chunk in resp.timeout(stallWindow)) {
        got += chunk.length;
      }
      return got >= floor; // got the bulk ⇒ no freeze
    } on TimeoutException {
      // Stalled. The 16KB-freeze signature is specifically "flowed PAST ~16KB then
      // froze" — so only call it a freeze if we actually crossed that wall. A stall
      // with little data is more likely a transient blip / slow start, so treat it
      // as inconclusive (don't burn a transport hop on a slow link).
      return got < floor;
    } catch (_) {
      return true; // inconclusive (target/network) — don't false-flag a freeze
    } finally {
      client.close(force: true);
    }
  }

  // Does real traffic flow through the local proxy right now?
  // Cumulative download bytes seen at the last health tick. The delta tells us
  // whether the tunnel is carrying REAL traffic, independent of the synthetic
  // probe. Reset to 0 on each (re)connect (the core's counter restarts with it).
  int _lastDownloadTotal = 0;

  /// True if the tunnel pulled meaningful DOWNLOAD bytes since the previous health
  /// tick — a robust "the path actually works" signal that a single flaky probe
  /// can't override. Always refreshes the baseline so the next tick's delta is
  /// honest. Download specifically: data coming BACK proves the round-trip.
  Future<bool> _downloadGrewSinceLastTick() async {
    try {
      final snap = await ref.read(clashApiProvider).connections();
      if (snap == null) return false;
      final now = snap.downloadTotal;
      // >8 KB in an 18 s window — well above keepalive noise, well below any real
      // browsing/streaming, so genuine traffic reads true and a dead tunnel reads
      // false (no bytes come back through a blocked path).
      final grew = now > _lastDownloadTotal + 8192;
      _lastDownloadTotal = now;
      return grew;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tunnelHealthy() async {
    // RETRY before declaring the tunnel dark: a single synthetic 204 routed through
    // a CHURNING urltest (its parallel member-probe burst momentarily tripping a
    // per-foreign-IP connection throttle) can time out for a beat while the path is
    // actually fine. A genuinely dark tunnel fails BOTH tries; a flaky-probe-but-
    // working one passes the second. This cuts the false "dark" verdicts that were
    // restarting the core needlessly (dropping the local proxy → browser
    // ERR_PROXY_CONNECTION_FAILED + the "constant reconnects"). A genuinely dark
    // tunnel costs one extra probe per tick (~7s upstream timeout + 900ms ≈ 8s);
    // worst-case _tunnelHealthy ≈ 15s still fits under the 18s watchdog interval,
    // and the 3-dark-tick (~54s) gate before any restart is unchanged.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (await _probe204()) return true;
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }
    }
    return false;
  }

  Future<bool> _probe204() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (_) =>
          'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
    try {
      final req = await client.getUrl(
        Uri.parse('http://www.gstatic.com/generate_204'),
      );
      final resp = await req.close().timeout(const Duration(seconds: 7));
      return resp.statusCode == 204 || resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// One end-to-end check that traffic actually flows through the tunnel right
  /// now. Used right after an import to catch a node that came UP (API alive) but
  /// carries ZERO traffic (silent-dead) — so the success toast never implies a
  /// dead node works (M6). Only meaningful while `running`.
  Future<bool> probeTrafficFlowing() => _tunnelHealthy();

  // Is the local network up at all? A raw dial to a RU host (routed DIRECT even
  // in Smart/TUN), so "up" here means the tunnel SPECIFICALLY is dead, not the
  // whole connection — don't burn variants on a dropped Wi-Fi.
  Future<bool> _directNetworkUp() async {
    try {
      final s = await Socket.connect(
        'ya.ru',
        443,
        timeout: const Duration(seconds: 5),
      );
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  // Is ANY foreign host reachable by a RAW TCP dial that BYPASSES the tunnel? In
  // proxy mode a raw Socket isn't proxied (system-proxy only affects proxy-aware
  // apps), so it goes direct already. In TUN mode auto_route would capture even
  // THIS dial — so [SingBoxConfig.withTun] routes these exact IPs DIRECT, making
  // the probe measure the PHYSICAL uplink either way. That distinguishes a real
  // whitelist collapse (every foreign SYN dropped) from a mere node block
  // (foreign still reachable). Shares [SingBoxConfig.foreignProbeIps] so the
  // dialed IPs and the direct route rule can never drift apart. Returns on the
  // first success; false only when EVERY probe IP is dark. Runs only on the dark
  // path (after ~54s tunnel-dark), so the direct dials stay infrequent + benign.
  Future<bool> _foreignNetworkUp() async {
    for (final ip in SingBoxConfig.foreignProbeIps) {
      try {
        final s = await Socket.connect(
          ip,
          443,
          timeout: const Duration(seconds: 4),
        );
        s.destroy();
        return true;
      } catch (_) {
        // try the next control IP
      }
    }
    return false;
  }

  void _clearWhitelistMode() {
    if (!_whitelistMode) return;
    _whitelistMode = false;
    state = state.copyWith(whitelistMode: false);
  }

  // Latch the "network collapsed to the state WHITELIST" banner (RU answers but
  // every foreign IP is dark — a mobile shutdown). Once per collapse; cleared when
  // real traffic flows again. Never disconnects — we stay fail-closed. Called from
  // the dark-path AND the auto-adapt-OFF detect-only branch.
  void _latchWhitelistMode() {
    if (_whitelistMode) return;
    _whitelistMode = true;
    state = state.copyWith(whitelistMode: true);
    _log(
      'network collapsed to the state WHITELIST — RU sites answer but every '
      'foreign IP is dropped (mobile shutdown). No foreign exit is reachable; '
      'pausing transport/fp cycling. Use Wi-Fi or a domestic relay.',
    );
  }

  // The tunnel is dark (no traffic) while still "running" — drive the honest
  // "checking" status so the UI doesn't show a solid green "Connected" + a stale
  // exit-IP during the watchdog's dark window. Transition-guarded (no churn).
  void _setTunnelDark(bool v) {
    if (state.tunnelDark == v) return;
    state = state.copyWith(tunnelDark: v);
  }

  // The active leaf's refined anti-DPI family (for the fp-no-op decision) —
  // prefers the PRE-bridge family map (knows Reality vs plain-TLS), falling back
  // to the leaf's raw Clash type lowercased (still catches QUIC, not Reality).
  Future<String?> _currentLeafFamily() async {
    final groups = await ref.read(clashApiProvider).proxies();
    final leaf = resolveLeafFromGroups(groups);
    if (leaf == null) return null;
    final fam = _familyByTag[leaf];
    if (fam != null) return fam;
    for (final g in groups) {
      if (g.name == leaf) return g.type.toLowerCase();
    }
    return null;
  }
}

/// Live traffic samples while the core is running; idle otherwise.
final trafficProvider = StreamProvider<Traffic>((ref) async* {
  final status = ref.watch(coreControllerProvider.select((s) => s.status));
  if (status != CoreStatus.running) {
    yield Traffic.zero;
    return;
  }
  final api = ref.read(clashApiProvider);
  yield Traffic.zero;
  try {
    yield* api.traffic();
  } catch (_) {
    yield Traffic.zero;
  }
});

/// Polls active connections (~1.5s) while the core is running.
final connectionsProvider = StreamProvider<ConnectionsSnapshot>((ref) async* {
  final status = ref.watch(coreControllerProvider.select((s) => s.status));
  // Only poll while the Activity tab is showing — this list isn't visible
  // elsewhere, so polling it every 1.5 s in the background was wasted work.
  final onActivity = ref.watch(navIndexProvider) == 1;
  if (status != CoreStatus.running || !onActivity) {
    yield ConnectionsSnapshot.empty;
    return;
  }
  final api = ref.read(clashApiProvider);
  yield ConnectionsSnapshot.empty;
  final first = await api.connections();
  if (first != null) yield first;
  await for (final _ in Stream<void>.periodic(
    const Duration(milliseconds: 1500),
  )) {
    final snap = await api.connections();
    if (snap != null) yield snap;
  }
});

/// The running config's switchable proxy GROUPS (Selector / URLTest with ≥2
/// members) — the "policies" the user can see and flip between. Empty for a
/// single simple node (nothing to choose). Polled while connected.
final proxyGroupsProvider = StreamProvider<List<ProxyGroup>>((ref) async* {
  final status = ref.watch(coreControllerProvider.select((s) => s.status));
  // Policies live on the Activity tab only — pause the 2 s poll when it's hidden.
  final onActivity = ref.watch(navIndexProvider) == 1;
  if (status != CoreStatus.running || !onActivity) {
    yield const [];
    return;
  }
  final api = ref.read(clashApiProvider);
  Future<List<ProxyGroup>> fetch() async {
    // The /proxies poll returns EVERY proxy (groups AND leaf members) each with its
    // own warm delay. Build a tag→delay map from the FULL list BEFORE filtering, so
    // each kept group carries its members' delays — the pool-health chip then reads
    // memberDelays[memberTag] (the leaf), not the group name (always null for a
    // member, which made healthy pools show 0/N). Zero extra API calls.
    final all = await api.proxies();
    final memberDelays = {for (final p in all) p.name: p.delay};
    return all
        .where(
          (g) =>
              g.all.length >= 2 &&
              (g.type == 'Selector' || g.type == 'URLTest'),
        )
        .map((g) => g.withMemberDelays(memberDelays))
        .toList();
  }

  yield await fetch();
  await for (final _ in Stream<void>.periodic(const Duration(seconds: 2))) {
    yield await fetch();
  }
});

/// Latency (ms) of the ACTIVE path while running; null otherwise. Universal:
/// never assumes a config's group is named anything in particular — for an
/// imported config it asks the core which outbound is the route final.
final latencyProvider = StreamProvider<int?>((ref) async* {
  final status = ref.watch(coreControllerProvider.select((s) => s.status));
  // Watch only the slices that change WHICH proxy we measure — not the whole
  // profiles/settings objects (a sub-info refresh or an unrelated setting was
  // tearing down + rebuilding this polling stream).
  final selectedTag = ref.watch(
    profilesProvider.select((p) => p.selectedNode?.tag),
  );
  final selectedIsConfig = ref.watch(
    profilesProvider.select((p) => p.selectedNode?.isConfig ?? false),
  );
  // Mirror start()'s autoPool predicate EXACTLY: the ⚡ Auto group is built only
  // from NON-insecure simple nodes (auto-failover never silently hops onto an
  // insecure node — H5). Counting raw simple nodes here would make us measure a
  // "⚡ Auto" group that start() never created when one of the two is insecure.
  final autoPoolCount = ref.watch(
    profilesProvider.select(
      (p) => p.nodes.where((n) => !n.isConfig && !n.insecure).length,
    ),
  );
  final autoFailover = ref.watch(
    settingsProvider.select((s) => s.autoFailover),
  );
  if (status != CoreStatus.running) {
    yield null;
    return;
  }
  final api = ref.read(clashApiProvider);
  final auto = autoFailover && autoPoolCount >= 2;

  // Resolve the proxy/group to measure WITHOUT hardcoding config-specific names:
  // a simple node → its tag; our auto-failover → the auto group; an imported
  // config → the route-final group the Clash API reports (GLOBAL.now), else the
  // first switchable group.
  Future<String?> resolveTag() async {
    if (auto) return SingBoxConfig.autoTag;
    if (selectedTag != null && !selectedIsConfig) return selectedTag;
    final groups = await api.proxies();
    for (final g in groups) {
      if (g.name == 'GLOBAL' && g.now != null && g.now!.isNotEmpty) {
        return g.now;
      }
    }
    for (final g in groups) {
      if (g.type == 'Selector' || g.type == 'URLTest') return g.name;
    }
    return selectedTag;
  }

  // Prefer the proxy's OWN measured delay (warm, matches other clients) over a
  // forced cold /delay test that double-counts the Reality handshake.
  Future<int?> measure() async {
    final tag = await resolveTag();
    if (tag == null) return null;
    return await api.lastDelay(tag) ?? await api.delay(tag);
  }

  yield await measure();
  await for (final _ in Stream<void>.periodic(const Duration(seconds: 5))) {
    yield await measure();
  }
});

/// The LEAF outbound actually carrying traffic right now (the server name), or
/// null. Resolves the top switchable group (route final, excluding GLOBAL) and
/// follows each group's `now` down through nested selectors/urltests to the leaf
/// node — so Home can answer "which server am I on?" after an auto-hop/switch
/// instead of showing the static profile name. (Hiddify shows this under connect.)
final activeOutboundProvider = StreamProvider<String?>((ref) async* {
  final status = ref.watch(coreControllerProvider.select((s) => s.status));
  final profiles = ref.watch(profilesProvider);
  if (status != CoreStatus.running) {
    yield null;
    return;
  }
  final api = ref.read(clashApiProvider);
  final node = profiles.selectedNode;
  final simpleTag = (node != null && !node.isConfig) ? node.tag : null;

  Future<String?> resolve() async {
    final groups = await api.proxies();
    if (groups.isEmpty) return simpleTag;
    final byName = {for (final g in groups) g.name: g};
    bool isGroup(ProxyGroup g) => g.type == 'Selector' || g.type == 'URLTest';
    // Members of any group — used to find the TOP group (not nested in another).
    final nested = <String>{};
    for (final g in groups) {
      if (isGroup(g)) nested.addAll(g.all);
    }
    ProxyGroup? top;
    for (final g in groups) {
      if (g.name == 'GLOBAL' || !isGroup(g) || nested.contains(g.name)) {
        continue;
      }
      top = g;
      if (g.type == 'Selector') {
        break; // a manual selector is the truest "route final"
      }
    }
    // Follow `now` down to the leaf (a non-group entry).
    var tag = top?.now ?? top?.name;
    final seen = <String>{};
    while (tag != null && byName.containsKey(tag) && seen.add(tag)) {
      final g = byName[tag]!;
      if (!isGroup(g)) break; // reached a real node
      tag = g.now ?? (g.all.isNotEmpty ? g.all.first : null);
    }
    return tag ?? simpleTag;
  }

  yield await resolve();
  await for (final _ in Stream<void>.periodic(const Duration(seconds: 3))) {
    yield await resolve();
  }
});

/// The tunnel's public exit IP while connected — fetched THROUGH the local
/// proxy, so a value here proves real traffic is flowing end-to-end.
final exitIpProvider = StreamProvider<String?>((ref) async* {
  final status = ref.watch(coreControllerProvider.select((s) => s.status));
  if (status != CoreStatus.running) {
    yield null;
    return;
  }
  yield null;
  while (true) {
    yield await _fetchExitIp();
    await Future<void>.delayed(const Duration(seconds: 15));
  }
});

Future<String?> _fetchExitIp() async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..findProxy = (_) =>
        'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
  try {
    for (final url in const ['http://api.ipify.org', 'http://ifconfig.me/ip']) {
      try {
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close().timeout(const Duration(seconds: 9));
        if (resp.statusCode != 200) continue;
        final ip = (await resp.transform(utf8.decoder).join()).trim();
        if (ip.isNotEmpty && ip.length < 64) return ip;
      } catch (_) {
        // try the next endpoint
      }
    }
    return null;
  } finally {
    client.close(force: true);
  }
}
