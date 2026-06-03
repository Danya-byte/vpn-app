import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/proxy_node.dart';
import '../../../widgets/glass.dart';

/// Show a profile's underlying sing-box config / outbound as formatted JSON.
void showConfigViewer(BuildContext context, ParsedNode node) {
  showGlassDialog<void>(context, child: _ConfigViewer(node: node));
}

class _ConfigViewer extends StatelessWidget {
  const _ConfigViewer({required this.node});

  final ParsedNode node;

  @override
  Widget build(BuildContext context) {
    final json = const JsonEncoder.withIndent('  ')
        .convert(node.config ?? node.outbound);
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
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
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
                color: Colors.black.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  json,
                  style: const TextStyle(
                      fontFamily: 'Consolas', fontSize: 11, height: 1.4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
