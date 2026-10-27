import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

import 'compact_content_card.dart';
import 'compact_time.dart';
import 'content_drag_surface.dart';
import 'models.dart';
import 'text_selection_surface.dart';
import 'ui_tokens.dart';
import 'received_order.dart';

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
  final countKey = GlobalKey(),
      openKey = GlobalKey(),
      closeKey = GlobalKey(),
      stripKey = GlobalKey(),
      errorKey = GlobalKey();
  final surfaces = <String, GlobalKey>{};
  bool regionScheduled = false, menuOpen = false, pointerHeld = false;
  int? heldPointer;
  Offset pointerOrigin = Offset.zero;
  bool pointerTouch = false;
  String regionSnapshot = '';

  void scheduleRegions() {
    if (regionScheduled || !mounted) return;
    regionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      regionScheduled = false;
      if (!mounted) return;
      final view = View.of(context), scale = view.devicePixelRatio;
      final screen = Offset.zero & (view.physicalSize / scale);
      Rect? bounds(GlobalKey key) {
        final box = key.currentContext?.findRenderObject();
        return box is RenderBox && box.attached && box.hasSize
            ? MatrixUtils.transformRect(
                box.getTransformTo(null),
                Offset.zero & box.size,
              )
            : null;
      }

      final strip = bounds(stripKey);
      final rects = <Rect>[];
      if (menuOpen || pointerHeld) {
        rects.add(screen);
      } else {
        for (final key in [countKey, openKey, closeKey, errorKey]) {
          final rect = bounds(key);
          if (rect != null) rects.add(rect.inflate(2).intersect(screen));
        }
        if (strip != null)
          for (final id in order) {
            final rect = bounds(surfaces[id]!);
            final visible = rect?.intersect(strip);
            if (visible != null && !visible.isEmpty)
              rects.add(visible.inflate(2).intersect(screen));
          }
      }
      final data = {
        'width': view.physicalSize.width.round(),
        'height': view.physicalSize.height.round(),
        'rects': [
          for (final rect in rects.where((r) => !r.isEmpty))
            {
              'left': (rect.left * scale).floor(),
              'top': (rect.top * scale).floor(),
              'right': (rect.right * scale).ceil(),
              'bottom': (rect.bottom * scale).ceil(),
            },
        ],
      };
      final snapshot = '$data';
      if (snapshot == regionSnapshot) return;
      regionSnapshot = snapshot;
      unawaited(ReceiveDockApp.channel.invokeMethod<void>('hitRegions', data));
    });
  }

  void setMenuOpen(bool value) {
    menuOpen = value;
    scheduleRegions();
    WidgetsBinding.instance.scheduleFrame();
  }

  void setPointerHeld(bool value) {
    pointerHeld = value;
    if (!value) heldPointer = null;
    scheduleRegions();
    WidgetsBinding.instance.scheduleFrame();
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
    // Scrolling can only move retained composited layers in the real engine;
    // the card paint observer does not necessarily repaint in that case.
    scroll.addListener(scheduleRegions);
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
        final ids = entries.map((entry) => entry.id).toList();
        final added = ids.where((id) => !order.contains(id)).toList();
        entering = order.isEmpty ? {} : added.toSet();
        final frontChanged =
            order.isNotEmpty && ids.isNotEmpty && order.first != ids.first;
        order = ids;
        for (final id in order) {
          surfaces.putIfAbsent(id, GlobalKey.new);
        }
        surfaces.removeWhere((id, _) => !order.contains(id));
        payload = next;
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
    final needsAction =
        entry.status == 'failed' || entry.relayConfirmationPending;
    final active = const [
      'uploading',
      'downloading',
      'directSending',
    ].contains(entry.status);
    List<PopupMenuEntry<String>> menuItems(BuildContext _) => [
      const PopupMenuItem(value: 'open', child: Text('打开')),
      if (entry.kind == 'text' || entry.localPath.isNotEmpty)
        const PopupMenuItem(value: 'stage', child: Text('加入待发')),
    ];
    return ContentDragSurface(
      entry: entry,
      enabled: entry.kind == 'text' || entry.localPath.isNotEmpty,
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
            setMenuOpen(true);
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
            setMenuOpen(false);
            if (selected != null && mounted) await action(selected, entry.id);
          },
          child: CompactContentCard(
            surfaceColor: Colors.transparent,
            previewColor: Ui.input.withValues(alpha: .78),
            metadataColor: const Color(0xC7ECF3EE),
            menuColor: Colors.white.withValues(alpha: .82),
            entry: entry,
            sender: value['sender'] as String? ?? entry.sourceLabel,
            timestamp: compactTime(DateTime.fromMillisecondsSinceEpoch(time)),
            status: entry.status == 'failed'
                ? '接收失败'
                : entry.relayConfirmationPending
                ? '需要确认中继'
                : '',
            action: needsAction
                ? TextButton(
                    onPressed: () => action('open', entry.id),
                    child: const Text('处理'),
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
                onOpened: () => setMenuOpen(true),
                onCanceled: () => setMenuOpen(false),
                onSelected: (value) {
                  setMenuOpen(false);
                  action(value, entry.id);
                },
                itemBuilder: menuItems,
                icon: const Icon(Icons.more_horiz, size: 20),
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
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: Ui.theme(),
    // Compact previews and icon hover highlights are already self-explanatory.
    // TooltipTriggerMode.manual still shows mouse hover overlays, which both
    // obscure these small cards and lie outside their native window region.
    builder: (_, child) => TooltipVisibility(visible: false, child: child!),
    home: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => action('close'),
      },
      child: Focus(
        autofocus: true,
        child: _DockPaintSurfaces(
          onPaint: scheduleRegions,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Listener(
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
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: (_) => beginMove(),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: DecoratedBox(
                                      key: countKey,
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: .78,
                                        ),
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
                                  ),
                                ),
                              ),
                              DecoratedBox(
                                key: openKey,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .78),
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
                                      icon: const Icon(
                                        Icons.open_in_full,
                                        size: 19,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              DecoratedBox(
                                key: closeKey,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .78),
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
                                      icon: const Icon(Icons.close, size: 20),
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
                            key: stripKey,
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
                                  // The viewport is a repaint boundary: the
                                  // observer above Scaffold does not repaint
                                  // when only horizontal scroll changes. Read
                                  // current card transforms inside that boundary.
                                  child: _DockPaintSurfaces(
                                    onPaint: scheduleRegions,
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
                                                      key: surfaces[order[i]],
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
                                ),
                              );
                            },
                          ),
                        ),
                        if (error.isNotEmpty)
                          Padding(
                            key: errorKey,
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
    ),
  );
}

class _DockMovePan extends PanGestureRecognizer {
  @override
  bool isPointerAllowed(PointerEvent event) =>
      !isContentDragControlPosition(event.position, event.viewId) &&
      super.isPointerAllowed(event);
}

class _DockPaintSurfaces extends SingleChildRenderObjectWidget {
  const _DockPaintSurfaces({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _DockSurfacesRender(onPaint);
  @override
  void updateRenderObject(
    BuildContext context,
    _DockSurfacesRender renderObject,
  ) => renderObject.onPaint = onPaint;
}

class _DockSurfacesRender extends RenderProxyBox {
  _DockSurfacesRender(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}
