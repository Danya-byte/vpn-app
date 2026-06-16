import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/amnezia_config.dart';
import '../../../core/app_settings.dart';
import '../../../core/cascade.dart'
    show familiesFromConfig, transportWidelyBlocked;
import '../../../core/core_controller.dart';
import '../../../core/core_paths.dart';
import '../../../core/format.dart';
import '../../../core/profiles_controller.dart';
import '../../../core/proxy_node.dart';
import '../../../core/qr_decode.dart';
import '../../../core/share_link_encoder.dart';
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
      // Declined → roll the import BACK. A node the user said "no" to (it came
      // from an untrusted link/QR/drop) must NOT linger in the list — that was
      // the reported bug. Only newly-added nodes are removed; a re-import of an
      // existing node leaves the original alone.
      final n = ref.read(profilesProvider.notifier);
      for (final t in r.addedTags) {
        n.remove(t);
      }
      toast.message(
        r.addedTags.isEmpty ? l.importNotConnected : l.importDiscarded,
      );
      return;
    }
  }
  final tag = r.firstTag;
  if (tag != null) ref.read(profilesProvider.notifier).select(tag);
  toast.message(
    r.alreadyImported ? l.msgAlreadyImported : l.msgAddedNodes(r.added),
    kind: ToastKind.success,
  );
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

/// Import a decoded `vpn://share` bundle: add its nodes, then ONE confirmation
/// that previews the node, offers (opt-in) the sender's protection settings, and
/// notes auto-update — with the same untrusted-source warning + rollback-on-
/// cancel as a normal external import. Applying settings is never silent (it
/// changes how the recipient's own app behaves). The preview is shown for EVERY
/// caller — a bundle can rewire settings, so there is no trusted fast-path.
Future<void> _importBundle(
  BuildContext context,
  WidgetRef ref,
  ShareBundle bundle,
) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final notifier = ref.read(profilesProvider.notifier);
  final r = notifier.importNodes(
    bundle.nodes,
    selectFirst: false,
    source: bundle.autoUpdate ? bundle.subUrl : null,
  );
  if (!r.recognized) {
    toast.message(l.msgNotRecognized, kind: ToastKind.error);
    return;
  }
  if (!context.mounted) return;
  final choice = await showGlassDialog<_BundleChoice>(
    context,
    child: _BundleImportDialog(
      node: _nodeByTag(ref, r.firstTag),
      hasSettings: bundle.settings != null && bundle.settings!.isNotEmpty,
      autoUpdate: bundle.autoUpdate && (bundle.subUrl?.isNotEmpty ?? false),
    ),
  );
  if (!context.mounted) return;
  if (choice == null || !choice.connect) {
    for (final t in r.addedTags) {
      notifier.remove(t);
    }
    toast.message(
      r.addedTags.isEmpty ? l.importNotConnected : l.importDiscarded,
    );
    return;
  }
  if (choice.applySettings && bundle.settings != null) {
    // applyShared coerces every field, but wrap defensively: a future unguarded
    // field on an untrusted bundle must surface a toast, never dead-end the import
    // with the nodes already added (we've passed the rollback-on-cancel point).
    try {
      ref.read(settingsProvider.notifier).applyShared(bundle.settings!);
    } catch (_) {
      if (context.mounted) {
        toast.message(l.msgNotRecognized, kind: ToastKind.error);
      }
    }
  }
  final tag = r.firstTag;
  if (tag != null) notifier.select(tag);
  toast.message(
    r.alreadyImported ? l.msgAlreadyImported : l.msgAddedNodes(r.added),
    kind: ToastKind.success,
  );
  final core = ref.read(coreControllerProvider.notifier);
  await core.restart(reason: 'import bundle');
  // Mirror applyImport: the success toast mustn't be the last word if the tunnel
  // never came up (bad node / rejected config) or came up silent-dead.
  final status = ref.read(coreControllerProvider).status;
  if (status == CoreStatus.error) {
    toast.message(l.importFailed, kind: ToastKind.error);
  } else if (status == CoreStatus.running) {
    final flowing = await core.probeTrafficFlowing();
    if (!flowing && context.mounted) {
      toast.message(l.importNoTraffic, kind: ToastKind.error);
    }
  }
}

