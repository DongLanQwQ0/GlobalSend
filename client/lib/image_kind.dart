import 'package:flutter/widgets.dart';

import 'received_file_access.dart';
import 'image_signature.dart';
export 'image_signature.dart';

/// Legacy gallery filenames can have no extension. Read only the signature,
/// using the same Android descriptor lease as previews; never rename/copy it.
Future<bool> imageAtLocation(String location, String name) async {
  if (knownImageName(name)) return true;
  if (location.isEmpty) return false;
  try {
    final source = await ReceivedFileAccess.open(location);
    try {
      final file = await source.file.open();
      try {
        return imageHeader(await file.read(32));
      } finally {
        await file.close();
      }
    } finally {
      await source.close();
    }
  } catch (_) {
    return false;
  }
}

class ImageKindBuilder extends StatefulWidget {
  const ImageKindBuilder({
    super.key,
    required this.location,
    required this.name,
    required this.builder,
  });
  final String location, name;
  final Widget Function(BuildContext, bool) builder;
  @override
  State<ImageKindBuilder> createState() => _ImageKindBuilderState();
}

class _ImageKindBuilderState extends State<ImageKindBuilder> {
  Future<bool>? probe;
  void load() {
    probe = knownImageName(widget.name) || widget.location.isEmpty
        ? null
        : imageAtLocation(widget.location, widget.name);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(ImageKindBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location ||
        oldWidget.name != widget.name) {
      load();
    }
  }

  @override
  Widget build(BuildContext context) => probe == null
      ? widget.builder(context, knownImageName(widget.name))
      : FutureBuilder<bool>(
          future: probe,
          builder: (context, result) =>
              widget.builder(context, result.data ?? false),
        );
}
