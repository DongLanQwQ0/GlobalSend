import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

import 'compact_content_card.dart';
import 'bulk_file_drag.dart';
import 'app_icon.dart';
import 'system_bridge.dart';
import 'compact_time.dart';
import 'content_drag_surface.dart';
import 'models.dart';
import 'text_selection_surface.dart';
import 'ui_tokens.dart';
import 'appearance.dart';
import 'received_order.dart';
import 'incoming_receipt_state.dart';

final _batchDragMarker = Object();

/// The native dock launches this UI-only app before main creates a controller.
/// Content and user actions go through the primary engine; no session is opened.
void runGlobalSendReceiveDock() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReceiveDockApp());
}

class ReceiveDockApp extends StatefulWidget {
  const ReceiveDockApp({super.key});
  static const channel = MethodChannel('dev.globalsend/receive-dock');
  @override
  State<ReceiveDockApp> createState() => _ReceiveDockAppState();
}

class _ReceiveDockAppState extends State<ReceiveDockApp> {
  Map<String, dynamic> payload = {};
  int revision = 0;
  bool presented = false;
  String error = '';
  final scroll = ScrollController();
  List<String> order = [];
  Set<String> entering = {};
  List<DockEntry> exportableFiles = [];
  int? heldPointer;
  Offset pointerOrigin = Offset.zero;
  bool pointerTouch = false;
  void setPointerHeld(bool value) {
    if (!value) heldPointer = null;
  }

