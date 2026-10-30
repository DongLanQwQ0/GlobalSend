import 'app_icon.dart';

import 'dart:io';
import 'dart:math' as math;
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'received_file_access.dart';
import 'image_kind.dart';
import 'ui_tokens.dart';

bool isSavedImage(String path) => knownImageName(path);

Future<bool> showSavedImagePreview(
  BuildContext context, {
  required String path,
  required String title,
}) async {
  if (!await imageAtLocation(path, title)) return false;
  if (!context.mounted) return true;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SavedImagePreview(path: path, title: title),
    ),
  );
  return true;
}

class SavedImagePreview extends StatefulWidget {
  const SavedImagePreview({
    super.key,
    required this.path,
    required this.title,
    this.onOpenExternal,
  });
  final String path, title;
  final Future<void> Function()? onOpenExternal;
  @override
  State<SavedImagePreview> createState() => _SavedImagePreviewState();
}

class _SavedImagePreviewState extends State<SavedImagePreview> {
  final transform = TransformationController();
  Size viewport = Size.zero;
  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  void zoom(double factor) {
    final current = transform.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(.5, 8.0);
    final center = viewport.center(Offset.zero);
    final scene = transform.toScene(center);
    final ratio = next / current;
    final matrix = transform.value.clone()
      ..scaleByDouble(ratio, ratio, ratio, 1);
    final moved = MatrixUtils.transformPoint(matrix, scene);
    // Buttons use the viewport center; InteractiveViewer uses the actual
    // gesture focal point. Both matrices share the child's top-left origin.
    // Match the viewer's half-viewport boundary margin at the new scale.
    matrix.setTranslationRaw(
      (matrix.storage[12] + center.dx - moved.dx).clamp(
        viewport.width * (1 - 1.5 * next),
        viewport.width * .5 * next,
      ),
      (matrix.storage[13] + center.dy - moved.dy).clamp(
        viewport.height * (1 - 1.5 * next),
        viewport.height * .5 * next,
      ),
      0,
    );
    transform.value = matrix;
  }

  Future<void> openExternal() async {
    try {
      await (widget.onOpenExternal?.call() ??
          ReceivedFileAccess.openExternal(widget.path));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: '用其他应用打开',
          onPressed: openExternal,
          icon: const AppIcon(Icons.open_in_new),
        ),
        const SizedBox(width: 4),
      ],
    ),
    body: LayoutBuilder(
      builder: (context, bounds) {
        viewport = bounds.biggest;
        final pixels =
            (bounds.maxWidth * MediaQuery.devicePixelRatioOf(context)).round();
        return GestureDetector(
          onDoubleTap: openExternal,
          child: InteractiveViewer(
            key: const ValueKey('saved-image-viewer'),
            transformationController: transform,
            minScale: .5,
            maxScale: 8,
            trackpadScrollCausesScale: true,
            // Do not add an alignment pivot: toScene and the framework's
            // focal-point/boundary calculations already use the top-left.
            boundaryMargin: EdgeInsets.symmetric(
              horizontal: viewport.width / 2,
              vertical: viewport.height / 2,
            ),
            child: SizedBox(
              width: bounds.maxWidth,
              height: bounds.maxHeight,
              child: SavedFilePicture(
                location: widget.path,
                fit: BoxFit.contain,
                cacheWidth: math.min(4096, math.max(1, pixels)),
                errorBuilder: (context, error, stack) => UiEmpty(
                  icon: Icons.broken_image_outlined,
                  title: '无法预览这张图片',
                  action: OutlinedButton(
                    onPressed: openExternal,
                    child: const Text('用其他应用打开'),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: '缩小',
              onPressed: () => zoom(1 / 1.5),
              icon: const AppIcon(Icons.remove),
            ),
            ValueListenableBuilder(
              valueListenable: transform,
              builder: (context, value, _) => SizedBox(
                width: 68,
                child: Text(
                  '${(value.getMaxScaleOnAxis() * 100).round()}%',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            IconButton(
              tooltip: '放大',
              onPressed: () => zoom(1.5),
              icon: const AppIcon(Icons.add),
            ),
            const SizedBox(width: 16),
            TextButton(
              onPressed: () => transform.value = Matrix4.identity(),
              child: const Text('适应窗口'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Keeps an Android URI descriptor open for the lifetime of its image decoder.
/// Cache identity is the durable URI, never a reusable /proc/self/fd number.
class SavedFilePicture extends StatefulWidget {
  const SavedFilePicture({
    super.key,
    required this.location,
    required this.cacheWidth,
    required this.fit,
    required this.errorBuilder,
  });
  final String location;
  final int cacheWidth;
  final BoxFit fit;
  final ImageErrorWidgetBuilder errorBuilder;
  @override
  State<SavedFilePicture> createState() => _SavedFilePictureState();
}

class _SavedFilePictureState extends State<SavedFilePicture> {
  ReceivedFileAccess? source;
  Uint8List? descriptorBytes;
  Object? error;
  int version = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(SavedFilePicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) load();
  }

  Future<void> load() async {
    final current = ++version;
    final previous = source;
    source = null;
    descriptorBytes = null;
    error = null;
    await previous?.close();
    if (!ReceivedFileAccess.isContentUri(widget.location) &&
        !Platform.isAndroid)
      return;
    ReceivedFileAccess? opened;
    try {
      opened = await ReceivedFileAccess.open(widget.location);
      final bytes = opened.descriptorOnly
          ? await opened.file.readAsBytes()
          : null;
      if (!mounted || current != version) {
        await opened.close();
        return;
      }
      setState(() {
        source = opened;
        descriptorBytes = bytes;
      });
    } catch (failure) {
      await opened?.close();
      if (mounted && current == version) setState(() => error = failure);
    }
  }

  @override
  void dispose() {
    version++;
    final opened = source;
    if (opened != null) unawaited(opened.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return widget.errorBuilder(context, error!, null);
    final leased =
        ReceivedFileAccess.isContentUri(widget.location) || Platform.isAndroid;
    if (leased && source == null) return const SizedBox.shrink();
    final ImageProvider image = descriptorBytes != null
        ? _UriMemoryImage(descriptorBytes!, widget.location)
        : leased
        ? _UriFileImage(source!.file, widget.location)
        : FileImage(File(widget.location));
    return Image(
      image: ResizeImage(image, width: widget.cacheWidth),
      fit: widget.fit,
      errorBuilder: widget.errorBuilder,
      gaplessPlayback: true,
    );
  }
}

class _UriMemoryImage extends MemoryImage {
  const _UriMemoryImage(super.bytes, this.location);
  final String location;
  @override
  bool operator ==(Object other) =>
      other is _UriMemoryImage && other.location == location;
  @override
  int get hashCode => Object.hash(_UriMemoryImage, location);
}

class _UriFileImage extends FileImage {
  const _UriFileImage(super.file, this.location);
  final String location;
  @override
  bool operator ==(Object other) =>
      other is _UriFileImage && other.location == location;
  @override
  int get hashCode => Object.hash(_UriFileImage, location);
}
