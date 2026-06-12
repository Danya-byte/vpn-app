import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vpn_app/core/app_settings.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/main.dart';

/// The first-run protection chooser is now DEFERRED to after the first successful
/// connect (a newcomer isn't asked a security question before they even have a
/// server). The headless-testable invariant is therefore the NEGATIVE: on a fresh
/// install the chooser must NOT block the launch, and setup must not be silently
/// completed. (The post-connect appearance needs the real core, which tests never
/// drive — see the "tests never touch the real store / never launch the VPN" rule.)
void main() {
  late Directory tmp;

  setUp(() {
    // Throwaway store — never touch the real user profiles/settings (see memory).
    tmp = Directory.systemTemp.createTempSync('vpn_firstrun_test_');
    ProfileStore.overrideDir = tmp.path;
    SettingsController.overrideDir = tmp.path;
    // Deliberately DO NOT write settings.json → seenSetup defaults false. The
    // chooser must NOT fire on first frame (it's deferred to post-first-connect).
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

  testWidgets('first-run chooser is DEFERRED — it does not block a fresh launch',
      (tester) async {
    tester.view.physicalSize = const Size(440, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: VpnApp()));
    await tester.pumpAndSettle();

    // The protection chooser must NOT appear up-front (en is the test default) —
    // it's deferred to after the first successful connect.
    expect(find.text('Choose your protection'), findsNothing);
    expect(find.text('Full-device protection'), findsNothing);

    // And it must NOT have been silently completed on launch — setup stays pending
    // until the user actually connects and makes the choice.
    final s = persistedSettings();
    expect(s['seenSetup'] ?? false, isFalse,
        reason: 'setup is deferred, not auto-completed on launch');
  });
}
