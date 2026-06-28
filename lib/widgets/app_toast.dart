import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vpn_app/app/theme.dart';
import 'package:vpn_app/l10n/app_localizations.dart';
import 'package:vpn_app/widgets/glass.dart';

/// Severity of a toast — drives its icon/colour and how long it stays. Errors
/// must read as errors (not the same neutral chip as a success) and linger long
/// enough to read + tap-to-copy, instead of vanishing in ~3 s.
enum ToastKind { info, success, error }

/// Liquid-glass notification. Unlike a SnackBar it:
///  - drops from the TOP,
///  - mounts in the ROOT overlay, so it floats OVER open dialogs/popups,
///  - dismisses with a slide-up fade,
///  - matches the app's frosted-glass look.
///
/// Two entry points: [show] for a sync context, or capture [of] BEFORE an
/// `await` and call [message] after (so we never touch a stale BuildContext).
class AppToast {
  AppToast._(this._overlay, this._scheme, this._topPad);

  final OverlayState _overlay;
  final ColorScheme _scheme;
  final double _topPad;

  // Active toasts, so a second one stacks below the first instead of overlapping.
  static final List<_ToastHandle> _active = [];

  static AppToast of(BuildContext context) => AppToast._(
        Overlay.of(context, rootOverlay: true),
        Theme.of(context).colorScheme,
        MediaQuery.of(context).padding.top,
      );

  static void show(BuildContext context, String message,
          {ToastKind kind = ToastKind.info}) =>
      of(context).message(message, kind: kind);

  /// Convenience for the common error path.
  void error(String text) => message(text, kind: ToastKind.error);

  void message(String text, {ToastKind kind = ToastKind.info}) {
    final handle = _ToastHandle();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastWidget(
        text: text,
        kind: kind,
        scheme: _scheme,
        topPad: _topPad,
        slot: () => _active.indexOf(handle),
        onDone: () {
          handle.entry?.remove();
          _active.remove(handle);
        },
      ),
    );
    handle.entry = entry;
    _active.add(handle);
    _overlay.insert(entry);
  }
}

class _ToastHandle {
  OverlayEntry? entry;
}

class _ToastWidget extends StatefulWidget {
  const _ToastWidget({
    required this.text,
    required this.kind,
    required this.scheme,
    required this.topPad,
    required this.slot,
    required this.onDone,
  });

  final String text;
  final ToastKind kind;
  final ColorScheme scheme;
  final double topPad;
  final int Function() slot;
  final VoidCallback onDone;

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  // Errors linger (~6.5 s) so they're readable + tappable; info/success ~3.4 s.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(
        milliseconds: widget.kind == ToastKind.error ? 6500 : 3400),
  )
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    })
    ..forward();

  static const _enterEnd = 0.106; // ~360ms in

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Exit start scales with total duration so the enter/hold/exit shape holds.
    final exitStart = widget.kind == ToastKind.error ? 0.9 : 0.823;
    // Recompute slot/top INSIDE the per-frame builder so survivors pack upward
    // when an earlier toast dismisses (the live index shrinks every frame),
    // instead of holding a stale top and leaving a gap.
    return Positioned(
      top: 0,
      left: 16,
      right: 16,
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) {
            final t = _c.value;
            final slot = widget.slot().clamp(0, 4);
            final top = widget.topPad + 14 + slot * 62.0;
            final enter = (t / _enterEnd).clamp(0.0, 1.0);
            final exit = ((t - exitStart) / (1 - exitStart)).clamp(0.0, 1.0);
            final dy = (1 - Curves.easeOutBack.transform(enter)) * -36 -
                Curves.easeInCubic.transform(exit) * 70;
            final opacity = enter * (1 - exit);
            return Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, top + dy),
                child: child,
              ),
            );
          },
          child: _ToastCard(
              text: widget.text, kind: widget.kind, scheme: widget.scheme),
        ),
      ),
    );
  }
}

class _ToastCard extends StatelessWidget {
  const _ToastCard(
      {required this.text, required this.kind, required this.scheme});

  final String text;
  final ToastKind kind;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color accent) = switch (kind) {
      ToastKind.error => (Icons.error_outline_rounded, scheme.error),
      ToastKind.success => (Icons.check_circle_outline_rounded, AppTheme.success),
      ToastKind.info => (Icons.info_outline_rounded, scheme.primary),
    };
    // Severity reads at a glance via a tinted border; info keeps the neutral
    // white@0.16 glass rim. The body is the shared liquid-glass material.
    // GlassCard already paints its own white rim + drop shadow; the old outer
    // shadow + white border DOUBLED both. Drop the shadow, and give info a
    // transparent rim (the glass rim suffices) — only warning/error keep a thin
    // severity-coloured rim on top.
    final border = kind == ToastKind.info
        ? Colors.transparent
        : accent.withValues(alpha: 0.55);
    final card = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.rCard),
        border: Border.all(color: border),
      ),
      child: GlassCard(
        radius: AppTheme.rCard,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: 10),
            Flexible(
              // Announce a freshly-mounted toast to screen readers (it floats in
              // an overlay with no focus change, so without a live region it goes
              // unread). `container` gives it its own a11y node.
              child: Semantics(
                liveRegion: true,
                container: true,
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.tsBody,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                    color: scheme.onSurface,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
            if (kind == ToastKind.error) ...[
              const SizedBox(width: 8),
              Icon(Icons.copy_rounded,
                  size: 14, color: scheme.onSurface.withValues(alpha: 0.5)),
            ],
          ],
        ),
      ),
    );
    // An error is the one a user wants to keep/report — tap to copy its text.
    if (kind != ToastKind.error) return card;
    // The tap-to-copy affordance is otherwise invisible to a screen reader (a
    // bare GestureDetector has no role/label); expose it as a labelled button.
    return Semantics(
      button: true,
      label: AppLocalizations.of(context).copy,
      child: GestureDetector(
        onTap: () => Clipboard.setData(ClipboardData(text: text)),
        child: card,
      ),
    );
  }
}
