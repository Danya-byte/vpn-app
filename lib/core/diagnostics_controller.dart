import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_controller.dart';
import 'diagnostics.dart';
import 'profiles_controller.dart';

/// Holds the last diagnostics run so results SURVIVE leaving the tab. Previously
/// they lived in the view's State and were wiped the moment the user switched
/// inner tabs (the view is built via `switch`, so it unmounts). A plain
/// (non-autoDispose) Notifier keeps them until the next run.
class DiagnosticsState {
  const DiagnosticsState({
    this.running = false,
    this.results = const [],
    this.serverRunning = false,
    this.serverRan = false,
    this.serverForeignUp = true,
    this.serverResults = const [],
  });

  final bool running;
  final List<SiteResult> results;
  // Server-connect diagnostic ("why won't MY server connect here?").
  final bool serverRunning;
  final bool serverRan; // a run happened (so we can show "no endpoints" vs blank)
  final bool serverForeignUp; // was ANY foreign IP reachable (whitelist gate)
  final List<ServerProbeResult> serverResults;

  DiagnosticsState copyWith({
    bool? running,
    List<SiteResult>? results,
    bool? serverRunning,
    bool? serverRan,
    bool? serverForeignUp,
    List<ServerProbeResult>? serverResults,
  }) =>
      DiagnosticsState(
        running: running ?? this.running,
        results: results ?? this.results,
        serverRunning: serverRunning ?? this.serverRunning,
        serverRan: serverRan ?? this.serverRan,
        serverForeignUp: serverForeignUp ?? this.serverForeignUp,
        serverResults: serverResults ?? this.serverResults,
      );
}

final diagnosticsControllerProvider =
    NotifierProvider<DiagnosticsController, DiagnosticsState>(
        DiagnosticsController.new);

class DiagnosticsController extends Notifier<DiagnosticsState> {
  @override
  DiagnosticsState build() => const DiagnosticsState();

  Future<void> run() async {
    if (state.running) return;
    final connected = ref.read(coreControllerProvider).isOn;
    state = state.copyWith(running: true, results: const []);
    try {
      // Hard ceiling: even if a single probe wedges (a socket that ignores its
      // own timeout on a flaky path), the spinner MUST stop — "Checking…"
      // forever was exactly this. Per-site timeouts live in Diagnostics.
      await Diagnostics.run(
        throughTunnel: connected,
        onResult: (r) {
          final next = [...state.results]..removeWhere((x) => x.host == r.host);
          next.add(r);
          state = state.copyWith(results: next);
        },
        // Above the worst-case of 2 bounded-concurrency waves (≈2×22s) so the
        // overall ceiling never cuts the tail before its own per-site backstop.
      ).timeout(const Duration(seconds: 50), onTimeout: () => state.results);
    } catch (_) {
      // swallow — whatever resolved is already in state.results
    } finally {
      state = state.copyWith(running: false);
    }
  }

  /// Stage-probe the SELECTED node's server endpoint(s), raw (bypassing the
  /// tunnel), to pinpoint WHERE a connection breaks on the current network —
  /// the "works on Wi-Fi, not on mobile" diagnostic. Each endpoint gets a named
  /// verdict (whitelist / IP-port block / L4-ok-suspect-DPI / UDP-inconclusive).
  Future<void> runServerProbe() async {
    if (state.serverRunning) return;
    final node = ref.read(profilesProvider).selectedNode;
    final cfg = node == null
        ? const <String, dynamic>{}
        : (node.isConfig ? node.config! : {'outbounds': [node.outbound]});
    final eps = Diagnostics.endpointsOf(cfg);
    state = state.copyWith(
        serverRunning: true, serverRan: true, serverResults: const []);
    try {
      final net = await Diagnostics.probeNetwork().timeout(
          const Duration(seconds: 12),
          onTimeout: () => (foreign: false, localUp: false));
      state = state.copyWith(serverForeignUp: net.foreign);
      final acc = <ServerProbeResult>[];
      for (final ep in eps) {
        final r =
            await Diagnostics.probeServer(ep, net.foreign, localUp: net.localUp)
                .timeout(
          const Duration(seconds: 9),
          onTimeout: () => ServerProbeResult(
            endpoint: ep,
            controlReachable: net.foreign,
            serverReachable: ep.udp ? null : false,
            verdict: Diagnostics.verdictFor(
                controlUp: net.foreign,
                udp: ep.udp,
                reachable: ep.udp ? null : false,
                localUp: net.localUp),
          ),
        );
        acc.add(r);
        state = state.copyWith(serverResults: [...acc]);
      }
    } catch (_) {
      // swallow — whatever resolved is already in state.serverResults
    } finally {
      state = state.copyWith(serverRunning: false);
    }
  }
}
