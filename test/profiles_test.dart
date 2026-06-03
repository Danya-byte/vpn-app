import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/core/profiles_controller.dart';

void main() {
  // Never touch the real user profile store from tests.
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vpn_profiles_test');
    ProfileStore.overrideDir = tmp.path;
  });
  tearDown(() {
    ProfileStore.overrideDir = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('importText adds nodes and auto-selects one', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    final notifier = c.read(profilesProvider.notifier);
    notifier.clear();

    final added = notifier.importText(
      'vless://b831e6e8-7c0e-4e8e-9f0a-2b2b2b2b2b2b@a.com:443?security=reality&pbk=k&sid=1#A\n'
      'trojan://secret@c.com:443?sni=c.com#C',
    );

    expect(added.added, 2);
    final state = c.read(profilesProvider);
    expect(state.nodes.length, 2);
    expect(state.selectedNode, isNotNull);
    expect(state.selectedNode!.tag, 'A');
  });

  test('subscription source is tagged on imported nodes', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(profilesProvider.notifier);
    n.clear();
    n.importText('trojan://p@x.com:443?sni=x#S',
        source: 'https://sub.example/abc');
    final node = c.read(profilesProvider).nodes.single;
    expect(node.source, 'https://sub.example/abc');
  });

  test('duplicate tags are de-duplicated', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(profilesProvider.notifier);
    notifier.clear();

    notifier.importText('trojan://p@x.com:443?sni=x#Same');
    notifier.importText('trojan://p@y.com:443?sni=y#Same');

    final tags = c.read(profilesProvider).nodes.map((n) => n.tag).toList();
    expect(tags, ['Same', 'Same (2)']);
  });
}
