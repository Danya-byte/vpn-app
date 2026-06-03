import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/profiles_controller.dart';
import '../../../core/server_gen.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/glass.dart';

/// "Create your own node": generate a VLESS+Reality server (clean own IP,
/// fronted by a real allowlisted SNI) + the matching client profile + a
/// one-paste VPS setup script. The differentiator no mainstream GUI has.
void showServerGenSheet(BuildContext context, WidgetRef ref) {
  showGlassSheet<void>(context, child: _ServerGenSheet(ref: ref));
}

class _ServerGenSheet extends StatefulWidget {
  const _ServerGenSheet({required this.ref});

  final WidgetRef ref;

  @override
  State<_ServerGenSheet> createState() => _ServerGenSheetState();
}

class _ServerGenSheetState extends State<_ServerGenSheet> {
  bool _chain = false; // single node vs domestic-relay chain (2 VPS)
  final _ip = TextEditingController(); // single-node / relay IP
  final _exitIp = TextEditingController(); // chain exit IP
  String _sni = ServerGen.stealSnis.first;
  String _relaySni = ServerGen.ruFrontSnis.first;
  bool _busy = false;
  ServerBundle? _bundle;
  RelayChainBundle? _chainBundle;

  @override
  void dispose() {
    _ip.dispose();
    _exitIp.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    final toast = AppToast.of(context);
    final ip = _ip.text.trim();
    final exitIp = _exitIp.text.trim();
    if (!_validHost(ip) || (_chain && !_validHost(exitIp))) {
      toast.message(l.serverGenInvalidIp);
      return;
    }
    setState(() => _busy = true);
    ServerBundle? b;
    RelayChainBundle? c;
    try {
      if (_chain) {
        c = await ServerGen.relayChain(
            relayIp: ip, exitIp: exitIp, relaySni: _relaySni, exitSni: _sni);
      } else {
        b = await ServerGen.reality(serverIp: ip, sni: _sni);
      }
    } catch (_) {/* surfaced below */}
    if (!mounted) return;
    setState(() {
      _busy = false;
      _bundle = b;
      _chainBundle = c;
    });
    // The differentiator feature must never just silently reset the button.
    if ((_chain && c == null) || (!_chain && b == null)) {
      toast.message(l.serverGenFailed);
    }
  }

  // Accept an IPv4 address or a DNS hostname (some VPS hand out a name).
  static bool _validHost(String s) {
    if (s.isEmpty) return false;
    if (RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(s)) {
      return s.split('.').every((o) {
        final n = int.tryParse(o);
        return n != null && n >= 0 && n <= 255;
      });
    }
    return RegExp(r'^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$').hasMatch(s);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    final b = _bundle;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 10,
        bottom: 18 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(l.createOwnNode,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              l.serverGenDesc,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 14),
            // Mode: a single node, or a 2-VPS domestic-relay chain.
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, label: Text(l.createOwnNode)),
                  ButtonSegment(
                      value: true, label: Text(l.serverGenChainToggle)),
                ],
                selected: {_chain},
                onSelectionChanged: (s) => setState(() => _chain = s.first),
              ),
            ),
            if (_chain) ...[
              const SizedBox(height: 8),
              Text(l.serverGenChainDesc,
                  style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.6))),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _ip,
              keyboardType: TextInputType.url,
              decoration: glassInputDecoration(
                  context, _chain ? l.serverGenRelayIp : l.serverGenIp),
            ),
            if (_chain) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _exitIp,
                keyboardType: TextInputType.url,
                decoration: glassInputDecoration(context, l.serverGenExitIp),
              ),
              const SizedBox(height: 10),
              _sniDropdown(context, _relaySni, ServerGen.ruFrontSnis,
                  (v) => setState(() => _relaySni = v)),
            ],
            const SizedBox(height: 10),
            _sniDropdown(context, _sni, ServerGen.stealSnis,
                (v) => setState(() => _sni = v)),
            const SizedBox(height: 12),
            GlassButton(
              onPressed: _busy ? null : _generate,
              child: Center(
                child: _busy
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: scheme.primary),
                          ),
                          const SizedBox(width: 10),
                          Text(l.generating),
                        ],
                      )
                    : Text(l.generate),
              ),
            ),
            if (!_chain && b != null) ...[
              const SizedBox(height: 16),
              _output(context, l.serverGenStep1, b.setupScript),
              const SizedBox(height: 12),
              GlassButton(
                onPressed: () {
                  final toast = AppToast.of(context);
                  widget.ref
                      .read(profilesProvider.notifier)
                      .importText(b.allLinks, selectFirst: true);
                  Navigator.pop(context);
                  toast.message(l.serverGenAdded);
                },
                child: Center(child: Text(l.serverGenStep2)),
              ),
            ],
            if (_chain && _chainBundle != null) ...[
              const SizedBox(height: 16),
              _output(context, l.serverGenRelayScript,
                  _chainBundle!.relaySetupScript),
              const SizedBox(height: 12),
              _output(
                  context, l.serverGenExitScript, _chainBundle!.exitSetupScript),
              const SizedBox(height: 12),
              GlassButton(
                onPressed: () {
                  final toast = AppToast.of(context);
                  widget.ref
                      .read(profilesProvider.notifier)
                      .importText(_chainBundle!.clientConfigJson,
                          selectFirst: true);
                  Navigator.pop(context);
                  toast.message(l.serverGenChainAdded);
                },
                child: Center(child: Text(l.serverGenStep2)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sniDropdown(BuildContext context, String value, List<String> options,
      ValueChanged<String> onChanged) {
    final l = AppLocalizations.of(context);
    return GlassDropdown<String>(
      value: value,
      items: options,
      labelOf: (s) => l.serverGenMasquerade(s),
      onChanged: onChanged,
    );
  }

  Widget _output(BuildContext context, String title, String content) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13))),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.copy_rounded, size: 18, color: scheme.primary),
              onPressed: () => Clipboard.setData(ClipboardData(text: content)),
            ),
          ],
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 150),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: SingleChildScrollView(
              child: SelectableText(content,
                  style:
                      const TextStyle(fontFamily: 'Consolas', fontSize: 10.5)),
            ),
          ),
        ),
      ],
    );
  }
}
