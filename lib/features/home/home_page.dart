import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'; // StateProvider (Riverpod 3)

import '../../core/app_settings.dart';
import '../../core/core_controller.dart';
import '../../core/deeplink.dart' show importablePayload;
import '../../core/format.dart';
import '../../core/native_admin.dart';
import '../../core/profiles_controller.dart';
import '../../core/sub_info.dart';
import '../../core/update_check.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/glass.dart';
import 'widgets/clipboard_offer.dart';
import 'widgets/config_viewer.dart';
import 'widgets/connect_button.dart';
import 'widgets/import_actions.dart';
import 'widgets/profiles_sheet.dart';

// Compact subscription status: "12.3 / 100 GB  ·  28 d left" (each part shown
// only if the panel returned it).
String? _fmtSub(AppLocalizations l, SubInfo? info) {
  if (info == null) return null;
  final parts = <String>[];
  if (info.hasTraffic) {
    parts.add('${fmtBytes(info.used)} / ${fmtBytes(info.total)}');
  }
  if (info.hasExpiry) {
    final d = info.daysLeft(DateTime.now()) ?? 0;
    parts.add(d <= 0 ? l.subExpired : l.subDaysLeft(d));
  }
  return parts.isEmpty ? null : parts.join('  ·  ');
}

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No whole-CoreState watch here — each child watches the slice it needs, so
    // a log line or detail change doesn't rebuild the entire Home column.
    return Padding(
      // bottom clears the floating nav (~76 bar + 12 margin).
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _HomeTitle(),
          const SizedBox(height: 18),
          const _ProfileBar(),
          const _UpdateBanner(),
          const _ClipboardImportBanner(),
          // Center the stack when it fits, but SCROLL when it doesn't (small
          // window + several status banners) — else the bottom items, including
          // the fail-closed _UnblockButton, get pushed off-screen with no way to
          // tap them out of a locked state.
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const ConnectButton(),
                      const SizedBox(height: 26),
                      const _StatusLabel(),
                      const SizedBox(height: 10),
                      const _PingLabel(),
                      const _ActiveServerLabel(),
                      const SizedBox(height: 6),
                      const _ExitIpLabel(),
                      const _FenceBadge(),
                      const _WhitelistBanner(),
                      const _HardNetworkCta(),
                      const _UnblockButton(),
                      const _ProxyModeHint(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dismissed-update version for THIS session — re-appears on the next launch so
/// the user always learns about a pending update on entry, but isn't nagged after
/// they've acknowledged it once.
final _updateDismissedProvider = StateProvider<String?>((_) => null);

/// Prominent "a new version is out" banner on Home — so a user learns about an
/// update the moment they open the app, not only if they dig into Settings →
/// About. Opens the SIGNED release page (GitHub) to download; the app never
/// auto-downloads or runs an installer over a possibly-tampered network — that is
/// exactly the supply-chain risk this app exists to avoid.
class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateProvider).value;
    if (update == null) return const SizedBox.shrink();
    if (ref.watch(_updateDismissedProvider) == update.version) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.system_update_rounded,
                size: 20, color: scheme.primary),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.updateAvailable(update.version),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(l.updateBannerHint,
                      style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withValues(alpha: 0.6))),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TgButton(
                label: l.updateNow,
                onPressed: () => NativeAdmin.openUrl(update.url)),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: l.cancel,
              onPressed: () => ref
                  .read(_updateDismissedProvider.notifier)
                  .state = update.version,
            ),
          ],
        ),
      ),
    );
  }
}

/// One-tap "import the server link I spotted on your clipboard" banner — the
/// highest-ROI cold-start helper. Tapping Add routes through the SAME untrusted
/// import preview-gate as a dropped file / deeplink, so a hostile link can never
/// silently apply. Dismiss (or Add) won't re-offer the same link.
class _ClipboardImportBanner extends ConsumerWidget {
  const _ClipboardImportBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payload = ref.watch(clipboardImportProvider);
    if (payload == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Icon(Icons.content_paste_go_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(l.clipboardOfferText,
                  style: const TextStyle(fontSize: 12.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            TextButton(
              onPressed: () async {
                final p = importablePayload(payload);
                // Hide the banner now but DON'T latch yet — the preview-gate may be
                // cancelled, and latching here would permanently suppress a link the
                // user wanted to retry.
                clearClipboardOffer(ref, latch: false);
                if (p == null) return;
                final before = ref.read(profilesProvider).nodes.length;
                // Untrusted source (clipboard) → the import preview-gate decides.
                // Clipboard text is always CONTENT, never a file path — and an
                // unwrapped payload may legitimately lack '://' (hiddify://import/
                // unwraps to a bare base64 subscription), which importFromFile
                // would misread as a path and fail with a load error.
                await importDroppedContent(context, ref, utf8.encode(p),
                    trusted: false);
                // Only suppress re-offers once the import actually added node(s); a
                // cancelled preview leaves the count unchanged → stays re-offerable.
                if (ref.read(profilesProvider).nodes.length != before) {
                  markClipboardImported(payload);
                }
              },
              child: Text(l.importAction),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              tooltip: l.cancel,
              onPressed: () => clearClipboardOffer(ref),
            ),
          ],
        ),
      ),
    );
  }
}

