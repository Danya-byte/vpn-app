import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'; // StateProvider (moved in Riverpod 3)

import '../../../core/deeplink.dart' show importablePayload;

/// A server link the app spotted on the clipboard (e.g. a vless:// link copied
/// from a chat) that it OFFERS to import via a one-tap, dismissible Home banner —
/// NEVER auto-applied; tapping it still goes through the untrusted import
/// preview-gate. Null = nothing pending. The highest-ROI cold-start helper: a
/// first-timer who pasted a link into the wrong place gets a one-tap path in.
final clipboardImportProvider = StateProvider<String?>((_) => null);

// The exact clipboard text we already offered (or the user dismissed), so we
// don't re-nag for the same link on every window focus.
String? _lastClipboardOffered;

bool _looksLikeServerLink(String s) => RegExp(
        r'^(vless|vmess|trojan|ss|hysteria2?|hy2|tuic|socks5?|anytls|vpn|clash|sing-box|hiddify)://',
        caseSensitive: false)
    .hasMatch(s.trim());

/// Peek the clipboard; if it holds an importable SERVER link we haven't already
/// offered, surface it via [clipboardImportProvider]. Bare http(s) URLs are
/// intentionally ignored — too ambiguous to auto-offer without nagging.
Future<void> peekClipboardForImport(WidgetRef ref) async {
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || text == _lastClipboardOffered) return;
    if (!_looksLikeServerLink(text) || importablePayload(text) == null) return;
    ref.read(clipboardImportProvider.notifier).state = text;
  } catch (_) {
    // clipboard unavailable / not text — ignore
  }
}

/// Hide the current clipboard offer. [latch] records the text as already-offered
/// so it's never re-surfaced. Pass true for an explicit DISMISS (the user said
/// "no"); pass false for the ADD path — the untrusted preview-gate may still be
/// cancelled, so the banner hides now but the link stays re-offerable until
/// [markClipboardImported] confirms it was actually added. Latching on Add (the
/// old behaviour) permanently suppressed a link whenever the user cancelled the
/// preview.
void clearClipboardOffer(WidgetRef ref, {bool latch = true}) {
  if (latch) _lastClipboardOffered = ref.read(clipboardImportProvider);
  ref.read(clipboardImportProvider.notifier).state = null;
}

/// Latch a link as already-imported so it isn't re-offered on the next focus.
/// Called from the ADD path ONLY after the import actually added node(s) — so an
/// aborted preview never suppresses a link the user still wants to retry.
void markClipboardImported(String text) {
  _lastClipboardOffered = text;
}
