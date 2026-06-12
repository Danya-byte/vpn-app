import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'; // StateProvider (Riverpod 3)

import '../../core/cascade.dart' show mitmTagsFromConfig;
import '../../core/clash_api.dart';
import '../../core/app_settings.dart';
import '../../core/core_controller.dart';
import '../../core/native_admin.dart'; // isElevatedProvider, relaunchElevated
import '../../core/diagnostics.dart';
import '../../core/diagnostics_controller.dart';
import '../../core/format.dart';
import '../../core/profiles_controller.dart';
import '../../core/speed_test.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/glass.dart';

class ActivityPage extends ConsumerStatefulWidget {
  const ActivityPage({super.key});

  @override
  ConsumerState<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends ConsumerState<ActivityPage> {
  int _tab = 0; // 0 = connections, 1 = logs

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      // bottom clears the floating nav so the card isn't trapped behind it.
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(icon: Icons.insights_rounded, title: l.navActivity),
          const SizedBox(height: 14),
          const _InfoCard(),
          const SizedBox(height: 12),
          const _SpeedTestCard(),
          const SizedBox(height: 12),
          Row(
            children: [
              // Horizontally scrollable so 4 chips never overflow the narrow window.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _chip(l.tabConnections, 0),
                      const SizedBox(width: 6),
                      _chip(l.tabLogs, 1),
                      const SizedBox(width: 6),
                      _chip(l.diagnostics, 2),
                      const SizedBox(width: 6),
                      _chip(l.policies, 3),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: GlassCard(
              padding: const EdgeInsets.all(12),
              child: switch (_tab) {
                0 => const _ConnectionsView(),
                1 => const _LogsView(),
                2 => const _DiagnosticsView(),
                _ => const _PoliciesView(),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, int index) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _tab == index;
    return GestureDetector(
      onTap: () => setState(() => _tab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.40)
                : Colors.white.withValues(alpha: 0.10),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends ConsumerWidget {
  const _InfoCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final traffic = ref.watch(trafficProvider).value ?? Traffic.zero;
    // Only what matters live: down/up speed, centered, with a small rolling graph.
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _speed(
                context,
                Icons.arrow_downward_rounded,
                l.download,
                traffic.down,
              ),
              Container(
                width: 1,
                height: 38,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              _speed(context, Icons.arrow_upward_rounded, l.upload, traffic.up),
            ],
          ),
          const SizedBox(height: 10),
          const _TrafficSparkline(),
        ],
      ),
    );
  }

  Widget _speed(BuildContext context, IconData icon, String label, int bps) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: scheme.primary),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          fmtRate(bps),
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

/// A rolling 60-sample down/up sparkline over the SAME live trafficProvider — no
/// new data source, just a visual the leading clients have. Subtle (low height +
/// alpha) so it informs without adding clutter. Flatlines to zero when idle.
class _TrafficSparkline extends ConsumerStatefulWidget {
  const _TrafficSparkline();
  @override
  ConsumerState<_TrafficSparkline> createState() => _TrafficSparklineState();
}

class _TrafficSparklineState extends ConsumerState<_TrafficSparkline> {
  final _dn = <int>[];
  final _up = <int>[];
  static const _max = 60;

  @override
  Widget build(BuildContext context) {
    // Append each new sample to the rolling window (the listener fires AFTER this
    // build, on the next stream emission — never setState-during-build).
    ref.listen(trafficProvider, (prev, next) {
      final t = next.value;
      if (t == null || !mounted) return;
      setState(() {
        _dn.add(t.down);
        _up.add(t.up);
        if (_dn.length > _max) _dn.removeAt(0);
        if (_up.length > _max) _up.removeAt(0);
      });
    });
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 26,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparkPainter(
          List.of(_dn),
          List.of(_up),
          scheme.primary,
          const Color(0xFF3B82F6),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.dn, this.up, this.dnColor, this.upColor);
  final List<int> dn, up;
  final Color dnColor, upColor;

  @override
  void paint(Canvas canvas, Size size) {
    var maxV = 1;
    for (final v in dn) {
      if (v > maxV) maxV = v;
    }
    for (final v in up) {
      if (v > maxV) maxV = v;
    }
    void draw(List<int> data, Color color) {
      if (data.length < 2) return;
      final path = Path();
      for (var i = 0; i < data.length; i++) {
        final x = size.width * i / (data.length - 1);
        final y = size.height - (data[i] / maxV) * size.height;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeJoin = StrokeJoin.round,
      );
      final fill = Path.from(path)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..color = color.withValues(alpha: 0.08)
          ..style = PaintingStyle.fill,
      );
    }

    draw(dn, dnColor);
    draw(up, upColor);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true; // tiny paint, new sample each tick
}

/// Real Mbps throughput test through the tunnel — a number neither Hiddify nor
/// Happ surfaces in-GUI (they only show ping + the live byte-counter arrows).
class _SpeedTestCard extends ConsumerWidget {
  const _SpeedTestCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final st = ref.watch(speedTestProvider);
    final connected = ref.watch(coreControllerProvider.select((s) => s.isOn));
    String fmt(double? m) => m == null ? '—' : m.toStringAsFixed(1);

