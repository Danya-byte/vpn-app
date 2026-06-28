import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/proxy_node.dart';
import '../../../l10n/app_localizations.dart';
import '../../../widgets/glass.dart';

/// Show a profile's underlying sing-box config / outbound as formatted JSON.
void showConfigViewer(BuildContext context, ParsedNode node) {
  showGlassDialog<void>(context, child: _ConfigViewer(node: node));
}

class _ConfigViewer extends StatefulWidget {
  const _ConfigViewer({required this.node});

  final ParsedNode node;

  @override
  State<_ConfigViewer> createState() => _ConfigViewerState();
}

class _ConfigViewerState extends State<_ConfigViewer> {
  final _hScroll = ScrollController();

  @override
  void dispose() {
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final node = widget.node;
    final source = node.config ?? node.outbound;
    String json;
    if (source.isEmpty) {
      json = '(no config)';
    } else {
      try {
        json = JsonEncoder.withIndent('  ', (o) => o.toString()).convert(source);
      } catch (_) {
        json = source.toString();
      }
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(node.tag,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: AppTheme.tsHeading,
                        fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: l.copy,
                child: GlassCopyButton(text: json),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: l.cancel,
                child: GlassButton(
                  onPressed: () => Navigator.pop(context),
                  padding: const EdgeInsets.all(8),
                  radius: AppTheme.rButton,
                  child: const Icon(Icons.close_rounded, size: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(AppTheme.rPanel),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: SingleChildScrollView(
                child: Scrollbar(
                  controller: _hScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _hScroll,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SelectableText(
                      json,
                      style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 11,
                          height: 1.4,
                          color: scheme.onSurface.withValues(alpha: 0.85)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
