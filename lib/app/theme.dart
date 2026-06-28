import 'package:flutter/material.dart';

/// Dark-first theme in the spirit of Happ/Hiddify: deep near-black surfaces,
/// a single vivid accent, generous rounding.
class AppTheme {
  static const Color _seed = Color(0xFF3DDC97); // emerald accent
  static const Color _bg = Color(0xFF0E1116);
  static const Color _surface = Color(0xFF161B22);
  static const Color _surfaceHigh = Color(0xFF1C232D);

  // ── Semantic colour tokens (dark-only theme). Use THESE instead of ad-hoc
  // hex so success/warning/danger mean ONE colour app-wide — replacing the
  // duplicated amber 0xFFE0A53D, the stray Tailwind green 0xFF4ADE80, and loose
  // Colors.orange/Colors.red usages the audit found scattered across screens.
  static const Color success = _seed; // the ONE success green (== primary)
  static const Color warning = Color(0xFFE0A53D); // the ONE warning amber
  static const Color danger = Color(0xFFE5544B); // destructive / error red
  static const Color info = Color(0xFF3B82F6); // informational blue (matches backdrop)

  // ── Named type scale (px). The audit found ad-hoc 22/17/16/14.5/12.5/10.5/9.5
  // for the SAME roles; snap to these so titles/body/captions are consistent.
  static const double tsTitle = 20; // screen header (w700) — PageHeader
  static const double tsHeading = 16; // dialog / section title (w700)
  static const double tsBody = 13; // primary body / list / button text
  static const double tsLabel = 12; // secondary labels, chips
  static const double tsCaption = 11; // hints/captions — the readable FLOOR
  static const double tsMicro = 10; // badges ONLY (always near-full alpha)
  // Secondary-text opacity floor: text this faint must be >= tsCaption in size.
  static const double alphaSecondary = 0.66;

  // ── Named radius scale. Audit: r6/r8/r10/r12/r14/r18/r22 for the same roles.
  static const double rChip = 8; // small chips / badges
  static const double rButton = 12; // buttons / inputs / inner panels
  static const double rPanel = 14; // inset panels (code box, menus)
  static const double rCard = 18; // cards / banners
  static const double rDialog = 24; // centered dialogs
  static const double rSheet = 28; // bottom sheets

  // ── Shared layout constants (were duplicated magic numbers across files).
  static const double kNavReserve = 96; // clearance under the floating bottom nav

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    ).copyWith(
      surface: _surface,
      surfaceContainerHighest: _surfaceHigh,
      primary: _seed,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: _bg,
      fontFamily: 'Inter',
    );

    return base.copyWith(
      // Kill ALL the stock Material hover/ripple "saws" — on a rounded glass UI
      // the rectangular hover highlight + ink splash look jagged and wrong.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      cardTheme: CardThemeData(
        color: _surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: _surface,
        contentTextStyle: const TextStyle(color: Colors.white),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
        // The nav is an in-body floating bar, so lift snackbars clear of it.
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 104),
      ),
      // One coherent control language so no screen falls back to stock Material.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? _seed : const Color(0xFFC9D1D9)),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? _seed.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.10)),
        trackOutlineColor:
            WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.14)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected)
                  ? scheme.primary.withValues(alpha: 0.24)
                  : Colors.white.withValues(alpha: 0.04)),
          foregroundColor: WidgetStateProperty.resolveWith((s) =>
              s.contains(WidgetState.selected)
                  ? scheme.primary
                  : scheme.onSurface),
          side: WidgetStatePropertyAll(
              BorderSide(color: Colors.white.withValues(alpha: 0.12))),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10))),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          visualDensity: VisualDensity.compact,
          textStyle: const WidgetStatePropertyAll(
              TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurface.withValues(alpha: 0.7),
        textColor: scheme.onSurface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