    Widget body;
    if (!connected || st.error == 'not-connected') {
      body = Text(
        l.speedTestConnect,
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSurface.withValues(alpha: 0.55),
        ),
      );
    } else if (st.running) {
      body = Row(
        children: [
          SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            st.phase == SpeedPhase.upload
                ? l.speedTestUploading
                : l.speedTestDownloading,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          if (st.downMbps != null) ...[
            const SizedBox(width: 10),
            _mbps(context, Icons.arrow_downward_rounded, fmt(st.downMbps)),
          ],
        ],
      );
    } else if (st.phase == SpeedPhase.done) {
      body = Row(
        children: [
          _mbps(context, Icons.arrow_downward_rounded, fmt(st.downMbps)),
          const SizedBox(width: 14),
          _mbps(context, Icons.arrow_upward_rounded, fmt(st.upMbps)),
          const SizedBox(width: 5),
          Text(
            'Mbps',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      );
    } else {
      body = Text(
        l.speedTestHint,
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSurface.withValues(alpha: 0.55),
        ),
      );
    }

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.speed_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: body),
          const SizedBox(width: 10),
          GlassButton(
            onPressed: (st.running || !connected)
                ? null
                : () => ref.read(speedTestProvider.notifier).run(),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Text(
              st.phase == SpeedPhase.done ? l.speedTestRetry : l.speedTestRun,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: (st.running || !connected)
                    ? scheme.onSurface.withValues(alpha: 0.3)
                    : scheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mbps(BuildContext context, IconData icon, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: scheme.primary),
        const SizedBox(width: 3),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _LogsView extends ConsumerWidget {
  const _LogsView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final logs = ref.watch(coreControllerProvider.select((s) => s.logs));
    final scheme = Theme.of(context).colorScheme;
    if (logs.isEmpty) {
      return Center(
        child: Text(
          l.empty,
          style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.4)),
        ),
      );
    }
    return Stack(
      children: [
        // Newest line at the TOP; scroll down for older. SelectableText + wrap so
        // a long single-line core error can be read/copied on the narrow window.
        ListView.builder(
          padding: const EdgeInsets.only(
            bottom: 46,
          ), // clear the floating button
          itemCount: logs.length,
          itemBuilder: (_, i) {
            final line = logs[logs.length - 1 - i];
            return SelectableText(
              line,
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontSize: 11,
                height: 1.4,
              ),
            );
          },
        ),
        // Floating copy — bottom-right, clear of the latest logs (at the top).
        const Positioned(right: 0, bottom: 0, child: _FloatingCopyLogs()),
      ],
    );
  }
}

/// Floating copy-logs button that sits inside the logs panel (bottom-right),
/// out of the way of the newest lines at the top.
class _FloatingCopyLogs extends ConsumerWidget {
  const _FloatingCopyLogs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final logs = ref.watch(coreControllerProvider.select((s) => s.logs));
    return Material(
      color: Colors.transparent,
      child: Tooltip(
        message: l.copy,
        child: InkWell(
          borderRadius: BorderRadius.circular(19),
          onTap: logs.isEmpty
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: logs.join('\n')));
                  AppToast.show(context, l.copied);
                },
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.22),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.45)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(Icons.copy_rounded, size: 17, color: scheme.primary),
          ),
        ),
      ),
    );
  }
}

