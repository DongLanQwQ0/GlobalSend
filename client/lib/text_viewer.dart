import 'app_icon.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'system_bridge.dart';
import 'ui_tokens.dart';
import 'web_links.dart';
import 'text_selection_surface.dart';
import 'content_drag_surface.dart';
import 'dock_platform.dart';
import 'models.dart';
import 'received_file_access.dart';

Future<void> showTextViewer(
  BuildContext context, {
  required String title,
  required String text,
  bool editable = false,
  Future<void> Function(String)? onSave,
  Future<void> Function(String)? onCopy,
  String copyLabel = '复制',
  String? notice,
  TextEditingValue? initialValue,
  ValueChanged<TextEditingValue>? onDraftChanged,
  Future<void> Function()? onOpenExternal,
  Future<void> Function(String text, String pointerKind)? onDrag,
}) async {
  final route = DialogRoute<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: Colors.white,
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: SizedBox(
          height: Ui.editorSize(context).height,
          child: _TextViewer(
            title: title,
            text: text,
            editable: editable,
            onSave: onSave,
            onCopy: onCopy,
            copyLabel: copyLabel,
            notice: notice,
            initialValue: initialValue,
            onDraftChanged: onDraftChanged,
            onOpenExternal: onOpenExternal,
            onDrag: onDrag,
          ),
        ),
      ),
    ),
  );
  await Navigator.of(context).push(route);
  await route.completed;
}

class _TextViewer extends StatefulWidget {
  const _TextViewer({
    required this.title,
    required this.text,
    required this.editable,
    required this.copyLabel,
    this.onSave,
    this.onCopy,
    this.notice,
    this.initialValue,
    this.onDraftChanged,
    this.onOpenExternal,
    this.onDrag,
  });
  final String title, text, copyLabel;
  final String? notice;
  final bool editable;
  final TextEditingValue? initialValue;
  final ValueChanged<TextEditingValue>? onDraftChanged;
  final Future<void> Function()? onOpenExternal;
  final Future<void> Function(String text, String pointerKind)? onDrag;
  final Future<void> Function(String)? onSave, onCopy;

  @override
  State<_TextViewer> createState() => _TextViewerState();
}

class _TextViewerState extends State<_TextViewer> {
  late final editor = TextEditingController.fromValue(
    widget.initialValue ?? TextEditingValue(text: widget.text),
  );
  late String savedText = widget.text;
  final focus = FocusNode();
  bool saving = false, copying = false;
  String status = '';

  @override
  void initState() {
    super.initState();
    editor.addListener(draftChanged);
  }

  void draftChanged() => widget.onDraftChanged?.call(editor.value);

