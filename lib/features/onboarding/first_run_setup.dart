import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../app/theme.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/glass.dart';

/// First-run, one-time protection-mode chooser. Closes audit #4 (H3): instead of
/// silently landing on the leak-prone system-proxy default, the user makes an
/// INFORMED choice between full-device TUN (captures all traffic — no DNS/IPv6
/// leak) and the simpler app proxy. Deliberately does NOT enable the experimental
/// WFP kill-switch — that stays a conscious opt-in until it's leak-tested.
Future<void> showFirstRunSetup(BuildContext context, WidgetRef ref) async {
  // Non-dismissable: a stray tap on the barrier must NOT strand the user on the
  // leak-prone systemProxy default this very gate exists to prevent.
  final mode = await showGlassDialog<VpnMode>(
    context,
    barrierDismissible: false,
    child: const _FirstRunSetup(),
  );
  // Only record a DELIBERATE choice. If somehow dismissed (mode == null), leave
  // seenSetup false so the chooser re-fires next launch rather than silently
  // committing the leak-prone default.
  if (mode != null) {
    ref.read(settingsProvider.notifier).completeSetup(mode);
  }
}

class _FirstRunSetup extends StatelessWidget {
  const _FirstRunSetup();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      // Block Esc / system-back too — the choice is mandatory, no leak-prone
      // default escape hatch.
      canPop: false,
      child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(icon: Icons.shield_rounded, title: l.setupTitle),
          const SizedBox(height: 8),
          Text(l.setupBody,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: scheme.onSurface.withValues(alpha: 0.7))),
          const SizedBox(height: 18),
          _Choice(
            icon: Icons.verified_user_rounded,
            title: l.setupTunTitle,
            body: l.setupTunBody,
            badge: l.setupTunBadge,
            highlight: true,
            onTap: () => Navigator.pop(context, VpnMode.tun),
          ),
          const SizedBox(height: 10),
          _Choice(
            icon: Icons.apps_rounded,
            title: l.setupProxyTitle,
            body: l.setupProxyBody,
            badge: l.setupProxyBadge,
            highlight: false,
            onTap: () => Navigator.pop(context, VpnMode.systemProxy),
          ),
        ],
      ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.body,
    required this.badge,
    required this.highlight,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final String badge;
  final bool highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = highlight ? scheme.primary : scheme.onSurface;
    return GlassCard(
      radius: AppTheme.rPanel,
      padding: EdgeInsets.zero,
      child: Material(
        color: highlight
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rPanel),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rPanel),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: AppTheme.tsBody,
                                  fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.16),
                            borderRadius:
                                BorderRadius.circular(AppTheme.rChip),
                          ),
                          child: Text(badge,
                              style: TextStyle(
                                  fontSize: AppTheme.tsMicro,
                                  fontWeight: FontWeight.w700,
                                  color: accent)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(body,
                        style: TextStyle(
                            fontSize: AppTheme.tsLabel,
                            height: 1.35,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.72))),
                  ],
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