/// The live exit server actually carrying traffic — answers "which server am I
/// on?" on the main screen after an auto-hop or a Policies switch, instead of
/// only the static profile name in the bar. Resolves the selector chain to the
/// leaf node (activeOutboundProvider).
class _ActiveServerLabel extends ConsumerWidget {
  const _ActiveServerLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(coreControllerProvider.select((s) => s.isOn));
    final server = ref.watch(activeOutboundProvider).value;
    if (!connected || server == null || server.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_rounded,
              size: 13, color: scheme.primary.withValues(alpha: 0.8)),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(server,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface.withValues(alpha: 0.78))),
          ),
        ],
      ),
    );
  }
}

/// Visible state of the WFP TUN kill-switch — green when the fence is actually
/// up, AMBER when it was requested (TUN + setting) but could NOT install, so the
/// user is never silently left unprotected while believing they're fenced (H4).
class _FenceBadge extends ConsumerWidget {
  const _FenceBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOn = ref.watch(coreControllerProvider.select((s) => s.isOn));
    if (!isOn) return const SizedBox.shrink();
    final fenceActive =
        ref.watch(coreControllerProvider.select((s) => s.fenceActive));
    if (fenceActive) {
      return const _FenceChip(
        color: Color(0xFF4ADE80),
        icon: Icons.shield_rounded,
        labelKey: _FenceLabel.active,
      );
    }
    // The kill-switch was asked for in TUN mode but the fence isn't up — warn
    // LOUDLY instead of leaving a fail-open the user can't see.
    final wantFence = ref.watch(settingsProvider
        .select((s) => s.killSwitchTun && s.vpnMode == VpnMode.tun));
    if (wantFence) {
      return const _FenceChip(
        color: Color(0xFFE0A53D),
        icon: Icons.gpp_bad_rounded,
        labelKey: _FenceLabel.unprotected,
      );
    }
    return const SizedBox.shrink();
  }
}

/// ①-watchdog: the mobile network collapsed to the state IP/SNI allowlist
/// ("белый список") — RU sites answer but no foreign exit is reachable, so the
/// tunnel is dark by physics, not by a fixable block. The watchdog stops burning
/// transport/fp variants and shows this instead of a misleading "blocked" error;
/// the honest guidance is Wi-Fi or a domestic relay. Amber, prominent (not a
/// muted hint) because it explains why nothing connects right now.
class _WhitelistBanner extends ConsumerWidget {
  const _WhitelistBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(coreControllerProvider
        .select((s) => s.isOn && s.whitelistMode));
    if (!show) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    const amber = Color(0xFFE0A53D);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: amber.withValues(alpha: 0.45)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.public_off_rounded, size: 15, color: amber),
                const SizedBox(width: 6),
                Text(l.whitelistModeTitle,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: amber)),
              ],
            ),
            const SizedBox(height: 4),
            Text(l.whitelistModeBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.35,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7))),
          ],
        ),
      ),
    );
  }
}

/// "Works on Wi-Fi, not on mobile" — when the tunnel goes dark on a NON-whitelist
/// network (selective operator blocking), offer ONE tap that turns on the full
/// hard-network escalation (force TLS fragmentation + survivor-preferring cascade
/// + auto-adapt) atomically, instead of making the user dig through Advanced.
/// Hidden once that's already on (it can't help twice) and on a pure whitelist
/// collapse (where _WhitelistBanner explains the physics limit instead).
class _HardNetworkCta extends ConsumerWidget {
  const _HardNetworkCta();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = ref.watch(coreControllerProvider
        .select((s) => s.isOn && s.tunnelDark && !s.whitelistMode));
    final canEscalate =
        !ref.watch(settingsProvider.select((s) => s.maxResistance));
    if (!dark || !canEscalate) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    const amber = Color(0xFFE0A53D);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: amber.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: amber.withValues(alpha: 0.4)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.hardNetworkCtaText,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.75))),
            const SizedBox(height: 8),
            GlassButton(
              onPressed: () async {
                final changed =
                    ref.read(settingsProvider.notifier).enableHardNetwork();
                if (!changed) return;
                // On a default install antiDpi+autoAdapt are already on, so flipping
                // maxResistance leaves the generated config byte-identical → the
                // settings-watcher schedules NO restart and the escalation would
                // silently do nothing while the toast claims "reconnecting". Force a
                // genuine reconnect so the tunnel actually re-dials (fresh cascade +
                // fp cycle under maxResistance) — the CTA exists precisely for the
                // dark state, where re-attempting the connection is the whole point.
                if (ref.read(coreControllerProvider).isOn) {
                  await ref
                      .read(coreControllerProvider.notifier)
                      .restart(reason: 'hard network escalation');
                }
                if (context.mounted) {
                  AppToast.of(context).message(l.hardNetworkCtaDone);
                }
              },
              child: Text(l.hardNetworkCtaAction),
            ),
          ],
        ),
      ),
    );
  }
}

