import 'dart:io' show InternetAddress;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, FilteringTextInputFormatter, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'; // StateProvider (moved in Riverpod 3)

import '../../core/app_settings.dart';
import '../../core/censorship_facts_feed.dart';
import '../../core/core_controller.dart';
import '../../core/desync_config.dart';
import '../../core/native_admin.dart';
import '../../core/profiles_controller.dart';
import '../../core/route_mode.dart';
import '../../core/route_rule.dart';
import '../../core/update_check.dart';
import '../../core/webdav_sync.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/glass.dart';

// The app's glass SegmentedButton style — top-level so EVERY card (VpnMode,
// RouteMode, desync method, custom-rule field/action) renders the same translucent
// look instead of default opaque Material3 chrome (the "not our style" complaint).
ButtonStyle _segStyle(ColorScheme scheme,
        {double? fontSize, bool compact = false}) =>
    ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary.withValues(alpha: 0.20)
            : Colors.white.withValues(alpha: 0.04),
      ),
      foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
      side: WidgetStatePropertyAll(
        BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      visualDensity: compact ? VisualDensity.compact : null,
      textStyle: fontSize != null
          ? WidgetStatePropertyAll(TextStyle(fontSize: fontSize))
          : null,
    );

// One switch row for a GROUPED settings card. Replaces the old
// one-switch-per-GlassCard pattern that stacked ~11 near-identical cards with
// 12px gaps (the "settings junk" the user wanted gone). [hint] shows a small
// amber note under the row (e.g. "works only in TUN mode") when the toggle is
// inert in the current mode.
Widget _switchTile({
  required ColorScheme scheme,
  required String title,
  required String desc,
  required bool value,
  required ValueChanged<bool> onChanged,
  String? hint,
  bool enabled = true,
}) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Custom row + GlassSwitch instead of stock SwitchListTile so the toggle
        // animates with the same springy easeOutBack feel as the floating nav.
        // When disabled (e.g. a TUN-only toggle while in proxy mode) the row is
        // greyed AND non-interactive, so it can't flip to a green "on" that quietly
        // does nothing — the [hint] explains why.
        Opacity(
          opacity: enabled ? 1.0 : 0.4,
          child: IgnorePointer(
            ignoring: !enabled,
            child: InkWell(
              onTap: () => onChanged(!value),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title),
                          const SizedBox(height: 3),
                          Text(
                            desc,
                            style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurface.withValues(alpha: 0.6)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    GlassSwitch(value: value, onChanged: onChanged),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 13, color: Color(0xFFE0A53D)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(hint,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFFE0A53D))),
                ),
              ],
            ),
          ),
      ],
    );

// Stack switch rows in ONE GlassCard with hairline dividers — the declutter
// primitive that collapses the page's repeated single-switch cards.
Widget _switchGroup(List<Widget> rows) => GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(
                    height: 1,
                    thickness: 1,
                    indent: 12,
                    endIndent: 12,
                    color: Colors.white.withValues(alpha: 0.06)),
              rows[i],
            ],
          ],
        ),
      ),
    );

// Label for a desync preset key. Unknown keys (a future strategy with no l10n
// yet) fall back to the raw key so the picker never shows a blank segment.
String _desyncStratLabel(AppLocalizations l, String key) {
  switch (key) {
    case 'fake_split':
      return l.desyncStratFakeSplit;
    case 'fake_disorder':
      return l.desyncStratFakeDisorder;
    case 'split':
      return l.desyncStratSplit;
    default:
      return key;
  }
}