ParsedNode? _nodeByTag(WidgetRef ref, String? tag) {
  for (final n in ref.read(profilesProvider).nodes) {
    if (n.tag == tag) return n;
  }
  return null;
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
    bytes = utf8.encode(
      qr,
    ); // re-enter the normal text path with the decoded link
  }
  final content = _decodeBytes(bytes);
  // Our own `vpn://share` bundle (nodes carried losslessly + the sender's
  // protection settings + an optional auto-update URL). Handle it before the
  // generic parsers, which don't know the scheme.
  final bundle = ShareLinkEncoder.decodeBundle(content);
  if (bundle != null) {
    await _importBundle(context, ref, bundle);
    return;
  }
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
        context,
        host != null && host.isNotEmpty ? host : url,
        insecure: url.startsWith('http://'),
      );
      if (!context.mounted || go != true) return;
    }
    ImportResult fetched;
    try {
      fetched = await ref
          .read(profilesProvider.notifier)
          .importSubscriptionUrl(url);
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
  BuildContext context,
  WidgetRef ref,
  ImportResult r,
) {
  ParsedNode? node;
  for (final n in ref.read(profilesProvider).nodes) {
    if (n.tag == r.firstTag) {
      node = n;
      break;
    }
  }
  return showGlassDialog<bool>(context, child: _ImportPreview(node: node));
}

/// Consent before fetching an untrusted subscription URL (it leaks the IP).
Future<bool?> _confirmFetch(
  BuildContext context,
  String host, {
  bool insecure = false,
}) {
  final l = AppLocalizations.of(context);
  final body = insecure
      ? '${l.importFetchBody(host)}\n\n⚠ ${l.importFetchInsecure}'
      : l.importFetchBody(host);
  return showGlassDialog<bool>(
    context,
    child: _ConsentDialog(
      title: l.importFetchTitle,
      body: body,
      confirmLabel: l.importContinue,
    ),
  );
}

/// The result of the bundle-import dialog: whether to connect, and whether to
/// also apply the sender's shared protection settings.
class _BundleChoice {
  const _BundleChoice(this.connect, this.applySettings);
  final bool connect;
  final bool applySettings;
}

/// Preview a shared `vpn://share` bundle: the node, an opt-in toggle to apply the
/// sender's protection settings, an auto-update note, and the untrusted-source
/// warning → Connect / Cancel.
class _BundleImportDialog extends StatefulWidget {
  const _BundleImportDialog({
    required this.node,
    required this.hasSettings,
    required this.autoUpdate,
  });

  final ParsedNode? node;
  final bool hasSettings;
  final bool autoUpdate;

  @override
  State<_BundleImportDialog> createState() => _BundleImportDialogState();
}