/// Subtle, non-alarming reminder (H3): in the DEFAULT system-proxy mode, apps
/// that ignore the system proxy (and their DNS) go direct — it is NOT leak-proof.
/// For the at-risk audience this must be visible while connected, not buried in
/// settings. Shown only in proxy mode while up; muted so it doesn't cry wolf.
class _ProxyModeHint extends ConsumerWidget {
  const _ProxyModeHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(coreControllerProvider.select((s) => s.isOn)) &&
        ref.watch(
            settingsProvider.select((s) => s.vpnMode == VpnMode.systemProxy));
    if (!show) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 12, color: scheme.onSurface.withValues(alpha: 0.4)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(l.proxyModeLeakHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurface.withValues(alpha: 0.45))),
          ),
        ],
      ),
    );
  }
}

/// M5 — when the tunnel gave up WHILE the kill-switch is engaged, traffic stays
/// fail-CLOSED (fence up, proxy at our dead port). That must never be a silent
/// lockout: this button is the explicit, reachable way OUT — disconnect → the
/// fence drops + the real proxy is restored.
class _UnblockButton extends ConsumerWidget {
  const _UnblockButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(coreControllerProvider
        .select((s) => s.status == CoreStatus.error && s.fenceActive));
    if (!blocked) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.unblockHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurface.withValues(alpha: 0.7))),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => ref.read(coreControllerProvider.notifier).stop(),
            style: FilledButton.styleFrom(backgroundColor: scheme.error),
            icon: const Icon(Icons.lock_open_rounded, size: 18),
            label: Text(l.unblockAction),
          ),
        ],
      ),
    );
  }
}

enum _FenceLabel { active, unprotected }

class _FenceChip extends StatelessWidget {
  const _FenceChip(
      {required this.color, required this.icon, required this.labelKey});

