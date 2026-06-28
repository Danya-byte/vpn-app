import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_settings.dart';
import '../../../core/core_controller.dart';
import '../../../core/format.dart';
import '../../../core/latency_probe.dart';
import '../../../core/native_admin.dart';
import '../../../core/profiles_controller.dart';
import '../../../core/proxy_node.dart';
import '../../../core/share_link_encoder.dart';
import '../../../l10n/app_localizations.dart';
import '../../../app/theme.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/glass.dart';
import 'config_viewer.dart';
import 'import_actions.dart';
import 'server_node_dialog.dart';

const _filesChannel = MethodChannel('app/files');

Future<void> showProfilesSheet(BuildContext context) {
  return showGlassSheet(context, child: const _ProfilesSheet());
}

class _ProfilesSheet extends ConsumerWidget {
  const _ProfilesSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(profilesProvider);
    final latency = ref.watch(latencyProbeProvider);
    // The pre-connect probe dials servers DIRECTLY (raw TCP, ignores the system
    // proxy) — while connected in proxy mode that leaks the real IP→server map
    // around the tunnel, and it's redundant (live latency lives in Policies). So
    // it's a disconnected-only action.
    final connected = ref.watch(coreControllerProvider).isOn;
    // Live in-tunnel ping of the ACTIVE node (clash urltest) — gives the connected
    // node a real `ms` even on a UDP transport (hy2/tuic) the pre-connect TCP probe
    // can't measure (it'd show "UDP" otherwise — the user's hy2 "no ping" gripe).
    final liveMs = ref.watch(latencyProvider).value;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 10,
        bottom: 18 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // (grabber is provided by showGlassSheet itself now)
          Row(
            children: [
              Text('${l.profiles} (${state.nodes.length})',
                  style: const TextStyle(
                      fontSize: AppTheme.tsTitle, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (state.nodes.isNotEmpty)
                IconButton(
                  tooltip: connected ? l.pingAllWhileOn : l.pingAll,
                  visualDensity: VisualDensity.compact,
                  icon: latency.measuring.isNotEmpty
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: scheme.primary),
                        )
                      : Icon(Icons.network_check_rounded,
                          color: connected
                              ? scheme.onSurface.withValues(alpha: 0.3)
                              : scheme.primary),
                  onPressed: (latency.measuring.isNotEmpty || connected)
                      ? null
                      : () => ref
                          .read(latencyProbeProvider.notifier)
                          .measureAll(state.nodes,
                              abort: () =>
                                  ref.read(coreControllerProvider).isOn),
                ),
              if (state.nodes.any((n) => n.source != null))
                IconButton(
                  tooltip: l.refreshSubs,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.refresh_rounded, color: scheme.primary),
                  onPressed: () => _refreshSubs(context, ref),
                ),
              IconButton(
                tooltip: l.addProfile,
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.more_vert_rounded, color: scheme.primary),
                onPressed: () => showGlassDialog<void>(
                  context,
                  child: _AddMenu(parentContext: context, ref: ref),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (state.nodes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(l.profilesEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.5))),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: state.nodes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final n = state.nodes[i];
                  final selected = n.tag == state.selectedNode?.tag;
                  return _NodeTile(
                    node: n,
                    selected: selected,
                    // Connected active node: prefer its real TCP ms, else the live
                    // in-tunnel ping (so a hy2/tuic active node shows a number).
                    latencyMs: (connected && selected)
                        ? (latency.results[n.tag] ?? liveMs)
                        : latency.results[n.tag],
                    measured: latency.measured(n.tag),
                    measuring: latency.isMeasuring(n.tag),
                    unverified: latency.isUnverified(n.tag),
                    // select() already restarts the live tunnel to the new node;
                    // a second restart here caused a DOUBLE restart per tap.
                    onTap: () => _selectGuarded(context, ref, n),
                    onDelete: () => _confirmDelete(context, ref, n),
                    onRename: () => _renameDialog(context, ref, n),
                    onView:
                        n.isConfig ? () => showConfigViewer(context, n) : null,
                    onPinCert: n.insecure
                        ? () => _pinCertDialog(context, ref, n)
                        : null,
                    onUnpin: n.pinned
                        ? () => _unpinDialog(context, ref, n)
                        : null,
                    onShare: () => _shareNode(context, ref, n),
                  );
                },
              ),
            ),
          // Admin mode has no live drag-hover overlay (Windows UIPI), so a
          // persistent hint tells the user drag-drop still works there.
          if (ref.watch(isElevatedProvider).value == true) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.file_download_outlined,
                    size: 13, color: scheme.onSurface.withValues(alpha: 0.4)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(l.adminDropHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: AppTheme.tsCaption,
                          color: scheme.onSurface
                              .withValues(alpha: AppTheme.alphaSecondary))),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The "add profile" methods, shown in a centered glass dialog.
