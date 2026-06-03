import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'; // StateProvider (moved in Riverpod 3)

import '../../core/app_settings.dart';
import '../../core/core_controller.dart';
import '../../core/native_admin.dart';
import '../../core/route_mode.dart';
import '../../core/update_check.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/glass.dart';

// Expert toggles are collapsed by default — the defaults are already RF-correct,
// so an ordinary user sees only the 4 essentials. Survives tab switches.
final _advancedOpenProvider = StateProvider<bool>((_) => false);

// Stamped at build time by tool/package.ps1 (`--dart-define`), so the About
// screen reports the EXACT build/commit a user is running — not a hardcoded
// guess. Debug builds show the pubspec version + "dev".
const _appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '1.0.0',
);
const _appBuild = String.fromEnvironment('APP_BUILD', defaultValue: 'dev');
const _githubUrl = 'https://github.com/Danya-byte/vpn-app';
const _developerUrl = 'https://t.me/rollpit';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final mode = ref.watch(settingsProvider.select((s) => s.mode));
    final vpnMode = ref.watch(settingsProvider.select((s) => s.vpnMode));
    final antiDpi = ref.watch(settingsProvider.select((s) => s.antiDpi));
    final autoFailover = ref.watch(
      settingsProvider.select((s) => s.autoFailover),
    );
    final tlsFp = ref.watch(settingsProvider.select((s) => s.tlsFingerprint));
    final logLevel = ref.watch(settingsProvider.select((s) => s.logLevel));
    final mux = ref.watch(settingsProvider.select((s) => s.mux));
    final ech = ref.watch(settingsProvider.select((s) => s.ech));
    final autoAdapt = ref.watch(settingsProvider.select((s) => s.autoAdapt));
    final registerLinks =
        ref.watch(settingsProvider.select((s) => s.registerLinks));
    final launchAtStartup =
        ref.watch(settingsProvider.select((s) => s.launchAtStartup));
    final closeToTray =
        ref.watch(settingsProvider.select((s) => s.closeToTray));
    final connectOnLaunch = ref.watch(
      settingsProvider.select((s) => s.connectOnLaunch),
    );
    final desyncDirect = ref.watch(
      settingsProvider.select((s) => s.desyncDirect),
    );
    final killSwitchTun = ref.watch(
      settingsProvider.select((s) => s.killSwitchTun),
    );
    final elevated = ref.watch(isElevatedProvider).value ?? false;
    final localeCode = ref.watch(settingsProvider.select((s) => s.localeCode));
    final version = ref.watch(coreControllerProvider.select((s) => s.version));
    final update = ref.watch(updateProvider).value;
    final advancedOpen = ref.watch(_advancedOpenProvider);

    return ListView(
      // bottom inset lets the list scroll UNDER the floating nav, last item clear.
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 104),
      children: [
        PageHeader(icon: Icons.tune_rounded, title: l.navSettings),
        const SizedBox(height: 14),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(context, Icons.vpn_lock_rounded, l.vpnModeTitle),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<VpnMode>(
                  showSelectedIcon: false,
                  style: _segStyle(scheme),
                  segments: VpnMode.values
                      .map(
                        (m) => ButtonSegment(
                          value: m,
                          label: Text(
                            m == VpnMode.systemProxy
                                ? l.vpnModeProxy
                                : l.vpnModeTun,
                          ),
                        ),
                      )
                      .toList(),
                  selected: {vpnMode},
                  onSelectionChanged: (s) =>
                      ref.read(settingsProvider.notifier).setVpnMode(s.first),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                vpnMode == VpnMode.systemProxy
                    ? l.vpnModeProxyDesc
                    : l.vpnModeTunDesc,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              if (vpnMode == VpnMode.tun && !elevated) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => NativeAdmin.relaunchElevated(),
                  icon: const Icon(Icons.shield_rounded, size: 18),
                  label: Text(l.restartAsAdmin),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(context, Icons.alt_route_rounded, l.routingMode),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<RouteMode>(
                  showSelectedIcon: false,
                  style: _segStyle(scheme),
                  segments: RouteMode.values
                      .map(
                        (m) => ButtonSegment(
                          value: m,
                          label: Text(
                            m == RouteMode.global ? l.modeGlobal : l.modeSmart,
                          ),
                        ),
                      )
                      .toList(),
                  selected: {mode},
                  onSelectionChanged: (s) =>
                      ref.read(settingsProvider.notifier).setMode(s.first),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                mode == RouteMode.global ? l.modeGlobalDesc : l.modeSmartDesc,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // Connect on launch (basic).
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Material(
            color: Colors.transparent,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(l.connectOnLaunchTitle),
              subtitle: Text(
                l.connectOnLaunchDesc,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              value: connectOnLaunch,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setConnectOnLaunch(v),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Register vpn:// / sing-box:// / .json OS handlers so an OS click fires
        // the deeplink import (HKCU, no admin). Opt-in (last-installed wins).
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Material(
            color: Colors.transparent,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(l.registerLinksTitle),
              subtitle: Text(
                l.registerLinksDesc,
                style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6)),
              ),
              value: registerLinks,
              onChanged: (v) {
                ref.read(settingsProvider.notifier).setRegisterLinks(v);
                NativeAdmin.registerLinkHandlers(v);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Launch at login (HKCU Run, no admin). Note: in TUN mode the tunnel
        // still needs admin, so autostart brings the app up but won't auto-raise
        // TUN without a UAC prompt — best paired with system-proxy mode.
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Material(
            color: Colors.transparent,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(l.autostartTitle),
              subtitle: Text(
                l.autostartDesc,
                style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6)),
              ),
              value: launchAtStartup,
              onChanged: (v) {
                ref.read(settingsProvider.notifier).setLaunchAtStartup(v);
                NativeAdmin.setAutostart(v, minimized: false);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Close-to-tray: keep the tunnel running in the background when the
        // window is closed (the tray icon is the way back).
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Material(
            color: Colors.transparent,
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Text(l.closeToTrayTitle),
              subtitle: Text(
                l.closeToTrayDesc,
                style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6)),
              ),
              value: closeToTray,
              onChanged: (v) {
                ref.read(settingsProvider.notifier).setCloseToTray(v);
                NativeAdmin.setCloseToTray(v);
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Language (basic).
        GlassCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: [
                _langTile(context, ref, l.languageSystem, null, localeCode),
                _langTile(context, ref, 'English', 'en', localeCode),
                _langTile(context, ref, 'Русский', 'ru', localeCode),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // ── ADVANCED — collapsed; the defaults below are already RF-correct ──
        _advancedHeader(context, ref, advancedOpen, l),
        if (advancedOpen) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              l.settingsAdvancedHint,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(l.antiDpiTitle),
                subtitle: Text(
                  l.antiDpiDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                value: antiDpi,
                onChanged: (v) =>
                    ref.read(settingsProvider.notifier).setAntiDpi(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // uTLS fingerprint pool.
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(context, Icons.fingerprint_rounded, l.tlsFpTitle),
                const SizedBox(height: 6),
                Text(
                  l.tlsFpDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 10),
                GlassDropdown<String>(
                  value: tlsFp,
                  items: tlsFingerprints,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setTlsFingerprint(v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Log verbosity (in-app log view). Takes effect on the next connect.
          GlassCard(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label(context, Icons.article_outlined, l.logLevelTitle),
                const SizedBox(height: 6),
                Text(
                  l.logLevelDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 10),
                GlassDropdown<String>(
                  value: logLevel,
                  items: logLevels,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setLogLevel(v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(l.muxTitle),
                subtitle: Text(
                  l.muxDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                value: mux,
                onChanged: (v) => ref.read(settingsProvider.notifier).setMux(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(l.echTitle),
                subtitle: Text(
                  l.echDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                value: ech,
                onChanged: (v) => ref.read(settingsProvider.notifier).setEch(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(l.autoFailoverTitle),
                subtitle: Text(
                  l.autoFailoverDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                value: autoFailover,
                onChanged: (v) =>
                    ref.read(settingsProvider.notifier).setAutoFailover(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(l.autoAdaptTitle),
                subtitle: Text(
                  l.autoAdaptDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                value: autoAdapt,
                onChanged: (v) =>
                    ref.read(settingsProvider.notifier).setAutoAdapt(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(l.desyncTitle),
                subtitle: Text(
                  l.desyncDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                value: desyncDirect,
                onChanged: (v) =>
                    ref.read(settingsProvider.notifier).setDesyncDirect(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Material(
              color: Colors.transparent,
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(l.killSwitchTitle),
                subtitle: Text(
                  l.killSwitchDesc,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                value: killSwitchTun,
                onChanged: (v) =>
                    ref.read(settingsProvider.notifier).setKillSwitchTun(v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const _SplitTunnelCard(),
          const SizedBox(height: 12),
          const _Hysteria2Card(),
          const SizedBox(height: 12),
          const _CustomDnsCard(),
        ],
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label(context, Icons.info_outline_rounded, l.about),
              const SizedBox(height: 12),
              _kv(context, l.version, '$_appVersion ($_appBuild)'),
              const SizedBox(height: 6),
              _kv(context, l.core, version ?? l.coreNotRunning),
              const SizedBox(height: 4),
              Text(
                l.openSourceNote,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              if (update != null)
                _linkTile(
                  context,
                  Icons.system_update_rounded,
                  l.updateAvailable(update.version),
                  update.url,
                ),
              const SizedBox(height: 6),
              _linkTile(context, Icons.code_rounded, l.sourceCode, _githubUrl),
              _linkTile(
                context,
                Icons.person_rounded,
                l.developer,
                _developerUrl,
              ),
            ],
          ),
        ),
      ],
    );
  }

  ButtonStyle _segStyle(ColorScheme scheme) => ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? scheme.primary.withValues(alpha: 0.20)
          : Colors.white.withValues(alpha: 0.04),
    ),
    foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
    side: WidgetStatePropertyAll(
      BorderSide(color: Colors.white.withValues(alpha: 0.12)),
    ),
  );

  Widget _label(BuildContext context, IconData icon, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }

  // Tappable "Advanced" expander row. Collapsed by default so the page shows
  // only the 4 essentials; the chevron rotates on open.
  Widget _advancedHeader(
    BuildContext context,
    WidgetRef ref,
    bool open,
    AppLocalizations l,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => ref.read(_advancedOpenProvider.notifier).state = !open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Icon(Icons.tune_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  l.settingsAdvanced,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.expand_more_rounded,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          k,
          style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.6)),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            v,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  Widget _linkTile(
    BuildContext context,
    IconData icon,
    String label,
    String url,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => NativeAdmin.openUrl(url),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              Icon(
                Icons.open_in_new_rounded,
                size: 15,
                color: scheme.onSurface.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _langTile(
    BuildContext context,
    WidgetRef ref,
    String label,
    String? code,
    String? current,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final selected = current == code;
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: selected
          ? Icon(Icons.check_rounded, color: scheme.primary, size: 20)
          : null,
      onTap: () => ref.read(settingsProvider.notifier).setLocale(code),
    );
  }
}

/// Custom DoH resolver. Blank = the RF-safe default (Yandex 77.88.8.8). Kept a
/// DoH server so a custom value stays DPI-resistant.
class _CustomDnsCard extends ConsumerStatefulWidget {
  const _CustomDnsCard();

  @override
  ConsumerState<_CustomDnsCard> createState() => _CustomDnsCardState();
}

class _CustomDnsCardState extends ConsumerState<_CustomDnsCard> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ref.read(settingsProvider).customDns);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.dnsTitle,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            l.dnsDesc,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            decoration: glassInputDecoration(context, l.dnsHint),
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setCustomDns(v),
          ),
        ],
      ),
    );
  }
}

/// Hysteria2 Brutal bandwidth tuning: enter your real line speed (Mbps) so
/// Hysteria2's congestion control holds throughput under loss/jitter on a noisy
/// RF link. Blank/0 = auto-tune. Only affects hysteria2 nodes.
class _Hysteria2Card extends ConsumerStatefulWidget {
  const _Hysteria2Card();

  @override
  ConsumerState<_Hysteria2Card> createState() => _Hysteria2CardState();
}

class _Hysteria2CardState extends ConsumerState<_Hysteria2Card> {
  late final TextEditingController _upCtrl;
  late final TextEditingController _downCtrl;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _upCtrl =
        TextEditingController(text: s.hy2UpMbps > 0 ? '${s.hy2UpMbps}' : '');
    _downCtrl =
        TextEditingController(text: s.hy2DownMbps > 0 ? '${s.hy2DownMbps}' : '');
  }

  @override
  void dispose() {
    _upCtrl.dispose();
    _downCtrl.dispose();
    super.dispose();
  }

  void _commit() => ref.read(settingsProvider.notifier).setHy2Bandwidth(
        up: int.tryParse(_upCtrl.text.trim()) ?? 0,
        down: int.tryParse(_downCtrl.text.trim()) ?? 0,
      );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.brutalTitle,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            l.brutalDesc,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _field(_downCtrl, l.brutalDown, l)),
              const SizedBox(width: 10),
              Expanded(child: _field(_upCtrl, l.brutalUp, l)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label, AppLocalizations l) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: glassInputDecoration(context, l.brutalHint),
          onChanged: (_) => _commit(),
        ),
      ],
    );
  }
}

/// Per-app routing editor: two lists — processes routed DIRECT (bypass VPN) and
/// processes FORCED through the VPN (blocked apps). TUN only.
class _SplitTunnelCard extends ConsumerStatefulWidget {
  const _SplitTunnelCard();

  @override
  ConsumerState<_SplitTunnelCard> createState() => _SplitTunnelCardState();
}

class _SplitTunnelCardState extends ConsumerState<_SplitTunnelCard> {
  final _directCtrl = TextEditingController();
  final _vpnCtrl = TextEditingController();

  @override
  void dispose() {
    _directCtrl.dispose();
    _vpnCtrl.dispose();
    super.dispose();
  }

  void _add(
    TextEditingController c,
    List<String> cur,
    void Function(List<String>) save,
  ) {
    final n = c.text.trim();
    if (n.isEmpty) return;
    if (!cur.contains(n)) save([...cur, n]);
    c.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final direct = ref.watch(settingsProvider.select((s) => s.splitTunnelApps));
    final vpn = ref.watch(settingsProvider.select((s) => s.forceVpnApps));
    final notifier = ref.read(settingsProvider.notifier);
    const amber = Color(0xFFE0A53D);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.splitTunnelTitle,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            l.splitTunnelDesc,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 14),
          _section(
            l.splitDirectLabel,
            Icons.call_split_rounded,
            amber,
            direct,
            _directCtrl,
            () => _add(_directCtrl, direct, notifier.setSplitTunnelApps),
            (n) => notifier.setSplitTunnelApps(
              direct.where((a) => a != n).toList(),
            ),
            l,
            scheme,
          ),
          const SizedBox(height: 14),
          _section(
            l.splitVpnLabel,
            Icons.vpn_lock_rounded,
            scheme.primary,
            vpn,
            _vpnCtrl,
            () => _add(_vpnCtrl, vpn, notifier.setForceVpnApps),
            (n) => notifier.setForceVpnApps(vpn.where((a) => a != n).toList()),
            l,
            scheme,
          ),
        ],
      ),
    );
  }

  Widget _section(
    String label,
    IconData icon,
    Color color,
    List<String> apps,
    TextEditingController ctrl,
    VoidCallback onAdd,
    void Function(String) onRemove,
    AppLocalizations l,
    ColorScheme scheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (apps.isEmpty)
          Text(
            l.splitTunnelEmpty,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in apps) _chip(a, color, () => onRemove(a), scheme),
            ],
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                decoration: glassInputDecoration(context, l.splitTunnelHint),
                onSubmitted: (_) => onAdd(),
              ),
            ),
            const SizedBox(width: 8),
            GlassButton(
              onPressed: onAdd,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Icon(Icons.add_rounded, size: 20, color: color),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip(
    String name,
    Color color,
    VoidCallback onRemove,
    ColorScheme scheme,
  ) => Container(
    padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(name, style: TextStyle(fontSize: 12, color: scheme.onSurface)),
        const SizedBox(width: 3),
        InkWell(
          onTap: onRemove,
          borderRadius: BorderRadius.circular(10),
          child: Icon(
            Icons.close_rounded,
            size: 15,
            color: scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    ),
  );
}