  @override
  void dispose() {
    editor.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> copy() async {
    if (copying) return;
    setState(() => copying = true);
    try {
      await (widget.onCopy?.call(editor.text) ??
          SystemBridge.copy(editor.text, private: true));
      if (mounted) setState(() => status = '');
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    } finally {
      if (mounted) setState(() => copying = false);
    }
  }

  Future<void> save() async {
    final value = editor.value;
    if (saving ||
        widget.onSave == null ||
        value.text.trim().isEmpty ||
        value.text == savedText ||
        value.composing.isValid && !value.composing.isCollapsed) {
      return;
    }
    setState(() {
      saving = true;
      status = '';
    });
    try {
      await widget.onSave!(value.text);
      if (mounted) {
        setState(() {
          savedText = value.text;
          status = '';
        });
      }
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> drag(String kind) async {
    try {
      if (widget.onDrag != null) {
        await widget.onDrag!(editor.text, kind);
      } else if (Platform.isWindows) {
        await SystemBridge.dragOut(text: editor.text, pointerKind: kind);
      } else if (Platform.isAndroid) {
        await DockPlatform.startDrag(text: editor.text, label: widget.title);
      }
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<TextEditingValue>(
    valueListenable: editor,
    builder: (_, value, child) {
      final composing = value.composing.isValid && !value.composing.isCollapsed;
      return CallbackShortcuts(
        bindings: {
          if (!composing)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).maybePop(),
          if (widget.editable && !composing) ...{
            const SingleActivator(LogicalKeyboardKey.enter, control: true):
                save,
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): save,
          },
        },
        child: ContentDragSurface(
          entry: DockEntry(
            id: 'text-viewer-drag',
            kind: 'text',
            title: widget.title,
            source: '',
            text: value.text,
          ),
          enabled: value.text.isNotEmpty && !saving && !composing,
          onExport: drag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ContentDragControl(
                      child: IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const AppIcon(Icons.close, size: 21),
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.notice != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    widget.notice!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xff69756d),
                    ),
                  ),
                ),
              Expanded(
                child: !widget.editable
                    ? RawGestureDetector(
                        behavior: HitTestBehavior.opaque,
                        gestures: {
                          if (widget.onOpenExternal != null)
                            BlankDoubleTapGestureRecognizer:
                                GestureRecognizerFactoryWithHandlers<
                                  BlankDoubleTapGestureRecognizer
                                >(
                                  BlankDoubleTapGestureRecognizer.new,
                                  (recognizer) =>
                                      recognizer.onDoubleTap = () async {
                                        try {
                                          await widget.onOpenExternal!();
                                        } catch (error) {
                                          if (mounted)
                                            setState(() => status = '$error');
                                        }
                                      },
                                ),
                        },
                        child: SingleChildScrollView(
                          key: const ValueKey('text-viewer-input'),
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                          child: WebLinkText(
                            value.text,
                            style: const TextStyle(fontSize: 16, height: 1.55),
                          ),
                        ),
                      )
                    : EditableTextSelectionSurface(
                        onBlankTap: (point) {
                          final editable = focus.context
                              ?.findAncestorStateOfType<EditableTextState>();
                          final offset =
                              editable?.renderEditable
                                  .getPositionForPoint(point)
                                  .offset ??
                              editor.text.length;
                          focus.requestFocus();
                          editor.selection = TextSelection.collapsed(
                            offset: offset,
                          );
                        },
                        child: TextField(
                          key: const ValueKey('text-viewer-input'),
                          controller: editor,
                          focusNode: focus,
                          readOnly: !widget.editable || saving,
                          expands: true,
                          minLines: null,
                          maxLines: null,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          textAlignVertical: TextAlignVertical.top,
                          style: const TextStyle(fontSize: 16, height: 1.55),
                          decoration: const InputDecoration(
                            hintText: '暂无内容',
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.fromLTRB(20, 12, 20, 16),
                          ),
                        ),
                      ),
              ),
              if (widget.editable && findWebLinks(value.text).isNotEmpty)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final link in {
                        for (final link in findWebLinks(value.text))
                          link.uri.toString(): link,
                      }.values)
                        ContentDragControl(
                          child: TextButton.icon(
                            onPressed: () => openWebLink(context, link.uri),
                            icon: const AppIcon(Icons.open_in_new, size: 16),
                            label: Text(link.uri.host),
                          ),
                        ),
                    ],
                  ),
                ),
              if (status.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              Container(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    ContentDragControl(
                      child: TextButton.icon(
                        onPressed: copying ? null : copy,
                        icon: const AppIcon(Icons.copy, size: 17),
                        label: Text(widget.copyLabel),
                      ),
                    ),
                    if (widget.editable && value.text != savedText)
                      ContentDragControl(
                        child: FilledButton(
                          onPressed:
                              saving ||
                                  composing ||
                                  value.text.trim().isEmpty ||
                                  value.text == savedText
                              ? null
                              : save,
                          child: saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('保存'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class TextFilePreview {
  const TextFilePreview({
    required this.text,
    required this.truncated,
    required this.totalBytes,
  });
  final String text;
  final bool truncated;
  final int totalBytes;
}

const _textExtensions = {
  'txt',
  'md',
  'markdown',
  'log',
  'json',
  'jsonl',
  'csv',
  'tsv',
  'xml',
  'yaml',
  'yml',
  'ini',
  'conf',
  'config',
  'toml',
  'html',
  'htm',
  'css',
  'js',
  'ts',
  'dart',
  'java',
  'kt',
  'py',
  'c',
  'cpp',
  'h',
  'sh',
  'ps1',
  'sql',
  'svg',
  'srt',
  'vtt',
};

bool isTextPreviewFile(String name) {
  final filename = name.replaceAll('\\', '/').split('/').last.toLowerCase();
  return _textExtensions.contains(filename.split('.').last) ||
      {'.gitignore', '.env', 'readme', 'license'}.contains(filename);
}

Future<TextFilePreview?> readTextFilePreview(
  String path, {
  int maxBytes = 1024 * 1024,
  String? title,
}) async {
  if (!isTextPreviewFile(title ?? path)) return null;
  final access = await ReceivedFileAccess.open(path);
  RandomAccessFile? file;
  late final int totalBytes;
  late final List<int> bytes;
  try {
    file = await access.file.open();
    totalBytes = await file.length();
    bytes = await file.read(math.min(maxBytes, totalBytes));
  } finally {
    try {
      await file?.close();
    } finally {
      await access.close();
    }
  }
  final truncated = totalBytes > bytes.length;
  String? decoded;
  if (bytes.length >= 2 &&
      (bytes[0] == 0xff && bytes[1] == 0xfe ||
          bytes[0] == 0xfe && bytes[1] == 0xff)) {
    if (!truncated && (bytes.length - 2).isOdd) return null;
    final littleEndian = bytes[0] == 0xff;
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(
        littleEndian
            ? bytes[i] | bytes[i + 1] << 8
            : bytes[i] << 8 | bytes[i + 1],
      );
    }
    if (truncated &&
        units.isNotEmpty &&
        units.last >= 0xd800 &&
        units.last <= 0xdbff) {
      units.removeLast();
    }
    decoded = String.fromCharCodes(units);
  } else {
    final start =
        bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf
        ? 3
        : 0;
    for (
      var trim = 0;
      trim <= (truncated ? 3 : 0) && start <= bytes.length - trim;
      trim++
    ) {
      try {
        decoded = utf8.decode(bytes.sublist(start, bytes.length - trim));
        break;
      } on FormatException {
        // Only a truncated UTF-8 tail is retried; invalid content stays external.
      }
    }
  }
  if (decoded == null || decoded.contains('\u0000')) return null;
  return TextFilePreview(
    text: decoded,
    truncated: truncated,
    totalBytes: totalBytes,
  );
}

Future<bool> showTextFilePreview(
  BuildContext context, {
  required String path,
  required String title,
  Future<void> Function()? onOpenExternal,
}) async {
  final preview = await readTextFilePreview(path, title: title);
  if (preview == null) return false;
  if (!context.mounted) return true;
  await showTextViewer(
    context,
    title: title,
    text: preview.text,
    onOpenExternal: onOpenExternal,
    copyLabel: preview.truncated ? '复制预览' : '复制',
    notice: preview.truncated
        ? '仅预览前 1 MiB · 原文件 ${(preview.totalBytes / 1048576).toStringAsFixed(1)} MiB'
        : null,
  );
  return true;
}