class _AddMenu extends StatelessWidget {
  const _AddMenu({required this.parentContext, required this.ref});

  final BuildContext parentContext;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget item(IconData icon, String label,
        void Function(BuildContext, WidgetRef) run) {
      return InkWell(
        onTap: () {
          Navigator.pop(context);
          run(parentContext, ref);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 14),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        // Primary import paths first — the cold-start move is pasting a link from a
        // chat or scanning a QR, so those lead; power actions go below the divider.
        item(Icons.paste_rounded, l.btnFromClipboard, _importClipboard),
        item(Icons.content_paste_rounded, l.btnLinkList, _importTextDialog),
        item(Icons.qr_code_scanner_rounded, l.btnScanScreenQr, _scanScreenQr),
        item(Icons.link_rounded, l.btnSubscriptionUrl, _importUrlDialog),
        item(Icons.folder_open_rounded, l.btnFromFile, _importFile),
        const Divider(height: 6, indent: 18, endIndent: 18),
        item(Icons.dns_rounded, l.createOwnNode, showServerGenSheet),
        item(Icons.ios_share_rounded, l.shareTitle, _shareProfiles),
        item(Icons.save_alt_rounded, l.btnExport, _exportProfiles),
        const SizedBox(height: 6),
      ],
    );
  }
}

Future<void> _renameDialog(
    BuildContext context, WidgetRef ref, ParsedNode n) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final ctrl = TextEditingController(text: n.tag);
  try {
    final ok = await showGlassDialog<bool>(
      context,
      child: _GlassFormDialog(
        title: l.renameAction,
        confirmLabel: l.renameAction,
        field: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 64,
          decoration: glassInputDecoration(context, l.renameAction),
        ),
      ),
    );
    if (ok == true) {
      final renamed =
          ref.read(profilesProvider.notifier).rename(n.tag, ctrl.text);
      // Name empty / unchanged / already taken — say so instead of silently
      // closing as if the rename happened (sibling dialogs all toast failures).
      if (!renamed && ctrl.text.trim() != n.tag) {
        toast.message(l.renameInvalid, kind: ToastKind.error);
      }
    }
  } finally {
    ctrl.dispose(); // release on every path (confirm / cancel / throw)
  }
}

/// Pin a server's TLS certificate onto an insecure node so verification can be
/// turned ON (the secure alternative to "trust anything"). The user pastes the
/// server's PEM; sing-box then validates the handshake against exactly that cert.
Future<void> _pinCertDialog(
    BuildContext context, WidgetRef ref, ParsedNode n) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final ctrl = TextEditingController();
  bool? ok;
  var pem = '';
  try {
    ok = await showGlassDialog<bool>(
      context,
      child: _GlassFormDialog(
        title: l.pinCertTitle,
        confirmLabel: l.pinCertAction,
        field: TextField(
          controller: ctrl,
          maxLines: 7,
          minLines: 4,
          autofocus: true,
          style: const TextStyle(fontSize: 11, height: 1.3),
          decoration: glassInputDecoration(context, l.pinCertHint),
        ),
      ),
    );
    pem = ctrl.text; // capture before dispose
  } finally {
    ctrl.dispose();
  }
  if (ok != true || !context.mounted) return;
  final r = ref.read(profilesProvider.notifier).pinCertificate(n.tag, pem);
  final (msg, kind) = switch (r) {
    PinResult.ok => (l.pinCertDone, ToastKind.success),
    PinResult.multipleServers => (l.pinCertMulti, ToastKind.error),
    _ => (l.pinCertInvalid, ToastKind.error),
  };
  toast.message(msg, kind: kind);
}

