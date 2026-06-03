// PURE lifecycle / safety decisions, kept FFI-free (like cascade.dart) so the
// safety-critical contract is unit-tested without constructing the controller.

/// What [CoreController._onExit] should do when the core process dies. The
/// safety-critical invariant: during a TRANSIENT reconnect the user's real proxy
/// is NOT restored (traffic fails CLOSED in the gap), and only a DELIBERATE stop
/// or a TERMINAL give-up restores connectivity + drops the fence.
enum ExitOutcome {
  restartingKeepClosed, // a node-switch/network-change swap owns the relaunch
  stopRestore, // deliberate Stop / autoReconnect off → restore the user's proxy
  portInUse, // another copy/orphan holds the local port — terminal
  wireguardDead, // plain-WG/Amnezia peer never handshook — terminal
  gaveUp, // exhausted reconnects — terminal, restore connectivity
  gaveUpFenced, // exhausted reconnects WITH kill-switch on — stay fail-CLOSED
  killSwitchFailed, // fence couldn't INSTALL + user wanted it → refuse to run
  reconnect, // unexpected death → KEEP closed + retry with backoff
}

class ExitDecision {
  const ExitDecision(this.outcome,
      {required this.restoreProxy, required this.disengageFence});

  final ExitOutcome outcome;
  final bool restoreProxy; // restore the user's real system proxy (fail OPEN)?
  final bool disengageFence; // drop the WFP kill-switch fence?

  /// Fail-closed = we did NOT restore the proxy and did NOT drop the fence.
  bool get failsClosed => !restoreProxy && !disengageFence;
}

/// Pure decision for [CoreController._onExit]. [exitRetries] is the count AFTER
/// this death is tallied. Order matters and is the contract the tests lock.
ExitDecision decideExit({
  required bool restarting,
  required bool stopping,
  required bool autoReconnect,
  required bool portConflict,
  required bool wgDead,
  required int exitRetries,
  bool fenceFailed = false,
  bool killSwitchActive = false,
  int maxRetries = 6,
}) {
  if (fenceFailed) {
    // The user enabled the kill-switch but the WFP fence could NOT install;
    // start() refused to run TUN unprotected and tore the core down. Restore
    // connectivity (nothing was ever protected) + surface a clear error. Checked
    // FIRST so a fence-install failure never silently relaunches or keeps-closed.
    return const ExitDecision(ExitOutcome.killSwitchFailed,
        restoreProxy: true, disengageFence: true);
  }
  if (restarting) {
    // The swap keeps the proxy at our local port → fail CLOSED during it.
    return const ExitDecision(ExitOutcome.restartingKeepClosed,
        restoreProxy: false, disengageFence: false);
  }
  if (stopping || !autoReconnect) {
    return const ExitDecision(ExitOutcome.stopRestore,
        restoreProxy: true, disengageFence: true);
  }
  if (portConflict) {
    return const ExitDecision(ExitOutcome.portInUse,
        restoreProxy: true, disengageFence: true);
  }
  if (wgDead) {
    return const ExitDecision(ExitOutcome.wireguardDead,
        restoreProxy: true, disengageFence: true);
  }
  if (exitRetries > maxRetries) {
    if (killSwitchActive) {
      // The user EXPLICITLY enabled the kill-switch → honour it: stay fail-CLOSED
      // even on give-up (no proxy restore, fence stays up), so a permanently-bad
      // node can't silently leak. NOT a lockout — the UI surfaces an explicit
      // "unblock (disconnect)" that calls stop(), and the dynamic WFP also
      // auto-purges if the app exits.
      return const ExitDecision(ExitOutcome.gaveUpFenced,
          restoreProxy: false, disengageFence: false);
    }
    // No kill-switch: restore connectivity so the user can reach the net to fix
    // it (anti-lockout default).
    return const ExitDecision(ExitOutcome.gaveUp,
        restoreProxy: true, disengageFence: true);
  }
  // Unexpected death mid-session: fail CLOSED (no proxy restore, fence stays up)
  // and retry — so a block/crash never leaks plaintext during the gap.
  return const ExitDecision(ExitOutcome.reconnect,
      restoreProxy: false, disengageFence: false);
}

/// A lifecycle-relevant signal recognised in a core stdout line — extracted PURE
/// so the "what does this line MEAN" classification is testable + decoupled from
/// the side effect (the audit: log ingestion and lifecycle were coupled in _log).
enum CoreLogSignal { none, portConflict, wgHandshakeFail, wgHandshakeOk }

CoreLogSignal classifyCoreLog(String line) {
  if (line.contains('bind:') &&
      (line.contains('Only one usage') ||
          line.contains('address already in use'))) {
    return CoreLogSignal.portConflict;
  }
  if (line.contains('handshake did not complete')) {
    return CoreLogSignal.wgHandshakeFail;
  }
  if (line.contains('Receiving handshake response') ||
      line.contains('Sending keepalive')) {
    return CoreLogSignal.wgHandshakeOk;
  }
  return CoreLogSignal.none;
}

/// #M4 — the gate before a wake-from-sleep probe: only CONSIDER re-probing /
/// reconnecting when the tunnel is on and we're not already mid-restart/adapt,
/// so a healthy tunnel is never torn down for a resume event. (Whether it's
/// actually dead is an I/O probe the caller does after this passes.) PURE.
bool shouldProbeOnResume({
  required bool isOn,
  required bool restarting,
  required bool adapting,
}) =>
    isOn && !restarting && !adapting;

/// #M4 — the gate before reacting to a network change: only act while connected
/// and not already swapping, so a Wi-Fi blip never restarts a healthy tunnel.
bool shouldActOnNetworkChange({
  required bool isOn,
  required bool restarting,
}) =>
    isOn && !restarting;

/// The absolute paths the WFP kill-switch fence must PERMIT — every core binary
/// that dials out to the server. Omitting the xray bridge blacks out XHTTP /
/// Reality-over-XHTTP the instant the fence engages (H1). Pure + tested.
List<String> fencePermitPaths(String singBoxExe, String? xrayExe,
    {required bool xrayAvailable, String? awgExe, bool awgAvailable = false}) {
  return [
    singBoxExe,
    if (xrayAvailable && xrayExe != null && xrayExe.isNotEmpty) xrayExe,
    // The AmneziaWG bridge dials out as its own process too — permit it or the
    // fence blacks out AmneziaWG the instant it engages (same as xray, H1).
    if (awgAvailable && awgExe != null && awgExe.isNotEmpty) awgExe,
  ];
}
