import 'dart:convert';
import 'dart:io' show File;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_settings.dart';
import '../../core/core_controller.dart';
import '../../core/deeplink.dart';
import '../../core/native_admin.dart';
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

  @override
  void dispose() {
    _hideDragOverlay();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _dropChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onFile':
          _hideDragOverlay();
          if (mounted) {
            // A dropped / "Open with" file is an EXTERNAL source — preview-gate.
            await importFromFile(context, ref, call.arguments as String,
                trusted: false);
          }
        case 'onContent':
          _hideDragOverlay();
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
    const MethodChannel('app/system').setMethodCallHandler((call) async {
      switch (call.method) {
        case 'networkChanged':
          ref.read(coreControllerProvider.notifier).onNetworkChanged();
        case 'resumed':
          ref.read(coreControllerProvider.notifier).onResumed();
          // Window regained focus — the user may have just copied a server link.
          peekClipboardForImport(ref);
        case 'deeplink':
          // Warm-start: a second instance forwarded a clicked link/file (native
          // WM_COPYDATA). Same untrusted path as a cold-launch deeplink.
          final payload = call.arguments as String?;
          final p = payload == null ? null : importablePayload(payload);
          if (p != null && mounted) {
            // File ONLY when the payload IS an existing file ("Open with") —
            // an unwrapped opaque blob (base64 subscription) has no '://' either
            // and must go down the CONTENT path, not File().readAsBytes().
            if (!p.contains('://') && File(p).existsSync()) {
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
  }

  @override
  Widget build(BuildContext context) {
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
                      color: scheme.primary.withValues(alpha: 0.18),
                      border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.5)),
                    ),
                    child: Icon(Icons.file_download_rounded,
                        size: 52, color: scheme.primary),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    l.dropToImport,
                    style: TextStyle(
                        fontSize: 17,
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
                                  borderRadius: BorderRadius.circular(22),
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
                          return Expanded(
                            child: IgnorePointer(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(_icons[i], size: 22, color: color),
                                  const SizedBox(height: 2),
                                  Text(labels[i],
                                      style: TextStyle(
                                          fontSize: 10.5,
                                          color: color,
                                          fontWeight: selected
                                              ? FontWeight.w700
                                              : FontWeight.w500)),
                                ],
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
