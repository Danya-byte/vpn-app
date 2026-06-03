import 'package:flutter/material.dart';

/// Dark-first theme in the spirit of Happ/Hiddify: deep near-black surfaces,
/// a single vivid accent, generous rounding.
class AppTheme {
  static const Color _seed = Color(0xFF3DDC97); // emerald accent
  static const Color _bg = Color(0xFF0E1116);
  static const Color _surface = Color(0xFF161B22);
  static const Color _surfaceHigh = Color(0xFF1C232D);

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
