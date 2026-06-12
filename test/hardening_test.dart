import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/app_settings.dart';
import 'package:vpn_app/core/core_paths.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/core/profiles_controller.dart';
import 'package:vpn_app/core/route_mode.dart';
import 'package:vpn_app/core/singbox_config.dart';
import 'package:vpn_app/core/update_check.dart';

/// Locks in the independent-audit hardening so it can't silently regress.
void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vpn_hardening_test');
    ProfileStore.overrideDir = tmp.path;
    SettingsController.overrideDir = tmp.path;
  });
  tearDown(() {
    ProfileStore.overrideDir = null;
    SettingsController.overrideDir = null;
    SingBoxConfig.clashSecret = '';
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('one corrupt node does NOT discard the whole store (C3)', () {
    // A hand-edited / partially-corrupt store: one valid node, several broken.
    final file = File('${tmp.path}${Platform.pathSeparator}profiles.json');
    file.writeAsStringSync(jsonEncode({
      'nodes': [
        {'tag': 'good', 'outbound': {'type': 'trojan', 'tag': 'good'}},
        {'tag': 42, 'outbound': {}}, // tag not a String
        {'tag': 'noOutbound'}, // missing outbound
        {'outbound': {'type': 'x'}}, // missing tag
        'not even a map',
      ],
      'selected': 'good',
    }));
    final loaded = ProfileStore.load();
    expect(loaded.nodes.map((n) => n.tag), ['good']);
    expect(loaded.selected, 'good');
  });

  test('a totally corrupt store degrades to empty, not a crash', () {
    File('${tmp.path}${Platform.pathSeparator}profiles.json')
        .writeAsStringSync('{ this is not json');
    final loaded = ProfileStore.load();
    expect(loaded.nodes, isEmpty);
    expect(loaded.selected, isNull);
  });

  test('atomicWrite leaves no .tmp turd and round-trips (C2)', () {
    final path = '${tmp.path}${Platform.pathSeparator}atomic.txt';
    CorePaths.atomicWrite(path, 'hello-Ω-привет');
    expect(File(path).readAsStringSync(), 'hello-Ω-привет');
    expect(File('$path.tmp').existsSync(), isFalse);
    // Overwrite is also atomic and complete.
    CorePaths.atomicWrite(path, 'second');
    expect(File(path).readAsStringSync(), 'second');
  });

  test('settings are isolated by overrideDir and never touch the real store (C1)',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(settingsProvider.notifier).setVpnMode(VpnMode.tun);
    // Written to the temp dir, NOT %LOCALAPPDATA%.
    final f = File('${tmp.path}${Platform.pathSeparator}settings.json');
    expect(f.existsSync(), isTrue);
    expect(jsonDecode(f.readAsStringSync())['vpnMode'], 'tun');
  });

  test('insecure-node consent persists per tag, asked ONCE not every connect (#4)',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final s = c.read(settingsProvider.notifier);
    expect(c.read(settingsProvider).insecureAccepted, isEmpty);
    s.acceptInsecure('🌍 VPN');
    s.acceptInsecure('🌍 VPN'); // idempotent
    expect(c.read(settingsProvider).insecureAccepted, {'🌍 VPN'});
    // Persisted...
    expect(
        (jsonDecode(File('${tmp.path}${Platform.pathSeparator}settings.json')
            .readAsStringSync())['insecureAccepted'] as List),
        contains('🌍 VPN'));
    // ...and reloaded into a fresh controller (survives a relaunch).
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    expect(c2.read(settingsProvider).insecureAccepted.contains('🌍 VPN'), isTrue);
    expect(c2.read(settingsProvider).insecureAccepted.contains('other'), isFalse);
  });

  test('unknown enum in settings.json defaults only that field (not all)', () {
    File('${tmp.path}${Platform.pathSeparator}settings.json').writeAsStringSync(
        jsonEncode({'mode': 'from_the_future', 'antiDpi': true}));
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final s = c.read(settingsProvider);
    expect(s.mode, RouteMode.smart); // bad enum -> default
    expect(s.antiDpi, isTrue); // other fields preserved
  });

  test('winws desync toggle + strategy persist; junk strategy clamps to default',
      () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final s = c.read(settingsProvider.notifier);
    s.setWinwsDesync(true);
    s.setDesyncStrategy('fake_disorder');
    s.setDesyncStrategy('totally-bogus'); // rejected — stays on the valid one
    expect(c.read(settingsProvider).winwsDesync, isTrue);
    expect(c.read(settingsProvider).desyncStrategy, 'fake_disorder');
    // Reload: persisted + survives a relaunch.
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    expect(c2.read(settingsProvider).winwsDesync, isTrue);
    expect(c2.read(settingsProvider).desyncStrategy, 'fake_disorder');
    // A hostile/corrupt settings.json with a junk strategy must NOT be trusted —
    // winws would otherwise be handed an unvalidated method string.
    File('${tmp.path}${Platform.pathSeparator}settings.json').writeAsStringSync(
        jsonEncode({'winwsDesync': true, 'desyncStrategy': 'rm -rf'}));
    final c3 = ProviderContainer();
    addTearDown(c3.dispose);
    expect(c3.read(settingsProvider).desyncStrategy, 'fake_split'); // default
  });

  test('maxResistance ("hard network") persists across a relaunch (was dropped '
      'from _save → silently reset to OFF every launch)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(settingsProvider).maxResistance, isFalse); // default off
    c.read(settingsProvider.notifier).setMaxResistance(true);
    expect(c.read(settingsProvider).maxResistance, isTrue);
    // Persisted to disk...
    expect(
        jsonDecode(File('${tmp.path}${Platform.pathSeparator}settings.json')
            .readAsStringSync())['maxResistance'],
        isTrue);
    // ...and survives a relaunch (the bug: it was read on load but never written).
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    expect(c2.read(settingsProvider).maxResistance, isTrue);
  });

  test('configs that differ only in key order dedupe on re-import (C9)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(profilesProvider.notifier);
    n.clear();
    const a =
        '{"outbounds":[{"type":"vless","tag":"x","server":"a.com","uuid":"u"}],"route":{"final":"x"}}';
    const b =
        '{"route":{"final":"x"},"outbounds":[{"uuid":"u","server":"a.com","tag":"x","type":"vless"}]}';
    expect(n.importText(a).added, 1);
    expect(n.importText(b).added, 0); // same content, just reordered keys
    expect(c.read(profilesProvider).nodes.length, 1);
  });

  test('update version comparison handles v-prefix, build suffix, ordering', () {
    expect(isNewerVersion('v1.0.1', '1.0.0'), isTrue);
    expect(isNewerVersion('1.2.0', '1.10.0'), isFalse); // 2 < 10, not string cmp
    expect(isNewerVersion('1.0.0+5', '1.0.0+2'), isFalse); // build suffix ignored
    expect(isNewerVersion('2.0.0', 'v1.9.9'), isTrue);
    expect(isNewerVersion('1.0.0', '1.0.0'), isFalse);
  });

  test('Clash API config carries a secret only when one is set (B4)', () {
    SingBoxConfig.clashSecret = '';
    var cfg = SingBoxConfig.m0Local();
    expect((cfg['experimental']['clash_api'] as Map).containsKey('secret'),
        isFalse);

    SingBoxConfig.clashSecret = 'abc123';
    cfg = SingBoxConfig.m0Local();
    expect(cfg['experimental']['clash_api']['secret'], 'abc123');
  });
}