// A custom DoH resolver is used as a sing-box DNS `server` (host or IP), NOT a
// full URL. Accept empty (the RF-safe default), a bare IPv4/IPv6, or a hostname;
// reject a URL / path / whitespace so a malformed value can't be saved and then
// silently break resolution at the next connect.
bool _validDnsServer(String v) {
  final s = v.trim();
  if (s.isEmpty) return true;
  if (s.contains('://') || s.contains('/') || s.contains(RegExp(r'\s'))) {
    return false;
  }
  if (InternetAddress.tryParse(s) != null) return true; // bare IPv4/IPv6
  return DesyncConfig.cleanHost(s) != null; // hostname (e.g. dns.yandex.com)
}

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
    final maxResistance =
        ref.watch(settingsProvider.select((s) => s.maxResistance));
    final autoFailover = ref.watch(
      settingsProvider.select((s) => s.autoFailover),
    );
    final tlsFp = ref.watch(settingsProvider.select((s) => s.tlsFingerprint));
    final logLevel = ref.watch(settingsProvider.select((s) => s.logLevel));
    final mux = ref.watch(settingsProvider.select((s) => s.mux));
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
    final killSwitchTun = ref.watch(
      settingsProvider.select((s) => s.killSwitchTun),
    );
    final fakeIpTun = ref.watch(
      settingsProvider.select((s) => s.fakeIpTun),
    );
    final elevated = ref.watch(isElevatedProvider).value ?? false;
    final localeCode = ref.watch(settingsProvider.select((s) => s.localeCode));
    final version = ref.watch(coreControllerProvider.select((s) => s.version));
    final update = ref.watch(updateProvider).value;
    final facts = ref.watch(censorshipFactsProvider);
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
              GlassSegmented<VpnMode>(
                value: vpnMode,
                segments: VpnMode.values,
                labelOf: (m) =>
                    m == VpnMode.systemProxy ? l.vpnModeProxy : l.vpnModeTun,
                onChanged: (m) =>
                    ref.read(settingsProvider.notifier).setVpnMode(m),
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
              // Apps that ignore the Windows system proxy (Telegram desktop +
              // its calls, CLI tools) only get tunnelled in TUN — surface it so a
              // user doesn't think the VPN is broken when Telegram won't load.
              if (vpnMode == VpnMode.systemProxy) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        size: 14, color: Color(0xFFE0A53D)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(l.proxyAppsHint,
                          style: const TextStyle(
                              fontSize: 11.5, color: Color(0xFFE0A53D))),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Tap-to-copy the local proxy for a proxy-aware app's own SOCKS5
                // (Telegram → carries calls in proxy mode, where the system proxy
                // alone is TCP-only). matches SingBoxConfig.mixedListen:mixedPort.
                Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    onTap: () {
                      Clipboard.setData(
                          const ClipboardData(text: '127.0.0.1:2080'));
                      AppToast.of(context).message(l.proxyAddrCopied);
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: scheme.primary.withValues(alpha: 0.4)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.copy_rounded,
                            size: 13, color: scheme.primary),
                        const SizedBox(width: 6),
                        Text('SOCKS5  127.0.0.1:2080',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary)),
                      ]),
                    ),
                  ),
                ),
              ],
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
              GlassSegmented<RouteMode>(
                value: mode,
                segments: RouteMode.values,
                labelOf: (m) =>
                    m == RouteMode.global ? l.modeGlobal : l.modeSmart,
                onChanged: (m) => ref.read(settingsProvider.notifier).setMode(m),
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
        // System & startup — grouped (was 4 near-identical single-switch cards).
        _switchGroup([
          _switchTile(
            scheme: scheme,
            title: l.connectOnLaunchTitle,
            desc: l.connectOnLaunchDesc,
            value: connectOnLaunch,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setConnectOnLaunch(v),
          ),
          // vpn:// / sing-box:// / .json OS handlers (HKCU, no admin).
          _switchTile(
            scheme: scheme,
            title: l.registerLinksTitle,
            desc: l.registerLinksDesc,
            value: registerLinks,
            onChanged: (v) {
              ref.read(settingsProvider.notifier).setRegisterLinks(v);
              NativeAdmin.registerLinkHandlers(v);
            },
          ),
          // Launch at login (HKCU Run). In TUN mode the tunnel still needs admin.
          _switchTile(
            scheme: scheme,
            title: l.autostartTitle,
            desc: l.autostartDesc,
            value: launchAtStartup,
            onChanged: (v) {
              ref.read(settingsProvider.notifier).setLaunchAtStartup(v);
              NativeAdmin.setAutostart(v, minimized: false);
            },
          ),
          _switchTile(
            scheme: scheme,
            title: l.closeToTrayTitle,
            desc: l.closeToTrayDesc,
            value: closeToTray,
            onChanged: (v) {
              ref.read(settingsProvider.notifier).setCloseToTray(v);
              NativeAdmin.setCloseToTray(v);
            },
          ),
        ]),
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
          // Network resistance — grouped (anti-DPI + "hard network" for mobile
          // operators, which forces fragmentation + the active survivor-cascade).
          _switchGroup([
            _switchTile(
              scheme: scheme,
              title: l.antiDpiTitle,
              desc: l.antiDpiDesc,
              value: antiDpi,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setAntiDpi(v),
            ),
            _switchTile(
              scheme: scheme,
              title: l.maxResistTitle,
              desc: l.maxResistDesc,
              value: maxResistance,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setMaxResistance(v),
            ),
          ]),
          const SizedBox(height: 12),
          // Server-less WinDivert DPI-bypass (winws sidecar) — the heavy-resistance
          // layer that survives TLS-fragment reassembly. Needs admin + the binary.
          const _DesyncCard(),
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
          // Connection behaviour — grouped (mux + auto-failover + auto-adapt).
          _switchGroup([
            _switchTile(
              scheme: scheme,
              title: l.muxTitle,
              desc: l.muxDesc,
              value: mux,
              onChanged: (v) => ref.read(settingsProvider.notifier).setMux(v),
            ),
            _switchTile(
              scheme: scheme,
              title: l.autoFailoverTitle,
              desc: l.autoFailoverDesc,
              value: autoFailover,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setAutoFailover(v),
            ),
            _switchTile(
              scheme: scheme,
              title: l.autoAdaptTitle,
              desc: l.autoAdaptDesc,
              value: autoAdapt,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setAutoAdapt(v),
            ),
          ]),
          const SizedBox(height: 12),
          // TUN-only — grouped, with a hint when NOT in TUN mode (else these
          // toggles silently do nothing in the default system-proxy mode).
          _switchGroup([
            _switchTile(
              scheme: scheme,
              title: l.killSwitchTitle,
              desc: l.killSwitchDesc,
              value: killSwitchTun,
              enabled: vpnMode == VpnMode.tun,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setKillSwitchTun(v),
              hint: vpnMode == VpnMode.tun ? null : l.tunOnlyHint,
            ),
            _switchTile(
              scheme: scheme,
              title: l.fakeIpTitle,
              desc: l.fakeIpDesc,
              value: fakeIpTun,
              enabled: vpnMode == VpnMode.tun,
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setFakeIpTun(v),
              hint: vpnMode == VpnMode.tun ? null : l.tunOnlyHint,
            ),
          ]),
          const SizedBox(height: 12),
          const _SplitTunnelCard(),
          const SizedBox(height: 12),
          const _Hysteria2Card(),
          const SizedBox(height: 12),
          const _CustomDnsCard(),
          const SizedBox(height: 12),
          const _CustomRulesCard(),
          const SizedBox(height: 12),
          const _WebDavCard(),
          const SizedBox(height: 12),
          const _AdvancedCard(),
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
              const SizedBox(height: 6),
              // ② — the live ТСПУ-fact feed status: "built-in" until a newer
              // signed-in-spirit doc is pulled through the tunnel on connect.
              _kv(
                context,
                l.factsFeed,
                facts.version == 0
                    ? l.factsFeedBuiltIn
                    : 'v${facts.version} · ${facts.updated}',
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

/// Server-less WinDivert DPI-bypass (winws sidecar) toggle. Reflects the live
/// engine status from [CoreState.desyncEngine] — active / needs-admin (one-tap
/// elevate) / engine-missing — and exposes the desync-method picker. The right
/// method is ISP-specific, so the user can switch presets to find what survives.
class _DesyncCard extends ConsumerWidget {
  const _DesyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final on = ref.watch(settingsProvider.select((s) => s.winwsDesync));
    final strategy = ref.watch(settingsProvider.select((s) => s.desyncStrategy));
    final status =
        ref.watch(coreControllerProvider.select((s) => s.desyncEngine));
    // Distinguish "elevation still resolving" from a confirmed non-elevated: the
    // FutureProvider is null while loading, and `?? false` would flash a bogus
    // "needs admin" + relaunch button on an actually-elevated process. Only treat
    // it as not-elevated once the value is KNOWN.
    final elevatedAsync = ref.watch(isElevatedProvider);
    final confirmedNotElevated =
        elevatedAsync.hasValue && elevatedAsync.value == false;

    // No status line at all when the toggle is off — gate once, so a future
    // status can't accidentally render while disabled. The engine status is only
    // KNOWN after a connect, but we surface readiness immediately: confirmed-not-
    // elevated -> "needs admin" right away (WinDivert can't load otherwise).
    Widget? statusLine;
    if (on) {
      if (status == DesyncEngineStatus.active) {
        statusLine = Row(children: [
          Expanded(
              child: _line(Icons.check_circle, scheme.primary, l.desyncActive)),
          // ② Site still blocked? One tap advances to the next preset + ④ decoy SNI
          // (the user has ground truth — they can see the page didn't open).
          TextButton(
            onPressed: () {
              final ok =
                  ref.read(coreControllerProvider.notifier).desyncEscalate();
              AppToast.of(context)
                  .message(ok ? l.desyncTryingNext : l.desyncNoMore);
            },
            child: Text(l.desyncTryNext, style: const TextStyle(fontSize: 12)),
          ),
        ]);
      } else if (status == DesyncEngineStatus.missing) {
        statusLine =
            _line(Icons.error_outline, Colors.orangeAccent, l.desyncMissing);
      } else if (status == DesyncEngineStatus.needsAdmin ||
          confirmedNotElevated) {
        statusLine = Row(children: [
          Expanded(
              child: _line(Icons.shield_outlined, Colors.orangeAccent,
                  l.desyncNeedsAdmin)),
          TextButton(
            onPressed: () => NativeAdmin.relaunchElevated(),
            child: Text(l.restartAsAdmin, style: const TextStyle(fontSize: 12)),
          ),
        ]);
      } else {
        // elevated + toggle on, but not connected yet -> it engages on connect.
        statusLine = _line(Icons.info_outline,
            scheme.onSurface.withValues(alpha: 0.6), l.desyncIdle);
      }
    }

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () =>
                  ref.read(settingsProvider.notifier).setWinwsDesync(!on),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.desyncTitle),
                          const SizedBox(height: 3),
                          Text(
                            l.desyncDesc,
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    GlassSwitch(
                        value: on,
                        onChanged: (v) =>
                            ref.read(settingsProvider.notifier).setWinwsDesync(v)),
                  ],
                ),
              ),
            ),
            if (statusLine != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
                child: statusLine,
              ),
            if (on)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(l.desyncStrategyLabel,
                      style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withValues(alpha: 0.6))),
                ),
              ),
            if (on)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: _segStyle(scheme),
                    // Built from DesyncConfig.strategies.keys so a new preset
                    // added there auto-appears here (no hardcoded UI drift).
                    segments: [
                      for (final key in DesyncConfig.strategies.keys)
                        ButtonSegment(
                            value: key,
                            label: Text(_desyncStratLabel(l, key),
                                style: const TextStyle(fontSize: 11.5))),
                    ],
                    selected: {
                      DesyncConfig.isValidStrategy(strategy)
                          ? strategy
                          : DesyncConfig.defaultStrategy
                    },
                    onSelectionChanged: (s) => ref
                        .read(settingsProvider.notifier)
                        .setDesyncStrategy(s.first),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _line(IconData icon, Color color, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                style: TextStyle(fontSize: 11.5, color: color)),
          ),
        ],
      );
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
  late String _applied; // DNS the running core was last (re)started with

  @override
  void initState() {
    super.initState();
    _applied = ref.read(settingsProvider).customDns;
    _ctrl = TextEditingController(text: _applied);
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
            // Persist only a plausible resolver (IP or host). A URL/garbage value
            // would otherwise be saved and silently break resolution on the next
            // connect — the bug the audit flagged (the field had no validation).
            onChanged: (v) {
              if (_validDnsServer(v)) {
                ref.read(settingsProvider.notifier).setCustomDns(v);
              }
            },
            // Enter applies a changed resolver LIVE. customDns is excluded from the
            // per-keystroke live-restart (a half-typed value would bounce the
            // tunnel), so a deliberate submit is how a connected user applies it.
            onSubmitted: (v) {
              if (!_validDnsServer(v)) {
                AppToast.of(context).error(l.dnsInvalid);
                return;
              }
              ref.read(settingsProvider.notifier).setCustomDns(v);
              // Only restart if the resolver actually changed — a stray Enter on an
              // unchanged value shouldn't bounce the tunnel.
              if (v.trim() == _applied.trim()) return;
              _applied = v.trim();
              if (ref.read(coreControllerProvider).isOn) {
                ref
                    .read(coreControllerProvider.notifier)
                    .restart(reason: 'dns change');
              }
            },
          ),
          const SizedBox(height: 6),
          Text(
            l.dnsApplyHint,
            style: TextStyle(
                fontSize: 10.5,
                fontStyle: FontStyle.italic,
                color: scheme.onSurface.withValues(alpha: 0.45)),
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
  static const _files = MethodChannel('app/files');
  final _directCtrl = TextEditingController();
  final _vpnCtrl = TextEditingController();

  // Friendly label → executable name, for the one-tap common-app presets (most
  // users don't know the exact .exe). Tapping a suggestion adds its process name.
  static const _commonApps = <String, String>{
    'Telegram': 'Telegram.exe',
    'Chrome': 'chrome.exe',
    'Edge': 'msedge.exe',
    'Firefox': 'firefox.exe',
    'Brave': 'brave.exe',
    'Discord': 'Discord.exe',
    'Steam': 'steam.exe',
    'Spotify': 'Spotify.exe',
  };

  @override
  void dispose() {
    _directCtrl.dispose();
    _vpnCtrl.dispose();
    super.dispose();
  }

  void _addName(
      String name, List<String> cur, void Function(List<String>) save) {
    final n = name.trim();
    if (n.isEmpty || cur.contains(n)) return;
    save([...cur, n]);
  }

  void _add(
    TextEditingController c,
    List<String> cur,
    void Function(List<String>) save,
  ) {
    _addName(c.text, cur, save);
    c.clear();
  }

  // Pick the actual .exe from disk (the native open-file dialog) → add its
  // basename, so the user never has to know/type the exact process name.
  Future<void> _browse(
      List<String> cur, void Function(List<String>) save) async {
    final path = await _files.invokeMethod<String>('openFile');
    if (path == null || path.trim().isEmpty) return;
    final base = path.split(RegExp(r'[\\/]')).last.trim();
    if (base.isNotEmpty) _addName(base, cur, save);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final direct = ref.watch(settingsProvider.select((s) => s.splitTunnelApps));
    final vpn = ref.watch(settingsProvider.select((s) => s.forceVpnApps));
    final tunMode =
        ref.watch(settingsProvider.select((s) => s.vpnMode)) == VpnMode.tun;
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
          // Per-app routing is enforced by the TUN engine — flag it as inert in
          // the default system-proxy mode (the audit's "no mode guard").
          if (!tunMode) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline, size: 13, color: amber),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(l.tunOnlyHint,
                      style: const TextStyle(fontSize: 11, color: amber)),
                ),
              ],
            ),
          ],
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
            onBrowse: () => _browse(direct, notifier.setSplitTunnelApps),
            onPreset: (name) =>
                _addName(name, direct, notifier.setSplitTunnelApps),
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
            onBrowse: () => _browse(vpn, notifier.setForceVpnApps),
            onPreset: (name) => _addName(name, vpn, notifier.setForceVpnApps),
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
    ColorScheme scheme, {
    required VoidCallback onBrowse,
    required void Function(String) onPreset,
  }) {
    // Common-app one-tap suggestions not already in THIS list (most users don't
    // know exact .exe names) — the native "Browse" picker covers the rest.
    final suggestions = _commonApps.entries
        .where((e) => !apps.contains(e.value))
        .toList();
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
            // Native "pick the .exe from disk" — no need to know the process name.
            GlassButton(
              onPressed: onBrowse,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Icon(Icons.folder_open_rounded, size: 18, color: color),
            ),
            const SizedBox(width: 8),
            GlassButton(
              onPressed: onAdd,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Icon(Icons.add_rounded, size: 20, color: color),
            ),
          ],
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(l.splitCommonApps,
              style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurface.withValues(alpha: 0.45))),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final e in suggestions)
                InkWell(
                  onTap: () => onPreset(e.value),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.add_rounded,
                          size: 13,
                          color: scheme.onSurface.withValues(alpha: 0.55)),
                      const SizedBox(width: 4),
                      Text(e.key,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurface.withValues(alpha: 0.8))),
                    ]),
                  ),
                ),
            ],
          ),
        ],
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

