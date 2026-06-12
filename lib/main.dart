import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme.dart';
import 'core/app_settings.dart';
import 'core/core_paths.dart';
import 'core/deeplink.dart';
import 'features/root/root_scaffold.dart';
import 'l10n/app_localizations.dart';

void main(List<String> args) {
  // A debug build runs as an isolated dev instance (own store dir + native
  // mutex/title) so it can coexist with an installed release client — seed its
  // store from the release one once so it has the user's servers. No-op in
  // release/tests.
  CorePaths.seedDevInstanceFromRelease();
  // Cold-launch deeplink / "Open with": the runner forwards argv to this
  // entrypoint, so a clicked vpn://… link or a config file becomes a pending
  // import that RootScaffold applies on the first frame.
  pendingLaunchImport = launchImportFromArgs(args);
  runApp(const ProviderScope(child: VpnApp()));
}

class VpnApp extends ConsumerWidget {
  const VpnApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(settingsProvider.select((s) => s.locale));
    return MaterialApp(
      // A debug build appends "· dev" so the isolated dev-instance window is
      // visibly distinct from a running release client in the taskbar.
      onGenerateTitle: (context) {
        final t = AppLocalizations.of(context).appTitle;
        return kDebugMode ? '$t · dev' : t;
      },
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      scrollBehavior: const _AppScrollBehavior(),
      locale: locale, // null = follow system locale (auto-detect)
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const RootScaffold(),
    );
  }
}

/// Hide scrollbars app-wide for a clean look (wheel/trackpad scrolling stays).
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}
