import 'dart:convert';
import 'dart:io' show File;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/app_settings.dart';
import '../../core/core_controller.dart';
import '../../core/deeplink.dart';
import '../../core/native_admin.dart';
import '../../core/profiles_controller.dart';
import '../../core/telegram_native_provider.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/glass.dart';
import '../activity/activity_page.dart';
import '../home/home_page.dart';
import '../home/widgets/clipboard_offer.dart';
import '../home/widgets/import_actions.dart';
import '../onboarding/first_run_setup.dart';
import '../settings/settings_page.dart';

class RootScaffold extends ConsumerStatefulWidget {
  const RootScaffold({super.key});

  @override
  ConsumerState<RootScaffold> createState() => _RootScaffoldState();
}

class _RootScaffoldState extends ConsumerState<RootScaffold> {
  static const _dropChannel = MethodChannel('app/files');
  // Held as a field so dispose() can null out its handler — a const-channel
  // closure left set keeps firing into a disposed State (stale ref/context).
  static const _systemChannel = MethodChannel('app/system');
  int _index = 0;
  OverlayEntry? _dragEntry;
  // Synchronous re-entrancy latch for the deferred first-run chooser. seenSetup is
  // only persisted AFTER the dialog is dismissed, so a restart() that flaps isOn
  // false→true while the dialog is still open would re-fire the listener and stack
  // a SECOND dialog (the seenSetup guard hasn't flipped yet). Latched the instant
  // the edge fires, closing that window.
  bool _setupShown = false;

  void _showDragOverlay() {
    if (_dragEntry != null || !mounted) return;
    _dragEntry = OverlayEntry(builder: (_) => const _DragOverlay());
    Overlay.of(context, rootOverlay: true).insert(_dragEntry!);
  }

  void _hideDragOverlay() {
    _dragEntry?.remove();
    _dragEntry = null;
  }

  // Admin mode (Windows UIPI) blocks the OLE drag-enter event, so there's no
  // hover overlay there — flash it on the DROP itself so the user still gets
  // visual feedback that the file registered. No-op when not elevated (the live
  // hover overlay already fired on drag-enter).
  Future<void> _flashDropIfElevated() async {
    if (ref.read(isElevatedProvider).value != true) return;
    _showDragOverlay();
    await Future.delayed(const Duration(milliseconds: 450));
    _hideDragOverlay();
  }

