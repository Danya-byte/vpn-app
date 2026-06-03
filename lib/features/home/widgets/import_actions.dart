import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/core_controller.dart';
import '../../../core/format.dart';
import '../../../core/profiles_controller.dart';
import '../../../core/proxy_node.dart';
import '../../../core/qr_decode.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/glass.dart';

/// Select the imported profile, (re)connect to it, and report the outcome.
/// Shared by every import path.
///
/// [autoConnect] is true for SELF-INITIATED imports (the in-app paste / URL /
/// file-picker dialogs — the user is the source). It is FALSE for EXTERNALLY-
/// triggered imports — a deeplink, a QR image, a window drop — whose content
/// came from an untrusted place (a Telegram message). Connecting to such a node
/// silently would make a hostile server a ONE-CLICK MITM (it sees every
/// destination and can tamper with plaintext) — for activists/journalists a
/// hostile node is worse than no VPN. So an untrusted import never auto-selects
/// or auto-connects: it previews the node (protocol/server/SNI + the insecure
/// badge + a source warning) and connects ONLY on explicit confirmation; on
/// cancel the node is left sitting in the list, not active.
Future<void> applyImport(
  BuildContext context,
  WidgetRef ref,
  ImportResult r, {
  bool autoConnect = true,
}) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  if (!r.recognized) {
    toast.message(l.msgNotRecognized, kind: ToastKind.error);
    return;
  }
  if (!autoConnect) {
    final go = await _confirmExternalImport(context, ref, r);
    if (!context.mounted) return;
    if (go != true) {
      toast.message(l.importNotConnected); // it's in the list, just not active
      return;
    }
  }
  final tag = r.firstTag;
  if (tag != null) ref.read(profilesProvider.notifier).select(tag);
  toast.message(
      r.alreadyImported ? l.msgAlreadyImported : l.msgAddedNodes(r.added),
      kind: ToastKind.success);
  final core = ref.read(coreControllerProvider.notifier);
  await core.restart(reason: 'import');
  // The success toast above mustn't be the last word if the tunnel never
  // came up — surface the real failure (bad node / rejected config).
  final status = ref.read(coreControllerProvider).status;
  if (status == CoreStatus.error) {
    toast.message(l.importFailed, kind: ToastKind.error);
  } else if (status == CoreStatus.running) {
    // The core is "running" (API alive) but a node can come up and carry ZERO
    // traffic (silent-dead) — probe end-to-end so the success isn't a lie (M6).
    final flowing = await core.probeTrafficFlowing();
    if (!flowing && context.mounted) {
      toast.message(l.importNoTraffic, kind: ToastKind.error);
    }
  }
}

/// Read a dropped/picked file (any text encoding) and import it as profiles.
/// [trusted] forwards the self-initiated vs external distinction (see
/// [applyImport]); an in-app file picker is trusted, a dragged/"Open with" file
/// is not.
Future<void> importFromFile(
  BuildContext context,
  WidgetRef ref,
  String path, {
  bool trusted = true,
}) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  List<int> bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (e) {
    toast.message(l.msgLoadError('$e'));
    return;
  }
  if (!context.mounted) return;
  await importDroppedContent(context, ref, bytes, trusted: trusted);
}

/// Import raw dropped bytes — a file's contents, a virtual file (e.g. dragged
/// from a Telegram/browser bubble), or dragged text / a share link. [trusted]:
/// see [applyImport] — drops and deeplinks are NOT trusted.
Future<void> importDroppedContent(
  BuildContext context,
  WidgetRef ref,
  List<int> bytes, {
  bool trusted = true,
}) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  // A QR-code IMAGE (dropped PNG / screenshot / picked photo): decode it to its
  // link text first — QR in Telegram is the dominant way configs are shared in
  // RF. Decoded OFF the UI isolate so a big screenshot never freezes the window.
  if (looksLikeImage(bytes)) {
    final qr = await decodeQrFromImageInBackground(bytes);
    if (!context.mounted) return;
    if (qr == null) {
      toast.message(l.msgQrNotFound, kind: ToastKind.error);
      return;
    }
    bytes = utf8.encode(qr); // re-enter the normal text path with the decoded link
  }
  final content = _decodeBytes(bytes);
  // A bare subscription URL: fetch it (same path as the URL dialog) instead of
  // trying to parse the link text itself — this is the most common import.
  final url = _soleUrl(content);
  if (url != null) {
    // An UNTRUSTED sub-URL deeplink: the fetch itself reveals the user's IP to
    // that host and pulls a foreign config — so get consent (naming the host)
    // BEFORE the network request, never silently on cold launch.
    if (!trusted) {
      final host = Uri.tryParse(url)?.host;
      final go = await _confirmFetch(
          context, host != null && host.isNotEmpty ? host : url);
      if (!context.mounted || go != true) return;
    }
    ImportResult fetched;
    try {
      fetched =
          await ref.read(profilesProvider.notifier).importSubscriptionUrl(url);
    } catch (e) {
      toast.message(l.msgLoadError(friendlyError(e)), kind: ToastKind.error);
      return;
    }
    if (!context.mounted) return;
    await applyImport(context, ref, fetched, autoConnect: trusted);
    return;
  }
  // Don't auto-select an untrusted node — selection is decided at the gate.
  final r = ref
      .read(profilesProvider.notifier)
      .importText(content, selectFirst: trusted);
  if (!r.recognized && content.trim().isNotEmpty) {
    // Show a snippet so an unknown format can be reported and added.
    final head = content.trimLeft().replaceAll(RegExp(r'\s+'), ' ');
    final snip = head.length <= 48 ? head : '${head.substring(0, 48)}…';
    toast.message('${l.msgNotRecognized}: «$snip»', kind: ToastKind.error);
    return;
  }
  await applyImport(context, ref, r, autoConnect: trusted);
}

