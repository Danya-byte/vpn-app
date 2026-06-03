import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/core/proxy_node.dart';

/// The store-wipe guard: a profile store that reads back EMPTY (unclean exit /
/// transient empty-load persisted / crash mid-write) must NOT silently lose every
/// profile — it recovers from the `.bak` mirror of the last non-empty save. A
/// DELIBERATE clear / last-node removal drops the backup so empty genuinely
/// sticks. This locks the exact data loss that bit the user ("configs vanished").
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('storerec');
    ProfileStore.overrideDir = tmp.path;
  });
  tearDown(() {
    ProfileStore.overrideDir = null;
    tmp.deleteSync(recursive: true);
  });

  ParsedNode node(String tag) => ParsedNode(
        tag: tag,
        outbound: {'type': 'vless', 'tag': tag, 'server': '1.2.3.4'},
      );

  File main() => File('${tmp.path}${Platform.pathSeparator}profiles.json');

  test('a non-empty save mirrors a .bak backup', () {
    ProfileStore.save([node('A')], 'A');
    expect(File('${tmp.path}${Platform.pathSeparator}profiles.bak.json').existsSync(),
        isTrue);
  });

  test('a wiped main store is RECOVERED from the backup on load', () {
    ProfileStore.save([node('A'), node('B')], 'A');
    // Simulate the wipe: the main file reads back as a valid-but-empty store.
    main().writeAsStringSync('{"nodes":[],"selected":null}');
    final loaded = ProfileStore.load();
    expect(loaded.nodes.map((n) => n.tag), ['A', 'B'],
        reason: 'profiles recovered from .bak, not lost');
    expect(loaded.selected, 'A');
    // load() also heals the main file so the next launch is clean.
    expect(ProfileStore.load().nodes.length, 2);
  });

  test('a DELIBERATE clear (dropBackup) is NOT resurrected', () {
    ProfileStore.save([node('A')], 'A');
    ProfileStore.save(const [], null, const {}, true); // deliberate clear
    final loaded = ProfileStore.load();
    expect(loaded.nodes, isEmpty, reason: 'cleared store stays empty');
  });

  test('recovery only triggers when main is empty (healthy main wins)', () {
    ProfileStore.save([node('A')], 'A');
    ProfileStore.save([node('C')], 'C'); // newer non-empty main + bak
    final loaded = ProfileStore.load();
    expect(loaded.nodes.map((n) => n.tag), ['C']);
  });
}
