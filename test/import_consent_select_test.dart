import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/core/profiles_controller.dart';

/// H2 (empty-store leg): an EXTERNAL / untrusted import (deeplink / QR / drag)
/// must never silently become the ACTIVE node — not even on a fresh install
/// where nothing is selected yet. Otherwise the preview-consent gate is
/// back-doored: cancel the preview, but the attacker node is already selected,
/// so a later manual Connect routes through it with no warning. Self-initiated
/// (trusted) imports still auto-select. Locks the `importText(selectFirst:)`
/// contract.
void main() {
  late Directory tmp;

  setUp(() {
    // Point the store at a throwaway temp dir so the test NEVER touches the real
    // user profiles (a prior incident wiped them — see memory).
    tmp = Directory.systemTemp.createTempSync('vpn_select_test_');
    ProfileStore.overrideDir = tmp.path;
  });

  tearDown(() {
    ProfileStore.overrideDir = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  const linkA =
      'vless://11111111-1111-1111-1111-111111111111@1.1.1.1:443?type=tcp&security=tls&sni=a.example&fp=chrome#Alpha';
  const linkB =
      'vless://22222222-2222-2222-2222-222222222222@2.2.2.2:443?type=tcp&security=tls&sni=b.example&fp=chrome#Beta';

  test('untrusted import into an EMPTY store does NOT auto-select (H2)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(profilesProvider.notifier);

    expect(c.read(profilesProvider).selected, isNull); // fresh store
    final r = ctrl.importText(linkA, selectFirst: false);

    expect(r.recognized, isTrue,
        reason: 'the link must parse, else the test asserts nothing');
    expect(c.read(profilesProvider).nodes, isNotEmpty,
        reason: 'the node IS imported (it just must not be activated)');
    expect(c.read(profilesProvider).selected, isNull,
        reason:
            'an untrusted node must not become active without the consent gate');
  });

  test('trusted import (selectFirst:true) still auto-selects on empty store',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(profilesProvider.notifier);

    final r = ctrl.importText(linkA, selectFirst: true);
    expect(r.recognized, isTrue);
    expect(c.read(profilesProvider).selected, isNotNull);
    expect(c.read(profilesProvider).selected, r.firstTag);
  });

  test('a later untrusted import never moves an existing selection', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ctrl = c.read(profilesProvider.notifier);

    ctrl.importText(linkA, selectFirst: true); // user picks A
    final picked = c.read(profilesProvider).selected;
    expect(picked, isNotNull);

    ctrl.importText(linkB, selectFirst: false); // untrusted B arrives
    expect(c.read(profilesProvider).selected, picked,
        reason: 'selection stays on A; B is imported but not activated');
  });
}
