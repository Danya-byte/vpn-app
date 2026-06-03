import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'censorship_facts.dart';
import 'core_controller.dart';
import 'singbox_config.dart';

/// The Riverpod layer over the pure [CensorshipFacts] model (②). Kept SEPARATE
/// from the model so the model stays FFI-free — importable by `dart run` tools +
/// unit tests — while this file may pull in the FFI-heavy [coreControllerProvider]
/// for the "only refresh over a live tunnel" gate. build() mirrors the cached
/// [CensorshipFacts.active] (loaded at controller startup) into provider state so
/// the Settings tile shows the persisted version immediately.
final censorshipFactsProvider =
    NotifierProvider<CensorshipFactsController, CensorshipFacts>(
        CensorshipFactsController.new);

class CensorshipFactsController extends Notifier<CensorshipFacts> {
  @override
  CensorshipFacts build() => CensorshipFacts.active;

  /// Fetch the feed THROUGH the tunnel, validate+clamp, and (if newer) cache +
  /// apply it. No-op when disconnected, no URL, or unreachable. Returns true only
  /// when a newer document was actually applied.
  Future<bool> refresh({String? feedUrl}) async {
    final url = (feedUrl ?? kDefaultFactsFeedUrl).trim();
    if (url.isEmpty) return false;
    if (!ref.read(coreControllerProvider).isOn) {
      return false; // only over a working tunnel (github-raw blocked direct in RF)
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) =>
          'PROXY ${SingBoxConfig.mixedListen}:${SingBoxConfig.mixedPort}';
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'vpn-app');
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return false; // 404 (no feed yet) → no-op
      final body = await resp.transform(utf8.decoder).join();
      final facts = CensorshipFacts.parse(body, haveVersion: state.version);
      if (facts == null) return false; // not newer / not an object
      CensorshipFacts.apply(facts);
      CensorshipFacts.cache(facts);
      state = facts;
      return true;
    } catch (_) {
      return false; // network/parse failure → keep what we have
    } finally {
      client.close(force: true);
    }
  }
}
