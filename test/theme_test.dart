import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vpn_app/app/theme.dart';

void main() {
  // Locks in the "snackbar must float ABOVE the in-body nav, not behind it" fix
  // (a repeatedly-reported bug). The nav is a ~88px floating bar at the bottom;
  // the theme lifts floating snackbars clear of it via insetPadding.
  testWidgets('floating snackbar sits above the in-body nav band',
      (tester) async {
    tester.view.physicalSize = const Size(440, 880);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: messengerKey,
      theme: AppTheme.dark,
      home: const Scaffold(body: SizedBox.expand()),
    ));
    messengerKey.currentState!
        .showSnackBar(const SnackBar(content: Text('Нет узлов')));
    await tester.pump(); // build
    await tester.pump(const Duration(milliseconds: 400)); // entry animation

    const screenH = 880.0;
    // The SnackBar widget spans the screen; the insetPadding lifts the VISIBLE
    // content, so measure that (the text), which must clear the ~88px nav band.
    final content = tester.getRect(find.text('Нет узлов'));
    expect(content.bottom < screenH - 90, true,
        reason: 'content.bottom=${content.bottom} screenH=$screenH — snackbar '
            'content must clear the ~88px bottom nav, not hide behind it');
  });

  test('snackbar theme keeps the bottom inset clear of the nav', () {
    final inset = AppTheme.dark.snackBarTheme.insetPadding as EdgeInsets;
    expect(inset.bottom, greaterThanOrEqualTo(96),
        reason: 'must stay above the in-body nav (~88px)');
  });
}
