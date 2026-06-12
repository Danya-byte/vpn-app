import 'dart:ui';

import 'package:flutter/material.dart';

/// Frosted "liquid glass" panel: blurred translucent surface + hairline border.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = 18,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return _GlassMaterial(
      radius: radius,
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
  }
}

/// The shared "liquid glass" material. What makes it read as *liquid* glass
/// rather than flat frost: (1) a top-down gradient so the surface looks lit from
/// above, and (2) a bright **specular crescent** hugging the top rim — the
/// single biggest tell of refractive glass. Plus a hairline rim border.
class _GlassMaterial extends StatelessWidget {
  const _GlassMaterial({
    required this.child,
    required this.radius,
    this.sigma = 22,
  });

  final Widget child;
  final double radius;
  final double sigma;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // Lit from above: brighter top edge falling off downward. A touch more
            // contrast top-to-bottom reads as real thickness/refraction.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.13),
                Colors.white.withValues(alpha: 0.06),
                Colors.white.withValues(alpha: 0.025),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Stack(
            children: [
              // Specular crescent along the top edge (light off the glass rim).
              // Sits BEHIND the content so it never washes out text/icons.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: radius * 2.6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(radius),
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.18),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // A crisp rim-light hairline hugging the very top edge — the single
              // strongest "this is glass" tell (a bright refracted highlight on the
              // top bevel). 1.5px, fades in from the corners.
              Positioned(
                top: 0,
                left: radius * 0.5,
                right: radius * 0.5,
                child: IgnorePointer(
                  child: Container(
                    height: 1.5,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.0),
                          Colors.white.withValues(alpha: 0.45),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              // Soft inner shadow on the BOTTOM edge → the panel reads as having
              // depth/thickness rather than a flat frosted rectangle.
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    height: radius * 1.4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(radius),
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.10),
                          Colors.black.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// One consistent screen header: a rounded accent chip + title, so every tab
/// reads as the same designed system (not just Home).
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.primary.withValues(alpha: 0.30)),
          ),
          child: Icon(icon, size: 18, color: scheme.primary),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

/// Aurora-like gradient backdrop the glass panels sit on.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B1220), Color(0xFF0E1116), Color(0xFF0A1410)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -90,
            left: -70,
            child: _blob(primary.withValues(alpha: 0.28), 320),
          ),
          Positioned(
            bottom: -120,
            right: -90,
            child: _blob(const Color(0xFF3B82F6).withValues(alpha: 0.20), 360),
          ),
          // A soft mid glow so glass panels in the middle of a page still have
          // colour to frost (otherwise they read flat over the dark centre).
          Positioned(
            top: 240,
            left: -100,
            child: _blob(primary.withValues(alpha: 0.10), 300),
          ),
          // Glow behind the floating nav so its BackdropFilter frosts real
          // colour instead of flat black.
          Positioned(
            bottom: -90,
            left: 20,
            child: _blob(primary.withValues(alpha: 0.16), 380),
          ),
        ],
      ),
    );
  }

  Widget _blob(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );
}

/// Frosted, rounded, tappable glass button.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.padding,
    this.radius = 12,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: Colors.white.withValues(alpha: 0.045),
          child: InkWell(
            onTap: onPressed,
            child: Container(
              padding:
                  padding ??
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: scheme.onSurface, size: 18),
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating frosted bottom sheet (iOS-style: side + bottom insets, rounded).
Future<T?> showGlassSheet<T>(BuildContext context, {required Widget child}) {
  final media = MediaQuery.of(context);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Cap height so a tall sheet keeps a symmetric gap top and bottom.
    constraints: BoxConstraints(
      maxHeight: media.size.height - media.padding.top - 32,
    ),
    builder: (_) => Padding(
      padding: const EdgeInsets.only(left: 10, right: 10, bottom: 16),
      child: GlassSurface(radius: 28, child: child),
    ),
  );
}

/// Centered frosted dialog.
Future<T?> showGlassDialog<T>(BuildContext context, {required Widget child}) {
  return showDialog<T>(
    context: context,
    builder: (_) => Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: GlassSurface(
            radius: 24,
            child: Material(color: Colors.transparent, child: child),
          ),
        ),
      ),
    ),
  );
}

/// Glassy rounded text-field decoration.
InputDecoration glassInputDecoration(BuildContext context, String hint) {
  final scheme = Theme.of(context).colorScheme;
  OutlineInputBorder mk(Color c) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: BorderSide(color: c),
  );
  return InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.06),
    border: mk(Colors.white.withValues(alpha: 0.14)),
    enabledBorder: mk(Colors.white.withValues(alpha: 0.14)),
    focusedBorder: mk(scheme.primary.withValues(alpha: 0.6)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  );
}

/// Liquid-glass dropdown: a frosted field that opens a frosted, anchored menu
/// (NOT the flat stock Material dropdown). One reusable component for every
/// picker in the app. [labelOf] maps a value to its display text.
class GlassDropdown<T> extends StatefulWidget {
  const GlassDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.labelOf,
    this.radius = 12,
  });

  final T value;
  final List<T> items;
  final ValueChanged<T> onChanged;
  final String Function(T)? labelOf;
  final double radius;

  @override
  State<GlassDropdown<T>> createState() => _GlassDropdownState<T>();
}

class _GlassDropdownState<T> extends State<GlassDropdown<T>> {
  final LayerLink _link = LayerLink();
  final GlobalKey _fieldKey = GlobalKey();
  OverlayEntry? _entry;

  String _label(T v) => widget.labelOf?.call(v) ?? '$v';
  bool get _open => _entry != null;

  void _toggle() => _open ? _close() : _openMenu();