/// Custom routing rules editor (competitor parity): force a domain/IP through
/// the tunnel, direct, or block it. Rules win over Smart routing. The whole list
/// is committed on each add/remove; the controller restarts a live tunnel to
/// apply it.
class _CustomRulesCard extends ConsumerStatefulWidget {
  const _CustomRulesCard();

  @override
  ConsumerState<_CustomRulesCard> createState() => _CustomRulesCardState();
}

class _CustomRulesCardState extends ConsumerState<_CustomRulesCard> {
  final _ctrl = TextEditingController();
  RuleField _field = RuleField.domainSuffix;
  RuleAction _action = RuleAction.proxy;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color _actionColor(RuleAction a, ColorScheme scheme) => switch (a) {
        RuleAction.proxy => scheme.primary,
        RuleAction.direct => const Color(0xFFE0A53D),
        RuleAction.block => scheme.error,
      };

  String _actionLabel(RuleAction a, AppLocalizations l) => switch (a) {
        RuleAction.proxy => l.ruleActionProxy,
        RuleAction.direct => l.ruleActionDirect,
        RuleAction.block => l.ruleActionBlock,
      };

  String _fieldLabel(RuleField f, AppLocalizations l) => switch (f) {
        RuleField.domainSuffix => l.ruleFieldDomainSuffix,
        RuleField.domain => l.ruleFieldDomain,
        RuleField.ipCidr => l.ruleFieldIpCidr,
      };