  void beginMove() {
    final scale = View.of(context).devicePixelRatio;
    final pointer = heldPointer;
    if (pointer != null) GestureBinding.instance.cancelPointer(pointer);
    unawaited(
      ReceiveDockApp.channel.invokeMethod<void>('move', {
        'x': (pointerOrigin.dx * scale).round(),
        'y': (pointerOrigin.dy * scale).round(),
        'touch': pointerTouch,
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    ReceiveDockApp.channel.setMethodCallHandler((call) async {
      if (call.method == 'content') {
        revision++;
        apply(Map<String, dynamic>.from(call.arguments));
      } else if (call.method == 'interactionEnded') {
        setPointerHeld(false);
      }
    });
    unawaited(initialize());
  }

  Future<void> initialize() async {
    final before = revision;
    final initial = await ReceiveDockApp.channel.invokeMethod<Map>('ready');
    if (mounted && initial != null && revision == before) {
      apply(Map<String, dynamic>.from(initial));
    }
  }

  void apply(Map<String, dynamic> next) {
    final generation = next['arrivalGeneration'] as int? ?? 0;
    if (generation < (payload['arrivalGeneration'] as int? ?? 0)) return;
    if (next['reveal'] == true) presented = false;
    if (mounted) {
      setState(() {
        final entries =
            (next['items'] as List? ?? const [])
                .map(
                  (value) => DockEntry.fromJson(
                    Map<String, dynamic>.from(value as Map),
                  ),
                )
                .toList()
              ..sort(compareReceivedNewestFirst);
        final ids = receiptDisplayOrder(order, entries);
        final added = ids.where((id) => !order.contains(id)).toList();
        entering = order.isEmpty ? {} : added.toSet();
        final frontChanged =
            order.isNotEmpty && ids.isNotEmpty && order.first != ids.first;
        order = ids;
        payload = next;
        // A content/progress update must not unmount the active batch source
        // while its async filesystem refresh is still in flight.
        final retainedPaths = entries
            .where(
              (entry) =>
                  entry.kind != 'text' && IncomingReceiptState(entry).canExport,
            )
            .map((entry) => entry.localPath)
            .toSet();
        exportableFiles = exportableFiles
            .where((entry) => retainedPaths.contains(entry.localPath))
            .toList();
        error = '';
        if (frontChanged) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && scroll.hasClients && scroll.offset > 0) {
              unawaited(
                scroll.animateTo(
                  0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                ),
              );
            }
          });
        }
      });
      unawaited(refreshExportableFiles(next));
      if (!presented && items.isNotEmpty) {
        presented = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(ReceiveDockApp.channel.invokeMethod<void>('presented'));
          }
        });
      }
    }
  }

  List<Map<String, dynamic>> get items =>
      (payload['items'] as List? ?? const [])
          .map((value) => Map<String, dynamic>.from(value))
          .toList();

  Future<void> refreshExportableFiles(Map<String, dynamic> snapshot) async {
    final entries =
        items
            .map(DockEntry.fromJson)
            .where(
              (entry) =>
                  entry.kind != 'text' && IncomingReceiptState(entry).canExport,
            )
            .toList()
          ..sort(compareReceivedNewestFirst);
    final existing = await Future.wait(
      entries.map((entry) async {
        final type = await FileSystemEntity.type(entry.localPath);
        return type == FileSystemEntityType.file ||
                type == FileSystemEntityType.directory
            ? entry
            : null;
      }),
    );
    if (!mounted || !identical(payload, snapshot)) return;
    final seen = <String>{};
    setState(
      () => exportableFiles = [
        for (final entry in existing)
          if (entry != null && seen.add(entry.localPath)) entry,
      ],
    );
  }

  Widget bulkDragHandle() {
    final entries = exportableFiles;
    if (entries.isEmpty) return const SizedBox.shrink();
    final paths = entries.map((entry) => entry.localPath).toList();
    return MetaData(
      metaData: _batchDragMarker,
      behavior: HitTestBehavior.opaque,
      child: ContentDragSurface(
        entry: BulkFileEntry(paths),
        itemCount: paths.length,
        onExport: (kind) async {
          setPointerHeld(false);
          try {
            await ReceiveDockApp.channel.invokeMethod<bool>('dragOut', {
              'pointerKind': kind,
              'paths': paths,
              ...SystemBridge.dragPreviewArguments,
            });
          } on PlatformException catch (failure) {
            if (mounted) setState(() => error = failure.message ?? '无法拖出');
          }
        },
        child: TooltipVisibility(
          visible: true,
          child: Tooltip(
            message: '拖出全部文件',
            triggerMode: TooltipTriggerMode.manual,
            child: Semantics(
              label: '拖出全部文件',
              child: const SizedBox(
                key: ValueKey('dock-drag-all-files'),
                width: 44,
                height: 30,
                child: Center(
                  child: AppIcon(Icons.file_copy_outlined, size: 18),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> action(String action, [String? id]) async {
    final snapshot = payload;
    final ids = items.map((item) => item['id']).toList();
    try {
      await ReceiveDockApp.channel.invokeMethod<void>('action', {
        'action': action,
        'id': id,
        'serial': snapshot['serial'],
        'arrivalGeneration': snapshot['arrivalGeneration'],
        'itemIds': ids,
      });
    } on PlatformException catch (failure) {
      if (mounted) setState(() => error = failure.message ?? '操作未完成');
    }
  }

  Future<void> export(DockEntry entry, String pointerKind) async {
    setPointerHeld(false);
    try {
      await ReceiveDockApp.channel.invokeMethod<bool>('dragOut', {
        'pointerKind': pointerKind,
        ...SystemBridge.dragPreviewArguments,
        if (entry.kind == 'text')
          'text': entry.text
        else
          'paths': [entry.localPath],
      });
    } on PlatformException catch (failure) {
      if (mounted) setState(() => error = failure.message ?? '无法拖出');
    }
  }

  Widget card(Map<String, dynamic> value) {
    final entry = DockEntry.fromJson(value);
    entry.progress = (value['progress'] as num?)?.toDouble() ?? 0;
    final time = entry.receivedAtMillis > 0
        ? entry.receivedAtMillis
        : entry.createdAtMillis;
    final state = IncomingReceiptState(entry);
    final needsAction =
        state.pending ||
        state.paused ||
        state.failed ||
        entry.relayConfirmationPending;
    final active = state.pending;
    List<PopupMenuEntry<String>> menuItems(BuildContext _) => [
      const PopupMenuItem(value: 'open', height: 32, child: Text('打开')),
      if (state.canExport && entry.localPath.isNotEmpty)
        const PopupMenuItem(value: 'reveal', height: 32, child: Text('定位文件')),
      if (state.canExport)
        const PopupMenuItem(value: 'stage', height: 32, child: Text('加入待发送')),
      if (state.pending || state.paused)
        PopupMenuItem(
          value: state.paused ? 'resume' : 'pause',
          height: 32,
          child: Text(state.paused ? '继续' : '暂停'),
        ),
      if (state.pending || state.paused)
        const PopupMenuItem(value: 'cancel', height: 32, child: Text('取消接收')),
      const PopupMenuItem(value: 'delete', height: 32, child: Text('删除')),
      const PopupMenuItem(value: 'details', height: 32, child: Text('详情')),
    ];
    return ContentDragSurface(
      entry: entry,
      enabled: state.canExport,
      onExport: (kind) => export(entry, kind),
      child: Builder(
        builder: (context) => GestureDetector(
          onSecondaryTapDown: (details) async {
            if (!ContentDragSurface.allowsContextMenu(context, details.kind)) {
              return;
            }
            final overlay =
                Navigator.of(context).overlay!.context.findRenderObject()!
                    as RenderBox;
            final selected = await showMenu<String>(
              context: context,
              position: RelativeRect.fromRect(
                Rect.fromLTWH(
                  details.globalPosition.dx,
                  details.globalPosition.dy,
                  0,
                  0,
                ),
                Offset.zero & overlay.size,
              ),
              items: menuItems(context),
            );
            if (selected != null && mounted) await action(selected, entry.id);
          },
          child: CompactContentCard(
            previewOnly: true,
            surfaceColor: Colors.transparent,
            previewColor: Colors.transparent,
            metadataColor: Colors.transparent,
            menuColor: Colors.transparent,
            entry: entry,
            sender: value['sender'] as String? ?? entry.sourceLabel,
            timestamp: compactTime(DateTime.fromMillisecondsSinceEpoch(time)),
            status: state.label,
            action: needsAction
                ? TextButton(
                    onPressed: () => action(state.primaryAction, entry.id),
                    child: Text(state.primaryLabel),
                  )
                : null,
            speed: active && (value['transferBytesPerSecond'] as num? ?? 0) > 0
                ? '${bytesLabel((value['transferBytesPerSecond'] as num).round())}/s'
                : '',
            onOpen: () => action('open', entry.id),
            onCopy: entry.kind == 'text'
                ? () => action('copy', entry.id)
                : null,
            menu: Semantics(
              label: '更多',
              child: PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (value) {
                  action(value, entry.id);
                },
                itemBuilder: menuItems,
                icon: const AppIcon(Icons.more_horiz, size: 20),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    scroll.dispose();
    ReceiveDockApp.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = Appearance.fromJson(
      payload['appearance'] as Map? ?? const {},
    );
    final theme = Ui.theme(appearance), palette = UiPalette.from(appearance);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(
        popupMenuTheme: theme.popupMenuTheme.copyWith(
          color: palette.softGreen,
          elevation: 0,
          shadowColor: Colors.transparent,
          menuPadding: const EdgeInsets.symmetric(vertical: 4),
          shape: RoundedRectangleBorder(
            borderRadius: Ui.fieldRadius,
            side: BorderSide(color: palette.border),
          ),
        ),
      ),
      // Keep labels out of the compact content strip; buttons retain semantics.
      // One opacity layer includes routes (menus), images and controls. Painting
      // individual translucent layers over each other made cards almost opaque.
      builder: (_, child) => Opacity(
        opacity: .7,
        child: TooltipVisibility(visible: false, child: child!),
      ),
      home: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              action('close'),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            key: const ValueKey('dock-pane'),
            backgroundColor: palette.softGreen,
            body: Listener(
              // Translucent gesture hits in the pane's gaps must also reach this
              // listener; otherwise window movement reuses an older down point.
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                heldPointer ??= event.pointer;
                pointerOrigin = event.position;
                pointerTouch = event.kind != PointerDeviceKind.mouse;
                setPointerHeld(true);
                if (HardwareKeyboard.instance.isAltPressed) {
                  beginMove();
                }
              },
              onPointerUp: (_) => setPointerHeld(false),
              onPointerCancel: (_) => setPointerHeld(false),
              child: RawGestureDetector(
                behavior: HitTestBehavior.translucent,
                gestures: {
                  _DockMovePan:
                      GestureRecognizerFactoryWithHandlers<_DockMovePan>(
                        _DockMovePan.new,
                        (recognizer) => recognizer.onStart = (_) => beginMove(),
                      ),
                },
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 30,
                          child: Row(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    DecoratedBox(
                                      key: const ValueKey('dock-count'),
                                      decoration: BoxDecoration(
                                        color: Colors.transparent,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 9,
                                          vertical: 5,
                                        ),
                                        child: Text(
                                          '收到 ${items.length} 项',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                    bulkDragHandle(),
                                  ],
                                ),
                              ),
                              DecoratedBox(
                                key: const ValueKey('dock-open'),
                                decoration: BoxDecoration(
                                  color: Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: ContentDragControl(
                                  child: Semantics(
                                    label: '打开 GlobalSend',
                                    child: IconButton(
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 30,
                                            height: 28,
                                          ),
                                      padding: EdgeInsets.zero,
                                      tooltip: '打开 GlobalSend',
                                      onPressed: () => action('open'),
                                      icon: const AppIcon(
                                        Icons.open_in_full,
                                        size: 19,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              DecoratedBox(
                                key: const ValueKey('dock-close'),
                                decoration: BoxDecoration(
                                  color: Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: ContentDragControl(
                                  child: Semantics(
                                    label: '关闭',
                                    child: IconButton(
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 30,
                                            height: 28,
                                          ),
                                      padding: EdgeInsets.zero,
                                      tooltip: '关闭',
                                      onPressed: () => action('close'),
                                      icon: const AppIcon(
                                        Icons.close,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Expanded(
                          child: LayoutBuilder(
                            key: const ValueKey('dock-content-strip'),
                            builder: (context, bounds) {
                              final edge = bounds.maxHeight;
                              final values = {
                                for (final item in items)
                                  item['id'] as String: item,
                              };
                              return Listener(
                                onPointerSignal: (event) {
                                  if (event is PointerScrollEvent &&
                                      scroll.hasClients) {
                                    GestureBinding
                                        .instance
                                        .pointerSignalResolver
                                        .register(event, (_) {
                                          scroll.jumpTo(
                                            (scroll.offset +
                                                    event.scrollDelta.dy +
                                                    event.scrollDelta.dx)
                                                .clamp(
                                                  0.0,
                                                  scroll
                                                      .position
                                                      .maxScrollExtent,
                                                ),
                                          );
                                        });
                                  }
                                },
                                child: SingleChildScrollView(
                                  key: const ValueKey('dock-horizontal-scroll'),
                                  controller: scroll,
                                  scrollDirection: Axis.horizontal,
                                  child: SizedBox(
                                    width: ((edge + 10) * order.length - 10)
                                        .clamp(
                                          bounds.maxWidth,
                                          double.infinity,
                                        ),
                                    height: edge,
                                    child: Stack(
                                      children: [
                                        for (var i = 0; i < order.length; i++)
                                          AnimatedPositioned(
                                            key: ValueKey(
                                              'dock-tile-${order[i]}',
                                            ),
                                            duration: const Duration(
                                              milliseconds: 240,
                                            ),
                                            curve: Curves.easeOutCubic,
                                            left: i * (edge + 10),
                                            top: 0,
                                            width: edge,
                                            height: edge,
                                            child:
                                                TweenAnimationBuilder<double>(
                                                  key: ValueKey(
                                                    'dock-arrival-${order[i]}',
                                                  ),
                                                  tween: Tween(
                                                    begin:
                                                        entering.contains(
                                                          order[i],
                                                        )
                                                        ? 1
                                                        : 0,
                                                    end: 0,
                                                  ),
                                                  duration: const Duration(
                                                    milliseconds: 260,
                                                  ),
                                                  curve: Curves.easeOutCubic,
                                                  builder: (_, value, child) =>
                                                      Transform.translate(
                                                        offset: Offset(
                                                          0,
                                                          -edge * value,
                                                        ),
                                                        child: Opacity(
                                                          opacity: 1 - value,
                                                          child: child,
                                                        ),
                                                      ),
                                                  child: SizedBox.expand(
                                                    child: card(
                                                      values[order[i]]!,
                                                    ),
                                                  ),
                                                ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        if (error.isNotEmpty)
                          Padding(
                            key: const ValueKey('dock-error'),
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              error,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockMovePan extends PanGestureRecognizer {
  @override
  bool isPointerAllowed(PointerEvent event) {
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    final bulkHandle = result.path.any(
      (entry) =>
          entry.target is RenderMetaData &&
          (entry.target as RenderMetaData).metaData == _batchDragMarker,
    );
    return !bulkHandle &&
        !isContentDragControlPosition(event.position, event.viewId) &&
        super.isPointerAllowed(event);
  }
}