  void _openMenu() {
    final box = _fieldKey.currentContext!.findRenderObject() as RenderBox;
    final width = box.size.width;
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);

    // Decide direction + height from the field's on-screen position so the menu
    // NEVER runs off-window (under the floating nav). Not enough room below ->
    // flip ABOVE the field; cap height to the free space and scroll within it.
    final fieldTop = box.localToGlobal(Offset.zero).dy;
    final fieldBottom = fieldTop + box.size.height;
    const gap = 6.0;
    const navReserve = 96.0; // clear the floating bottom nav
    final topReserve = media.padding.top + 8;
    final spaceBelow = media.size.height - fieldBottom - gap - navReserve;
    final spaceAbove = fieldTop - gap - topReserve;
    final openUp = spaceBelow < 180 && spaceAbove > spaceBelow;
    final maxH = (openUp ? spaceAbove : spaceBelow).clamp(120.0, 320.0);

    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Full-screen catcher: a tap anywhere outside closes the menu.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: openUp ? Alignment.topLeft : Alignment.bottomLeft,
            followerAnchor: openUp ? Alignment.bottomLeft : Alignment.topLeft,
            offset: Offset(0, openUp ? -gap : gap),
            child: SizedBox(
              width: width,
              child: GlassSurface(
                radius: 14,
                child: Material(
                  color: Colors.transparent,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxH),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final item in widget.items) _row(item, scheme),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
    setState(() {});
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    if (mounted) setState(() {});
  }

  Widget _row(T item, ColorScheme scheme) {
    final selected = item == widget.value;
    // A rounded "pill" highlight (with margin) so the selected row reads as
    // part of the glass — never a hard square edge.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () {
            _close();
            if (item != widget.value) widget.onChanged(item);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: selected
                  ? Border.all(color: scheme.primary.withValues(alpha: 0.4))
                  : null,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _label(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? scheme.primary : scheme.onSurface,
                    ),
                  ),
                ),
                if (selected)
                  Icon(Icons.check_rounded, size: 17, color: scheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CompositedTransformTarget(
      link: _link,
      child: GlassButton(
        key: _fieldKey,
        radius: widget.radius,
        onPressed: _toggle,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _label(widget.value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ),
            AnimatedRotation(
              turns: _open ? 0.5 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Liquid-glass toggle with a springy thumb slide — the same `easeOutBack` feel
/// as the floating nav bar (Material's stock Switch animates flat and short by
/// comparison). Drop-in for [Switch]: takes [value] + [onChanged].
class GlassSwitch extends StatelessWidget {
  const GlassSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const w = 48.0, h = 28.0, pad = 3.0;
    const thumb = h - pad * 2;
    final on = value;
    final enabled = onChanged != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          width: w,
          height: h,
          padding: const EdgeInsets.all(pad),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(h),
            color: on
                ? scheme.primary.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.10),
            border: Border.all(
              color: on
                  ? scheme.primary.withValues(alpha: 0.55)
                  : Colors.white.withValues(alpha: 0.16),
            ),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 330),
            curve: Curves.easeOutBack,
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: thumb,
              height: thumb,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? scheme.primary : const Color(0xFFC9D1D9),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The prominent primary-action CTA for the ONE main action on a card (vs the
/// muted [GlassButton]). Uses the app's brand colour (emerald) in a SOFT
/// tinted-glass fill — clearly "ours", on-brand with the glass aesthetic, gentler
/// than a hard saturated solid. Colour comes from the theme, so it auto-matches.
class TgButton extends StatelessWidget {
  const TgButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final enabled = onPressed != null;
    final a = enabled ? 1.0 : 0.45;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: primary.withValues(alpha: 0.20 * a),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: primary.withValues(alpha: 0.55 * a)),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: primary.withValues(alpha: a),
            ),
            child: icon == null
                ? Text(label)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 17, color: primary.withValues(alpha: a)),
                      const SizedBox(width: 7),
                      Text(label),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A segmented switch with the SAME sliding-glass-pill spring as the floating nav
/// bar (easeOutBack) — the in-app twin of the bottom navigation. Stock Material
/// [SegmentedButton] snaps flat and opaque; this glides in liquid glass. Drop-in
/// for any 2–N mutually-exclusive choice (VpnMode, RouteMode, …).
class GlassSegmented<T> extends StatelessWidget {
  const GlassSegmented({
    super.key,
    required this.value,
    required this.segments,
    required this.labelOf,
    required this.onChanged,
    this.height = 44,
  });

  final T value;
  final List<T> segments;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = segments.length;
    final idx = segments.indexOf(value).clamp(0, n - 1);
    // Pill alignment along [-1, 1], matching _GlassNav's mapping.
    final alignX = n == 1 ? 0.0 : (idx / (n - 1)) * 2 - 1;
    final r = height / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(r),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withValues(alpha: 0.06),
                Colors.white.withValues(alpha: 0.015),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Stack(
            children: [
              // The sliding glass pill behind the active segment — springs on tap
              // with the same easeOutBack feel as the nav.
              AnimatedAlign(
                duration: const Duration(milliseconds: 360),
                curve: Curves.easeOutBack,
                alignment: Alignment(alignX, 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / n,
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(r - 3),
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < n; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (segments[i] != value) onChanged(segments[i]);
                        },
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: i == idx
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: i == idx
                                  ? scheme.primary
                                  : scheme.onSurface.withValues(alpha: 0.7),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Text(
                                labelOf(segments[i]),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Frosted translucent surface — the base for cards, sheets and dialogs.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child, this.radius = 24});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    // Same liquid-glass material as GlassCard so every surface reads as one.
    return _GlassMaterial(radius: radius, sigma: 20, child: child);
  }
}
