import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vpn_app/core/profile_store.dart';
import 'package:vpn_app/core/profiles_controller.dart';
import 'package:vpn_app/core/proxy_node.dart';
import 'package:vpn_app/core/sub_info.dart';

/// B1: an exported backup must re-import LOSSLESSLY — not just the node list, but
/// the saved selection AND the per-subscription usage/expiry info. The re-import
/// path used to read only `nodes`, silently dropping `selected` + `subInfo`.
void main() {
  ParsedNode node(String tag, String server, {String? source}) => ParsedNode(
        tag: tag,
        outbound: {
          'type': 'vless',
          'tag': tag,
          'server': server,
          'server_port': 443,
          'uuid': '11111111-1111-1111-1111-111111111111',
        },
        source: source,
      );

  group('ProfileStore.encode/decode round-trip (pure)', () {
    test('preserves nodes, selection, and subInfo', () {
      const src = 'https://sub.example/abc';
      final nodes = [
        node('Alpha', '1.1.1.1', source: src),
        node('Beta', '2.2.2.2'),
      ];
      final subInfo = {
        src: const SubInfo(
            upload: 10, download: 20, total: 1000, expire: 1767139200),
      };

      final got = ProfileStore.decode(ProfileStore.encode(nodes, 'Beta', subInfo));
      expect(got, isNotNull);
      expect(got!.nodes.map((n) => n.tag), ['Alpha', 'Beta']);
      expect(got.selected, 'Beta');
      expect(got.subInfo[src]?.total, 1000);
      expect(got.subInfo[src]?.used, 30);
    });

    test('returns null for non-store JSON (falls through to link parsing)', () {
      expect(ProfileStore.decode('{"outbounds":[]}'), isNull);
      expect(ProfileStore.decode('not json at all'), isNull);
    });

    test('one corrupt node is skipped, the rest survive', () {
      const json = '{"nodes":['
          '{"tag":"Good","outbound":{"type":"vless"}},'
          '{"tag":123,"outbound":{}},' // bad tag type -> skipped
          '{"oops":true}' // no tag/outbound -> skipped
          '],"selected":"Good"}';
      final got = ProfileStore.decode(json);
      expect(got, isNotNull);
      expect(got!.nodes.map((n) => n.tag), ['Good']);
      expect(got.selected, 'Good');
    });
  });

  group('importText restores selection + subInfo from a backup', () {
    late Directory tmp;
    setUp(() {
      // Throwaway store dir — NEVER touch the real user profiles (see memory).
      tmp = Directory.systemTemp.createTempSync('vpn_roundtrip_');
      ProfileStore.overrideDir = tmp.path;
    });
    tearDown(() {
      ProfileStore.overrideDir = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('re-import into an EMPTY store restores selected + subInfo', () {
      const src = 'https://sub.example/abc';
      final backup = ProfileStore.encode(
        [node('Alpha', '1.1.1.1', source: src), node('Beta', '2.2.2.2')],
        'Beta',
        {src: const SubInfo(total: 5000, expire: 1767139200)},
      );

      final c = ProviderContainer();
      addTearDown(c.dispose);
      // No selectFirst — the selection must come from the backup itself.
      final r = c.read(profilesProvider.notifier).importText(backup);

      expect(r.recognized, isTrue);
      final s = c.read(profilesProvider);
      expect(s.nodes.map((n) => n.tag), containsAll(['Alpha', 'Beta']));
      expect(s.selected, 'Beta', reason: 'the backup selection is restored');
      expect(s.subInfo[src]?.total, 5000, reason: 'subscription info restored');
    });
  });
}
