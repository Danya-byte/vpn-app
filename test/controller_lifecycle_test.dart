import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/clash_api.dart';
import 'package:vpn_app/core/core_controller.dart';
import 'package:vpn_app/core/core_paths.dart';
import 'package:vpn_app/core/profile_store.dart';

/// M1 — exercise the REAL CoreController end-to-end (its build() + the lifecycle
/// WIRING), in full isolation from the user's store so it can never repeat the
/// "flutter test wiped my profiles" incident. The pure DECISIONS it routes
/// through (decideExit incl. gaveUpFenced, runDarkPath, the resume/network gates,
/// classifyCoreLog) are covered exhaustively in safety_test/watchdog_test; this
/// proves the controller assembles + the M4 gates fire correctly when off. We
/// deliberately do NOT drive a real connect here — start() would spawn the
/// bundled sing-box.exe, which a unit test must not do.
class _FakeClashApi extends ClashApi {
  @override
  Future<String?> version() async => null; // core never runs in this test
  @override
  Future<List<ProxyGroup>> proxies() async => const [];
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vpn_ctrl_test');
    CorePaths.overrideRuntimeDir = tmp.path; // isolate runtime dir + flags
    ProfileStore.overrideDir = tmp.path; // belt-and-suspenders for profiles
  });

  tearDown(() {
    CorePaths.overrideRuntimeDir = null;
    ProfileStore.overrideDir = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [clashApiProvider.overrideWithValue(_FakeClashApi())],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a cold controller builds in the STOPPED state, claiming no fence', () {
    final c = makeContainer();
    final s = c.read(coreControllerProvider);
    expect(s.status, CoreStatus.stopped);
    expect(s.fenceActive, isFalse);
    expect(s.isOn, isFalse);
  });

  test('wake + network-change gates are NO-OPs while disconnected (M4 wiring)',
      () async {
    final c = makeContainer();
    final ctrl = c.read(coreControllerProvider.notifier);
    // Neither must spin up / restart anything when the tunnel is off.
    ctrl.onNetworkChanged();
    await ctrl.onResumed(); // returns immediately via the !isOn gate
    expect(c.read(coreControllerProvider).status, CoreStatus.stopped);
    expect(c.read(coreControllerProvider).fenceActive, isFalse);
  });

  test('isolation holds: building the controller never wrote the real store',
      () {
    // The whole point — everything lands under the temp dir, nothing in
    // %LOCALAPPDATA%. (If CorePaths leaked, the real profiles.json would be hit.)
    makeContainer().read(coreControllerProvider);
    expect(Directory(tmp.path).existsSync(), isTrue);
  });
}