  void _add(List<RouteRule> cur) {
    // Validate with the SAME rule the engine uses — so the editor never accepts a
    // value that would be silently dropped (or FATAL the core) at build time.
    if (!RouteRule.isValidValue(_field, _ctrl.text)) {
      AppToast.of(context)
          .error(AppLocalizations.of(context).customRulesInvalid);
      return;
    }
    final value = RouteRule.cleanValue(_field, _ctrl.text); // normalised/lowercased
    final rule = RouteRule(field: _field, value: value, action: _action);
    final exists = cur.any((r) =>
        r.field == rule.field &&
        r.value == rule.value &&
        r.action == rule.action);
    if (!exists) {
      ref.read(settingsProvider.notifier).setCustomRules([...cur, rule]);
    }
    _ctrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rules = ref.watch(settingsProvider.select((s) => s.customRules));
    final notifier = ref.read(settingsProvider.notifier);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.customRulesTitle,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            l.customRulesDesc,
            style: TextStyle(
                fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 4),
          Text(
            l.customRulesLiveNote,
            style: TextStyle(
                fontSize: 10.5,
                fontStyle: FontStyle.italic,
                color: scheme.onSurface.withValues(alpha: 0.45)),
          ),
          const SizedBox(height: 12),
          if (rules.isEmpty)
            Text(
              l.customRulesEmpty,
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.4)),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in rules)
                  _ruleChip(r, scheme, l,
                      () => notifier.setCustomRules(
                          rules.where((x) => x != r).toList())),
              ],
            ),
          const SizedBox(height: 12),
          // Field selector — a segmented control matching the action selector
          // below + the rest of the app (the default DropdownButton wasn't ours).
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<RuleField>(
              showSelectedIcon: false,
              style: _segStyle(scheme, fontSize: 11.5, compact: true),
              segments: [
                for (final f in RuleField.values)
                  ButtonSegment(value: f, label: Text(_fieldLabel(f, l))),
              ],
              selected: {_field},
              onSelectionChanged: (s) => setState(() => _field = s.first),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            decoration: glassInputDecoration(context, l.customRulesValueHint),
            onSubmitted: (_) => _add(rules),
          ),
          const SizedBox(height: 10),
          // Action selector + add.
          Row(
            children: [
              Expanded(
                child: SegmentedButton<RuleAction>(
                  showSelectedIcon: false,
                  style: _segStyle(scheme, fontSize: 12, compact: true),
                  segments: [
                    for (final a in RuleAction.values)
                      ButtonSegment(
                        value: a,
                        label: Text(_actionLabel(a, l),
                            style: TextStyle(
                                color: _action == a
                                    ? _actionColor(a, scheme)
                                    : null)),
                      ),
                  ],
                  selected: {_action},
                  onSelectionChanged: (s) =>
                      setState(() => _action = s.first),
                ),
              ),
              const SizedBox(width: 8),
              GlassButton(
                onPressed: () => _add(rules),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Icon(Icons.add_rounded,
                    size: 20, color: _actionColor(_action, scheme)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ruleChip(RouteRule r, ColorScheme scheme, AppLocalizations l,
      VoidCallback onRemove) {
    final color = _actionColor(r.action, scheme);
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${_actionLabel(r.action, l)} · ',
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
          // Cap width + ellipsis: a value can be a 253-char domain; without this
          // the min-size Row inside the Wrap overflows the 440px window.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(r.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurface)),
          ),
          const SizedBox(width: 3),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Icon(Icons.close_rounded,
                size: 15, color: scheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
}

/// Cloud sync of the profile bundle over WebDAV (competitor parity: Karing's
/// iCloud/WebDAV sync) — back up profiles to the user's own cloud and restore
/// them on any device. Guards against the config-loss the user hit before.
class _WebDavCard extends ConsumerStatefulWidget {
  const _WebDavCard();

  @override
  ConsumerState<_WebDavCard> createState() => _WebDavCardState();
}

class _WebDavCardState extends ConsumerState<_WebDavCard> {
  late final TextEditingController _url;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  String? _busyOp; // 'backup' | 'restore' | null — which op is in flight
  bool get _busy => _busyOp != null;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _url = TextEditingController(text: s.webdavUrl);
    _user = TextEditingController(text: s.webdavUser);
    _pass = TextEditingController(text: s.webdavPass);
  }

  @override
  void dispose() {
    // Persist ONCE on leave instead of on every keystroke — the password is
    // plaintext on disk, so per-character writes were needless churn. Backup /
    // restore already _persist() before acting, so credentials are never lost.
    _persist();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _persist() => ref.read(settingsProvider.notifier).setWebdav(
        url: _url.text,
        user: _user.text,
        pass: _pass.text,
      );

  Future<void> _backup() async {
    _persist();
    final toast = AppToast.of(context);
    final l = AppLocalizations.of(context);
    setState(() => _busyOp = 'backup');
    final body = ref.read(profilesProvider.notifier).exportJson();
    final err =
        await WebDavSync.upload(_url.text, _user.text, _pass.text, body);
    if (!mounted) return;
    setState(() => _busyOp = null);
    if (err != null) {
      toast.error('${l.syncError}: $err');
    } else {
      toast.message(l.webdavBackedUp, kind: ToastKind.success);
    }
  }

  Future<void> _restore() async {
    _persist();
    final toast = AppToast.of(context);
    final l = AppLocalizations.of(context);
    setState(() => _busyOp = 'restore');
    final r = await WebDavSync.download(_url.text, _user.text, _pass.text);
    if (!mounted) return;
    setState(() => _busyOp = null);
    if (r.error != null || r.body == null) {
      toast.error('${l.syncError}: ${r.error ?? 'empty'}');
      return;
    }
    // The body came from the user's OWN WebDAV, but the server may be shared /
    // compromised — a malformed/hostile backup must surface an error toast, not
    // throw out of the button handler and dead-end the restore silently.
    try {
      final res = ref.read(profilesProvider.notifier).importText(r.body!);
      toast.message(res.added > 0 ? l.msgAddedNodes(res.added) : l.subsUpToDate,
          kind: ToastKind.success);
    } catch (_) {
      toast.error('${l.syncError}: restore');
    }
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
          Text(l.webdavTitle,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(l.webdavDesc,
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: glassInputDecoration(context, l.webdavUrlHint),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _user,
                  decoration: glassInputDecoration(context, l.webdavUserLabel),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: glassInputDecoration(context, l.webdavPassLabel),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  onPressed: _busy ? null : _backup,
                  child: _busyOp == 'backup'
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Opacity(
                          opacity: _busy ? 0.4 : 1, // dim while the other op runs
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.cloud_upload_rounded,
                                  size: 18, color: scheme.primary),
                              const SizedBox(width: 6),
                              Text(l.webdavBackup),
                            ],
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GlassButton(
                  onPressed: _busy ? null : _restore,
                  child: _busyOp == 'restore'
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Opacity(
                          opacity: _busy ? 0.4 : 1,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.cloud_download_rounded,
                                  size: 18, color: scheme.primary),
                              const SizedBox(width: 6),
                              Text(l.webdavRestore),
                            ],
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Collapsed-by-default "Advanced" section — expert transport knobs kept OUT of
/// the main settings flow (the app's principle: fewer controls on screen, more
/// native). Every knob defaults to the prior behaviour, so an untouched app is
/// unchanged; this just gives power users a tucked-away place to tune.
class _AdvancedCard extends ConsumerStatefulWidget {
  const _AdvancedCard();

  @override
  ConsumerState<_AdvancedCard> createState() => _AdvancedCardState();
}

class _AdvancedCardState extends ConsumerState<_AdvancedCard> {
  bool _open = false;
  late final TextEditingController _ecs;

  @override
  void initState() {
    super.initState();
    _ecs = TextEditingController(text: ref.read(settingsProvider).ecsSubnet);
  }

  @override
  void dispose() {
    _ecs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final s = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final tunMode = s.vpnMode == VpnMode.tun;
    final dim = scheme.onSurface.withValues(alpha: 0.6);
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 2, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, size: 18, color: dim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.advancedTitle,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(l.advancedDesc,
                            style: TextStyle(fontSize: 11, color: dim)),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child:
                        Icon(Icons.keyboard_arrow_down_rounded, color: dim),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 220),
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                _knob(context, l.tunStackTitle, l.tunStackDesc,
                    GlassDropdown<String>(
                      value: s.tunStack,
                      items: tunStacks,
                      onChanged: notifier.setTunStack,
                    ),
                    hint: tunMode ? null : l.tunOnlyHint),
                const SizedBox(height: 12),
                _knob(context, l.muxProtoTitle, '',
                    GlassDropdown<String>(
                      value: s.muxProtocol,
                      items: muxProtocols,
                      onChanged: notifier.setMuxProtocol,
                    )),
                const SizedBox(height: 8),
                _switchGroup([
                  _switchTile(
                    scheme: scheme,
                    title: l.muxPaddingTitle,
                    desc: l.muxPaddingDesc,
                    value: s.muxPadding,
                    onChanged: notifier.setMuxPadding,
                  ),
                  _switchTile(
                    scheme: scheme,
                    title: l.echTitle,
                    desc: l.echDesc,
                    value: s.ech,
                    onChanged: notifier.setEch,
                  ),
                  _switchTile(
                    scheme: scheme,
                    title: l.tfoTitle,
                    desc: l.tfoDesc,
                    value: s.tcpFastOpen,
                    onChanged: notifier.setTcpFastOpen,
                  ),
                  _switchTile(
                    scheme: scheme,
                    title: l.mptcpTitle,
                    desc: l.mptcpDesc,
                    value: s.mptcp,
                    onChanged: notifier.setMptcp,
                  ),
                ]),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.dns_outlined, size: 16, color: dim),
                    const SizedBox(width: 8),
                    Text(l.ecsTitle,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(l.ecsDesc, style: TextStyle(fontSize: 11, color: dim)),
                const SizedBox(height: 8),
                TextField(
                  controller: _ecs,
                  decoration: glassInputDecoration(context, l.ecsHint),
                  // Enter applies live — ECS IS in the live-restart watcher, so a
                  // per-keystroke commit would bounce the tunnel; submit is the
                  // deliberate apply (mirrors the custom-DNS field). A malformed
                  // subnet is rejected with a toast instead of FATAL-ing the core.
                  onSubmitted: (v) {
                    final t = v.trim();
                    if (t.isNotEmpty &&
                        !RouteRule.isValidValue(RuleField.ipCidr, t)) {
                      AppToast.of(context).error(l.ecsInvalid);
                      return;
                    }
                    notifier.setEcsSubnet(t);
                  },
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Title + optional description + a control (dropdown), with an optional amber
  // hint row underneath (e.g. "TUN only").
  Widget _knob(BuildContext context, String title, String desc, Widget control,
      {String? hint}) {
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(desc, style: TextStyle(fontSize: 11, color: dim)),
        ],
        const SizedBox(height: 8),
        control,
        if (hint != null) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.info_outline, size: 13, color: Color(0xFFE0A53D)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(hint,
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFFE0A53D))),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
