import 'package:flutter/material.dart';

import 'file_share.dart';
import 'ui_tokens.dart';

/// A live provider import is neither a completed attachment nor a send task.
/// Progress comes from committed items, not elapsed time or a fake percentage.
class SharedImportNotice extends StatelessWidget {
  const SharedImportNotice({
    super.key,
    required this.batches,
    required this.child,
  });
  final ValueNotifier<List<SharedBatch>> batches;
  final Widget child;
  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<List<SharedBatch>>(
    valueListenable: batches,
    child: child,
    builder: (context, imports, child) {
      if (imports.isEmpty) return child!;
      final total = imports.fold(0, (n, batch) => n + batch.totalItems);
      final completed = imports.fold(0, (n, batch) => n + batch.completedItems);
      final importing = imports.any((batch) => batch.importing);
      return Stack(
        fit: StackFit.expand,
        children: [
          child!,
          Positioned(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + Ui.space1,
            left: Ui.space3,
            right: Ui.space3,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Material(
                  color: Ui.colors(context).surface,
                  elevation: 4,
                  borderRadius: Ui.cardRadius,
                  child: Padding(
                    padding: const EdgeInsets.all(Ui.space2),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          importing ? '正在导入 $completed/$total 项' : '正在加入待发送',
                          style: const TextStyle(fontSize: Ui.textSm),
                        ),
                        const SizedBox(height: Ui.space1),
                        LinearProgressIndicator(
                          value: importing && total > 0
                              ? completed / total
                              : null,
                          minHeight: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