class _BundleImportDialogState extends State<_BundleImportDialog> {
  bool _applySettings = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final n = widget.node;
    // A bundle is just another UNTRUSTED external import — it must surface the
    // SAME safety signals as the bare-link preview gate (_ImportPreview), else a
    // hostile vpn://share simply chooses the path with no insecure/all-direct
    // warning. Mirror them: insecure badge, routes-everything-DIRECT, exit
    // servers + route.final for a config node, dead-transport hint.
    final insecure = n?.insecure ?? false;
    var routesDirect = false;
    String? cfgServers;
    String? cfgFinal;
    if (n != null && n.isConfig) {
      final cfg = n.config!;
      final outs = ((cfg['outbounds'] as List?) ?? const []).whereType<Map>();
      final servers = outs.map((o) => o['server']).whereType<String>().toSet();
      if (servers.isNotEmpty) cfgServers = servers.join(', ');
      final route = cfg['route'];
      final f = (route is Map ? route['final'] : null)?.toString();
      if (f != null && f.isNotEmpty) cfgFinal = f;
      routesDirect = _configRoutesDirect(cfg);
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.shareImportTitle,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (n != null && !n.isConfig) ...[
            _kvRow(l.importProtocol, n.type),
            _kvRow(
              l.importServer,
              '${n.outbound['server'] ?? '?'}:${n.outbound['server_port'] ?? '?'}',
            ),
          ] else if (n != null && n.isConfig) ...[
            _kvRow(l.importProtocol, l.importConfigProfile),
            if (cfgServers != null) _kvRow(l.importServer, cfgServers),
            if (cfgFinal != null) _kvRow(l.importExit, cfgFinal),
          ],
          if (insecure) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.insecureBadge),
          ],
          if (routesDirect) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.importRoutesDirect),
          ],
          if (n != null && _transportWidelyBlockedNode(n)) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.transportBlockedWarn),
          ],
          if (n != null && _amneziaNeedsBridge(n)) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.amneziaNoBridge),
          ],
          if (widget.autoUpdate) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.sync_rounded, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.shareAutoUpdateNote,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (widget.hasSettings) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: () => setState(() => _applySettings = !_applySettings),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l.shareApplySettings,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l.shareApplySettingsDesc,
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    GlassSwitch(
                      value: _applySettings,
                      onChanged: (v) => setState(() => _applySettings = v),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.error.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              l.importExternalWarning,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, const _BundleChoice(false, false)),
                child: Text(l.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _BundleChoice(true, _applySettings)),
                child: Text(l.importConnectAction),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kvRow(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 78,
          child: Text(
            k,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: SelectableText(v, style: const TextStyle(fontSize: 13)),
        ),
      ],
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
    var routesDirect = false;
    if (n != null && !n.isConfig) {
      final ob = n.outbound;
      rows.add(_kv(l.importProtocol, n.type));
      rows.add(
        _kv(
          l.importServer,
          '${ob['server'] ?? '?'}:${ob['server_port'] ?? '?'}',
        ),
      );
      final tls = ob['tls'];
      final sni = tls is Map ? tls['server_name']?.toString() : null;
      if (sni != null && sni.isNotEmpty) rows.add(_kv('SNI', sni));
    } else if (n != null && n.isConfig) {
      // A full sing-box config: surface what it ACTUALLY does so the user can
      // judge it — the exit server(s) + whether it tunnels or routes everything
      // DIRECT. A hostile config that sends all traffic direct = zero protection
      // + deanonymisation, and would otherwise look identical to a real one.
      final cfg = n.config!;
      final outs = ((cfg['outbounds'] as List?) ?? const []).whereType<Map>();
      final route = cfg['route'];
      final finalTag = (route is Map ? route['final'] : null)?.toString();
      final servers = outs.map((o) => o['server']).whereType<String>().toSet();
      rows.add(_kv(l.importProtocol, l.importConfigProfile));
      if (servers.isNotEmpty) rows.add(_kv(l.importServer, servers.join(', ')));
      if (finalTag != null && finalTag.isNotEmpty) {
        rows.add(_kv(l.importExit, finalTag));
      }
      routesDirect = _configRoutesDirect(cfg);
    }
    final insecure = n?.insecure ?? false;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            n?.tag ?? l.importReviewTitle,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          ...rows,
          if (insecure) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.insecureBadge),
          ],
          if (routesDirect) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.importRoutesDirect),
          ],
          if (n != null && _transportWidelyBlockedNode(n)) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.transportBlockedWarn),
          ],
          if (n != null && _amneziaNeedsBridge(n)) ...[
            const SizedBox(height: 10),
            _InsecureWarn(label: l.amneziaNoBridge),
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
                fontSize: 12.5,
                height: 1.35,
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l.importConnectAction),
              ),
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
          child: Text(
            k,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: SelectableText(v, style: const TextStyle(fontSize: 13)),
        ),
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
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(fontSize: 13.5, height: 1.35)),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmLabel),
              ),
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
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12.5,
              color: amber,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// True if a full imported sing-box config effectively sends ALL traffic DIRECT
// (zero protection / deanonymisation). Catches the evasions a naive
// final=='direct' check misses: NO proxy outbound; the effective `route.final`
// (resolved THROUGH selector/urltest `default`) lands on direct/block; or a
// trailing catch-all rule (no narrowing matcher, or a global 0.0.0.0/0 ip_cidr)
// routes everything to direct/block.
// True when EVERY proxy leaf of this profile rides a transport that's widely
// blocked in RF (plain WireGuard / Shadowsocks / plain VLESS) → warn + suggest a
// survivor (Reality / Hysteria2 / XHTTP). A mixed profile that still has a
// survivor does NOT warn (the cascade can fail over to it).
bool _transportWidelyBlockedNode(ParsedNode n) {
  final cfg = n.isConfig
      ? n.config!
      : {
          'outbounds': [n.outbound],
        };
  final fams = familiesFromConfig(cfg).values;
  return fams.isNotEmpty && fams.every(transportWidelyBlocked);
}

/// True if [n] is an AmneziaWG endpoint (Jc/Jmin/S1-4/H1-4 obfuscation) but the awg
/// bridge binary isn't installed. sing-box dials only PLAIN WireGuard, so without
/// the bridge the app falls back to vanilla WG — which an AmneziaWG server rejects
/// (the handshake never completes). The honest pre-connect signal so a user isn't
/// left guessing why "it won't connect / ping never measures" (a plain WG .conf,
/// by contrast, works natively).
bool _amneziaNeedsBridge(ParsedNode n) {
  if (!n.isConfig) return false;
  // `endpoints` is verbatim from an imported config and is NOT validated upstream
  // (ShareLink only guards `outbounds`), so `as List` would THROW on a hostile
  // `"endpoints": {}` / `"x"` / 5 and crash the preview. `is List` filters instead.
  final raw = n.config?['endpoints'];
  final eps = raw is List ? raw : const [];
  final isAmnezia = eps.any((e) => e is Map && AmneziaConfig.needsAmnezia(e));
  return isAmnezia && !File(CorePaths.awg()).existsSync();
}

