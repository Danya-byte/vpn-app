import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme.dart';
import 'core/app_settings.dart';
import 'core/deeplink.dart';
import 'features/root/root_scaffold.dart';
import 'l10n/app_localizations.dart';

void main(List<String> args) {
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
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
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
