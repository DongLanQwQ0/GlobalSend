import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'ui_tokens.dart';
import 'models.dart';
import 'saved_files.dart';
import 'saved_image_preview.dart';
import 'text_viewer.dart';
import 'received_file_access.dart';
import 'compact_content_card.dart';
import 'compact_time.dart';
import 'content_drag_surface.dart';
import 'system_bridge.dart';

const _sortLabels = {
  SavedFilesSort.newest: '最新接收',
  SavedFilesSort.oldest: '最早接收',
  SavedFilesSort.name: '名称',
  SavedFilesSort.largest: '最大优先',
  SavedFilesSort.smallest: '最小优先',
};

class SavedFilesScreen extends StatefulWidget {
  const SavedFilesScreen({
    super.key,
    required this.controller,
    this.embedded = false,
  });
  final SendController controller;
  final bool embedded;

  @override
  State<SavedFilesScreen> createState() => _SavedFilesScreenState();
}

class _SavedFilesScreenState extends State<SavedFilesScreen>
    with WidgetsBindingObserver {
  SendController get c => widget.controller;
  SavedFilesSort sort = SavedFilesSort.newest;
  bool selecting = false, working = false;
  final selected = <String>{};
  String error = '';

  @override
  void initState() {
    super.initState();
    c.addListener(refresh);
    WidgetsBinding.instance.addObserver(this);
    loadFiles();
  }

  @override
  void dispose() {
    c.removeListener(refresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) loadFiles();
  }

  void refresh() {
    if (!mounted) return;
    final available = c.savedFiles.map((file) => file.id).toSet();
    setState(() => selected.removeWhere((id) => !available.contains(id)));
  }

  Future<void> loadFiles() async {
    try {
      await c.refreshSavedFiles();
      if (mounted) setState(() => error = '');
    } catch (e) {
      if (mounted) setState(() => error = '读取失败：$e');
    }
  }

  Future<void> perform(Future<void> Function() action, String success) async {
    if (working) return;
    setState(() {
      working = true;
      error = '';
    });
    try {
      await action();
      if (!mounted) return;
      if (success.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void toggle(SavedFile file) => setState(() {
    selecting = true;
    if (!selected.add(file.id)) selected.remove(file.id);
  });

  void finishSelection() => setState(() {
    selected.clear();
    selecting = false;
  });

  Future<void> open(SavedFile file) => perform(() async {
    if (file.directory) {
      await ReceivedFileAccess.openExternal(file.path);
      return;
    }
    if (await showSavedImagePreview(
      context,
      path: file.path,
      title: file.name,
    )) {
      return;
    }
    if (!mounted) return;
    final source = await ReceivedFileAccess.open(file.path);
    try {
      if (!mounted) return;
      if (await showTextFilePreview(
        context,
        path: source.file.path,
        title: file.name,
        onOpenExternal: () => ReceivedFileAccess.openExternal(file.path),
      )) {
        return;
      }
    } finally {
      await source.close();
    }
    await ReceivedFileAccess.openExternal(file.path);
  }, '');

  Future<void> rename() async {
    final file = c.savedFiles
        .where((file) => selected.contains(file.id))
        .single;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => _RenameSavedFileDialog(name: file.name),
    );
    if (value == null || !mounted) return;
    await perform(() => c.renameSavedFile(file.id, value), '名称已保存');
  }

  Future<void> delete() async {
    final ids = selected.toList();
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${ids.length} 个文件？'),
        content: const Text('仅删除本机副本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await perform(() async {
      await c.deleteSavedFiles(ids);
      if (mounted) finishSelection();
    }, '已删除');
  }

  Future<void> forward() async {
    final ids = selected.toList();
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: AnimatedBuilder(
          animation: c,
          builder: (context, _) {
            final peers = c.sendablePeers;
            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .65,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 4, 24, 12),
                    child: Text(
                      '转发到',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (peers.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 8, 24, 28),
                      child: Text('暂无其他设备'),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: peers.length,
                        itemBuilder: (context, index) {
                          final peer = peers[index];
                          return ListTile(
                            leading: Icon(
                              peer['platform'] == 'windows'
                                  ? Icons.desktop_windows_outlined
                                  : peer['platform'] == 'android'
                                  ? Icons.phone_android
                                  : Icons.language,
                            ),
                            title: Text(peer['name'] as String),
                            subtitle: peer['online'] == true
                                ? null
                                : const Text('离线 · 可尝试'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.pop(
                              context,
                              peer['deviceId'] as String,
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (target == null || !mounted) return;
    await perform(() async {
      await c.forwardSavedFiles(target, ids);
      if (mounted) finishSelection();
    }, '已加入发送');
  }

  @override
  Widget build(BuildContext context) {
    final files = sortSavedFiles(c.savedFiles, sort);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: widget.embedded
          ? null
          : AppBar(
              automaticallyImplyLeading: !widget.embedded,
              toolbarHeight: widget.embedded ? 42 : 56,
              title: Text(
                selecting
                    ? '已选 ${selected.length} 项'
                    : widget.embedded
                    ? ''
                    : '文件库',
              ),
              actions: [
                if (selecting)
                  TextButton(
                    onPressed: working
                        ? null
                        : () => setState(() {
                            if (selected.length == files.length) {
                              selected.clear();
                            } else {
                              selected.addAll(files.map((file) => file.id));
                            }
                          }),
                    child: Text(
                      selected.length == files.length && selected.isNotEmpty
                          ? '取消全选'
                          : '全选',
                    ),
                  ),
                TextButton(
                  onPressed: working || files.isEmpty
                      ? null
                      : () => selecting
                            ? finishSelection()
                            : setState(() => selecting = true),
                  child: Text(selecting ? '完成' : '编辑'),
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${files.length} 个文件',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (!selecting)
                      PopupMenuButton<SavedFilesSort>(
                        tooltip: '排序',
                        initialValue: sort,
                        onSelected: (value) => setState(() => sort = value),
                        itemBuilder: (context) => _sortLabels.entries
                            .map(
                              (entry) => CheckedPopupMenuItem(
                                value: entry.key,
                                checked: entry.key == sort,
                                child: Text(entry.value),
                              ),
                            )
                            .toList(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 4,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _sortLabels[sort]!,
                                style: const TextStyle(fontSize: 13),
                              ),
                              const SizedBox(width: 5),
                              const Icon(Icons.sort, size: 18),
                            ],
                          ),
                        ),
                      ),
                    if (widget.embedded && selecting)
                      TextButton(
                        onPressed: () => setState(() {
                          if (selected.length == files.length)
                            selected.clear();
                          else
                            selected.addAll(files.map((file) => file.id));
                        }),
                        child: Text(
                          selected.length == files.length ? '取消全选' : '全选',
                        ),
                      ),
                    if (widget.embedded && files.isNotEmpty)
                      TextButton(
                        onPressed: working
                            ? null
                            : () => selecting
                                  ? finishSelection()
                                  : setState(() => selecting = true),
                        child: Text(selecting ? '取消' : '多选'),
                      ),
                  ],
                ),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          error,
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                      TextButton(
                        onPressed: working ? null : loadFiles,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: files.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.folder_open_rounded,
                              size: 48,
                              color: scheme.outline,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '收到的文件会保存在这里',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      )
                    : GridView.builder(
                        key: const ValueKey('saved-files-grid'),
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          mainAxisExtent:
                              230 +
                              math.max(
                                    0,
                                    MediaQuery.textScalerOf(context).scale(14) -
                                        14,
                                  ) *
                                  4,
                        ),
                        itemCount: files.length,
                        itemBuilder: (context, index) => tile(files[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: selecting
          ? SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(top: BorderSide(color: scheme.outlineVariant)),
                ),
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: working || selected.length != 1
                            ? null
                            : rename,
                        icon: const Icon(
                          Icons.drive_file_rename_outline,
                          size: 19,
                        ),
                        label: const Text('重命名'),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: working || selected.isEmpty ? null : delete,
                        icon: const Icon(Icons.delete_outline, size: 19),
                        label: const Text('删除'),
                      ),
                    ),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: working || selected.isEmpty ? null : forward,
                        icon: const Icon(Icons.send_outlined, size: 18),
                        label: const Text('转发'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget tile(SavedFile file) {
    final previous = c.historyDock
        .where((entry) => entry.kind == 'file' && entry.localPath == file.path)
        .firstOrNull;
    final item =
        previous ??
        DockEntry(
          id: file.id,
          kind: 'file',
          title: file.name,
          source: '',
          localPath: file.path,
          fileId: file.fileId,
          transferId: file.transferId,
          size: file.size,
          receivedAtMillis: file.receivedAtMillis,
          relativePath: file.relativePath,
          entryKind: file.directory ? 'directory' : 'file',
        );
    final windows = Theme.of(context).platform == TargetPlatform.windows;
    final card = CompactContentCard(
      entry: item,
      sender: previous?.sourceLabel ?? '',
      timestamp: compactTime(file.receivedAt),
      onOpen: () => open(file),
      selecting: selecting,
      selected: selected.contains(file.id),
      onToggle: () => toggle(file),
      onLongPress: windows ? null : () => toggle(file),
      menu: PopupMenuButton<String>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        onSelected: (action) async {
          if (action == 'open')
            await ReceivedFileAccess.openExternal(file.path);
          if (action == 'locate') await SystemBridge.revealFile(file.path);
          if (action == 'queue')
            await perform(
              () => file.directory
                  ? c.stageDirectory(file.path)
                  : c.stageInputs([file.path], []),
              '',
            );
          if (action == 'select') toggle(file);
          if (action == 'rename') {
            setState(() {
              selected
                ..clear()
                ..add(file.id);
            });
            await rename();
          }
          if (action == 'delete') {
            setState(() {
              selected
                ..clear()
                ..add(file.id);
            });
            await delete();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'open', child: Text('系统打开')),
          if (windows)
            const PopupMenuItem(value: 'locate', child: Text('定位文件')),
          const PopupMenuItem(value: 'queue', child: Text('加入待发送')),
          const PopupMenuItem(value: 'rename', child: Text('重命名')),
          const PopupMenuItem(value: 'select', child: Text('多选')),
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        ],
      ),
    );
    return ContentDragSurface(
      key: ValueKey('saved-file-${file.id}'),
      entry: item,
      enabled: !selecting && !working,
      touchDrags: windows,
      onExport: (kind) => perform(() => c.dragOut(item, pointerKind: kind), ''),
      child: card,
    );
  }

  Widget fileIcon(String extension) => Container(
    width: 66,
    height: 76,
    decoration: BoxDecoration(
      color: const Color(0xffedf3ee),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.insert_drive_file_outlined,
          size: 30,
          color: Color(0xff47795e),
        ),
        const SizedBox(height: 4),
        Text(
          extension.isEmpty
              ? 'FILE'
              : extension.toUpperCase().substring(
                  0,
                  math.min(extension.length, 6),
                ),
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: Color(0xff47795e),
          ),
        ),
      ],
    ),
  );
}

class _RenameSavedFileDialog extends StatefulWidget {
  const _RenameSavedFileDialog({required this.name});
  final String name;
  @override
  State<_RenameSavedFileDialog> createState() => _RenameSavedFileDialogState();
}

class _RenameSavedFileDialogState extends State<_RenameSavedFileDialog> {
  late final input = TextEditingController(text: widget.name);
  @override
  void initState() {
    super.initState();
    final dot = widget.name.lastIndexOf('.');
    input.selection = TextSelection(
      baseOffset: 0,
      extentOffset: dot > 0 ? dot : widget.name.length,
    );
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('重命名'),
    content: UiField(
      label: '文件名',
      child: TextField(
        key: const ValueKey('library-rename-input'),
        controller: input,
        autofocus: true,
        maxLength: 160,
        decoration: const InputDecoration(counterText: ''),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, input.text),
        child: const Text('保存'),
      ),
    ],
  );
}
