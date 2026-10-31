import 'dart:async';

import 'package:flutter/material.dart';

import 'url_intents.dart';
import 'app_icon.dart';
import 'ui_tokens.dart';

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
          left: Ui.space3,
          right: Ui.space3,
          bottom: Ui.space3,
          child: SafeArea(
            child: Material(
              elevation: Ui.elevationOverlay,
              borderRadius: Ui.cardRadius,
              color: Ui.colors(context).accentSoft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Ui.space3,
                  Ui.space0,
                  Ui.space0,
                  Ui.space0,
                ),
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