class _ConnectionsView extends ConsumerWidget {
  const _ConnectionsView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final snap =
        ref.watch(connectionsProvider).value ?? ConnectionsSnapshot.empty;
    final conns = snap.connections;
    if (conns.isEmpty) {
      return Center(
        child: Text(
          l.noConnections,
          style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.4)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            children: [
              Text(
                l.connectionsActive(conns.length),
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              const Spacer(),
              Text(
                '↓ ${fmtBytes(snap.downloadTotal)}   ↑ ${fmtBytes(snap.uploadTotal)}',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: conns.length,
            separatorBuilder: (_, _) =>
                Divider(height: 8, color: Colors.white.withValues(alpha: 0.06)),
            itemBuilder: (_, i) {
              final c = conns[i];
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          [
                            c.network,
                            c.chain,
                            c.rule,
                          ].where((s) => s.isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '↓ ${fmtBytes(c.download)}   ↑ ${fmtBytes(c.upload)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Built-in censorship diagnostics: probes RU control sites + RKN-blocked sites
/// DIRECT and (when connected) THROUGH the tunnel, pinpointing the block layer
/// (DNS poison / TLS DPI / reset) and proving the VPN fixes it. No mainstream
/// client offers this in-app.
class _DiagnosticsView extends ConsumerWidget {
  const _DiagnosticsView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final connected = ref.watch(coreControllerProvider.select((s) => s.isOn));
    // The raw server-probe dials the uplink directly to bypass the tunnel — but in
    // TUN mode auto_route captures even the app's own sockets, so a blocked server
    // would falsely read "reachable". Gate it: it's only meaningful disconnected or
    // in system-proxy mode (where the proxy is opt-in, so raw sockets go direct).
    final tunCaptured =
        connected &&
        ref.watch(settingsProvider.select((s) => s.vpnMode)) == VpnMode.tun;
    final diag = ref.watch(diagnosticsControllerProvider);
    final running = diag.running;
    final results = diag.results;
    final wl = results.where((r) => !r.blacklisted).toList();
    final bl = results.where((r) => r.blacklisted).toList();
    final rescued = bl.where((r) => r.tunnelRescued).length;
    // Close the detect→act loop: if the diagnostic found TLS-DPI (exactly what the
    // server-less winws bypass defeats) and that engine is available but off, offer
    // a one-tap enable — instead of leaving the user to find it in settings.
    final offerDesync =
        bl.any((r) => r.direct == BlockVerdict.tlsDpi) &&
        !ref.watch(settingsProvider.select((s) => s.winwsDesync)) &&
        ref.watch(coreControllerProvider.select((s) => s.desyncEngine)) !=
            DesyncEngineStatus.missing;
    // WinDivert needs admin: a one-tap enable while NOT elevated would just land in
    // the needsAdmin state (winws never starts) yet fire a "desync enabled" toast —
    // a lie. When confirmed-not-elevated the card's action becomes "restart as
    // admin" instead. Mirror settings_page: only treat as not-elevated once KNOWN
    // (the FutureProvider is null while resolving), so an elevated process never
    // flashes the relaunch button.
    final elevatedAsync = ref.watch(isElevatedProvider);
    final desyncNeedsAdmin =
        elevatedAsync.hasValue && elevatedAsync.value == false;
    // Everything — the two probe actions included — lives in ONE scroll, so the
    // buttons move up out of the way with the results as you scroll (not pinned).
    return ListView(
      children: [
        SizedBox(
          height: 42,
          child: GlassButton(
            onPressed: running
                ? null
                : () => ref.read(diagnosticsControllerProvider.notifier).run(),
            child: Center(
              child: running
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(l.diagChecking),
                      ],
                    )
                  : Text(l.diagRun),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // "Why won't MY server connect here?" — raw staged probe of the selected
        // server, the companion to the site probe above (the mobile-vs-Wi-Fi case).
        SizedBox(
          height: 42,
          child: GlassButton(
            onPressed: (diag.serverRunning || tunCaptured)
                ? null
                : () => ref
                      .read(diagnosticsControllerProvider.notifier)
                      .runServerProbe(),
            child: Center(
              child: diag.serverRunning
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    )
                  : Text(l.serverDiagRun),
            ),
          ),
        ),
        if (tunCaptured)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              l.serverDiagTunHint,
              style: TextStyle(
                fontSize: 10.5,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (bl.isNotEmpty && connected)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              l.diagRescued(rescued, bl.length),
              style: TextStyle(
                fontSize: 12,
                color: scheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          )
        else if (!connected && results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              l.diagConnectHint,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        if (diag.serverRan) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l.serverDiagHeader.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: scheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                if (diag.serverResults.isNotEmpty)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(text: _serverReport(diag)),
                      );
                      AppToast.of(
                        context,
                      ).message(l.serverDiagCopied, kind: ToastKind.success);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.copy_rounded,
                            size: 12,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            l.serverDiagCopy,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (diag.serverResults.isEmpty && !diag.serverRunning)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                l.serverDiagNone,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          for (final r in diag.serverResults) _ServerDiagRow(r),
          if (diag.serverResults.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
              child: Text(
                l.serverDiagHint,
                style: TextStyle(
                  fontSize: 10.5,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
        ],
        if (wl.isNotEmpty) _header(context, l.diagControls),
        ...wl.map((r) => _DiagRow(r)),
        if (bl.isNotEmpty) _header(context, l.diagBlocked),
        ...bl.map((r) => _DiagRow(r)),
        if (offerDesync) ...[
          const SizedBox(height: 10),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.diagDesyncOfferText,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: scheme.onSurface.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: 10),
                // Centered, soft brand-green CTA (compact).
                Center(
                  child: TgButton(
                    label: desyncNeedsAdmin
                        ? l.restartAsAdmin
                        : l.diagDesyncOfferAction,
                    onPressed: desyncNeedsAdmin
                        ? () => NativeAdmin.relaunchElevated()
                        : () {
                            ref
                                .read(settingsProvider.notifier)
                                .setWinwsDesync(true);
                            // Truthful only on the elevated path: here the
                            // engine WILL engage (on connect). Non-elevated
                            // taps hit the relaunch branch above, not here.
                            AppToast.of(context).message(l.diagDesyncOfferDone);
                          },
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _header(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: scheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow(this.r);

  final SiteResult r;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (String label, Color color) = switch (r.direct) {
      BlockVerdict.ok => (l.vOk, Colors.green),
      BlockVerdict.dnsPoisoned => (l.vDnsPoisoned, Colors.orange),
      BlockVerdict.tlsDpi => (l.vTlsDpi, scheme.error),
      BlockVerdict.tcpReset => (l.vTcpReset, scheme.error),
      BlockVerdict.timeout => (l.vTimeout, Colors.grey),
      BlockVerdict.down => (l.vDown, Colors.grey),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              r.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          _chip(label, color),
          if (r.tunnelOk != null) ...[
            Icon(
              Icons.arrow_right_alt_rounded,
              size: 16,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
            _chip(
              r.tunnelOk! ? l.vOk : '✗',
              r.tunnelOk! ? Colors.green : scheme.error,
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        color: color,
      ),
    ),
  );
}

/// One server-endpoint row of the staged "why won't MY server connect" probe.
class _ServerDiagRow extends StatelessWidget {
  const _ServerDiagRow(this.r);

  final ServerProbeResult r;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (String label, Color color) = switch (r.verdict) {
      // L4 reaches, but the proxy may still be DPI-killed → amber, not green.
      ServerVerdict.reachableL4 => (l.svReachableL4, Colors.orange),
      ServerVerdict.serverBlocked => (l.svServerBlocked, scheme.error),
      ServerVerdict.whitelistCollapse => (l.svWhitelist, scheme.error),
      ServerVerdict.udpInconclusive => (l.svUdpInconclusive, Colors.grey),
      ServerVerdict.dnsInconclusive => (l.svDnsInconclusive, Colors.grey),
      ServerVerdict.offline => (l.svOffline, Colors.grey),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${r.endpoint.host}:${r.endpoint.port}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
          Text(
            r.endpoint.udp ? 'UDP' : 'TCP',
            style: TextStyle(
              fontSize: 9.5,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
          if (r.tcpMs != null) ...[
            const SizedBox(width: 5),
            Text(
              '${r.tcpMs}ms',
              style: TextStyle(
                fontSize: 9.5,
                color: scheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// English technical report of the server diagnostic — for the user to copy and
/// share; it names the failing layer the way a server-side tcpdump would, but
/// entirely client-side.
String _serverReport(DiagnosticsState d) {
  final b = StringBuffer('Server connect diagnostic\n')
    ..writeln(
      'foreign reachable: ${d.serverForeignUp ? "yes" : "NO (whitelist?)"}',
    );
  for (final r in d.serverResults) {
    final e = r.endpoint;
    final v = switch (r.verdict) {
      ServerVerdict.reachableL4 => 'reaches L4 (suspect protocol-level DPI)',
      ServerVerdict.serverBlocked => 'IP/PORT BLOCKED (SYN dropped)',
      ServerVerdict.whitelistCollapse => 'WHITELIST (no foreign reachable)',
      ServerVerdict.udpInconclusive =>
        'UDP/QUIC (inconclusive — mobile throttles UDP/443)',
      ServerVerdict.dnsInconclusive =>
        'DNS inconclusive (DoH blocked; system resolver may answer with a blockpage)',
      ServerVerdict.offline => 'OFFLINE (local network down — not censorship)',
    };
    b.writeln(
      '- ${e.tag} ${e.host}:${e.port} ${e.udp ? "UDP" : "TCP"} -> $v'
      '${r.tcpMs != null ? " (${r.tcpMs}ms)" : ""}',
    );
  }
  return b.toString();
}

/// Optimistic pending pick (group name → member) so the radio moves the INSTANT
/// you tap, instead of waiting for the next ~2s Clash-API poll to confirm.
final _pendingPickProvider = StateProvider<Map<String, String>>((ref) => {});

/// Tags currently being latency-tested (show a spinner on their ping chip).
final _measuringProvider = StateProvider<Set<String>>((ref) => {});

/// Force a fresh latency measurement for [tag] (a node or a URLTest group).
Future<void> _testDelay(WidgetRef ref, String tag) => _testMany(ref, [tag]);

/// Probe many tags SEQUENTIALLY then refresh as each lands. sing-box's urltest
/// probes lazily — on connect only a couple of members carry warm `history`, so
/// the rest show "—" until actively pinged. Sequential on purpose: a dozen
/// simultaneous cold Reality handshakes can stress a live tunnel.
Future<void> _testMany(WidgetRef ref, List<String> tags) async {
  // [ref] is a ConsumerState's WidgetRef and this loop awaits real HTTP probes
  // for up to ~45s, fire-and-forget — the widget can be disposed mid-batch (tab
  // switch / disconnect), after which ref.read THROWS an uncaught StateError in
  // an async gap. Wrap every post-await ref touch; a disposed ref just means
  // nobody is watching the spinners anymore.
  void safeRef(void Function() f) {
    try {
      f();
    } catch (_) {
      /* widget disposed mid-probe — nothing to update */
    }
  }

  final pending = tags
      .where((t) => !ref.read(_measuringProvider).contains(t))
      .toList();
  if (pending.isEmpty) return;
  ref.read(_measuringProvider.notifier).update((s) => {...s, ...pending});
  final api = ref.read(clashApiProvider);
  try {
    for (final t in pending) {
      try {
        await api.delay(t);
      } catch (_) {}
      safeRef(
        () => ref
            .read(_measuringProvider.notifier)
            .update((s) => Set<String>.from(s)..remove(t)),
      );
      // No per-member invalidate (that re-polled + rebuilt the whole policies
      // list a dozen times); the 2 s proxyGroupsProvider poll already surfaces
      // each new `history` progressively, and we force one refresh at the end.
    }
  } finally {
    safeRef(() {
      ref
          .read(_measuringProvider.notifier)
          .update((s) => Set<String>.from(s)..removeAll(pending));
      ref.invalidate(proxyGroupsProvider); // one refresh after the batch
    });
  }
}

/// Test-all "докрутка": ping every member, THEN (for a switchable Selector)
/// auto-switch the live tunnel onto the FASTEST reachable one — the headline
/// "test all & connect fastest" the leading clients have. A URLTest group already
/// auto-picks, so it just reports the fastest. Honors H5: an insecure (cert-off)
/// fastest leaf is NAMED, never silently switched onto (the user taps it, which
/// runs the consent). No-op safe when nothing answers.
Future<void> _testAndPickFastest(
  BuildContext context,
  WidgetRef ref,
  ProxyGroup group,
) async {
  final l = AppLocalizations.of(context);
  final toast = AppToast.of(context);
  await _testMany(ref, group.all);
  if (!context.mounted) return;
  // Fresh per-member delays straight from the API — the /delay calls we just ran
  // updated each member's history.
  final all = await ref.read(clashApiProvider).proxies();
  if (!context.mounted) return;
  final delays = {for (final p in all) p.name: p.delay};
  String? best;
  var bestMs = 1 << 30;
  for (final m in group.all) {
    final d = delays[m];
    if (d != null && d > 0 && d < bestMs) {
      bestMs = d;
      best = m;
    }
  }
  if (best == null) {
    toast.message(l.noReachableServer);
    return;
  }
  final label = l.fastestServer('$best ($bestMs ms)');
  ProxyGroup? cur;
  for (final x in all) {
    if (x.name == group.name) {
      cur = x;
      break;
    }
  }
  // URLTest auto-picks; only a Selector is manually switchable. Already-fastest →
  // just confirm.
  if (group.type != 'Selector' || best == cur?.now) {
    toast.message(label);
    return;
  }
  // H5: never silently move the LIVE tunnel onto an insecure (cert-validation-off)
  // leaf — name it instead so the user taps it (that path asks the MITM consent).
  final selCfg = ref.read(profilesProvider).selectedNode?.config;
  final insecureTags = selCfg != null
      ? mitmTagsFromConfig(selCfg)
      : const <String>{};
  if (insecureTags.contains(best)) {
    toast.message(label);
    return;
  }
  ref
      .read(_pendingPickProvider.notifier)
      .update((m) => {...m, group.name: best!});
  // selectProxy returns false on a non-204 / refused / timed-out switch. If we
  // ignored it the optimistic pending pick would stick forever (the reconcile
  // only clears it once g.now == best, which a failed switch never reaches), so
  // the radio would lie that `best` is live while the core stayed on the old
  // member. Revert the pending pick and tell the user the switch didn't take.
  final ok = await ref.read(clashApiProvider).selectProxy(group.name, best);
  ref.invalidate(proxyGroupsProvider);
  if (ok) {
    toast.message(label);
  } else {
    ref
        .read(_pendingPickProvider.notifier)
        .update((m) => Map<String, String>.from(m)..remove(group.name));
    toast.message(l.noReachableServer);
  }
}

/// Colored latency chip: green <200, amber <500, red beyond; em-dash if unknown.
Widget _pingChip(BuildContext context, int? delay, bool measuring) {
  final scheme = Theme.of(context).colorScheme;
  if (measuring) {
    return SizedBox(
      width: 12,
      height: 12,
      child: CircularProgressIndicator(strokeWidth: 1.6, color: scheme.primary),
    );
  }
  if (delay == null) {
    return Text(
      '—',
      style: TextStyle(
        fontSize: 11,
        color: scheme.onSurface.withValues(alpha: 0.3),
      ),
    );
  }
  final color = delay < 200
      ? const Color(0xFF4ADE80)
      : (delay < 500 ? Colors.orange : scheme.error);
  return Text(
    '$delay ms',
    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
  );
}

/// Hide groups already inside a Selector (switchable there) + the auto-added
/// GLOBAL selector; lead with the Selector (the real switcher). Shared by the
/// live and the disconnected-preview branches.
List<ProxyGroup> _shownGroups(List<ProxyGroup> groups) {
  final inSelector = <String>{};
  for (final g in groups) {
    if (g.type == 'Selector') inSelector.addAll(g.all);
  }
  return groups
      .where(
        (g) =>
            g.name != 'GLOBAL' &&
            (g.type == 'Selector' || !inSelector.contains(g.name)),
      )
      .toList()
    ..sort(
      (a, b) => (a.type == 'Selector' ? 0 : 1).compareTo(
        b.type == 'Selector' ? 0 : 1,
      ),
    );
}

/// Parse a stored config's groups for a STATIC preview when disconnected — so
/// the user can inspect a profile's servers BEFORE connecting. No live `now` or
/// latency (those need the running core's Clash API).
List<ProxyGroup> _staticGroups(Map<String, dynamic> config) {
  final outs = (config['outbounds'] as List?) ?? const [];
  final out = <ProxyGroup>[];
  for (final o in outs) {
    if (o is! Map) continue;
    final type = o['type']?.toString();
    if (type != 'selector' && type != 'urltest') continue;
    final members = ((o['outbounds'] as List?) ?? const [])
        .map((e) => '$e')
        .toList();
    out.add(
      ProxyGroup(
        name: o['tag']?.toString() ?? '',
        type: type == 'selector' ? 'Selector' : 'URLTest',
        now:
            o['default']?.toString() ??
            (members.isNotEmpty ? members.first : null),
        all: members,
        delay: null,
      ),
    );
  }
  return out;
}

/// Live view of the running config's proxy GROUPS (Selector/URLTest) — see the
/// active member of each policy + its latency, tap to switch, tap the chip to
/// re-ping. No mainstream Windows client surfaces this directly.
class _PoliciesView extends ConsumerStatefulWidget {
  const _PoliciesView();

  @override
  ConsumerState<_PoliciesView> createState() => _PoliciesViewState();
}

class _PoliciesViewState extends ConsumerState<_PoliciesView> {
  // Per-connection probe loop. A cold XHTTP/Reality handshake routinely misses
  // the FIRST /delay (the bridge/upstream isn't warm yet) — a ONE-SHOT ping left
  // every non-hysteria leaf stuck on "—" while Hysteria2 (fast QUIC) resolved
  // first try. Retry the still-missing leaves a few bounded rounds: the first
  // probe WARMS the connection, the next one measures it.
  bool _probeStarted = false;
  Timer? _probeTimer;
  int _probeRounds = 0;
  static const _maxProbeRounds = 6; // immediate + ~6×7s ≈ 45s of fill-in

  @override
  void dispose() {
    _probeTimer?.cancel();
    super.dispose();
  }

  void _startProbeLoop() {
    _probeTimer?.cancel();
    _probeRounds = 0;
    _runProbeRound(); // immediate
    _probeTimer = Timer.periodic(
      const Duration(seconds: 7),
      (_) => _runProbeRound(),
    );
  }

  void _runProbeRound() {
    if (!mounted) {
      _probeTimer?.cancel();
      return;
    }
    final groups = ref.read(proxyGroupsProvider).value ?? const [];
    if (groups.isEmpty) {
      // A single simple node / a config with no ≥2-member switchable group never
      // yields groups — without counting these rounds the early return skipped
      // the self-cancel below and the timer ticked for the whole connection.
      if (++_probeRounds > _maxProbeRounds) {
        _probeTimer?.cancel();
        _probeTimer = null;
      }
      return;
    }
    final groupNames = {for (final g in groups) g.name};
    // Member delays keyed by MEMBER tag (carried on each group) — NOT the group
    // name, which is always null for a member and made every member look "missing".
    final delays = <String, int?>{for (final g in groups) ...g.memberDelays};
    final missing = <String>{};
    for (final g in _shownGroups(groups)) {
      for (final m in g.all) {
        // null or non-positive = dead / not-yet-warm (mirrors the alive chip).
        if (!groupNames.contains(m) && (delays[m] ?? 0) <= 0) missing.add(m);
      }
    }
    if (missing.isEmpty || ++_probeRounds > _maxProbeRounds) {
      _probeTimer?.cancel();
      _probeTimer = null;
    }
    if (missing.isNotEmpty) _testMany(ref, missing.toList());
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final connected = ref.watch(coreControllerProvider.select((s) => s.isOn));
    final groups = ref.watch(proxyGroupsProvider).value ?? const [];
    if (!connected) {
      _probeStarted = false; // restart the probe loop on the next connection
      _probeTimer?.cancel();
      _probeTimer = null;
      // Static preview: if a multi-group config profile is selected, show its
      // groups/servers READ-ONLY so the user can inspect them BEFORE connecting
      // (no live latency/switching — those need the running core's Clash API).
      final node = ref.watch(profilesProvider.select((p) => p.selectedNode));
      final cfg = node?.config;
      final preview = cfg != null
          ? _shownGroups(_staticGroups(cfg))
          : const <ProxyGroup>[];
      if (preview.isEmpty) {
        return Center(
          child: Text(
            l.diagConnectHint,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.6)),
          ),
        );
      }
      return ListView(
        children: [
          _PreviewBanner(text: l.policiesPreview),
          for (final g in preview)
            _GroupCard(group: g, delays: const {}, preview: true),
        ],
      );
    }
    if (groups.isEmpty) {
      return Center(
        child: Text(
          l.policiesEmpty,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    // Reconcile optimistic picks: once the core's real `now` matches the pending
    // value (or the member vanished), drop it — else it permanently shadows the
    // truth and the radio lies after an auto-hop/restart moved the selector.
    final pending = ref.read(_pendingPickProvider);
    if (pending.isNotEmpty) {
      final stale = <String>[];
      for (final e in pending.entries) {
        ProxyGroup? g;
        for (final x in groups) {
          if (x.name == e.key) {
            g = x;
            break;
          }
        }
        if (g == null || g.now == e.value || !g.all.contains(e.value)) {
          stale.add(e.key);
        }
      }
      if (stale.isNotEmpty) {
        Future.microtask(() {
          ref.read(_pendingPickProvider.notifier).update((m) {
            final n = Map<String, String>.from(m);
            for (final k in stale) {
              n.remove(k);
            }
            return n;
          });
        });
      }
    }
    final shown = _shownGroups(groups);
    // Start the bounded retry probe-loop once per connection so EVERY leaf's chip
    // fills in (not just the fast-handshake ones) — retrying cold XHTTP/Reality
    // leaves that miss the first /delay, instead of the old one-shot.
    if (!_probeStarted) {
      _probeStarted = true;
      Future.microtask(_startProbeLoop);
    }
    // Insecure (cert-validation-off) leaf members of the RUNNING config. Switching
    // the LIVE tunnel onto one here must pass the SAME MITM consent the Connect
    // button + profiles list enforce — else the Policies switcher silently
    // bypasses H5.
    final selCfg = ref
        .watch(profilesProvider.select((p) => p.selectedNode))
        ?.config;
    final insecure = selCfg != null
        ? mitmTagsFromConfig(selCfg)
        : const <String>{};
    return ListView(
      children: [
        for (final g in shown)
          // Pass the group's OWN member-tag→delay map (keyed by leaf tag) so the
          // pool-health chip counts the live members, not the group name.
          _GroupCard(group: g, delays: g.memberDelays, insecure: insecure),
      ],
    );
  }
}

/// ③ — "X of Y alive" pool-health badge. Green when every member answers, amber
/// when some are dark, red when the whole pool is dead (the moment to import a
/// fresh subscription). Tooltip names it for accessibility.
class _AliveChip extends StatelessWidget {
  const _AliveChip({
    required this.alive,
    required this.total,
    this.measuring = false,
  });

  final int alive;
  final int total;
  // The pool is still being probed (its members are in _measuringProvider) — show
  // a neutral "measuring" chip instead of flashing a red "0/N" before pings land.
  final bool measuring;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = measuring
        ? scheme.onSurface.withValues(alpha: 0.45)
        : (alive == 0
              ? scheme.error
              : (alive == total ? const Color(0xFF4ADE80) : Colors.orange));
    return Tooltip(
      message: AppLocalizations.of(context).policyAlive,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.monitor_heart_outlined, size: 11, color: color),
            const SizedBox(width: 3),
            Text(
              measuring ? '…/$total' : '$alive/$total',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupCard extends ConsumerWidget {
  const _GroupCard({
    required this.group,
    required this.delays,
    this.insecure = const {},
    this.preview = false,
  });

  final ProxyGroup group;
  final Map<String, int?> delays;
  final Set<String>
  insecure; // leaf members that need MITM consent to switch onto
  final bool preview; // disconnected static preview: no switch/ping actions

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isAuto = group.type == 'URLTest';
    // Optimistic: show the just-tapped member as active immediately.
    final now = ref.watch(_pendingPickProvider)[group.name] ?? group.now;
    // ③ pool-health at a glance: how many members answered the 204-through-proxy
    // probe (alive) vs total. Surfaces silent node death — the #1 churn driver —
    // without the user pinging each one. A positive warm delay == alive; null/0 ==
    // dead or not-yet-probed (the one-shot auto-ping fills these in on open).
    final total = group.all.length;
    final alive = group.all.where((m) => (delays[m] ?? 0) > 0).length;
    // While the one-shot auto-ping is still in flight, the chip would otherwise
    // count unprobed members as dead and flash red "0/N" — show neutral instead.
    final measuringSet = ref.watch(_measuringProvider);
    final measuring = group.all.any(measuringSet.contains);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isAuto ? l.policyAuto : group.type,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              if (!preview && total > 1) ...[
                const SizedBox(width: 6),
                _AliveChip(alive: alive, total: total, measuring: measuring),
              ],
              const Spacer(),
              // Ping every member (fan out the warm /delay probes). Hidden in the
              // disconnected preview — there's no core to probe against.
              if (!preview)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    // Test all members, then switch onto the fastest (Selector).
                    onTap: () => _testAndPickFastest(context, ref, group),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.bolt_rounded,
                            size: 13,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            l.policyTestAll,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          // Only a Selector accepts manual switching; URLTest auto-picks by
          // latency (sing-box rejects a manual PUT on it), so it's read-only —
          // but every member still shows + can be re-pinged. In preview nothing
          // is switchable/pingable (no live core).
          for (final m in group.all)
            _MemberRow(
              group: group.name,
              member: m,
              selected: m == now,
              switchable: group.type == 'Selector' && !preview,
              delay: delays[m],
              insecure: insecure.contains(m),
              preview: preview,
            ),
        ],
      ),
    );
  }
}

class _MemberRow extends ConsumerWidget {
  const _MemberRow({
    required this.group,
    required this.member,
    required this.selected,
    required this.switchable,
    required this.delay,
    this.insecure = false,
    this.preview = false,
  });

  final String group;
  final String member;
  final bool selected;
  final bool switchable;
  final int? delay;
  final bool
  insecure; // cert-validation-off leaf → consent before switching onto it
  final bool preview; // disconnected: no ping-tap, no switch

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final measuring = ref.watch(_measuringProvider).contains(member);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          // Tapping the active member is a no-op; tapping another switches it
          // (Selector only — URLTest is auto, so non-tappable).
          onTap: (selected || !switchable)
              ? null
              : () async {
                  final toast = AppToast.of(context); // capture before await
                  final l = AppLocalizations.of(context);
                  // Switching the LIVE tunnel onto an insecure (cert-validation-off)
                  // member is a MITM exposure — ask first, the SAME consent the
                  // Connect button + profiles list enforce (H5). Gate BEFORE the
                  // optimistic pick so a decline doesn't flash the radio.
                  // Key the consent on the node's STABLE content key (not the
                  // renameable/rotatable member tag) so a rotated subscription exit
                  // re-asks — matching connect_button/profiles. Fall back to a
                  // member-scoped key for config-internal members with no top node.
                  var insKey = 'member:$member';
                  for (final n in ref.read(profilesProvider).nodes) {
                    if (n.tag == member) {
                      insKey = n.insecureKey;
                      break;
                    }
                  }
                  if (insecure &&
                      !ref
                          .read(settingsProvider)
                          .insecureAccepted
                          .contains(insKey)) {
                    final consent = await showGlassDialog<bool>(
                      context,
                      child: _ConfirmDialog(
                        message: l.insecureConnectBody,
                        confirmLabel: l.insecureConnectAction,
                      ),
                    );
                    if (consent != true) return;
                    ref.read(settingsProvider.notifier).acceptInsecure(insKey);
                  }
                  // Optimistic: move the radio NOW, don't wait for the poll.
                  ref
                      .read(_pendingPickProvider.notifier)
                      .update((m) => {...m, group: member});
                  final ok = await ref
                      .read(clashApiProvider)
                      .selectProxy(group, member);
                  ref.invalidate(proxyGroupsProvider); // confirm from the core
                  if (ok) {
                    toast.message(
                      l.switchedTo(member),
                      kind: ToastKind.success,
                    );
                  } else {
                    // revert the optimistic pick if the core refused it
                    ref
                        .read(_pendingPickProvider.notifier)
                        .update(
                          (m) => Map<String, String>.from(m)..remove(group),
                        );
                  }
                },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: selected
                      ? scheme.primary
                      : scheme.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    member,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Latency chip — tap to re-ping just this member (no-op in the
                // disconnected preview: there's no core to probe).
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: preview ? null : () => _testDelay(ref, member),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: _pingChip(context, delay, measuring),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner shown above the disconnected static preview — clarifies the groups are
/// read-only until you connect.
class _PreviewBanner extends StatelessWidget {
  const _PreviewBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.visibility_outlined, size: 15, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                color: scheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Consent dialog for a risky switch (onto an insecure, cert-validation-off
/// member). Mirrors the profiles list's consent so the Policies switcher can't
/// bypass the H5 MITM gate.
class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({required this.message, required this.confirmLabel});

  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            message,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(backgroundColor: scheme.error),
                child: Text(confirmLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