/// Reverse a cert pin (confirm first — it restarts the active tunnel back to the
/// insecure state). The recovery path for a wrong pasted cert that bricked the
/// node while hiding its MITM badge.
Future<void> _unpinDialog(
    BuildContext context, WidgetRef ref, ParsedNode n) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final ok = await showGlassDialog<bool>(
    context,
    child: _ConfirmDialog(
        message: l.unpinCertConfirm, confirmLabel: l.unpinCertAction),
  );
  if (ok != true || !context.mounted) return;
  ref.read(profilesProvider.notifier).unpinCertificate(n.tag);
  toast.message(l.unpinCertDone);
}

Future<void> _importTextDialog(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  final ctrl = TextEditingController();
  bool? ok;
  var text = '';
  try {
    ok = await showGlassDialog<bool>(
      context,
      child: _GlassFormDialog(
        title: l.dlgImportTitle,
        confirmLabel: l.importAction,
        field: TextField(
          controller: ctrl,
          maxLines: 6,
          minLines: 3,
          autofocus: true,
          decoration: glassInputDecoration(context, l.dlgImportHint),
        ),
      ),
    );
    text = ctrl.text; // capture before dispose
  } finally {
    ctrl.dispose();
  }
  if (ok != true || !context.mounted) return;
  final r = ref.read(profilesProvider.notifier).importText(text);
  await applyImport(context, ref, r);
}

Future<void> _shareProfiles(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final nodes = ref.read(profilesProvider).nodes;
  if (nodes.isEmpty) {
    toast.message(l.shareNothing);
    return;
  }
  final mode = await showGlassDialog<String>(context, child: const _ShareMenu());
  if (mode == null || !context.mounted) return;
  final String link;
  if (mode == 'bundle') {
    // Our extended format: nodes + the user's protection settings — only our app
    // reads it. A self-hosted auto-update URL is an operator concern, not exposed
    // in a quick share, so this is a static one-shot bundle.
    link = ShareLinkEncoder.encodeBundle(
      nodes: nodes,
      settings: ref.read(settingsProvider).shareableSubset(),
    );
  } else {
    // Universal: standard URIs any client imports. A whole-config profile (the
    // common case — an imported `🌍 VPN`) has no single-URI form, but the servers
    // INSIDE it do: nodeLinks pulls them out. One link → copy it raw; many → a
    // base64 subscription. Only a config with zero single-URI exits (all
    // chained / exotic) yields nothing — then say so instead of copying empty.
    // "For any app" shares the WHOLE server list — every exit inside a config
    // becomes a link (a subscription when there's more than one), NOT just the
    // currently-connected one, so the recipient gets all your servers.
    final links = ShareLinkEncoder.nodeLinks(nodes);
    if (links.isEmpty) {
      toast.message(l.shareNoUniversal, kind: ToastKind.error);
      return;
    }
    link = links.length == 1
        ? links.single
        : ShareLinkEncoder.encodeSubscription(nodes);
  }
  await Clipboard.setData(ClipboardData(text: link));
  if (!context.mounted) return;
  toast.message(l.shareCopied, kind: ToastKind.success);
}

/// Share ONE profile straight from its row (no need to open the ⋮ menu): the same
/// universal-link / with-settings choice as [_shareProfiles], scoped to [n]. "For
/// any app" extracts EVERY exit server inside a config, not just the active one.
Future<void> _shareNode(
    BuildContext context, WidgetRef ref, ParsedNode n) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final mode = await showGlassDialog<String>(context, child: const _ShareMenu());
  if (mode == null || !context.mounted) return;
  final String link;
  if (mode == 'bundle') {
    link = ShareLinkEncoder.encodeBundle(
      nodes: [n],
      settings: ref.read(settingsProvider).shareableSubset(),
    );
  } else {
    final links = ShareLinkEncoder.nodeLinks([n]);
    if (links.isEmpty) {
      toast.message(l.shareNoUniversal, kind: ToastKind.error);
      return;
    }
    link = links.length == 1
        ? links.single
        : ShareLinkEncoder.encodeSubscription([n]);
  }
  await Clipboard.setData(ClipboardData(text: link));
  if (!context.mounted) return;
  toast.message(l.shareCopied, kind: ToastKind.success);
}

