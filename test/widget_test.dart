import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vpn_app/core/app_settings.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/main.dart';

void main() {
  late Directory tmp;

  setUp(() {
    // Isolate ALL persisted state to a throwaway dir — a widget test that pumps
    // the WHOLE app must never read or write the real user store (a prior
    // incident wiped real profiles; see memory). Pre-mark first-run setup as seen
    // so the one-time protection-mode chooser doesn't overlay Home in this test.
    tmp = Directory.systemTemp.createTempSync('vpn_widget_test_');
    ProfileStore.overrideDir = tmp.path;
    SettingsController.overrideDir = tmp.path;
    File('${tmp.path}${Platform.pathSeparator}settings.json')
        .writeAsStringSync('{"seenSetup":true}');
  });

  tearDown(() {
    ProfileStore.overrideDir = null;
    SettingsController.overrideDir = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('Home renders in disconnected state', (tester) async {
    // Match a realistic window size (the app enforces a ~420x760 minimum).
    tester.view.physicalSize = const Size(440, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: VpnApp()));
    await tester.pump();

    // Test binding defaults to the 'en' locale.
    expect(find.text('VPN App'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
  });
}
