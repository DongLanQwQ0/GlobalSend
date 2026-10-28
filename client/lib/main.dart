import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'screen.dart';
import 'system_bridge.dart';
import 'ui_session.dart';
import 'ui_tokens.dart';
import 'appearance.dart';
import 'app_update_ui.dart';
import 'receive_dock_window.dart';
import 'ios_back_swipe.dart';
import 'file_share.dart';
import 'url_intent_notice.dart';

void main(List<String> args) {
  if (Platform.isWindows && args.contains('--receive-dock')) {
    runGlobalSendReceiveDock();
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Google Material icon vectors',
    ], await rootBundle.loadString('assets/licenses/material-icons.txt'));
  });
  runApp(GlobalSendApp(controller: SendController()));
}

class GlobalSendApp extends StatefulWidget {
  const GlobalSendApp({super.key, required this.controller});
  final SendController controller;
  @override
  State<GlobalSendApp> createState() => _GlobalSendAppState();
}

class _GlobalSendAppState extends State<GlobalSendApp>
    with WidgetsBindingObserver {
  SendController get controller => widget.controller;
  SendUiSession session = SendUiSession();
  final navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<Map<String, dynamic>>? windowSubscription;
  StreamSubscription<void>? shareSubscription;
  Future<void>? shareWork;
  bool shareAgain = false;
  bool windowVisible = true;
  int receiptSerial = 0;
  String receiptPayload = '';
  int presentationRequest = 0;

  void receiptChanged() {
    if (!Platform.isWindows) return;
    final items = controller.pendingReceipts.values
        .where((item) => item.id != 'group-shared-text')
        .map(
          (item) => <String, dynamic>{
            ...item.toJson(),
            'transferBytesPerSecond': item.transferBytesPerSecond,
            'progress': item.progress,
            'sender': item.sourceLabel.isNotEmpty
                ? item.sourceLabel
                : controller.devices
                              .where(
                                (device) => device['deviceId'] == item.source,
                              )
                              .firstOrNull?['name']
                          as String? ??
                      '其他设备',
          },
        )
        .toList();
    final encoded = jsonEncode({
      'items': items,
      'appearance': controller.appearance.value.toJson(),
    });
    if (controller.receiptSerial == receiptSerial &&
        encoded == receiptPayload) {
      return;
    }
    final newArrival =
        receiptSerial != controller.receiptSerial || receiptPayload.isEmpty;
    receiptSerial = controller.receiptSerial;
    receiptPayload = encoded;
    final request = ++presentationRequest;
    if (items.isEmpty) {
      controller.receiptPresentedExternally = false;
      final generation = SystemBridge.receiptArrivalGeneration;
      if (generation != null) {
        unawaited(
          SystemBridge.dismissReceiveDock(generation).catchError((Object _) {}),
        );
      }
      return;
    }
    // Suppress the main overlay until native focus decides the presentation.
    if (newArrival) controller.receiptPresentedExternally = true;
    unawaited(presentReceipts(items, receiptSerial, request));
  }

  Future<void> presentReceipts(
    List<Map<String, dynamic>> items,
    int serial,
    int request,
  ) async {
    try {
      final state = await SystemBridge.presentReceiveDock(
        items: items,
        serial: serial,
        appearance: controller.appearance.value.toJson(),
      );
      if (!mounted ||
          request != presentationRequest ||
          controller.pendingReceipts.isEmpty ||
          serial != controller.receiptSerial ||
          state['presentation'] == 'superseded') {
        return;
      }
      controller.receiptPresentedExternally = state['presentation'] == 'dock';
      controller.changed();
    } catch (error) {
      if (!mounted ||
          request != presentationRequest ||
          serial != controller.receiptSerial) {
        return;
      }
      controller.message = '接收窗口未能打开：$error';
      controller.receiptPresentedExternally = false;
      controller.changed();
    }
  }

  Future<void> dockAction(Map<String, dynamic> action) async {
    try {
      final id = action['id'] as String?;
      final entry = controller.historyDock
          .where((item) => item.id == id)
          .firstOrNull;
      switch (action['action']) {
        case 'close':
          controller.dismissReceipts(
            List<String>.from(action['itemIds'] ?? []),
            throughSerial: action['serial'] as int?,
          );
          session.pendingReceipts.removeWhere(
            (id, _) => !controller.pendingReceipts.containsKey(id),
          );
          session.pendingReceipt = session.pendingReceipts.values.lastOrNull;
          if (controller.pendingReceipts.isEmpty) {
            controller.receiptPresentedExternally = false;
          }
          controller.changed();
        case 'copy':
          if (entry != null && entry.kind == 'text') {
            await controller.copyDockText(entry);
          }
        case 'receive':
          if (entry != null) {
            if (entry.status == 'offered') {
              await controller.accept(entry, true);
            } else {
              await controller.receive(entry);
            }
          }
        case 'retry':
          if (entry != null) await controller.retry(entry);
        case 'approveRelay':
          if (entry != null) await controller.approveRelay(entry);
        case 'pause':
          if (entry != null) await controller.pause(entry);
        case 'resume':
          if (entry != null) await controller.resume(entry);
        case 'cancel':
          if (entry != null) await controller.cancel(entry);
        case 'stage':
          if (entry != null) await controller.stageHistoryEntry(entry);
          await SystemBridge.activateWindow();
        case 'reveal':
          if (entry != null && entry.localPath.isNotEmpty) {
            await SystemBridge.revealFile(entry.localPath);
          }
        case 'delete':
          // Remove the presentation before filesystem/persistence work. Deletion
          // used to notify while the receipt was still present, then dismiss it
          // without notifying again, leaving a stale card until another event.
          if (id != null) {
            controller.dismissReceipts([id]);
            session.pendingReceipts.remove(id);
            session.pendingReceipt = session.pendingReceipts.values.lastOrNull;
            if (controller.pendingReceipts.isEmpty) {
              controller.receiptPresentedExternally = false;
            }
            controller.changed();
          }
          if (entry != null) await controller.removeHistoryEntries([entry]);
        case 'details':
          if (entry != null) {
            await SystemBridge.activateWindow();
            session.detailsId = entry.id;
            session.detailsRequest++;
            controller.changed();
          }
        case 'open':
          await SystemBridge.activateWindow();
          controller.receiptPresentedExternally = false;
          controller.openReceivedNotification(
            id == null ? 'receive' : 'receive:$id',
          );
      }
    } catch (error) {
      if (!mounted) return;
      controller.message = '操作未完成：$error';
      controller.changed();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    receiptSerial = controller.receiptSerial;
    controller.addListener(receiptChanged);
    controller.appearance.addListener(appearanceChanged);
    if (Platform.isWindows || Platform.isAndroid) {
      windowSubscription = SystemBridge.windowEvents.listen(windowEvent);
    }
    if (Platform.isWindows) {
      unawaited(
        SystemBridge.windowVisible().then((visible) {
          if (mounted) windowEvent({'visible': visible});
        }),
      );
    }
    initialize();
  }

  Future<void> initialize() async {
    await controller.init();
    if (!mounted) return;
    if (FileShareBridge.supported) {
      shareSubscription ??= FileShareBridge.incoming.listen(
        (_) => unawaited(drainSharedInputs()),
        onError: (Object error) {
          if (mounted) {
            controller.message = '未能导入分享内容：$error';
            controller.changed();
          }
        },
      );
      await drainSharedInputs();
    }
    if (Platform.isWindows) await SystemBridge.drainLaunchFiles();
    if (Platform.isWindows && controller.root != null) {
      await SystemBridge.configureWindowPersistence(
        '${controller.root!.path}/window.json',
        restore: false,
      );
    }
    if (Platform.isWindows) {
      // Startup/connection owns warm-up, not the first incoming receipt.
      // Native keeps this content-free UI engine for subsequent arrivals.
      unawaited(SystemBridge.prepareReceiveDock().catchError((Object _) {}));
    }
    if (Platform.isAndroid) {
      final state = await SystemBridge.receivedWindowState();
      if (!mounted) return;
      windowEvent({'receiptFloating': state['floating'] == true});
    }
    updateForeground(WidgetsBinding.instance.lifecycleState);
  }

  void appearanceChanged() {
    // Refresh an already visible UI-only dock without pretending a new file arrived.
    receiptChanged();
  }

  void windowEvent(Map<String, dynamic> event) {
    if (event['dockAction'] is Map) {
      unawaited(dockAction(Map<String, dynamic>.from(event['dockAction'])));
      return;
    }
    final floating = event['receiptFloating'];
    if (floating is bool && floating != controller.receiptWindowFloating) {
      controller.receiptWindowFloating = floating;
      controller.changed();
    }
    if (event['received'] == true) controller.openReceivedNotification();
    final visible = event['visible'];
    if (visible is! bool || visible == windowVisible || !mounted) return;
    setState(() => windowVisible = visible);
    updateForeground(WidgetsBinding.instance.lifecycleState);
    if (!visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      });
    }
  }

  Future<void> drainSharedInputs() {
    if (!FileShareBridge.supported || !mounted) return Future.value();
    if (shareWork != null) {
      shareAgain = true;
      return shareWork!;
    }
    final owner = controller;
    final work =
        () async {
          do {
            shareAgain = false;
            for (final batch in await FileShareBridge.pending()) {
              if (!mounted || !identical(owner, controller)) return;
              if (batch.error != null) {
                owner.message = batch.error!;
                owner.changed();
                continue;
              }
              final stored = await owner.stageSharedInputs(
                batch.batchId,
                batch.paths,
                batch.texts,
                batch.temporaryPaths,
              );
              if (stored) await FileShareBridge.ack(batch.batchId);
            }
          } while (shareAgain && mounted);
        }().catchError((Object error) {
          if (mounted && identical(owner, controller)) {
            owner.message = '未能导入分享内容：$error';
            owner.changed();
          }
        });
    shareWork = work;
    return work.whenComplete(() => shareWork = null);
  }

  void updateForeground(AppLifecycleState? state) {
    final active =
        windowVisible && (state == null || state == AppLifecycleState.resumed);
    controller.setAppForeground(active);
    controller.updates.setForeground(active);
    controller.setProbeForeground(
      windowVisible && (state == null || state == AppLifecycleState.resumed),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    updateForeground(state);
    if (state == AppLifecycleState.resumed) unawaited(drainSharedInputs());
    if (Platform.isWindows &&
        state == AppLifecycleState.resumed &&
        windowVisible &&
        controller.receiptPresentedExternally) {
      receiptPayload = '';
      receiptChanged();
    }
  }

  @override
  void didUpdateWidget(GlobalSendApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(receiptChanged);
      oldWidget.controller.appearance.removeListener(appearanceChanged);
      oldWidget.controller.dispose();
      receiptSerial = controller.receiptSerial;
      receiptPayload = '';
      presentationRequest++;
      controller.addListener(receiptChanged);
      controller.appearance.addListener(appearanceChanged);
      session = SendUiSession();
      initialize();
    }
  }

  @override
  void dispose() {
    windowSubscription?.cancel();
    shareSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(receiptChanged);
    controller.appearance.removeListener(appearanceChanged);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !windowVisible
      ? const SizedBox.shrink(key: ValueKey('window-ui-unloaded'))
      : AppUpdatesScope(
          updates: controller.updates,
          child: AppearanceScope(
            settings: controller.appearance,
            child: AnimatedBuilder(
              animation: controller.appearance,
              builder: (context, _) => MaterialApp(
                title: 'GlobalSend',
                debugShowCheckedModeBanner: false,
                navigatorObservers: [session.routes],
                navigatorKey: navigatorKey,
                theme: Ui.theme(
                  controller.appearance.value.resolve(Brightness.light),
                ),
                darkTheme: Ui.theme(
                  controller.appearance.value.resolve(Brightness.dark),
                ),
                themeMode:
                    controller.appearance.value.mode == AppearanceMode.system
                    ? ThemeMode.system
                    : controller.appearance.value.mode == AppearanceMode.dark
                    ? ThemeMode.dark
                    : ThemeMode.light,
                builder: (context, navigator) => AnimatedBuilder(
                  animation: controller,
                  child: navigator,
                  builder: (context, child) => IosBackSwipe(
                    navigatorKey: navigatorKey,
                    child: NativeDropFeedback(
                      active: controller.nativeDragActive,
                      importing: controller.nativeImporting,
                      child: UrlIntentNotice(
                        integration: controller.urlIntents,
                        child: AppUpdateNotice(child: child!),
                      ),
                    ),
                  ),
                ),
                home: SendScreen(controller: controller, session: session),
              ),
            ),
          ),
        );
}