/// Choose the share form: a universal link any client imports, or our extended
/// bundle that also carries the user's protection settings (this app only).
class _ShareMenu extends StatelessWidget {
  const _ShareMenu();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget opt(IconData icon, String title, String desc, String value) =>
        InkWell(
          onTap: () => Navigator.pop(context, value),
          borderRadius: BorderRadius.circular(AppTheme.rButton),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: AppTheme.tsBody,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(desc,
                          style: TextStyle(
                              fontSize: AppTheme.tsCaption,
                              color: scheme.onSurface.withValues(alpha: 0.6))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
          child: Text(l.shareTitle,
              style: const TextStyle(
                  fontSize: AppTheme.tsHeading, fontWeight: FontWeight.w700)),
        ),
        opt(Icons.public_rounded, l.shareForAnyClient, l.shareForAnyClientDesc,
            'any'),
        const Divider(height: 6, indent: 18, endIndent: 18),
        opt(Icons.shield_rounded, l.shareWithSettings, l.shareWithSettingsDesc,
            'bundle'),
        const SizedBox(height: 8),
      ],
    );
  }
}

Future<void> _importUrlDialog(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final ctrl = TextEditingController();
  bool? ok;
  var url = '';
  try {
    ok = await showGlassDialog<bool>(
      context,
      child: _GlassFormDialog(
        title: l.dlgUrlTitle,
        confirmLabel: l.loadAction,
        field: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: glassInputDecoration(context, l.dlgUrlHint),
        ),
      ),
    );
    url = ctrl.text.trim(); // capture before dispose
  } finally {
    ctrl.dispose();
  }
  if (ok != true) return;
  if (url.isEmpty) {
    toast.message(l.msgSubscriptionEmpty, kind: ToastKind.error);
    return;
  }
  try {
    final r =
        await ref.read(profilesProvider.notifier).importSubscriptionUrl(url);
    if (!context.mounted) return;
    await applyImport(context, ref, r);
  } catch (e) {
    toast.message(l.msgLoadError(friendlyError(e)), kind: ToastKind.error);
  }
}

Future<void> _importClipboard(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  if (!context.mounted) return;
  final text = data?.text ?? '';
  if (text.trim().isEmpty) {
    toast.message(l.msgClipboardEmpty, kind: ToastKind.error);
    return;
  }
  final r = ref.read(profilesProvider.notifier).importText(text);
  await applyImport(context, ref, r);
}

/// Export the whole profile store to a JSON file (a backup, re-importable via
/// the normal import path which recognises the store shape).
Future<void> _exportProfiles(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final json = ref.read(profilesProvider.notifier).exportJson();
  final path = await _filesChannel
      .invokeMethod<String>('saveFile', {'name': 'vpn-app-profiles.json'});
  if (path == null || path.isEmpty || !context.mounted) return;
  try {
    await File(path).writeAsString(json);
    toast.message(l.exportDone, kind: ToastKind.success);
  } catch (e) {
    toast.message(l.msgLoadError(friendlyError(e)), kind: ToastKind.error);
  }
}

/// Capture the screen natively and scan it for a QR — e.g. a config QR shown in
/// Telegram Desktop, the dominant RF sharing flow, without a camera. The source
/// is untrusted, so it goes through the preview-gate before connecting.
Future<void> _scanScreenQr(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  Uint8List? bytes;
  try {
    bytes = await _filesChannel.invokeMethod<Uint8List>('scanScreenQr');
  } catch (e) {
    toast.message(l.msgLoadError('$e'), kind: ToastKind.error);
    return;
  }
  if (!context.mounted) return;
  if (bytes == null || bytes.isEmpty) {
    toast.message(l.msgQrNotFound, kind: ToastKind.error);
    return;
  }
  await importDroppedContent(context, ref, bytes, trusted: false);
}

Future<void> _importFile(BuildContext context, WidgetRef ref) async {
  final path = await _filesChannel.invokeMethod<String>('openFile');
  if (path == null || path.isEmpty || !context.mounted) return;
  await importFromFile(context, ref, path);
}

/// Confirm before deleting — the trash icon sits next to the view/select
/// targets, so a mis-tap shouldn't silently drop a profile.
// A tap while the tunnel is UP immediately select()→restart()s onto the node. If
// it's insecure (cert-validation-off), ask first — the SAME MITM consent the
// Connect button enforces, so a mid-session switch can't bypass H5. A
// disconnected tap just sets the selection; the Connect button gates that one.
Future<void> _selectGuarded(
    BuildContext context, WidgetRef ref, ParsedNode n) async {
  if (n.insecure &&
      ref.read(coreControllerProvider).isOn &&
      !ref.read(settingsProvider).insecureAccepted.contains(n.insecureKey)) {
    final l = AppLocalizations.of(context);
    final ok = await showGlassDialog<bool>(
      context,
      child: _ConfirmDialog(
          message: l.insecureConnectBody, confirmLabel: l.insecureConnectAction),
    );
    if (ok != true) return;
    ref.read(settingsProvider.notifier).acceptInsecure(n.insecureKey);
  }
  ref.read(profilesProvider.notifier).select(n.tag);
}

