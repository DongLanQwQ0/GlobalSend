import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'file_share.dart';
import 'system_bridge.dart';

Future<String?> showContentMenuAt(
  BuildContext context,
  Offset globalPosition,
  List<PopupMenuEntry<String>> items,
) {
  if (items.isEmpty) return Future.value();
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromSize(
      overlay.globalToLocal(globalPosition) & Size.zero,
      overlay.size,
    ),
    items: items,
  );
}

Future<void> copySavedImage(String path) async {
  final copied = defaultTargetPlatform == TargetPlatform.windows
      ? await SystemBridge.copyImage(
          path,
          originDeviceId: '',
          sourceEventId: '',
        )
      : await FileShareBridge.copyReceivedImage(path);
  if (!copied) throw StateError('无法复制图片');
}
