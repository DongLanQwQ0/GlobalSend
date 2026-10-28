import 'dart:async';

import 'package:flutter/material.dart';

import 'url_intents.dart';
import 'app_icon.dart';

/// Recovery for a system launch whose result was interrupted. This is separate
/// from received messages and never creates a text/file receipt.
class UrlIntentNotice extends StatelessWidget {
  const UrlIntentNotice({
    super.key,
    required this.integration,
    required this.child,
  });
  final UrlIntentIntegration integration;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final pending = integration.needsAttention;
    if (pending.isEmpty) return child;
    final item = pending.first;
    return Stack(
      children: [
        child,
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: SafeArea(
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(16),
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                child: Row(
                  children: [
                    const Expanded(child: Text('网页请求等待打开')),
                    TextButton(
                      onPressed: () =>
                          unawaited(integration.openManually(item)),
                      child: const Text('打开'),
                    ),
                    IconButton(
                      onPressed: () => unawaited(integration.dismiss(item)),
                      icon: const AppIcon(
                        Icons.close,
                        size: 20,
                        semanticLabel: '关闭',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
