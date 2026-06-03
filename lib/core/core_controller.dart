import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'app_settings.dart';
import 'cascade.dart';
import 'clash_api.dart';
import 'core_paths.dart';
import 'lifecycle.dart';
import 'native_admin.dart';
import 'profiles_controller.dart';
import 'route_mode.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';
import 'xray_config.dart';

enum CoreStatus { stopped, starting, running, stopping, error }

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
  });

  final CoreStatus status;
  final String? version;
  final CoreError? error; // localized by the UI
  final String? detail; // optional extra (path / core message)
  final List<String> logs;
  final bool fenceActive; // WFP TUN kill-switch fence currently up?

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
  }) {
    return CoreState(
      status: status ?? this.status,
      version: version ?? this.version,
      error: identical(error, _unset) ? this.error : error as CoreError?,
      detail: identical(detail, _unset) ? this.detail : detail as String?,
      logs: logs ?? this.logs,
      fenceActive: fenceActive ?? this.fenceActive,
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
  Timer? _hop;
  bool _hopping = false;
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
    // Smart mode references these by local path; if packaging missed them or AV
    // quarantined them, degrade to a rule-set-free config instead of FATAL-ing.
    SingBoxConfig.ruleSetsReady = const [
      'geoip-ru',
      'geosite-ru',
      'geosite-ads',
    ].every((f) => File('$rsDir${Platform.pathSeparator}$f.srs').existsSync());
    SingBoxConfig.clashSecret = _randomSecret();
    ref.onDispose(() {
      _proc?.kill();
      _killXray();
      _netDebounce?.cancel();
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
    'ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEMS': 'true',
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
    SingBoxConfig.dnsServer =
        settings.customDns.isEmpty ? '77.88.8.8' : settings.customDns;
    final simpleNodes = profiles.nodes.where((n) => !n.isConfig).toList();
    // Auto-failover + the watchdog cascade run UNATTENDED — they must never
    // silently route through a cert-unvalidated (MITM-able) node. The auto pool
    // is SECURE nodes only; an insecure node is reachable solely via an explicit,
    // consent-gated manual connect (H5).
    final autoPool = simpleNodes.where((n) => !n.insecure).toList();
    final useAuto = settings.autoFailover && autoPool.length >= 2;
    final tunMode = settings.vpnMode == VpnMode.tun;
    final xrayAvailable = File(CorePaths.xray()).existsSync();
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
    final antiDpi = variant?.fragment ?? settings.antiDpi;
    final mux = variant?.mux ?? settings.mux;
    var cfg = useAuto
        ? SingBoxConfig.fromNodes(
            autoPool,
            mode: settings.mode,
            antiDpi: antiDpi,
            tlsFingerprint: fp,
            mux: mux,
            ech: settings.ech,
          )
        : node == null
        // No server selected: run the local DPI-desync mode so throttled
        // sites (YouTube/Discord) still work with zero config, no server.
        ? (settings.desyncDirect
              ? SingBoxConfig.desyncOnly()
              : SingBoxConfig.m0Local())
        : node.isConfig
        ? SingBoxConfig.fromConfig(
            node.config!,
            keepXray: xrayAvailable,
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
          );
    if (tunMode) {
      cfg = SingBoxConfig.withTun(
        cfg,
        splitApps: settings.splitTunnelApps,
        forceApps: settings.forceVpnApps,
      );
    }
    // Hysteria2 Brutal bandwidth caps (no-op unless the user set them AND a
    // hysteria2 outbound exists). One choke point covers every build path.
    cfg = SingBoxConfig.tuneHysteria2(
        cfg, settings.hy2UpMbps, settings.hy2DownMbps);
    // Snapshot the TRUE per-outbound families for the cascade BEFORE the xray
    // bridge rewrites XHTTP outbounds into `socks` (which would otherwise erase
    // the XHTTP↔Reality distinction). See [familiesFromConfig].
    _familyByTag = familiesFromConfig(cfg);
    _insecureByTag = insecureTagsFromConfig(cfg);
    if (xrayAvailable) cfg = await _bridgeXray(cfg);
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
    unawaited(_proc!.exitCode.then(_onExit));

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
      await SystemProxy.set(
        '${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}',
      );
    }

    // Re-check intent AFTER the proxy-set await: a user Stop — or an unexpected
    // core death — can land in that gap. Committing to `running` here would
    // leave a zombie (running with no process) that the next network change
    // silently reconnects, defeating the Stop.
    if (!_autoReconnect) {
      _proc?.kill();
      _proc = null;
      await _restoreProxy();
      state = state.copyWith(
        status: CoreStatus.stopped,
        error: null,
        detail: null,
      );
      return;
    }
    if (_proc == null) return; // died during start → _onExit already handled it

    state = state.copyWith(
      status: CoreStatus.running,
      version: version,
      error: null,
      detail: null,
    );
    _exitRetries = 0;
    _healthFails = 0;
    // Bringing a TUN up reshuffles routes/adapters → a burst of addr-change
    // events for ~10s. Ignore them so we don't restart the tunnel for its OWN
    // setup churn (the "reconnects every few seconds right after connect" storm).
    _settleUntil = DateTime.now().add(const Duration(seconds: 12));
    // Mark "was connected" for resume-on-launch — but ONLY for a real server.
    // A no-server mode (desync / m0Local) has nothing to resume TO, so flagging
    // it would auto-"reconnect" into a confusing "no VPN" state next launch.
    if (node != null || useAuto) _writeConnectedFlag();
    // TUN kill-switch: install/refresh the WFP fence so a later core death fails
    // CLOSED (no plaintext leak onto the physical NIC). Re-engaged each connect
    // because the tunnel interface LUID changes per session. Fail-safe: if it
    // can't install, we say so in the log and carry on (no fence, not a crash).
    if (tunMode && settings.killSwitchTun) {
      // Permit EVERY core that makes its OWN outbound — sing-box AND the xray
      // bridge — or the fence blacks out XHTTP / Reality-over-XHTTP, which dial
      // out as the xray process (H1). One path per binary; the WFP app-id
      // condition matches by image, so it covers all xray bridge processes.
      final ok = await NativeAdmin.fenceEngage(fencePermitPaths(
          exe, CorePaths.xray(),
          xrayAvailable: xrayAvailable));
      _fenceActive = ok;
      state = state.copyWith(fenceActive: ok);
      if (!ok) {
        // BLOCK-on-fail: the user EXPLICITLY enabled the kill-switch. Running TUN
        // unprotected would be a silent fail-OPEN — refuse. Tear the core down via
        // _onExit (the _fenceFailed flag routes it to a clear error); clear
        // _restarting so restart() can't relaunch into the same failure.
        _log('kill-switch: WFP fence could NOT install — refusing to run unprotected');
        _fenceFailed = true;
        _autoReconnect = false;
        _restarting = false;
        _proc?.kill();
        return;
      }
      _log('kill-switch: TUN fence engaged (fail-closed)');
    }
    _startHop();
    _startWatchdog();
  }

  /// Replace XHTTP outbounds with a `socks` outbound dialed by a per-outbound
  /// xray-core process — bridging transports sing-box can't do. Gated by the
  /// caller on the xray binary's presence.
  Future<Map<String, dynamic>> _bridgeXray(Map<String, dynamic> cfg) async {
    final outs = (cfg['outbounds'] as List?) ?? const [];
    var port = 24100;
    for (var i = 0; i < outs.length; i++) {
      final o = outs[i];
      if (o is! Map || !XrayConfig.needsXray(o)) continue;
      final xcfg = XrayConfig.fromOutbound(o, port);
      if (xcfg == null) continue;
      final path =
          '${CorePaths.runtimeDir().path}${Platform.pathSeparator}xray-$port.json';
      try {
        File(path).writeAsStringSync(XrayConfig.encode(xcfg));
        final p = await Process.start(CorePaths.xray(), [
          'run',
          '-c',
          path,
        ], workingDirectory: CorePaths.runtimeDir().path);
        _xrayProcs.add(p);
        _recordPid('xray.exe', p.pid);
        outs[i] = {
          'type': 'socks',
          'tag': o['tag'],
          'server': '127.0.0.1',
          'server_port': port,
          'version': '5',
        };
        port++;
      } catch (_) {
        // xray failed to start — leave the outbound; sing-box will report it.
      }
    }
    return cfg;
  }

  void _killXray() {
    for (final p in _xrayProcs) {
      p.kill();
    }
    _xrayProcs.clear();
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
    String content;
    try {
      if (!_pidFile.existsSync()) return;
      content = _pidFile.readAsStringSync();
    } catch (_) {
      return;
    }
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
    try {
      _pidFile.deleteSync();
    } catch (_) {}
    await _freeCorePorts();
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
    final proc = _proc;
    if (proc == null) {
      await _restoreProxy();
      _killXray();
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
    // settings again; only the auto-adapt loop keeps its current variant.
    if (!keepAdapt) _adaptStep = 0;
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
      // _onExit saw _restarting and left the proxy pointed at the (now refused)
      // local port. Bring the new core up — unless a user stop() cancelled us.
      if (_restarting) {
        await start();
      }
    } finally {
      // Always reset, even if start() threw, so the flag can't get stuck true
      // (which would make a later normal start() bypass its busy guard).
      _restarting = false;
    }
  }

  void _onExit(int code) {
    _proc = null;
    _hop?.cancel();
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
        _finishExit(d, CoreStatus.stopped); // deliberate stop — keep any detail
        return;
      case ExitOutcome.portInUse:
        // Not transient (another copy/orphan holds the port) — looping spams
        // FATALs. Stop, restore connectivity, tell the user.
        _portConflict = false;
        _autoReconnect = false;
        _finishExit(d, CoreStatus.error,
            error: CoreError.portInUse, detail: null);
        return;
      case ExitOutcome.wireguardDead:
        // Plain-WG dial to an Amnezia/blocked endpoint never handshook — futile
        // to retry. Nothing was ever protected (zero traffic), so restore + tell
        // the user to switch to Reality/Hysteria.
        _wgDead = false;
        _wgHandshakeFails = 0;
        _autoReconnect = false;
        _finishExit(d, CoreStatus.error,
            error: CoreError.wireguardHandshake, detail: null);
        return;
      case ExitOutcome.gaveUp:
        _autoReconnect = false;
        _finishExit(d, CoreStatus.error,
            error: CoreError.gaveUp, detail: null);
        return;
      case ExitOutcome.gaveUpFenced:
        // Kill-switch ON: give up but STAY fail-CLOSED (fence + proxy kept). The
        // unblock button (status==error && fenceActive) lets the user disconnect.
        _autoReconnect = false;
        _finishExit(d, CoreStatus.error,
            error: CoreError.gaveUp, detail: null);
        return;
      case ExitOutcome.killSwitchFailed:
        // Fence couldn't install + the user wanted the kill-switch → we refused to
        // run unprotected. Restore connectivity (nothing was protected) + a clear
        // error so they can fix it (run as admin / turn the kill-switch off).
        _fenceFailed = false;
        _autoReconnect = false;
        _finishExit(d, CoreStatus.error,
            error: CoreError.killSwitchFailed, detail: null);
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
  void _finishExit(ExitDecision d, CoreStatus status,
      {Object? error = _unset, Object? detail = _unset}) {
    // Only drop our proxy pointer when we actually restore the user's — a
    // fail-CLOSED give-up (gaveUpFenced) keeps the proxy at our dead local port
    // so proxy-aware apps stay blocked, not leaking direct.
    if (d.restoreProxy) {
      _proxyActive = false;
      SystemProxy.clear();
    }
    _clearPids();
    _clearConnectedFlag();
    if (d.disengageFence) _disengageFence();
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
      if (!shouldActOnNetworkChange(isOn: state.isOn, restarting: _restarting)) {
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
        isOn: state.isOn, restarting: _restarting, adapting: _adapting)) {
      return;
    }
    // Let the NIC/DHCP settle after wake before judging the path.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!shouldProbeOnResume(
        isOn: state.isOn, restarting: _restarting, adapting: _adapting)) {
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
  Future<bool> _tryTransportHop() async {
    final api = ref.read(clashApiProvider);
    final plan = planCascade(
      await api.proxies(),
      _triedTransports,
      families: _familyByTag,
      insecure: _insecureByTag,
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
    if (!ref.read(settingsProvider).autoAdapt) return;
    _watchdog = Timer.periodic(
      const Duration(seconds: 18),
      (_) => _checkHealth(),
    );
  }

  Future<void> _checkHealth() async {
    if (!ref.read(settingsProvider).autoAdapt) {
      _watchdog?.cancel(); // turned off mid-session
      return;
    }
    if (!state.isOn || _adapting || _restarting) return;
    if (await _tunnelHealthy()) {
      _healthFails = 0;
      _healthyStreak++;
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
      await _checkDegradation(); // L3: hop EARLY if the path is degrading
      return;
    }
    _healthFails++;
    _healthyStreak = 0; // a dark tick breaks the recovery streak
    if (_healthFails < 3) return; // ~54s of no traffic before acting
    _healthFails = 0;
    // Decide the dark-path action through the unit-tested orchestrator — keeping
    // the safety-critical ORDER (network gate BEFORE the cascade; IP-block & fp-
    // no-op stops BEFORE an fp-restart) in one place a test locks. We only
    // EXECUTE the chosen action here.
    final action = await runDarkPath(
      networkUp: _directNetworkUp,
      tryHop: _tryTransportHop, // sets _allTransportsDark as a side effect
      allDark: () => _allTransportsDark,
      leafFamily: _currentLeafFamily,
      variantsExhausted: _adaptStep >= _adaptVariants.length,
    );
    switch (action) {
      case DarkAction.networkDownBail: // local net down — not a tunnel block
      case DarkAction
          .cascaded: // a transport hop broke through; give it a cycle
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
        if (await _tryTransportHop()) {
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

  // Does real traffic flow through the local proxy right now?
  Future<bool> _tunnelHealthy() async {
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
  Future<List<ProxyGroup>> fetch() async => (await api.proxies())
      .where(
        (g) =>
            g.all.length >= 2 && (g.type == 'Selector' || g.type == 'URLTest'),
      )
      .toList();
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
  final selectedTag =
      ref.watch(profilesProvider.select((p) => p.selectedNode?.tag));
  final selectedIsConfig = ref
      .watch(profilesProvider.select((p) => p.selectedNode?.isConfig ?? false));
  // Mirror start()'s autoPool predicate EXACTLY: the ⚡ Auto group is built only
  // from NON-insecure simple nodes (auto-failover never silently hops onto an
  // insecure node — H5). Counting raw simple nodes here would make us measure a
  // "⚡ Auto" group that start() never created when one of the two is insecure.
  final autoPoolCount = ref.watch(profilesProvider
      .select((p) => p.nodes.where((n) => !n.isConfig && !n.insecure).length));
  final autoFailover =
      ref.watch(settingsProvider.select((s) => s.autoFailover));
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