// ── External-import safety gate ──────────────────────────────────────────────

/// Preview the just-imported (untrusted) node and ask before connecting.
Future<bool?> _confirmExternalImport(
    BuildContext context, WidgetRef ref, ImportResult r) {
  ParsedNode? node;
  for (final n in ref.read(profilesProvider).nodes) {
    if (n.tag == r.firstTag) {
      node = n;
      break;
    }
  }
  return showGlassDialog<bool>(context,
      child: _ImportPreview(node: node));
}

/// Consent before fetching an untrusted subscription URL (it leaks the IP).
Future<bool?> _confirmFetch(BuildContext context, String host) {
  final l = AppLocalizations.of(context);
  return showGlassDialog<bool>(
    context,
    child: _ConsentDialog(
      title: l.importFetchTitle,
      body: l.importFetchBody(host),
      confirmLabel: l.importContinue,
    ),
  );
}

/// Node preview + insecure badge + external-source warning → Connect / Cancel.
class _ImportPreview extends StatelessWidget {
  const _ImportPreview({required this.node});

  final ParsedNode? node;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final n = node;
    final rows = <Widget>[];
    if (n != null && !n.isConfig) {
      final ob = n.outbound;
      rows.add(_kv(l.importProtocol, n.type));
      rows.add(_kv(l.importServer, '${ob['server'] ?? '?'}:${ob['server_port'] ?? '?'}'));
      final tls = ob['tls'];
      final sni = tls is Map ? tls['server_name']?.toString() : null;
      if (sni != null && sni.isNotEmpty) rows.add(_kv('SNI', sni));
    } else if (n != null && n.isConfig) {
      rows.add(_kv(l.importProtocol, l.importConfigProfile));
    }
    final insecure = n?.insecure ?? false;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(n?.tag ?? l.importReviewTitle,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          ...rows,
          if (insecure) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.insecureBadge),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              l.importExternalWarning,
              style: TextStyle(
                  fontSize: 12.5, height: 1.35, color: scheme.onSurface),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l.cancel)),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(l.importConnectAction)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 78,
                child: Text(k,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600))),
            Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}

/// Title + body + confirm/cancel — used for the fetch-consent gate.
class _ConsentDialog extends StatelessWidget {
  const _ConsentDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
  });

  final String title;
  final String body;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(fontSize: 13.5, height: 1.35)),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l.cancel)),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(confirmLabel)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Amber inline warning that a node disables TLS cert validation (MITM-able).
class _InsecureWarn extends StatelessWidget {
  const _InsecureWarn({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFE0A53D);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.gpp_maybe_rounded, size: 16, color: amber),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12.5, color: amber, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

// A dropped/pasted blob that is a single http(s) URL and nothing else -> treat
// it as a subscription link to fetch. A JSON/YAML/link blob has whitespace or
// doesn't start with http, so it falls through to normal parsing.
String? _soleUrl(String s) {
  final t = s.trim();
  if (!t.startsWith('http://') && !t.startsWith('https://')) return null;
  if (RegExp(r'\s').hasMatch(t)) return null;
  return t;
}

// Decode file bytes as text, honoring a UTF-16/UTF-8 BOM (Windows configs are
// often UTF-16), falling back to UTF-8 then latin1 so nothing throws.
String _decodeBytes(List<int> b) {
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) return _utf16(b, le: true);
  if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) return _utf16(b, le: false);
  try {
    return utf8.decode(b);
  } catch (_) {
    return latin1.decode(b, allowInvalid: true);
  }
}

String _utf16(List<int> b, {required bool le}) {
  final units = <int>[];
  for (var i = 2; i + 1 < b.length; i += 2) {
    units.add(le ? (b[i] | (b[i + 1] << 8)) : ((b[i] << 8) | b[i + 1]));
  }
  return String.fromCharCodes(units);
}
