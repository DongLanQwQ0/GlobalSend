import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'folder_cards.dart';
import 'models.dart';
import 'saved_files.dart';
import 'ui_tokens.dart';

const _textTerms = ['文本', '文字', 'text'];
const _folderTerms = ['文件夹', '目录', 'folder', 'directory'];
const _fileCategoryTerms = {
  SavedFileCategory.image: ['图片', '照片', '图像', '截图', 'image', 'photo'],
  SavedFileCategory.video: ['视频', '影片', '录像', 'video'],
  SavedFileCategory.audio: ['音频', '音乐', '录音', 'audio'],
  SavedFileCategory.text: ['文本', '文字', '文档', 'text', 'document'],
  SavedFileCategory.archive: ['压缩包', '压缩文件', '归档', 'archive'],
  SavedFileCategory.other: ['其他', 'other'],
};
const _documentExtensions = {
  'pdf',
  'doc',
  'docx',
  'odt',
  'rtf',
  'xls',
  'xlsx',
  'ods',
  'ppt',
  'pptx',
  'odp',
};

/// Search only history metadata and stored message bodies, never local files.
/// A collapsed folder stays one result when any of its member names match.
bool matchesHistoryQuery(
  DockEntry entry,
  String query, {
  String deviceLabel = '',
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || deviceLabel.toLowerCase().contains(needle)) return true;

  bool anyTerm(Iterable<String> terms) =>
      terms.any((term) => term.contains(needle));

  bool matchesEntry(DockEntry item) {
    if (item.kind == 'text') {
      return item.text.toLowerCase().contains(needle) || anyTerm(_textTerms);
    }
    if (item.kind != 'file') return item.title.toLowerCase().contains(needle);

    final name = item.title.toLowerCase();
    if (name.contains(needle) || anyTerm(const ['文件', 'file'])) return true;
    if (item.isDirectory) return anyTerm(_folderTerms);
    if (anyTerm(_fileCategoryTerms[savedFileCategory(name)]!)) return true;
    final dot = name.lastIndexOf('.');
    return dot >= 0 &&
        _documentExtensions.contains(name.substring(dot + 1)) &&
        anyTerm(const ['文档', 'document']);
  }

  return matchesEntry(entry) ||
      entry is FolderCardEntry && entry.members.any(matchesEntry);
}

/// Toolbar entry point and inline field share a controller owned by the page.
/// Place the expanded control in a bounded row, separate from bulk actions.
class HistorySearchControl extends StatefulWidget {
  const HistorySearchControl({
    super.key,
    required this.controller,
    required this.expanded,
    required this.onOpen,
    required this.onClose,
    this.focusNode,
  });

  final TextEditingController controller;
  final bool expanded;
  final VoidCallback onOpen, onClose;
  final FocusNode? focusNode;

  @override
  State<HistorySearchControl> createState() => _HistorySearchControlState();
}

class _HistorySearchControlState extends State<HistorySearchControl> {
  late final _localFocus = FocusNode(debugLabel: 'history search');
  FocusNode get _focus => widget.focusNode ?? _localFocus;

  @override
  void dispose() {
    _localFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded) {
      return SizedBox.square(
        dimension: Ui.touch,
        child: IconButton(
          tooltip: '搜索历史',
          icon: const AppIcon(Icons.search, size: Ui.iconSm),
          onPressed: widget.onOpen,
        ),
      );
    }

    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: true,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '搜索历史',
        prefixIcon: const AppIcon(Icons.search, size: Ui.iconSm),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (context, value, child) {
            final hasQuery = value.text.isNotEmpty;
            return IconButton(
              tooltip: hasQuery ? '清空搜索' : '关闭搜索',
              icon: const AppIcon(Icons.close, size: Ui.iconSm),
              onPressed: hasQuery
                  ? () {
                      widget.controller.clear();
                      _focus.requestFocus();
                    }
                  : widget.onClose,
            );
          },
        ),
      ),
    );
  }
}
