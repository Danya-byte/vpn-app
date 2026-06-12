import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_settings.dart';
import '../../../core/core_controller.dart';
import '../../../core/profiles_controller.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/glass.dart';

/// Big frosted-glass power button. Ring colour + glow reflect the core state;
/// it dips on press for tactile feedback.
class ConnectButton extends ConsumerStatefulWidget {
  const ConnectButton({super.key});

  @override
  ConsumerState<ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends ConsumerState<ConnectButton> {
  bool _pressed = false;

  // Toggle the tunnel — but if we're about to CONNECT to a node that disables
  // TLS cert validation (MITM-able), require an explicit consent first (H5): the
  // amber badge alone is passive, and a silent connect to an insecure node is a
  // real interception risk for the at-risk audience. Disconnect is never gated.
  Future<void> _onTap() async {
    final notifier = ref.read(coreControllerProvider.notifier);
    final status = ref.read(coreControllerProvider).status;
    final connecting =
        status == CoreStatus.stopped || status == CoreStatus.error;
    if (connecting) {
      final node = ref.read(profilesProvider).selectedNode;
      // Ask the MITM consent ONCE per insecure node, then remember it — the
      // user's #4 complaint was being re-prompted on every single connect.
      if (node != null &&
          node.insecure &&
          !ref
              .read(settingsProvider)
              .insecureAccepted
              .contains(node.insecureKey)) {
        final go = await showGlassDialog<bool>(context,
            child: const _InsecureConnectConsent());
        if (go != true || !mounted) return;
        ref.read(settingsProvider.notifier).acceptInsecure(node.insecureKey);
      }
    }
    notifier.toggle();
  }

  @override
  Widget build(BuildContext context) {
    // Watch ONLY the status — not the whole CoreState — so this big button (with
    // a BackdropFilter) doesn't rebuild on every appended log line / detail change.
    final status = ref.watch(coreControllerProvider.select((s) => s.status));
    final swapping = ref.watch(coreControllerProvider.select((s) => s.swapping));
    // A seamless swap (node-switch / network / settings restart): the proxy stays
    // pinned, so keep the calm look (no red spinner) + an amber "Checking…".
    final swap = status == CoreStatus.starting && swapping;
    final isOn = status == CoreStatus.running;
    // A swap shows a spinner too (so the button never looks idle mid-swap), but in
    // amber + with the "Checking…" ring/label so it reads as a calm re-check, not a
    // fresh red "Connecting…".
    final isBusy =
        status == CoreStatus.starting || status == CoreStatus.stopping;
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    // Tappable except mid-teardown: while "Connecting…" a tap CANCELS, and in the
    // error state a tap RETRIES (toggle() routes both) — so the user is never
    // stuck on a hung connect or a port-busy error with no way out.
    // BUT disabled when stopped with an EMPTY store: connecting with no server
    // brings up a do-nothing local config that shows a misleading green
    // "Connected" while protecting nothing — the empty-state CTA guides import.
    final hasTarget =
        ref.watch(profilesProvider.select((s) => s.nodes.isNotEmpty));
    final enabled = status != CoreStatus.stopping &&
        (status != CoreStatus.stopped || hasTarget);

    // Distinct ring per state so "Connecting" / "Disconnecting" don't read as
    // idle (they previously fell through to the default white branch).
    final Color ring = swap
        ? const Color(0xFFE0A53D)
        : switch (status) {
            CoreStatus.running => scheme.primary,
            CoreStatus.error => scheme.error,
            CoreStatus.starting => scheme.primary.withValues(alpha: 0.6),
            CoreStatus.stopping => Colors.white.withValues(alpha: 0.5),
            CoreStatus.stopped => Colors.white.withValues(alpha: 0.28),
          };

    final String label = swap
        ? l.statusChecking
        : switch (status) {
            CoreStatus.running => l.statusConnected,
            CoreStatus.starting => l.statusConnecting,
            CoreStatus.stopping => l.statusDisconnecting,
            CoreStatus.error => l.statusError,
            CoreStatus.stopped => l.statusDisconnected,
          };

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        onTap: enabled ? _onTap : null,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          width: 196,
          height: 196,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: isOn
                ? [
                    BoxShadow(
                      color: ring.withValues(alpha: 0.45),
                      blurRadius: 48,
                      spreadRadius: 4,
                    ),
                  ]
                : const [],
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // Lit from above so the disc reads as a glass dome, not a flat
                  // ring — brighter at the crown, falling off to the base.
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.16),
                      Colors.white.withValues(alpha: 0.04),
                    ],
                  ),
                  border: Border.all(color: ring, width: 5),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    isBusy
                        ? SizedBox(
                            width: 44,
                            height: 44,
                            child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: swap
                                    ? const Color(0xFFE0A53D)
                                    : scheme.primary),
                          )
                        : Icon(Icons.power_settings_new_rounded,
                            size: 72, color: ring),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Consent before connecting to a node that turns off TLS cert validation (H5).
class _InsecureConnectConsent extends StatelessWidget {
  const _InsecureConnectConsent();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    const amber = Color(0xFFE0A53D);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.gpp_maybe_rounded, size: 20, color: amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(l.insecureConnectTitle,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(l.insecureConnectBody,
              style: const TextStyle(fontSize: 13.5, height: 1.35)),
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
                  style: FilledButton.styleFrom(backgroundColor: scheme.error),
                  child: Text(l.insecureConnectAction)),
            ],
          ),
        ],
      ),
    );
  }
}
