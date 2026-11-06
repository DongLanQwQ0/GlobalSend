import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'compact_content_card.dart';
import 'copied_file_reference_card.dart';
import 'bulk_file_drag.dart';
import 'app_icon.dart';
import 'system_bridge.dart';
import 'compact_time.dart';
import 'content_drag_surface.dart';
import 'content_actions.dart';
import 'image_kind.dart';
import 'models.dart';
import 'text_selection_surface.dart';
import 'ui_tokens.dart';
import 'appearance.dart';
import 'received_order.dart';
import 'incoming_receipt_state.dart';
import 'android_queue_drop_host.dart';

final _batchDragMarker = Object();
final _dockContentMarker = Object();

class _DockPopupObserver extends NavigatorObserver {
  _DockPopupObserver(this.changed);
  final ValueChanged<bool> changed;
  final popups = <Route<dynamic>>{};
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      popups.add(route);
      changed(true);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (popups.remove(route)) changed(popups.isNotEmpty);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (popups.remove(route)) changed(popups.isNotEmpty);
  }
}

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

class _ReceiveDockAppState extends State<ReceiveDockApp>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Map<String, dynamic> payload = {};
  int revision = 0;
  bool presented = false;
  String error = '';
  final scroll = ScrollController();
  final deviceScroll = ScrollController();
  final deviceKeys = <String, GlobalKey>{};
  final interactionPointers = <int>{};
  final interactionScrolls = <BuildContext>{};
  bool popupInteraction = false, publishedInteraction = false;
  int pendingActions = 0;
  late final popupObserver = _DockPopupObserver((active) {
    popupInteraction = active;
    publishInteraction();
  });
  void publishInteraction() {
    interactionScrolls.removeWhere((context) => !context.mounted);
    final active =
        popupInteraction ||
        pendingActions > 0 ||
        interactionPointers.isNotEmpty ||
        interactionScrolls.isNotEmpty;
    if (active == publishedInteraction) return;
    publishedInteraction = active;
    unawaited(
      ReceiveDockApp.channel.invokeMethod<void>('interaction', {
        'active': active,
      }),
    );
  }

  final dropQueueKey = GlobalKey();
  Timer? hoverTimer, restoreTimer;
  bool dropInside = false, deviceMode = false;
  String hoverDevice = '';
  Offset dropPointer = Offset.zero;
  late final Ticker edgeTicker;
  Duration lastEdgeFrame = Duration.zero;

  void dropHover(Map event) {
    final active = event['active'] == true;
    dropPointer =
        Offset(
          (event['x'] as num? ?? 0).toDouble(),
          (event['y'] as num? ?? 0).toDouble(),
        ) /
        View.of(context).devicePixelRatio;
    if (!active) {
      hoverTimer?.cancel();
      hoverTimer = null;
      edgeTicker.stop();
      dropInside = false;
      if (hoverDevice.isNotEmpty) setState(() => hoverDevice = '');
      if (deviceMode && restoreTimer == null) {
        restoreTimer = Timer(const Duration(seconds: 1), () {
          restoreTimer = null;
          if (mounted && !dropInside) setState(() => deviceMode = false);
        });
      }
      return;
    }
    restoreTimer?.cancel();
    restoreTimer = null;
    if (!dropInside) {
      dropInside = true;
      if (!deviceMode) {
        hoverTimer = Timer(const Duration(seconds: 1), () {
          hoverTimer = null;
          if (!mounted || !dropInside) return;
          setState(() => deviceMode = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) updateEdgeScroll();
          });
        });
      }
    }
    final target = event['targetDeviceId'] as String? ?? '';
    if (target != hoverDevice) setState(() => hoverDevice = target);
    updateEdgeScroll();
  }

  double get edgeDirection {
    final width =
        View.of(context).physicalSize.width / View.of(context).devicePixelRatio;
    if (dropPointer.dx < 36)
      return -((36 - dropPointer.dx) / 36).clamp(0.0, 1.0);
    if (dropPointer.dx > width - 36)
      return ((dropPointer.dx - width + 36) / 36).clamp(0.0, 1.0);
    return 0;
  }

  void updateEdgeScroll() {
    if (!deviceMode ||
        !dropInside ||
        edgeDirection == 0 ||
        !deviceScroll.hasClients ||
        deviceScroll.position.maxScrollExtent == 0) {
      edgeTicker.stop();
      return;
    }
    if (!edgeTicker.isActive) {
      lastEdgeFrame = Duration.zero;
      edgeTicker.start();
    }
  }

  void scrollDeviceEdge(Duration elapsed) {
    final seconds = (elapsed - lastEdgeFrame).inMicroseconds / 1000000;
    lastEdgeFrame = elapsed;
    if (!deviceMode ||
        !dropInside ||
        !deviceScroll.hasClients ||
        edgeDirection == 0) {
      edgeTicker.stop();
      return;
    }
    final direction = edgeDirection;
    final distance =
        direction.sign *
        (60 + 360 * direction.abs()) *
        seconds.clamp(0.0, .032);
    final next = (deviceScroll.offset + distance).clamp(
      0.0,
      deviceScroll.position.maxScrollExtent,
    );
    if (next == deviceScroll.offset && seconds > 0) {
      edgeTicker.stop();
      return;
    }
    deviceScroll.jumpTo(next);
  }

  Widget sendDevices() {
    final seen = <String>{};
    final devices = [
      for (final value in payload['devices'] as List? ?? const [])
        if (value is Map &&
            value['deviceId'] is String &&
            seen.add(value['deviceId'] as String))
          Map<String, dynamic>.from(value),
    ];
    deviceKeys.removeWhere((id, _) => !seen.contains(id));
    return LayoutBuilder(
      builder: (context, bounds) {
        if (devices.isEmpty) return const Center(child: Text('暂无可发送设备'));
        return ListView.separated(
          key: const ValueKey('dock-device-strip'),
          controller: deviceScroll,
          scrollDirection: Axis.horizontal,
          itemCount: devices.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final device = devices[index], id = device['deviceId'] as String;
            final colors = Ui.colors(context), selected = hoverDevice == id;
            return SizedBox(
              key: deviceKeys.putIfAbsent(id, GlobalKey.new),
              width: bounds.maxHeight,
              child: DecoratedBox(
                key: ValueKey('dock-device-$id'),
                decoration: BoxDecoration(
                  color: selected ? colors.accentSoft : colors.surfaceMuted,
                  borderRadius: Ui.cardRadius,
                  border: Border.all(
                    color: selected ? colors.accent : colors.line,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AppIcon(
                      device['platform'] == 'windows'
                          ? Icons.computer_outlined
                          : device['platform'] == 'web'
                          ? Icons.web_outlined
                          : Icons.phone_android_outlined,
                      size: 26,
                      color: selected ? colors.accent : colors.textSecondary,
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        device['name'] as String? ?? '设备',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: Ui.textXs),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

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
    WidgetsBinding.instance.addObserver(this);
    edgeTicker = createTicker(scrollDeviceEdge);
    ReceiveDockApp.channel.setMethodCallHandler((call) async {
      if (call.method == 'content') {
        revision++;
        apply(Map<String, dynamic>.from(call.arguments));
      } else if (call.method == 'interactionEnded') {
        setPointerHeld(false);
      } else if (call.method == 'dropHover') {
        dropHover(call.arguments as Map);
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
        final references = (next['copiedFiles'] as List? ?? []).cast<Map>();
        final ids = [
          if (next['clipboardSlot'] is Map) 'clipboard-slot',
          ...receiptDisplayOrder(order, entries),
          ...references.map((reference) => reference['id'] as String),
        ];
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
                scroll.animateTo(0, duration: Ui.durationSlow, curve: Ui.ease),
              );
            }
          });
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(payload, next)) return;
        final slot = next['clipboardSlot'];
        unawaited(
          ReceiveDockApp.channel.invokeMethod<void>('clipboardSlotRendered', {
            'path': slot is Map ? slot['localPath'] ?? '' : '',
          }),
        );
      });
      unawaited(refreshExportableFiles(next));
      if (items.isEmpty &&
          copiedReferences.isEmpty &&
          payload['clipboardSlot'] == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !identical(payload, next)) return;
          // This engine belongs only to the dock. Keeping it warm should not
          // retain decoded photos after its hidden content has been cleared.
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        });
      }
      if (!presented &&
          (items.isNotEmpty ||
              copiedReferences.isNotEmpty ||
              payload['clipboardSlot'] is Map)) {
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

  List<Map<String, dynamic>> get copiedReferences =>
      (payload['copiedFiles'] as List? ?? [])
          .map(
            (value) => <String, dynamic>{
              ...Map<String, dynamic>.from(value as Map),
              'copiedReference': true,
            },
          )
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
                width: Ui.touch,
                height: 30,
                child: Center(
                  child: AppIcon(Icons.file_copy_outlined, size: Ui.iconSm),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> action(String action, [String? id]) async {
    pendingActions++;
    publishInteraction();
    final snapshot = payload;
    final ids = items.map((item) => item['id']).toList();
    try {
      await ReceiveDockApp.channel.invokeMethod<void>('action', {
        'action': action,
        'id': id,
        'serial': snapshot['serial'],
        'arrivalGeneration': snapshot['arrivalGeneration'],
        'itemIds': ids,
        if (action == 'pullCopiedFile' || action == 'dismissCopiedFile')
          'serverKey': snapshot['serverKey'],
      });
    } on PlatformException catch (failure) {
      if (mounted) setState(() => error = failure.message ?? '操作未完成');
    } finally {
      pendingActions--;
      publishInteraction();
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
    if (value['copiedReference'] == true) {
      final ready =
          value['state'] == 'received' &&
          (value['localPath'] as String? ?? '').isNotEmpty;
      final entry = DockEntry(
        id: value['id'],
        kind: 'file',
        title: value['name'],
        source: value['sourceDeviceId'],
        localPath: value['localPath'] ?? '',
        entryKind: value['kind'] == 'directory' ? 'directory' : 'file',
        status: ready ? 'received' : 'offered',
      );
      return Builder(
        builder: (context) => MetaData(
          metaData: _dockContentMarker,
          behavior: HitTestBehavior.translucent,
          child: ContentDragSurface(
            entry: entry,
            nativeOnly: !ready,
            onExport: (kind) async {
              await ReceiveDockApp.channel.invokeMethod<bool>(
                ready ? 'dragOut' : 'startRemoteReferenceDrag',
                {
                  if (ready)
                    'paths': [entry.localPath]
                  else
                    'remoteReference': {
                      ...value,
                      if (value['entries'] is String)
                        'entries': jsonDecode(value['entries'] as String),
                    },
                  'pointerKind': kind,
                  ...SystemBridge.dragPreviewArguments,
                },
              );
            },
            child: CopiedFileReferenceCard(
              reference: value,
              surfaceColor: Ui.colors(context).surfaceMuted
                  .withValues(alpha: .45),
              onPull: () => action('pullCopiedFile', value['id'] as String),
              onDismiss: () =>
                  action('dismissCopiedFile', value['id'] as String),
            ),
          ),
        ),
      );
    }
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
    List<PopupMenuEntry<String>> menuItems(bool image) => [
      if (state.canExport && entry.localPath.isNotEmpty)
        const PopupMenuItem(value: 'reveal', height: 32, child: Text('定位文件')),
      if (entry.kind == 'text' || image && state.canExport)
        const PopupMenuItem(value: 'copy', height: 32, child: Text('复制')),
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
    return MetaData(
      metaData: _dockContentMarker,
      behavior: HitTestBehavior.translucent,
      child: ContentDragSurface(
        entry: entry,
        enabled: state.canExport,
        onExport: (kind) => export(entry, kind),
        child: Builder(
          builder: (context) => GestureDetector(
            onSecondaryTapDown: (details) async {
              if (!ContentDragSurface.allowsContextMenu(
                context,
                details.kind,
              )) {
                return;
              }
              final image =
                  state.canExport &&
                  entry.kind == 'file' &&
                  !entry.isDirectory &&
                  await imageAtLocation(entry.localPath, entry.title);
              if (!context.mounted) return;
              final selected = await showContentMenuAt(
                context,
                details.globalPosition,
                menuItems(image),
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
              speed:
                  active && (value['transferBytesPerSecond'] as num? ?? 0) > 0
                  ? '${bytesLabel((value['transferBytesPerSecond'] as num).round())}/s'
                  : '',
              onOpen: () => action('open', entry.id),
              onCopy: entry.kind == 'text'
                  ? () => action('copy', entry.id)
                  : null,
              menuBuilder: (_, image) => Semantics(
                label: '更多',
                child: PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) {
                    action(value, entry.id);
                  },
                  itemBuilder: (_) => menuItems(image),
                  icon: const AppIcon(Icons.more_horiz, size: Ui.iconSm),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void didChangePlatformBrightness() {
    setState(() {});
  }

  @override
  void dispose() {
    if (publishedInteraction)
      unawaited(
        ReceiveDockApp.channel.invokeMethod<void>('interaction', {
          'active': false,
        }),
      );
    WidgetsBinding.instance.removeObserver(this);
    scroll.dispose();
    hoverTimer?.cancel();
    restoreTimer?.cancel();
    edgeTicker.dispose();
    deviceScroll.dispose();
    ReceiveDockApp.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = Appearance.fromJson(
      payload['appearance'] as Map? ?? const {},
    ).resolve(WidgetsBinding.instance.platformDispatcher.platformBrightness);
    final theme = Ui.theme(appearance), palette = UiPalette.from(appearance);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorObservers: [popupObserver],
      theme: theme.copyWith(
        popupMenuTheme: theme.popupMenuTheme.copyWith(
          color: palette.accentSoft,
          elevation: Ui.elevationFlat,
          shadowColor: Colors.transparent,
          menuPadding: const EdgeInsets.symmetric(vertical: Ui.space0),
          shape: RoundedRectangleBorder(
            borderRadius: Ui.fieldRadius,
            side: BorderSide(color: palette.line),
          ),
        ),
      ),
      // Keep labels out of the compact content strip; buttons retain semantics.
      // One opacity layer includes routes (menus), images and controls. Painting
      // individual translucent layers over each other made cards almost opaque.
      builder: (_, child) => NativeQueueDropHost(
        target: dropQueueKey,
        enabled: deviceMode,
        deviceTargets: deviceKeys,
        serverKey: payload['serverKey'] as String? ?? '',
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            final source = notification.context;
            if (source != null) {
              if (notification is ScrollStartNotification)
                interactionScrolls.add(source);
              if (notification is ScrollEndNotification)
                interactionScrolls.remove(source);
              publishInteraction();
            }
            return false;
          },
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) {
              interactionPointers.add(event.pointer);
              publishInteraction();
            },
            onPointerUp: (event) {
              interactionPointers.remove(event.pointer);
              publishInteraction();
            },
            onPointerCancel: (event) {
              interactionPointers.remove(event.pointer);
              publishInteraction();
            },
            child: Opacity(
              opacity: .7,
              child: TooltipVisibility(visible: false, child: child!),
            ),
          ),
        ),
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
            backgroundColor: palette.accentSoft,
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
                  _DockBlankTap:
                      GestureRecognizerFactoryWithHandlers<_DockBlankTap>(
                        _DockBlankTap.new,
                        (recognizer) => recognizer.onTap = () => action('open'),
                      ),
                  _DockMovePan:
                      GestureRecognizerFactoryWithHandlers<_DockMovePan>(
                        _DockMovePan.new,
                        (recognizer) => recognizer.onStart = (_) => beginMove(),
                      ),
                },
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      10,
                      Ui.space0,
                      10,
                      Ui.space1,
                    ),
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
                                        borderRadius: Ui.fieldRadius,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: Ui.space1,
                                          vertical: Ui.space0,
                                        ),
                                        child: Text(
                                          deviceMode
                                              ? '发送至设备'
                                              : copiedReferences.isEmpty
                                              ? '收到 ${items.length} 项'
                                              : items.isEmpty
                                              ? '可拉取 ${copiedReferences.length} 项'
                                              : '收到 ${items.length} 项 · 可拉取 ${copiedReferences.length} 项',
                                          style: const TextStyle(
                                            fontSize: Ui.text2xs,
                                            fontWeight: Ui.weightLabel,
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
                                  borderRadius: Ui.fieldRadius,
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
                                        size: Ui.iconSm,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: Ui.space0),
                              DecoratedBox(
                                key: const ValueKey('dock-close'),
                                decoration: BoxDecoration(
                                  color: Colors.transparent,
                                  borderRadius: Ui.fieldRadius,
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
                                        size: Ui.iconSm,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: Ui.space0),
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              IgnorePointer(
                                ignoring: deviceMode,
                                child: AnimatedOpacity(
                                  opacity: deviceMode ? 0 : 1,
                                  duration: Ui.durationFast,
                                  child: LayoutBuilder(
                                    key: const ValueKey('dock-content-strip'),
                                    builder: (context, bounds) {
                                      final edge = bounds.maxHeight;
                                      final values = {
                                        if (payload['clipboardSlot'] is Map)
                                          'clipboard-slot':
                                              Map<String, dynamic>.from(
                                                payload['clipboardSlot'] as Map,
                                              ),
                                        for (final item in items)
                                          item['id'] as String: item,
                                        for (final reference
                                            in copiedReferences)
                                          reference['id'] as String: reference,
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
                                                            event
                                                                .scrollDelta
                                                                .dy +
                                                            event
                                                                .scrollDelta
                                                                .dx)
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
                                          key: const ValueKey(
                                            'dock-horizontal-scroll',
                                          ),
                                          controller: scroll,
                                          scrollDirection: Axis.horizontal,
                                          child: SizedBox(
                                            width:
                                                ((edge + 10) * order.length -
                                                        10)
                                                    .clamp(
                                                      bounds.maxWidth,
                                                      double.infinity,
                                                    ),
                                            height: edge,
                                            child: Stack(
                                              children: [
                                                for (
                                                  var i = 0;
                                                  i < order.length;
                                                  i++
                                                )
                                                  AnimatedPositioned(
                                                    key: ValueKey(
                                                      'dock-tile-${order[i]}',
                                                    ),
                                                    duration: Ui.durationSlow,
                                                    curve: Ui.ease,
                                                    left: i * (edge + 10),
                                                    top: 0,
                                                    width: edge,
                                                    height: edge,
                                                    child: TweenAnimationBuilder<double>(
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
                                                      duration: Ui.durationSlow,
                                                      curve: Ui.ease,
                                                      builder:
                                                          (_, value, child) =>
                                                              Transform.translate(
                                                                offset: Offset(
                                                                  0,
                                                                  -edge * value,
                                                                ),
                                                                child: Opacity(
                                                                  opacity:
                                                                      1 - value,
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
                              ),
                              IgnorePointer(
                                ignoring: !deviceMode,
                                child: AnimatedOpacity(
                                  opacity: deviceMode ? 1 : 0,
                                  duration: Ui.durationFast,
                                  child: sendDevices(),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (error.isNotEmpty)
                          Padding(
                            key: const ValueKey('dock-error'),
                            padding: const EdgeInsets.only(top: Ui.space1),
                            child: Text(
                              error,
                              style: TextStyle(
                                fontSize: Ui.textXs,
                                height: Ui.leadingCompact,
                                color: Ui.colors(context).danger,
                              ),
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

class _DockBlankTap extends TapGestureRecognizer {
  @override
  bool isPointerAllowed(PointerDownEvent event) {
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    final content = result.path.any(
      (entry) =>
          entry.target is RenderMetaData &&
          [
            _dockContentMarker,
            _batchDragMarker,
          ].contains((entry.target as RenderMetaData).metaData),
    );
    return !content &&
        !isContentDragControlPosition(event.position, event.viewId) &&
        super.isPointerAllowed(event);
  }
}