Future<void> _confirmDelete(
    BuildContext context, WidgetRef ref, ParsedNode n) async {
  final l = AppLocalizations.of(context);
  final ok = await showGlassDialog<bool>(
    context,
    child: _ConfirmDialog(
        message: l.deleteProfileConfirm(n.tag), confirmLabel: l.delete),
  );
  if (ok == true) ref.read(profilesProvider.notifier).remove(n.tag);
}

Future<void> _refreshSubs(BuildContext context, WidgetRef ref) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  final r = await ref.read(profilesProvider.notifier).refreshSubscriptions();
  if (!context.mounted) return;
  toast.message(r.added > 0 ? l.msgAddedNodes(r.added) : l.subsUpToDate);
}

class _GlassFormDialog extends StatelessWidget {
  const _GlassFormDialog({
    required this.title,
    required this.field,
    required this.confirmLabel,
  });

  final String title;
  final Widget field;
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
              style: const TextStyle(
                  fontSize: AppTheme.tsHeading, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          field,
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GlassButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l.cancel)),
              const SizedBox(width: 8),
              TgButton(
                  label: confirmLabel,
                  onPressed: () => Navigator.pop(context, true)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({required this.message, required this.confirmLabel});

  final String message;
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
          Text(message,
              style: const TextStyle(
                  fontSize: AppTheme.tsBody, fontWeight: FontWeight.w600)),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              GlassButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(l.cancel)),
              const SizedBox(width: 8),
              TgButton(
                  label: confirmLabel,
                  tone: AppTheme.danger,
                  onPressed: () => Navigator.pop(context, true)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Amber chip warning that a node disables TLS cert validation (MITM-able).
class _InsecureBadge extends StatelessWidget {
  const _InsecureBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    const amber = AppTheme.warning;
    return Tooltip(
      message: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: amber.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppTheme.rChip),
          border: Border.all(color: amber.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.gpp_maybe_rounded, size: 11, color: amber),
            const SizedBox(width: 3),
            Text(label,
                style: const TextStyle(
                    fontSize: AppTheme.tsMicro,
                    fontWeight: FontWeight.w700,
                    color: amber)),
          ],
        ),
      ),
    );
  }
}

/// Green chip = this node's TLS certificate is PINNED (server verified, no longer
/// trust-anything) — the inverse of [_InsecureBadge].
/// The profile tile's ⋮ actions, in OUR glass action-sheet (matches the rest of
/// the app's frosted sheets — not a stock Material popup).
class _NodeActionsSheet extends StatelessWidget {
  const _NodeActionsSheet({
    required this.title,
    required this.onRename,
    required this.onDelete,
    this.onView,
    this.onPinCert,
    this.onUnpin,
    this.onShare,
  });

  final String title;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onView;
  final VoidCallback? onPinCert;
  final VoidCallback? onUnpin;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    Widget row(IconData icon, String label, VoidCallback cb,
        {Color? color, bool danger = false}) {
      final c = danger ? AppTheme.danger : (color ?? scheme.onSurface);
      return InkWell(
        onTap: () {
          Navigator.pop(context);
          cb();
        },
        borderRadius: BorderRadius.circular(AppTheme.rPanel),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
          child: Row(children: [
            Icon(icon, size: 20, color: c),
            const SizedBox(width: 16),
            Text(label, style: TextStyle(fontSize: AppTheme.tsBody, color: c)),
          ]),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // (grabber is provided by showGlassSheet itself now)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: AppTheme.tsBody)),
            ),
            if (onView != null) row(Icons.code_rounded, l.viewConfig, onView!),
            if (onPinCert != null)
              row(Icons.verified_user_outlined, l.pinCertAction, onPinCert!),
            if (onUnpin != null)
              row(Icons.verified_user_rounded, l.unpinCertAction, onUnpin!,
                  color: AppTheme.success),
            if (onShare != null)
              row(Icons.ios_share_rounded, l.shareTitle, onShare!),
            row(Icons.edit_outlined, l.renameAction, onRename),
            row(Icons.delete_outline_rounded, l.deleteAction, onDelete,
                danger: true),
          ],
        ),
      ),
    );
  }
}