  final Color color;
  final IconData icon;
  final _FenceLabel labelKey;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final label = labelKey == _FenceLabel.active
        ? l.killSwitchActive
        : l.killSwitchUnprotected;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

/// First-run / empty-state onboarding: a cold user with NO servers used to see
/// just the power button + a tiny "tap to add" — closing the "empty screen with
/// no path" gap. Shown only when the profile list is empty; a clear CTA opens the
/// import sheet (QR / link / file).
class _HomeTitle extends StatelessWidget {
  const _HomeTitle();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [scheme.primary, scheme.primary.withValues(alpha: 0.6)],
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.shield_rounded, color: Colors.black, size: 20),
        ),
        const SizedBox(width: 10),
        Text(l.appTitle,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _ProfileBar extends ConsumerWidget {
  const _ProfileBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final profiles = ref.watch(profilesProvider);
    final sel = profiles.selectedNode;
    final empty = sel == null; // no servers yet → the bar IS the onboarding CTA
    final subText = _fmtSub(l, profiles.infoFor(sel));
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      radius: 14,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showProfilesSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(empty ? Icons.add_circle_rounded : Icons.dns_rounded,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sel?.tag ?? l.onboardTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: empty ? scheme.primary : null)),
                      Text(sel != null ? sel.type : l.onboardBody,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurface
                                  .withValues(alpha: empty ? 0.75 : 0.5))),
                      if (subText != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(subText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color:
                                      scheme.primary.withValues(alpha: 0.85))),
                        ),
                    ],
                  ),
                ),
                // View the raw sing-box config right from the active card.
                if (sel != null && sel.isConfig)
                  IconButton(
                    tooltip: l.viewConfig,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.code_rounded,
                        size: 20, color: scheme.primary),
                    onPressed: () => showConfigViewer(context, sel),
                  ),
                Icon(Icons.chevron_right_rounded,
                    color: scheme.onSurface.withValues(alpha: 0.4)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusLabel extends ConsumerWidget {
  const _StatusLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // Watch only the three fields shown — not the whole CoreState — so appended
    // log lines don't rebuild the status label (record select = structural eq).
    final (status, error, detail, dark, swapping) = ref.watch(
        coreControllerProvider.select(
            (s) => (s.status, s.error, s.detail, s.tunnelDark, s.swapping)));
    final (String label, Color color) = switch (status) {
      // Up but carrying no traffic (watchdog dark window) — don't claim a solid
      // "Connected"; show an honest amber "checking" until it recovers or acts.
      CoreStatus.running when dark => (l.statusChecking, const Color(0xFFE0A53D)),
      CoreStatus.running => (l.statusConnected, scheme.primary),
      // A swap (node-switch / network / settings restart) keeps the proxy pinned —
      // show a calm amber "Checking…", not the "Connecting…" of a fresh connect.
      CoreStatus.starting when swapping =>
        (l.statusChecking, const Color(0xFFE0A53D)),
      CoreStatus.starting => (l.statusConnecting, scheme.onSurface),
      CoreStatus.stopping => (l.statusDisconnecting, scheme.onSurface),
      CoreStatus.error => (l.statusError, scheme.error),
      CoreStatus.stopped => (
          l.statusDisconnected,
          scheme.onSurface.withValues(alpha: 0.6)
        ),
    };
    final msg = _message(l, error, detail);
    // Reconnecting is a transient kill-switch state, not a hard failure — show
    // it in a muted tone, real errors in the error colour.
    final msgColor = error == CoreError.reconnecting
        ? scheme.onSurface.withValues(alpha: 0.7)
        : scheme.error.withValues(alpha: 0.9);
    return Column(
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w600, color: color)),
        if (msg != null) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(msg,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: msgColor)),
          ),
        ],
      ],
    );
  }

  // Localize the core's error code (never store a one-language string in state).
  static String? _message(AppLocalizations l, CoreError? error, String? detail) {
    final d = detail ?? '';
    return switch (error) {
      null => null,
      CoreError.coreMissing => l.errCoreMissing,
      CoreError.tunNeedsAdmin => l.errTunNeedsAdmin,
      CoreError.configRejected => l.errConfigRejected(d),
      CoreError.writeFailed => l.errWriteFailed(d),
      CoreError.launchFailed => l.errLaunchFailed(d),
      CoreError.noApi => l.errNoApi,
      CoreError.reconnecting => l.errReconnecting,
      CoreError.gaveUp => l.errGaveUp,
      CoreError.portInUse => l.errPortInUse,
      CoreError.wireguardHandshake => l.errWireguardHandshake,
      CoreError.killSwitchFailed => l.errKillSwitchFailed,
      CoreError.proxyFailed => l.errProxyFailed,
      CoreError.xrayMissing => l.errXrayMissing,
    };
  }
}

class _PingLabel extends ConsumerWidget {
  const _PingLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final st = ref.watch(coreControllerProvider
        .select((s) => (s.status == CoreStatus.running, s.tunnelDark)));
    final on = st.$1;
    final dark = st.$2;
    final ms = ref.watch(latencyProvider).value;
    if (!on) return const SizedBox(height: 22);
    // Connected but the first probe hasn't returned, OR the tunnel is dark right
    // now (watchdog window): show "measuring…" — never a STALE green latency that
    // contradicts the amber "Checking…" headline.
    if (ms == null || dark) {
      return SizedBox(
        height: 22,
        child: Center(
          child: Text(l.measuring,
              style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurface.withValues(alpha: 0.5))),
        ),
      );
    }
    final color = ms < 200
        ? scheme.primary
        : (ms < 500 ? Colors.orange : scheme.error);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.bolt_rounded, size: 18, color: color),
        const SizedBox(width: 5),
        Text('$ms ms',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}

/// The live exit IP, fetched through the tunnel — visible proof it works.
class _ExitIpLabel extends ConsumerWidget {
  const _ExitIpLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dark = ref.watch(coreControllerProvider.select((s) => s.tunnelDark));
    final ip = ref.watch(exitIpProvider).value;
    // Hide a STALE exit IP during the dark window — it would falsely reassure.
    if (ip == null || dark) return const SizedBox(height: 16);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.public_rounded,
            size: 14, color: scheme.onSurface.withValues(alpha: 0.5)),
        const SizedBox(width: 5),
        Text('IP $ip',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface.withValues(alpha: 0.65))),
      ],
    );
  }
}