bool _configRoutesDirect(Map cfg) {
  const proxyTypes = {
    'vless',
    'vmess',
    'trojan',
    'hysteria2',
    'tuic',
    'shadowsocks',
    'shadowtls',
    'anytls',
    'socks',
    'http',
    'wireguard',
  };
  final outs = ((cfg['outbounds'] as List?) ?? const [])
      .whereType<Map>()
      .toList();
  if (!outs.any((o) => proxyTypes.contains(o['type']))) {
    return true; // no proxy at all
  }
  Map? byTag(String? t) {
    for (final o in outs) {
      if (o['tag']?.toString() == t) return o;
    }
    return null;
  }

  // Resolve a tag to its effective leaf type, following selector/urltest default.
  String? leaf(String? tag, [int depth = 0]) {
    if (tag == null || depth > 6) return null;
    final o = byTag(tag);
    if (o == null) return (tag == 'direct' || tag == 'block') ? tag : null;
    final t = o['type']?.toString();
    if (t == 'selector' || t == 'urltest') {
      final members =
          (o['outbounds'] as List?)?.whereType<String>().toList() ?? const [];
      final def =
          o['default']?.toString() ??
          (members.isNotEmpty ? members.first : null);
      return leaf(def, depth + 1);
    }
    return t;
  }

  final route = cfg['route'];
  if (route is! Map) {
    return false; // no route block → first outbound (a proxy) wins
  }
  // Effective final: explicit route.final, else sing-box uses the first outbound.
  final eff =
      leaf(route['final']?.toString()) ??
      leaf(outs.isNotEmpty ? outs.first['tag']?.toString() : null);
  if (eff == 'direct' || eff == 'block') return true;
  // Destination/identity matchers that genuinely NARROW which traffic a rule
  // catches. `network`/`protocol`/`ip_version` are deliberately NOT here — a rule
  // whose ONLY matcher is one of those still catches ~all browsing, so a hostile
  // config hides an all-direct rule behind e.g. `network:["tcp","udp"]`.
  const narrowing = {
    'domain',
    'domain_suffix',
    'domain_keyword',
    'domain_regex',
    'geosite',
    'rule_set',
    'ip_cidr',
    'geoip',
    'source_ip_cidr',
    'ip_is_private',
    'process_name',
    'process_path',
    'package_name',
    'wifi_ssid',
    'port',
    'source_port',
    'clash_mode',
    'inbound',
    'user',
  };
  bool listHas(Object? v, Set<String> globals) {
    if (v is List) return v.any((e) => globals.contains('$e'.trim()));
    if (v is String) return globals.contains(v.trim());
    return false;
  }

  final rules =
      (route['rules'] as List?)?.whereType<Map>().toList() ?? const <Map>[];
  for (final r in rules) {
    final tgt = leaf(r['outbound']?.toString());
    if (tgt != 'direct' && tgt != 'block') continue;
    // A rule routing ~ALL traffic to direct/block = no protection. Catch: no
    // narrowing matcher; a global IP (0.0.0.0/0, ::/0); or an all-matching domain
    // matcher ("", ".", ".*") an attacker hides behind to look scoped.
    final routesAll =
        !r.keys.any((k) => narrowing.contains(k)) ||
        listHas(r['ip_cidr'], const {'0.0.0.0/0', '::/0'}) ||
        listHas(r['domain_suffix'], const {'', '.'}) ||
        listHas(r['domain_keyword'], const {''}) ||
        listHas(r['domain'], const {''}) ||
        _regexCatchAll(r['domain_regex']);
    if (routesAll) return true;
  }
  return false;
}

// True if any domain_regex matches EVERYTHING — tested against sentinel hostnames
// rather than a literal blocklist, so equivalents like `a|`, `[\s\S]*`, `(.|\n)*`
// are all caught while a narrow regex (`^ads\.`) is not (no false-positive).
bool _regexCatchAll(Object? v) {
  final list = v is List ? v : (v is String ? [v] : const []);
  const sentinels = ['example.com', 'a1.b2.example', 'xyz.test', '10.0.0.1'];
  for (final rx in list) {
    try {
      final re = RegExp('$rx');
      if (sentinels.every(re.hasMatch)) return true;
    } catch (_) {
      /* invalid regex → not a catch-all */
    }
  }
  return false;
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
  if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
    return _utf16(b, le: false);
  }
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
