import 'package:flutter/material.dart';

import 'received_file_access.dart';
import 'saved_files.dart';
import 'saved_image_preview.dart';
import 'text_viewer.dart';
import 'web_links.dart';
import 'ui_tokens.dart';

/// A bounded preview for queue, transfer and library cards. Image decode size
/// is capped; text reads only the first 4 KiB, including HTML/code files.
class ContentPreview extends StatefulWidget {
  const ContentPreview({
    super.key,
    required this.location,
    required this.name,
    this.text,
    this.fit = BoxFit.cover,
    this.compact = false,
    this.topInset = 0,
    this.maxTextLines,
    this.backgroundColor,
    this.borderRadius,
  });
  final String location, name;
  final String? text;
  final BoxFit fit;
  final bool compact;
  final double topInset;
  final int? maxTextLines;
  final Color? backgroundColor;
  final BorderRadius? borderRadius;
  @override
  State<ContentPreview> createState() => _ContentPreviewState();
}

class _ContentPreviewState extends State<ContentPreview> {
  Future<TextFilePreview?>? _preview;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ContentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location ||
        oldWidget.name != widget.name) {
      _load();
    }
  }

  void _load() {
    if (widget.text == null &&
        widget.location.isNotEmpty &&
        isTextPreviewFile(widget.name)) {
      _preview = () async {
        final source = await ReceivedFileAccess.open(widget.location);
        try {
          return await readTextFilePreview(
            source.file.path,
            title: widget.name,
            maxBytes: 4096,
          );
        } finally {
          await source.close();
        }
      }();
    } else {
      _preview = null;
    }
  }

  Widget _text(BuildContext context, String value) => LayoutBuilder(
    builder: (context, bounds) {
      final padding = widget.compact ? 8.0 : 14.0;
      final font = widget.compact ? 13.0 : 14.0;
      final available = bounds.maxHeight - padding * 2 - widget.topInset;
      final lines = bounds.maxHeight.isFinite
          ? (available / (MediaQuery.textScalerOf(context).scale(font) * 1.55))
                .floor()
                .clamp(1, widget.maxTextLines ?? (widget.compact ? 2 : 5))
          : widget.maxTextLines ?? (widget.compact ? 2 : 5);
      return Padding(
        padding: EdgeInsets.fromLTRB(
          padding,
          padding + widget.topInset,
          padding,
          padding,
        ),
        child: WebLinkText(
          value,
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: font, height: 1.55, color: Ui.ink),
        ),
      );
    },
  );

  Widget _icon(BuildContext context) {
    final category = savedFileCategory(widget.name);
    return Center(
      child: Icon(
        widget.text != null
            ? Icons.notes_rounded
            : switch (category) {
                SavedFileCategory.image => Icons.image_outlined,
                SavedFileCategory.video => Icons.movie_outlined,
                SavedFileCategory.audio => Icons.music_note_outlined,
                SavedFileCategory.text => Icons.description_outlined,
                SavedFileCategory.archive => Icons.folder_zip_outlined,
                SavedFileCategory.other => Icons.insert_drive_file_outlined,
              },
        size: widget.compact ? 25 : 38,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: .65),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final category = savedFileCategory(widget.name);
    final Widget child;
    if (widget.text != null) {
      child = _text(context, widget.text!);
    } else if (category == SavedFileCategory.image &&
        widget.location.isNotEmpty) {
      child = SavedFilePicture(
        location: widget.location,
        cacheWidth: widget.compact ? 160 : 560,
        fit: widget.fit,
        errorBuilder: (context, _, stack) => _icon(context),
      );
    } else if (_preview != null) {
      child = FutureBuilder<TextFilePreview?>(
        future: _preview,
        builder: (context, snapshot) => snapshot.data == null
            ? _icon(context)
            : _text(context, snapshot.data!.text),
      );
    } else {
      child = _icon(context);
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color:
            widget.backgroundColor ??
            Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius:
            widget.borderRadius ??
            BorderRadius.circular(widget.compact ? 10 : 12),
      ),
      child: child,
    );
  }
}