  @override
  void dispose() {
    // Tear down the native channel handlers so their async closures can't run
    // against this disposed State (stale context/ref).
    _dropChannel.setMethodCallHandler(null);
    _systemChannel.setMethodCallHandler(null);
    _hideDragOverlay();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Instantiate the native Telegram controller at startup (keep-alive Notifier)
    // so a persisted `telegramNative:true` auto-starts the local MTProxy (tgcore)
    // on relaunch.
    ref.read(telegramNativeProvider);
    _dropChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onFile':
          _hideDragOverlay();
          await _flashDropIfElevated(); // admin: flash the overlay on the drop
          if (mounted) {
            // A dropped / "Open with" file is an EXTERNAL source — preview-gate.
            await importFromFile(context, ref, call.arguments as String,
                trusted: false);
          }
        case 'onContent':
          _hideDragOverlay();
          await _flashDropIfElevated(); // admin: flash the overlay on the drop
          if (mounted) {
            await importDroppedContent(
                context, ref, call.arguments as List<int>,
                trusted: false);
          }
        case 'dragEnter':
          _showDragOverlay();
        case 'dragLeave':
          _hideDragOverlay();
      }
      return null;
    });
    // Native network-change events -> seamless reconnect.
    _systemChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'trayToggle':
          await _handleTrayToggle();
        case 'networkChanged':
          ref.read(coreControllerProvider.notifier).onNetworkChanged();
        case 'resumed':
          ref.read(coreControllerProvider.notifier).onResumed();
          // Window regained focus — the user may have just copied a server link.
          if (mounted) peekClipboardForImport(ref);
        case 'deeplink':
          // Warm-start: a second instance forwarded a clicked link/file (native
          // WM_COPYDATA). Same untrusted path as a cold-launch deeplink.
          final payload = call.arguments as String?;
          final p = payload == null ? null : importablePayload(payload);
          if (p != null && mounted) {
            // File ONLY when the payload IS an existing file ("Open with") —
            // an unwrapped opaque blob (base64 subscription) has no '://' either
            // and must go down the CONTENT path, not File().readAsBytes().
            // A raw external payload can be a malformed path (illegal chars on
            // Windows) — existsSync() can THROW, so default to the content path.
            bool isFile = false;
            if (!p.contains('://')) {
              try {
                isFile = File(p).existsSync();
              } catch (_) {
                isFile = false;
              }
            }
            if (isFile) {
              await importFromFile(context, ref, p, trusted: false);
            } else {
              await importDroppedContent(context, ref, utf8.encode(p),
                  trusted: false);
            }
          }
      }
      return null;
    });
    // Push the close-to-tray choice to the native runner so it knows whether to
    // hide vs quit on window close (the native default matches; this syncs a
    // user override saved from a prior run).
    NativeAdmin.setCloseToTray(ref.read(settingsProvider).closeToTray);
    // Cold-launch deeplink / "Open with": apply the pending import on first frame
    // (a link/url goes through the text path; a file path through importFromFile).
    final pending = pendingLaunchImport;
    pendingLaunchImport = null;
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // Cold-launch deeplink: the payload came from OUTSIDE the app (a clicked
        // link / "Open with"), so it's untrusted — preview-gate before connect.
        // Same file-vs-content routing as the warm-start path above.
        if (!pending.contains('://') && File(pending).existsSync()) {
          await importFromFile(context, ref, pending, trusted: false);
        } else {
          await importDroppedContent(context, ref, utf8.encode(pending),
              trusted: false);
        }
      });
    } else {
      // No cold-launch import: peek the clipboard once so a freshly-copied server
      // link surfaces as a one-tap Home banner. The first-run TUN-vs-proxy chooser
      // is DEFERRED to AFTER the first successful connect (see build()'s listener),
      // so a newcomer isn't asked a security question before they even have a
      // server — they connect on the safe default first, then get the upgrade offer.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) peekClipboardForImport(ref);
      });
    }
    // Seed the tray menu label + tooltip once the first frame + l10n are ready
    // (the ref.listen below only fires on subsequent changes; prev==null skips
    // the launch balloon).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pushTrayLabels();
      _pushTrayState(null, ref.read(coreControllerProvider));
    });
  }

  // Tray "Connect/Disconnect": toggle on the spot — never pop the window or ask
  // for a normal node. The ONE exception is the H5 safety gate: an insecure
  // (cert-unvalidated, MITM-able) node the user has NEVER confirmed in-app must
  // not be silently connected from the tray. We don't pop a dialog (the user
  // dislikes that on the tray) — we refuse with a balloon so the one-time consent
  // is given in-app; every safe / already-confirmed node connects instantly.
  Future<void> _handleTrayToggle() async {
    final core = ref.read(coreControllerProvider);
    if (!core.isOn) {
      final p = ref.read(profilesProvider);
      // Resolve the SAME node start() will connect: selectedNode falls back to
      // nodes.first when `selected` is null/stale (profiles_controller). The old
      // manual tag loop had no such fallback, so a dangling selection left `sel`
      // null and the H5 gate below was skipped while start() still connected the
      // (possibly insecure) first node — a consent bypass.
      final sel = p.selectedNode;
      final accepted = ref.read(settingsProvider).insecureAccepted;
      // Consent is stored under insecureKey (content hash) EVERYWHERE else
      // (connect_button, profiles_sheet, activity_page) — never the display tag.
      // Keying off sel.tag made this gate always-false → an already-consented
      // insecure node could never be connected from the tray.
      if (sel != null && sel.insecure && !accepted.contains(sel.insecureKey)) {
        // Surface the window so the one-time in-app consent is actually reachable
        // — a balloon alone leaves a tray-hidden user with nowhere to confirm.
        await NativeAdmin.showWindow();
        if (mounted) {
          final l = AppLocalizations.of(context);
          await NativeAdmin.showTrayNotification(
              title: l.trayConnect, message: l.trayInsecureHint);
        }
        return;
      }
    }
    try {
      await ref.read(coreControllerProvider.notifier).toggle();
    } catch (_) {}
  }

  // Push the localized, state-aware tray labels to the native menu.
  void _pushTrayLabels() {
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    final status = ref.read(coreControllerProvider).status;
    final isOn =
        status == CoreStatus.running || status == CoreStatus.starting;
    NativeAdmin.setTrayLabels(
      toggle: isOn ? l.trayDisconnect : l.trayConnect,
      show: l.trayShow,
      quit: l.trayQuit,
    );
  }

  // Make the tray INFORMATIVE: keep the icon tooltip on the live state, and pop a
  // balloon on a real status change (connected / disconnected / error with the
  // core's detail) — the only feedback when you act from the tray with the window
  // hidden. The native side suppresses the balloon while the window is visible.
  void _pushTrayState(CoreState? prev, CoreState next) {
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    final label = switch (next.status) {
      CoreStatus.running => l.statusConnected,
      CoreStatus.starting => l.statusConnecting,
      CoreStatus.stopping => l.statusDisconnecting,
      CoreStatus.error => l.statusError,
      CoreStatus.stopped => l.statusDisconnected,
    };
    // Show the live in-tunnel ping next to "Connected" so a hidden-to-tray user
    // sees state + latency at a glance (re-pushed on each ping tick by the
    // latencyProvider listener in build()).
    final ms = next.status == CoreStatus.running
        ? ref.read(latencyProvider).value
        : null;
    NativeAdmin.setTrayTooltip(
        '${l.appTitle} — $label${ms != null ? ' · $ms ms' : ''}');
    // No balloon on the initial seed (prev == null) or when status didn't change.
    if (prev == null || prev.status == next.status) return;
    switch (next.status) {
      case CoreStatus.running:
        NativeAdmin.showTrayNotification(
            title: l.appTitle, message: l.statusConnected);
      case CoreStatus.error:
        final d = next.detail?.trim();
        NativeAdmin.showTrayNotification(
            title: l.appTitle,
            message: (d != null && d.isNotEmpty) ? d : l.statusError);
      case CoreStatus.stopped:
        NativeAdmin.showTrayNotification(
            title: l.appTitle, message: l.statusDisconnected);
      case CoreStatus.starting:
      case CoreStatus.stopping:
        break; // transient — the tooltip is enough, no balloon spam
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the tray live: on a real status change, refresh the menu label AND the
    // tooltip + balloon (so a tray-initiated connect/disconnect/error is never
    // silent). Locale change re-pushes the labels.
    ref.listen(coreControllerProvider, (prev, next) {
      if (prev?.status == next.status) return;
      _pushTrayLabels();
      _pushTrayState(prev, next);
    });
    // Keep the tray tooltip's live ping fresh while connected: the status doesn't
    // change but the latency ticks — re-push the tooltip (same status → no balloon).
    ref.listen(latencyProvider, (_, _) {
      final s = ref.read(coreControllerProvider);
      if (s.status == CoreStatus.running) _pushTrayState(s, s);
    });
    ref.listen(settingsProvider.select((s) => s.localeCode),
        (_, _) => _pushTrayLabels());
    // Deferred first-run: offer the TUN-vs-proxy upgrade AFTER the first successful
    // connect (not before the user even has a server). One-time — completeSetup()
    // flips seenSetup so it never re-fires.
    ref.listen(coreControllerProvider.select((s) => s.isOn), (prev, next) {
      if (next == true &&
          prev != true &&
          !_setupShown &&
          !ref.read(settingsProvider).seenSetup) {
        _setupShown = true; // latch synchronously, before the await window opens
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (mounted && !ref.read(settingsProvider).seenSetup) {
            await showFirstRunSetup(context, ref);
          }
        });
      }
    });
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: GlassBackground()),
          // Content fills to the bottom edge so scrollable pages slide UNDER the
          // floating nav (each page keeps its own bottom inset so nothing is
          // trapped behind the bar).
          SafeArea(
            bottom: false,
            child: IndexedStack(
              index: _index,
              children: const [
                HomePage(),
                ActivityPage(),
                SettingsPage(),
              ],
            ),
          ),
          // "Blur on top": a frosted scrim above the floating nav. Scrolling
          // content dissolves into blur as it slides under the bar — the blur
          // ramps up via a gradient mask instead of starting on a hard edge, and
          // the bar's own BackdropFilter finishes the frost.
          Positioned(
            left: 0,
            right: 0,
            bottom: 60,
            height: 76,
            child: IgnorePointer(
              child: ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black],
                  stops: [0.0, 0.72],
                ).createShader(r),
                blendMode: BlendMode.dstIn,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          // The nav lives INSIDE the stack (over the aurora) so its BackdropFilter
          // frosts the gradient — not the scaffold's black behind a bottom bar.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _GlassNav(
              index: _index,
              onTap: (i) {
                setState(() => _index = i);
                // Let the Activity-only pollers know which tab is visible so
                // they can pause when it isn't.
                ref.read(navIndexProvider.notifier).state = i;
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen frosted overlay shown while a file is dragged over the window.
class _DragOverlay extends StatelessWidget {
  const _DragOverlay();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    return Positioned.fill(
      child: Material(
        type: MaterialType.transparency,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              color: Colors.black.withValues(alpha: 0.10),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // Match the PageHeader chip alphas (0.14 fill / 0.30 border)
                      // so the drag badge reads as the same designed accent.
                      color: scheme.primary.withValues(alpha: 0.14),
                      border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.30)),
                    ),
                    child: Icon(Icons.file_download_rounded,
                        size: 52, color: scheme.primary),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    l.dropToImport,
                    style: TextStyle(
                        fontSize: AppTheme.tsHeading,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                        decoration: TextDecoration.none),
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

class _GlassNav extends StatefulWidget {
  const _GlassNav({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  @override
  State<_GlassNav> createState() => _GlassNavState();
}

class _GlassNavState extends State<_GlassNav> {
  static const List<IconData> _icons = [
    // Home = a shield (the product is protection), NOT the power glyph — that one
    // is the big Connect button, and sharing it made the Home tab read as "connect".
    Icons.shield_rounded,
    Icons.insights_rounded,
    Icons.settings_rounded,
  ];

  double? _dragPos; // continuous pill position [0, n-1] while dragging
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final labels = [l.navHome, l.navActivity, l.navSettings];
    final n = _icons.length;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: 12 + MediaQuery.of(context).padding.bottom,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.06),
                  Colors.white.withValues(alpha: 0.015),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: LayoutBuilder(
              builder: (context, c) {
                final itemW = c.maxWidth / n;
                final pos = _dragPos ?? widget.index.toDouble();
                final alignX = n == 1 ? 0.0 : (pos / (n - 1)) * 2 - 1;
                final activeIndex =
                    (_dragPos?.round() ?? widget.index).clamp(0, n - 1);

                double posFromDx(double dx) =>
                    (dx / itemW - 0.5).clamp(0.0, (n - 1).toDouble());

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    final i =
                        (d.localPosition.dx / itemW).floor().clamp(0, n - 1);
                    widget.onTap(i);
                  },
                  onHorizontalDragStart: (d) => setState(() {
                    _pressed = true;
                    _dragPos = posFromDx(d.localPosition.dx);
                  }),
                  onHorizontalDragUpdate: (d) => setState(() {
                    _dragPos = posFromDx(d.localPosition.dx);
                  }),
                  onHorizontalDragEnd: (_) {
                    final target = (_dragPos ?? widget.index.toDouble())
                        .round()
                        .clamp(0, n - 1);
                    setState(() {
                      _pressed = false;
                      _dragPos = null;
                    });
                    widget.onTap(target);
                  },
                  child: Stack(
                    children: [
                      // Single draggable pill: follows the finger, springs on tap.
                      AnimatedAlign(
                        duration: _dragPos == null
                            ? const Duration(milliseconds: 380)
                            : Duration.zero,
                        curve: Curves.easeOutBack,
                        alignment: Alignment(alignX, 0),
                        child: FractionallySizedBox(
                          widthFactor: 1 / n,
                          heightFactor: 1,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: AnimatedScale(
                              scale: _pressed ? 1.10 : 1.0,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOut,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: scheme.primary.withValues(alpha: 0.22),
                                  borderRadius:
                                      BorderRadius.circular(AppTheme.rCard),
                                  border: Border.all(
                                      color: scheme.primary
                                          .withValues(alpha: 0.45)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: List.generate(n, (i) {
                          final selected = i == activeIndex;
                          final color = selected
                              ? scheme.primary
                              : scheme.onSurface.withValues(alpha: 0.55);
                          // Per-tab semantics: each tab announces as a selectable
                          // button with its localized label + selected state, and
                          // exposes a tap action to assistive tech (the parent
                          // GestureDetector still owns the real tap/drag routing).
                          // excludeSemantics avoids double-announcing the visual
                          // label below.
                          return Expanded(
                            child: Semantics(
                              button: true,
                              selected: selected,
                              label: labels[i],
                              excludeSemantics: true,
                              onTap: () => widget.onTap(i),
                              child: IgnorePointer(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(_icons[i], size: 22, color: color),
                                    const SizedBox(height: 2),
                                    Text(labels[i],
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                            fontSize: AppTheme.tsLabel,
                                            color: selected
                                                ? color
                                                : scheme.onSurface.withValues(
                                                    alpha: 0.70),
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w500)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
