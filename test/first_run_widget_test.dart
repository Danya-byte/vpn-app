import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vpn_app/core/app_settings.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/main.dart';

/// #4 / click-test (#3): the first-run protection chooser must appear on a fresh
/// install (seenSetup=false), apply the user's pick, and never show again. This
/// automates the part of the native click-test that IS headless-testable (the
/// Dart UI flow + persistence) — the tray/UAC bits still need a human.
void main() {
  late Directory tmp;

  setUp(() {
    // Throwaway store — never touch the real user profiles/settings (see memory).
    tmp = Directory.systemTemp.createTempSync('vpn_firstrun_test_');
    ProfileStore.overrideDir = tmp.path;
    SettingsController.overrideDir = tmp.path;
    // Deliberately DO NOT write settings.json → seenSetup defaults false → the
    // chooser must fire on first frame.
  });

  tearDown(() {
    ProfileStore.overrideDir = null;
    SettingsController.overrideDir = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> persistedSettings() {
    final f = File('${tmp.path}${Platform.pathSeparator}settings.json');
    return f.existsSync()
        ? jsonDecode(f.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};
  }

  testWidgets('first-run chooser appears, applies the pick, and is one-shot',
      (tester) async {
    tester.view.physicalSize = const Size(440, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: VpnApp()));
    await tester.pumpAndSettle(); // let the post-frame dialog route settle

    // The chooser is up with both options (en is the test default).
    expect(find.text('Choose your protection'), findsOneWidget);
    expect(find.text('App proxy'), findsOneWidget);
    expect(find.text('Full-device protection'), findsOneWidget);

    // Pick the simple proxy mode.
    await tester.tap(find.text('App proxy'));
    await tester.pumpAndSettle();

    // Dialog dismissed and the choice persisted (one-shot + applied).
    expect(find.text('Choose your protection'), findsNothing);
    final s = persistedSettings();
    expect(s['seenSetup'], isTrue, reason: 'chooser must not show again');
    expect(s['vpnMode'], 'systemProxy', reason: 'the pick is applied + saved');
  });
}
