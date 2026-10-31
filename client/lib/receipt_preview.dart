import 'app_icon.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'ui_tokens.dart';
import 'received_file_access.dart';
import 'saved_image_preview.dart';
import 'image_kind.dart';
import 'text_viewer.dart';
import 'web_links.dart';
import 'text_selection_surface.dart';
import 'bulk_file_drag.dart';
import 'incoming_receipt_state.dart';

class ReceivedContentPreview extends StatelessWidget {
  const ReceivedContentPreview({
    super.key,
    required this.entry,
    required this.sender,
    required this.platformIcon,
    required this.onClose,
    required this.onCopy,
    required this.onOpen,
    required this.dragSurface,
    this.embedded = false,
    this.onExpand,
  });
  final DockEntry entry;
  final String sender;
  final IconData platformIcon;
  final VoidCallback onClose, onCopy, onOpen;
  final Widget Function(Widget) dragSurface;
  final bool embedded;
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final desktop = Theme.of(context).platform == TargetPlatform.windows;
    final transfer = IncomingReceiptState(entry);
    Widget desktopSurface(Widget child) =>
        desktop && transfer.canExport ? dragSurface(child) : child;
    Widget bodySurface(Widget child) =>
        !desktop && transfer.canExport ? dragSurface(child) : child;
    Widget control(Widget child) =>
        desktop ? ContentDragControl(child: child) : child;
    final lines = entry.text
        .split('\n')
        .fold<int>(
          0,
          (count, line) => count + math.max(1, (line.runes.length / 42).ceil()),
        );
    final contentHeight = entry.kind == 'text'
        ? (220.0 + lines * 29).clamp(300.0, 640.0)
        : 640.0;
    return _ReceiptFrame(
      embedded: embedded,
      child: desktopSurface(
        ConstrainedBox(
          key: const ValueKey('receipt-content-surface'),
          constraints: const BoxConstraints(maxWidth: 800),
          child: SizedBox(
            height: embedded
                ? double.infinity
                : math.min(
                    contentHeight,
                    MediaQuery.sizeOf(context).height * .82,
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Ui.space4,
                    Ui.space3,
                    Ui.space2,
                    Ui.space1,
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(Ui.space2),
                        decoration: BoxDecoration(
                          color: Ui.colors(context).accentSoft,
                          borderRadius: Ui.cardRadius,
                        ),
                        child: AppIcon(
                          platformIcon,
                          size: 25,
                          color: Ui.colors(context).accent,
                        ),
                      ),
                      const SizedBox(width: Ui.space2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sender,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: Ui.textLg,
                                height: Ui.leadingTight,
                                fontWeight: Ui.weightLabel,
                              ),
                            ),
                            const SizedBox(height: Ui.space0),
                            Text(
                              entry.kind == 'text'
                                  ? '收到文本'
                                  : transfer.label.isNotEmpty
                                  ? transfer.label
                                  : '收到文件',
                              style: TextStyle(
                                fontSize: Ui.textXs,
                                height: Ui.leadingCompact,
                                color: Ui.colors(context).textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (onExpand != null)
                        control(
                          IconButton(
                            key: const ValueKey('expand-receipt'),
                            tooltip: '全屏',
                            onPressed: onExpand,
                            icon: const AppIcon(
                              Icons.open_in_full_rounded,
                              size: 20,
                            ),
                          ),
                        ),
                      control(
                        IconButton(
                          key: const ValueKey('close-receipt'),
                          tooltip: '关闭',
                          onPressed: onClose,
                          icon: const AppIcon(Icons.close),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Ui.space1),
                Expanded(
                  child: bodySurface(
                    Padding(
                      padding: Ui.insetPanel,
                      child: entry.kind == 'text'
                          ? SingleChildScrollView(
                              key: const ValueKey('receipt-content-scroll'),
                              child: WebLinkText(
                                entry.text.isEmpty ? '空文本' : entry.text,
                                key: const ValueKey('receipt-text'),
                                style: const TextStyle(
                                  fontSize: Ui.textBase,
                                  height: Ui.leadingRelaxed,
                                ),
                              ),
                            )
                          : transfer.showProgress ||
                                transfer.failed ||
                                transfer.canceled
                          ? _IncomingProgressBody(entry: entry)
                          : _ReceivedFileBody(
                              key: ValueKey('${entry.id}:${entry.localPath}'),
                              entry: entry,
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Ui.space4,
                    Ui.space1,
                    Ui.space4,
                    Ui.space4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.kind == 'text'
                              ? '${entry.text.runes.length} 字符'
                              : entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Ui.textXs,
                            height: Ui.leadingCompact,
                            color: Ui.colors(context).textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: Ui.space2),
                      if (entry.kind == 'text')
                        control(
                          FilledButton.icon(
                            key: const ValueKey('copy-receipt'),
                            onPressed: onCopy,
                            icon: const AppIcon(Icons.copy, size: 17),
                            label: const Text('复制'),
                          ),
                        )
                      else
                        control(
                          OutlinedButton.icon(
                            onPressed: transfer.canceled ? null : onOpen,
                            icon: AppIcon(
                              transfer.canExport
                                  ? Icons.open_in_new
                                  : Icons.file_download_outlined,
                              size: 17,
                            ),
                            label: Text(transfer.primaryLabel),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A live, bounded batch: new arrivals update this grid rather than replacing it.
class ReceivedBatchPreview extends StatefulWidget {
  const ReceivedBatchPreview({
    super.key,
    required this.entries,
    required this.onClose,
    required this.itemBuilder,
    required this.onCopy,
    required this.onView,
    this.embedded = false,
    this.onExpand,
  });
  final List<DockEntry> entries;
  final VoidCallback onClose;
  final Widget Function(DockEntry, Widget) itemBuilder;
  final void Function(DockEntry) onCopy, onView;
  final bool embedded;
  final VoidCallback? onExpand;

  @override
  State<ReceivedBatchPreview> createState() => _ReceivedBatchPreviewState();
}

class _ReceivedBatchPreviewState extends State<ReceivedBatchPreview> {
  List<String> order = [];
  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final onClose = widget.onClose, onExpand = widget.onExpand;
    final itemBuilder = widget.itemBuilder, onCopy = widget.onCopy;
    final embedded = widget.embedded;
    order = receiptDisplayOrder(order, entries);
    final byId = {for (final entry in entries) entry.id: entry};
    final sorted = [for (final id in order) byId[id]!];
    return _ReceiptFrame(
      embedded: embedded,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: SizedBox(
          height: embedded
              ? double.infinity
              : MediaQuery.sizeOf(context).height * .82,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Ui.space4,
                  Ui.space3,
                  Ui.space2,
                  Ui.space1,
                ),
                child: Row(
                  children: [
                    Text(
                      '收到 ${entries.length} 项',
                      style: const TextStyle(
                        fontSize: Ui.textLg,
                        height: Ui.leadingTight,
                        fontWeight: Ui.weightLabel,
                      ),
                    ),
                    const Spacer(),
                    BulkFileDrag(
                      key: const ValueKey('receipt-drag-all'),
                      paths: entries
                          .where(
                            (entry) =>
                                entry.kind == 'file' &&
                                IncomingReceiptState(entry).canExport,
                          )
                          .map((entry) => entry.localPath)
                          .toList(),
                      onError: (error) =>
                          ScaffoldMessenger.maybeOf(context)
                              ?.showSnackBar(SnackBar(content: Text('$error'))),
                    ),
                    if (onExpand != null)
                      IconButton(
                        key: const ValueKey('expand-receipt'),
                        tooltip: '全屏',
                        onPressed: onExpand,
                        icon: const AppIcon(
                          Icons.open_in_full_rounded,
                          size: 20,
                        ),
                      ),
                    IconButton(
                      key: const ValueKey('close-receipt'),
                      tooltip: '关闭',
                      onPressed: onClose,
                      icon: const AppIcon(Icons.close),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Ui.space1),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, bounds) => GridView.builder(
                    key: const ValueKey('receipt-batch-grid'),
                    padding: Ui.insetField,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisExtent: embedded
                          ? math.min(
                              230 +
                                  (MediaQuery.textScalerOf(context).scale(14) -
                                          14) *
                                      10,
                              math.max(128, bounds.maxHeight - 32),
                            )
                          : 230 +
                                (MediaQuery.textScalerOf(context).scale(14) -
                                        14) *
                                    10,
                      crossAxisSpacing: Ui.space2,
                      mainAxisSpacing: Ui.space2,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (_, index) {
                      final item = sorted[index];
                      return KeyedSubtree(
                        key: ValueKey('receipt-batch-${item.id}'),
                        child: itemBuilder(
                          item,
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              if (item.kind == 'text')
                                TextButton(
                                  key: ValueKey('receipt-copy-${item.id}'),
                                  onPressed: () => onCopy(item),
                                  child: const Text('复制'),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReceiptFrame extends StatelessWidget {
  const _ReceiptFrame({required this.embedded, required this.child});
  final bool embedded;
  final Widget child;
  @override
  Widget build(BuildContext context) => embedded
      ? Material(
          key: const ValueKey('receipt-preview'),
          color: Ui.colors(context).surface,
          borderRadius: Ui.panelRadius,
          clipBehavior: Clip.antiAlias,
          child: child,
        )
      : Dialog(
          key: const ValueKey('receipt-preview'),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: Ui.space3,
            vertical: Ui.space4,
          ),
          backgroundColor: Ui.colors(context).surface,
          clipBehavior: Clip.antiAlias,
          child: child,
        );
}

class _IncomingProgressBody extends StatelessWidget {
  const _IncomingProgressBody({required this.entry});
  final DockEntry entry;
  @override
  Widget build(BuildContext context) {
    final state = IncomingReceiptState(entry);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              Icons.insert_drive_file_outlined,
              size: 56,
              color: Ui.colors(context).accent,
            ),
            const SizedBox(height: Ui.space4),
            Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: Ui.textLg,
                height: Ui.leadingTight,
                fontWeight: Ui.weightLabel,
              ),
            ),
            const SizedBox(height: Ui.space1),
            Text(
              bytesLabel(entry.size),
              style: TextStyle(color: Ui.colors(context).textSecondary),
            ),
            if (state.showProgress) ...[
              const SizedBox(height: Ui.space4),
              LinearProgressIndicator(value: state.progressValue, minHeight: 4),
            ],
            if (entry.transferBytesPerSecond > 0 && state.pending) ...[
              const SizedBox(height: Ui.space2),
              Text(
                '${bytesLabel(entry.transferBytesPerSecond.round())}/s',
                style: TextStyle(
                  fontSize: Ui.textXs,
                  height: Ui.leadingCompact,
                  color: Ui.colors(context).textSecondary,
                ),
              ),
            ],
            if (state.failed && entry.error.isNotEmpty) ...[
              const SizedBox(height: Ui.space2),
              Text(
                entry.error,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: Ui.textXs,
                  height: Ui.leadingCompact,
                  color: Ui.colors(context).danger,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReceivedFileBody extends StatefulWidget {
  const _ReceivedFileBody({super.key, required this.entry});
  final DockEntry entry;
  @override
  State<_ReceivedFileBody> createState() => _ReceivedFileBodyState();
}

class _ReceivedFileBodyState extends State<_ReceivedFileBody> {
  Future<TextFilePreview?>? text;
  @override
  void initState() {
    super.initState();
    if (isTextPreviewFile(widget.entry.title) &&
        widget.entry.localPath.isNotEmpty) {
      text = () async {
        final source = await ReceivedFileAccess.open(widget.entry.localPath);
        try {
          return await readTextFilePreview(
            source.file.path,
            title: widget.entry.title,
          );
        } finally {
          await source.close();
        }
      }();
    }
  }

  Widget fileSummary() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppIcon(
          Icons.insert_drive_file_outlined,
          size: 70,
          color: Ui.colors(context).textSecondary,
        ),
        const SizedBox(height: Ui.space4),
        Text(
          widget.entry.title,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: Ui.textLg,
            height: Ui.leadingTight,
            fontWeight: Ui.weightLabel,
          ),
        ),
        const SizedBox(height: Ui.space1),
        Text(
          bytesLabel(widget.entry.size),
          style: TextStyle(color: Ui.colors(context).textSecondary),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => ImageKindBuilder(
    location: widget.entry.localPath,
    name: widget.entry.title,
    builder: (context, image) => body(context, image),
  );

  Widget body(BuildContext context, bool image) {
    if (image && widget.entry.localPath.isNotEmpty) {
      return Center(
        child: SavedFilePicture(
          location: widget.entry.localPath,
          cacheWidth: 1200,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => fileSummary(),
        ),
      );
    }
    if (text != null) {
      return FutureBuilder<TextFilePreview?>(
        future: text,
        builder: (_, result) {
          if (!result.hasData) return fileSummary();
          return SingleChildScrollView(
            child: WebLinkText(
              result.data!.text,
              style: const TextStyle(
                fontSize: Ui.textBase,
                height: Ui.leadingRelaxed,
              ),
            ),
          );
        },
      );
    }
    return fileSummary();
  }
}
