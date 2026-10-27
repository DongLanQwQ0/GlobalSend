import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'content_drag_surface.dart';
import 'file_share.dart';
import 'models.dart';
import 'system_bridge.dart';
import 'ui_tokens.dart';

/// Flutter's in-window drop retains the same batch as the native file export.
class BulkFileEntry extends DockEntry {
  BulkFileEntry(this.paths)
    : super(
        id: 'bulk-file-drag',
        kind: 'file',
        title: '${paths.length} 个文件',
        source: '',
        localPath: paths.first,
      );
  final List<String> paths;
}

/// A drag affordance, not an action that opens another menu.
class BulkFileDrag extends StatelessWidget {
  const BulkFileDrag({
    super.key,
    required this.paths,
    this.enabled = true,
    this.onError,
  });
  final List<String> paths;
  final bool enabled;
  final void Function(Object)? onError;

  @override
  Widget build(BuildContext context) {
    final files = paths.where((path) => path.isNotEmpty).toSet().toList();
    if (files.isEmpty || !enabled) return const SizedBox.shrink();
    final handle = Tooltip(
      message: '全部拖拽',
      triggerMode: TooltipTriggerMode.manual,
      child: Semantics(
        label: '全部拖拽',
        child: Theme.of(context).platform == TargetPlatform.windows
            ? const SizedBox.square(
                dimension: 44,
                child: Center(
                  child: AppIcon(
                    Icons.drag_indicator,
                    size: 20,
                    color: Ui.green,
                  ),
                ),
              )
            : BulkDragHandle(paths: files, size: 44, onError: onError),
      ),
    );
    if (Theme.of(context).platform != TargetPlatform.windows) return handle;
    return ContentDragSurface(
      entry: BulkFileEntry(files),
      itemCount: files.length,
      onExport: (kind) async {
        try {
          await SystemBridge.exportFiles(files, pointerKind: kind);
        } catch (error) {
          onError?.call(error);
        }
      },
      child: handle,
    );
  }
}
