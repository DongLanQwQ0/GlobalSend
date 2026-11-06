import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'content_actions.dart';
import 'folder_cards.dart';
import 'screen.dart';
import 'system_bridge.dart';
import 'ui_session.dart';
import 'ui_tokens.dart';
import 'appearance.dart';
import 'app_update_ui.dart';
import 'receive_dock_window.dart';
import 'ios_back_swipe.dart';
import 'file_share.dart';
import 'shared_import_notice.dart';
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
  runApp(
    GlobalSendApp(
      controller: SendController(enableDesktopCommands: Platform.isWindows),
    ),
  );
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
  bool shareInputsReady = false;
  final shareImports = ValueNotifier<List<SharedBatch>>([]);
  bool windowVisible = true;
  bool updateDraftsReady = false;
  final updatePointers = <int>{};
  bool publishedUpdatePointer = false;
  void publishUpdatePointer() {
    final active = updatePointers.isNotEmpty;
    if (active == publishedUpdatePointer) return;
    publishedUpdatePointer = active;
    unawaited(SystemBridge.setMainUpdateInteraction(active));
  }

  int receiptSerial = 0;
  String receiptPayload = '';
  int presentationRequest = 0;
  Set<String> copiedReferenceIds = {};
  int copiedReferenceRevision = 0;

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
    final references = controller.nativeCopiedReferences;
    final referenceIds = references
        .map((reference) => reference['id']!)
        .toSet();
    final referenceArrival = referenceIds
        .difference(copiedReferenceIds)
        .isNotEmpty;
    if (referenceArrival) copiedReferenceRevision++;
    copiedReferenceIds = referenceIds;
    final encoded = jsonEncode({
      'items': items,
      'devices': controller.sendablePeers,
      'serverKey': controller.profile?.key ?? '',
      'appearance': controller.appearance.value.toJson(),
      'copiedFiles': references,
      'clipboardSlot': controller.clipboardSlot?.toJson(),
    });
    if (controller.receiptSerial == receiptSerial &&
        encoded == receiptPayload) {
      return;
    }
    final newArrival =
        receiptSerial != controller.receiptSerial ||
        referenceArrival ||
        receiptPayload.isEmpty && items.isNotEmpty;
    receiptSerial = controller.receiptSerial;
    receiptPayload = encoded;
    final request = ++presentationRequest;
    if (items.isEmpty &&
        references.isEmpty &&
        controller.clipboardSlot == null) {
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
    unawaited(
      presentReceipts(items, receiptSerial, request, quiet: !newArrival),
    );
  }

  Future<void> presentReceipts(
    List<Map<String, dynamic>> items,
    int serial,
    int request, {
    bool quiet = false,
  }) async {
    try {
      final state = await SystemBridge.presentReceiveDock(
        items: items,
        serial: serial,
        appearance: controller.appearance.value.toJson(),
        devices: controller.sendablePeers,
        serverKey: controller.profile?.key ?? '',
        copiedFiles: controller.nativeCopiedReferences,
        referenceRevision: copiedReferenceRevision,
        clipboardSlot: controller.clipboardSlot?.toJson(),
        quiet: quiet,
      );
      if (!mounted ||
          request != presentationRequest ||
          controller.pendingReceipts.isEmpty &&
              controller.copiedFiles.references.isEmpty ||
          serial != controller.receiptSerial ||
          state['presentation'] == 'superseded') {
        return;
      }
      if (!quiet)
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
    pendingDockUpdateActions++;
    try {
      final id = action['id'] as String?;
      final entry = id == 'clipboard-slot'
          ? controller.clipboardSlot
          : collapseFolderCards(controller.historyDock)
                .where((item) => item.id == id)
                .firstOrNull;
      switch (action['action']) {
        case 'pullCopiedFile':
          await controller.pullCopiedFileSelection({
            'id': id,
            'serverKey': action['serverKey'],
          });
        case 'dismissCopiedFile':
          await controller.pullCopiedFileSelection({
            'id': id,
            'serverKey': action['serverKey'],
            'dismiss': true,
          });
        case 'dropToDevice':
          await controller.handleNativeDockEvent({
            ...action,
            'type': 'nativeDrop',
          });
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
          if (id == 'clipboard-slot') {
            await controller.copyClipboardSlot();
          } else if (entry != null) {
            if (entry.kind == 'text') {
              await controller.copyDockText(entry);
            } else {
              await copySavedImage(entry.localPath);
            }
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
          if (id == 'clipboard-slot')
            await controller.stageClipboardSlot();
          else if (entry != null)
            await controller.stageHistoryEntry(entry);
          await SystemBridge.activateWindow();
        case 'reveal':
          if (entry != null && entry.localPath.isNotEmpty) {
            await SystemBridge.revealFile(entry.localPath);
          }
        case 'delete':
          if (id == 'clipboard-slot') {
            await controller.clearClipboardSlot();
            return;
          }
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
    } finally {
      pendingDockUpdateActions--;
      controller.updates.activityChanged();
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(FileShareBridge.startWindowLayout());
    if (FileShareBridge.supported) {
      shareSubscription = FileShareBridge.incoming.listen(
        (_) => unawaited(drainSharedInputs()),
        onError: (Object error) {
          if (mounted) {
            controller.message = '未能导入分享内容：$error';
            controller.changed();
          }
        },
      );
      unawaited(drainSharedInputs());
    }
    WidgetsBinding.instance.addObserver(this);
    configureUpdateHandoff();
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
    if (controller.root != null) {
      final restored = SendUiSession();
      try {
        if (await restored.loadUpdateDrafts(
          File('${controller.root!.path}/update-drafts.json'),
        )) {
          if (!mounted) return;
          setState(() => session = restored);
          if (restored.sharedDraftScope ==
              '${controller.profile?.storageKey}:${controller.profile?.groupId}') {
            controller.setSharedTextDraft(restored.sharedDraft);
          }
        }
      } on FormatException {
        /* A legacy handoff must not block app startup. */
      } on FileSystemException {
        /* Local files remain usable if the handoff is unavailable. */
      }
    }
    updateDraftsReady = true;
    shareInputsReady = true;
    controller.updates.activityChanged();
    if (FileShareBridge.supported) {
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

  void configureUpdateHandoff() {
    updateDraftsReady = false;
    controller.updates.canInstall = () =>
        updateDraftsReady &&
        pendingDockUpdateActions == 0 &&
        !SystemBridge.updateInteracting &&
        controller.updateIdle;
    controller.updates.beforeInstall = () async {
      final root = controller.root;
      if (root == null) return;
      session.sharedDraftScope = controller.sharedTextDirty
          ? '${controller.profile?.storageKey}:${controller.profile?.groupId}'
          : '';
      session.sharedDraft = controller.sharedTextDirty
          ? controller.sharedText
          : '';
      await session.saveUpdateDrafts(File('${root.path}/update-drafts.json'));
      await controller.saveForUpdate();
    };
    if (Platform.isWindows)
      SystemBridge.beforeUpdateExit = () {
        controller.updates.nativeInteractionChanged(
          SystemBridge.updateInteracting,
          retry: false,
        );
        return controller.updates.prepareExit();
      };
  }

  int pendingDockUpdateActions = 0;

  void windowEvent(Map<String, dynamic> event) {
    if (event['updateInteraction'] is bool) {
      controller.updates.nativeInteractionChanged(
        event['updateInteraction'] as bool,
      );
      return;
    }
    if (event['updateInstallDeferred'] == true) {
      controller.updates.installDeferred();
      return;
    }
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
            final batches = await FileShareBridge.pending();
            if (!mounted || !identical(owner, controller)) return;
            shareImports.value = batches;
            for (final batch in batches) {
              if (!mounted || !identical(owner, controller)) return;
              if (batch.importing || !shareInputsReady) continue;
              if (batch.error != null) {
                owner.message = batch.error!;
                owner.changed();
                if (batch.paths.isEmpty && batch.texts.isEmpty) {
                  await FileShareBridge.ack(batch.batchId);
                  shareImports.value = shareImports.value
                      .where((item) => item.batchId != batch.batchId)
                      .toList();
                  continue;
                }
              }
              final stored = await owner.stageSharedInputs(
                batch.batchId,
                batch.paths,
                batch.texts,
                batch.temporaryPaths,
                preserveTextCopies: batch.target != null,
              );
              if (stored) {
                await FileShareBridge.ack(batch.batchId);
                shareImports.value = shareImports.value
                    .where((item) => item.batchId != batch.batchId)
                    .toList();
                if (batch.target != null) {
                  try {
                    await owner.sendSharedBatch(batch);
                  } catch (error) {
                    owner.message = '自动发送未完成：$error';
                    owner.changed();
                  }
                }
              }
            }
          } while (shareAgain && mounted);
        }().catchError((Object error) {
          if (mounted && identical(owner, controller)) {
            shareImports.value = shareImports.value
                .where((batch) => batch.importing)
                .toList();
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
    if (!active) {
      updatePointers.clear();
      publishUpdatePointer();
    }
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
      configureUpdateHandoff();
      initialize();
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) SystemBridge.beforeUpdateExit = null;
    windowSubscription?.cancel();
    shareSubscription?.cancel();
    shareImports.dispose();
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
                // One shell-level motion for appearance changes: same 170ms
                // step and ease as the web token layer, so switching theme
                // never snaps between palettes.
                themeAnimationDuration: Ui.durationNormal,
                themeAnimationCurve: Ui.ease,
                builder: (context, navigator) => Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (event) {
                    updatePointers.add(event.pointer);
                    publishUpdatePointer();
                  },
                  onPointerUp: (event) {
                    updatePointers.remove(event.pointer);
                    publishUpdatePointer();
                  },
                  onPointerCancel: (event) {
                    updatePointers.remove(event.pointer);
                    publishUpdatePointer();
                  },
                  child: AnimatedBuilder(
                    animation: controller,
                    child: navigator,
                    builder: (context, child) => IosBackSwipe(
                      navigatorKey: navigatorKey,
                      child: NativeDropFeedback(
                        active: controller.nativeDragActive,
                        importing: controller.nativeImporting,
                        child: SharedImportNotice(
                          batches: shareImports,
                          child: UrlIntentNotice(
                            integration: controller.urlIntents,
                            child: AppUpdateNotice(child: child!),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                home: SendScreen(
                  key: ObjectKey(session),
                  controller: controller,
                  session: session,
                ),
              ),
            ),
          ),
        );
}