class _PinnedBadge extends StatelessWidget {
  const _PinnedBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    const green = AppTheme.success;
    return Tooltip(
      message: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: green.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppTheme.rChip),
          border: Border.all(color: green.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.verified_rounded, size: 11, color: green),
            const SizedBox(width: 3),
            Text(label,
                style: const TextStyle(
                    fontSize: AppTheme.tsMicro,
                    fontWeight: FontWeight.w700,
                    color: green)),
          ],
        ),
      ),
    );
  }
}

/// Compact latency readout: green/amber/red `N ms` for a reachable TCP server,
/// grey "UDP" when the transport is UDP (a TCP probe can't measure it — not a
/// block), a red block icon when a TCP server didn't answer (likely blocked), and
/// an amber "?" when the host couldn't be safely resolved over DoH (the system
/// resolver is poisonable, so the result can't be trusted either way).
class _LatencyChip extends StatelessWidget {
  const _LatencyChip(
      {required this.ms, required this.udp, this.unverified = false});

  final int? ms;
  final bool udp;
  final bool unverified;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final int? ping = ms;
    late final Color color;
    late final Widget child;
    if (unverified) {
      color = AppTheme.warning;
      child = Text('?',
          style: TextStyle(
              fontSize: AppTheme.tsCaption,
              fontWeight: FontWeight.w700,
              color: color));
    } else if (ping != null) {
      color = ping < 150
          ? AppTheme.success
          : ping < 400
              ? AppTheme.warning
              : AppTheme.danger;
      child = Text('$ping ms',
          style: TextStyle(
              fontSize: AppTheme.tsCaption,
              fontWeight: FontWeight.w700,
              color: color));
    } else if (udp) {
      color = scheme.onSurface.withValues(alpha: 0.4);
      child = Text('UDP',
          style: TextStyle(
              fontSize: AppTheme.tsCaption,
              fontWeight: FontWeight.w700,
              color: color));
    } else {
      color = AppTheme.danger;
      child = Icon(Icons.block_rounded, size: 12, color: color);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(AppTheme.rChip),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: child,
      ),
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.node,
    required this.selected,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    this.onView,
    this.onPinCert,
    this.onUnpin,
    this.onShare,
    this.latencyMs,
    this.measured = false,
    this.measuring = false,
    this.unverified = false,
  });

  final ParsedNode node;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback? onView;
  final VoidCallback? onPinCert;
  final VoidCallback? onUnpin;
  final VoidCallback? onShare;
  final int? latencyMs;
  final bool measured;
  final bool measuring;
  final bool unverified;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    // More info on the subtitle line: protocol · server:port (the user asked for
    // a richer, readable row). Region/flag would need a bundled GeoIP — separate.
    final ep = nodeEndpoint(node);
    final sub =
        ep != null ? '${node.type} · ${ep.host}:${ep.port}' : node.type;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.rCard),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.05),
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.rCard),
              border: Border.all(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.10),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  size: 20,
                  color: selected
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(node.tag,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Row(
                        children: [
                          Flexible(
                            child: Text(sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: AppTheme.tsCaption,
                                    color: scheme.onSurface
                                        .withValues(alpha: 0.5))),
                          ),
                          if (node.insecure) ...[
                            const SizedBox(width: 6),
                            _InsecureBadge(label: l.insecureBadge),
                          ],
                          if (node.pinned) ...[
                            const SizedBox(width: 6),
                            _PinnedBadge(label: l.pinnedBadge),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (measuring)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (measured)
                  _LatencyChip(
                    ms: latencyMs,
                    udp: nodeEndpoint(node)?.udp ?? false,
                    unverified: unverified,
                  ),
                // All row actions live in OUR glass action-sheet (not a stock
                // Material popup) so the row never overflows: select · name · ping · ⋮.
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: l.moreActions,
                  icon: Icon(Icons.more_vert_rounded,
                      size: 18, color: scheme.onSurface.withValues(alpha: 0.55)),
                  onPressed: () => showGlassSheet(
                    context,
                    child: _NodeActionsSheet(
                      title: node.tag,
                      onView: onView,
                      onPinCert: onPinCert,
                      onUnpin: onUnpin,
                      onShare: onShare,
                      onRename: onRename,
                      onDelete: onDelete,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

