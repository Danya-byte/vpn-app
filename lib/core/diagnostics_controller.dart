import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_controller.dart';
import 'diagnostics.dart';

/// Holds the last diagnostics run so results SURVIVE leaving the tab. Previously
/// they lived in the view's State and were wiped the moment the user switched
/// inner tabs (the view is built via `switch`, so it unmounts). A plain
/// (non-autoDispose) Notifier keeps them until the next run.
class DiagnosticsState {
  const DiagnosticsState({this.running = false, this.results = const []});

  final bool running;
  final List<SiteResult> results;

  DiagnosticsState copyWith({bool? running, List<SiteResult>? results}) =>
      DiagnosticsState(
        running: running ?? this.running,
        results: results ?? this.results,
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
}
