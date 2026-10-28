import 'app_icon.dart';
import 'incoming_receipt_state.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'ui_tokens.dart';
import 'dock_platform.dart';
import 'android_queue_drop_host.dart';
import 'directories.dart';
import 'models.dart';
import 'saved_files.dart';
import 'saved_files_screen.dart';
import 'saved_image_preview.dart';
import 'text_viewer.dart';
import 'network_bridge.dart';
import 'received_file_access.dart';
import 'receive_destination.dart';
import 'reachability_screen.dart';
import 'system_bridge.dart';
import 'content_preview.dart';
import 'ui_session.dart';
import 'receipt_preview.dart';
import 'text_selection_surface.dart';
import 'content_drag_surface.dart';
import 'compact_content_card.dart';
import 'compact_time.dart';
import 'content_groups.dart';
import 'bulk_file_drag.dart';
import 'file_share.dart';
import 'local_ip_menu.dart';
import 'received_order.dart';
import 'recent_photos.dart';
import 'recent_photos_view.dart';

const defaultCenterAddress = String.fromEnvironment(
  'GLOBALSEND_DEFAULT_CENTER',
  defaultValue: 'https://123.207.180.163/globalsend',
);
const routeLabels = {
  'auto': '自动',
  'lan': '局域网',
  'public': '公网',
  'relay': '中继',
  'direct': '直连',
  'pending': '等待连接',
};
const statuses = {
  'offered': '待接收',
  'accepted': '等待传输',
  'uploading': '发送中',
  'directSending': '发送中',
  'downloading': '接收中',
  'ready': '待保存',
  'received': '已送达',
  'sent': '已发送',
  'awaitingReceipt': '等待确认',
  'relayConsent': '需中继',
  'failed': '失败',
  'paused': '已暂停',
  'canceled': '已取消',
  'rejected': '已拒绝',
  'expired': '已过期',
};
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MiB';
  return '${(bytes / 1073741824).toStringAsFixed(1)} GiB';
}

bool _hasComposingText(TextEditingValue value) =>
    value.composing.isValid && !value.composing.isCollapsed;

class SendScreen extends StatefulWidget {
  const SendScreen({super.key, required this.controller, this.session});
  final SendController controller;
  final SendUiSession? session;
  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen>
    with WidgetsBindingObserver, RouteAware {
  late final ui = widget.session ?? SendUiSession();
  final address = TextEditingController(text: defaultCenterAddress);
  final name = TextEditingController();
  final secret = TextEditingController(),
      text = TextEditingController(),
      relayLimit = TextEditingController(text: '32'),
      retention = TextEditingController(text: '1'),
      cleanupSize = TextEditingController(text: '500');
  bool development = false, showKey = false;
  bool working = false,
      settingsOpen = false,
      selecting = false,
      renaming = false;
  bool _addressEdited = false, _initialCenterApplied = false;
  bool _nameEdited = false;
  String? clipboardChoice;
  int page = 1;
  int contentTab = 0;
  final Map<String, Timer> _sentFeedbackTimers = {};
  int _lastStagedCount = 0;
  bool retentionInDays = true;
  Set<SavedFileCategory> cleanupCategories = Set.of(
    SavedFileCleanupFilter().categories,
  );
  SavedFileSizeRule cleanupSizeRule = SavedFileSizeRule.atMost;
  String? target;
  final selected = <String>{};
  final draftFocus = FocusNode();
  final sharedText = TextEditingController();
  final sharedFocus = FocusNode();
  final targetScroll = ScrollController();
  final queueScroll = ScrollController();
  String _sharedSnapshot = '';
  bool _applyingSharedHistory = false;
  String get _sharedScope => '${c.profile?.key}:${c.profile?.groupId}';
  int _notificationOpenSerial = 0;
  bool _windowPasting = false;
  StreamSubscription<void>? _nativePasteRequests;
  bool refreshingDevices = false, sendingTargets = false;
  bool _receiptOpen = false, _receiptScheduled = false;
  VoidCallback? _closeNativeDismissedReceipt;
  final _receiptVersion = ValueNotifier<int>(0);
  bool _receiptWindowFloating = false;
  String _receiptSnapshot = '';
  bool _receiptPresentedExternally = false;
  final _nativeQueueKey = GlobalKey();
  final _savedFilesKey = GlobalKey<SavedFilesScreenState>();
  bool? _allFilesAccess;
  final _nativeSendNavigationKey = GlobalKey();
  int _nativeSendNavigationSerial = 0;
  bool _queueRouteVisible = true;
  bool _nativeLocalDragActive = false;
  int _detailsRequest = 0;
  bool _detailsScheduled = false;
  ModalRoute<dynamic>? _homeRoute;
  SendController get c => widget.controller;
  late final recentPhotos = RecentPhotos(directory: c.stateDirectory);
  bool get loggedIn => c.api?.token.isNotEmpty == true;
  List<Map<String, dynamic>> get peers => c.onlinePeers;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(refresh);
    recentPhotos.addListener(refreshPhotoSuggestions);
    page = ui.page;
    contentTab = ui.contentTab;
    settingsOpen = ui.settingsOpen;
    development = ui.development;
    showKey = ui.showKey;
    retentionInDays = ui.retentionInDays;
    cleanupCategories = Set.of(ui.cleanupCategories);
    cleanupSizeRule = ui.cleanupSizeRule;
    clipboardChoice = ui.clipboardChoice;
    _notificationOpenSerial = ui.notificationSerial;
    _detailsRequest = ui.detailsRequest;
    if (ui.pendingReceipt?.id == 'group-shared-text') ui.pendingReceipt = null;
    ui.pendingReceipts.remove('group-shared-text');
    collectReceipts(
      includeLatest:
          ui.receiptSerial != null && ui.receiptSerial != c.receiptSerial,
    );
    ui.receiptSerial ??= c.receiptSerial;
    _receiptWindowFloating = c.receiptWindowFloating;
    _receiptPresentedExternally = c.receiptPresentedExternally;
    _lastStagedCount = c.stagedFiles.length + c.stagedTexts.length;
    if (c.profile != null) {
      address.text = c.profile!.baseUrl;
      development = address.text.startsWith('http:');
      _initialCenterApplied = true;
      name.text = c.profile!.name;
    }
    for (final entry in formControllers.entries) {
      final restored = ui.fields[entry.key];
      if (restored != null) entry.value.value = restored;
    }
    if (ui.fields.isNotEmpty) development = ui.development;
    loadSystemDeviceName();
    sharedText.text = c.sharedText;
    _sharedSnapshot = c.sharedText;
    if (ui.sharedHistory.scope != _sharedScope ||
        ui.sharedHistory.value.text != c.sharedText) {
      ui.sharedHistory.synchronize(sharedText.value, _sharedScope);
    } else {
      sharedText.value = ui.sharedHistory.value;
    }
    sharedText.addListener(sharedEdited);
    if (Platform.isWindows) {
      FocusManager.instance.addEarlyKeyEventHandler(windowPasteKey);
      _nativePasteRequests = SystemBridge.pasteRequests.listen(
        (_) => pasteWindowClipboard(),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      refreshDevices();
      refresh();
      scheduleRequestedDetails();
      if (ui.composeOpen) {
        composeText(index: ui.composeIndex, restoring: true);
      } else if (ui.readerId.isNotEmpty) {
        final item = c.historyDock
            .where((entry) => entry.id == ui.readerId)
            .firstOrNull;
        if (item != null) readText(item);
      } else {
        scheduleReceipt();
      }
    });
  }

  Map<String, TextEditingController> get formControllers => {
    'address': address,
    'name': name,
    'secret': secret,
    'compose': text,
    'relayLimit': relayLimit,
    'retention': retention,
    'cleanupSize': cleanupSize,
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _homeRoute) {
      ui.routes.unsubscribe(this);
      _homeRoute = route;
      if (route != null) ui.routes.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    if (mounted) setState(() => _queueRouteVisible = true);
    scheduleReceipt();
  }

  @override
  void didPushNext() {
    if (mounted) setState(() => _queueRouteVisible = false);
  }

  Future<void> refreshDevices({bool manual = false}) async {
    if (!loggedIn || refreshingDevices) return;
    setState(() => refreshingDevices = true);
    try {
      await c.refreshGroupDevices();
    } catch (error) {
      if (manual && mounted) notice(shortError('$error'));
    } finally {
      if (mounted) setState(() => refreshingDevices = false);
    }
  }

  void scheduleRequestedDetails() {
    if (_detailsScheduled || ui.detailsId == null) return;
    _detailsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _detailsScheduled = false;
      final id = ui.detailsId;
      if (!mounted || id == null) return;
      ui.detailsId = null;
      final entry = c.historyDock.where((entry) => entry.id == id).firstOrNull;
      if (entry != null) unawaited(fileAction('details', entry));
    });
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.focused && mounted) refreshDevices();
  }

  KeyEventResult windowPasteKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      final editable = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>();
      if (editable != null && _hasComposingText(editable.controller.value)) {
        return KeyEventResult.ignored;
      }
      final navigator = Navigator.of(context);
      if (_homeRoute?.isCurrent != true && navigator.canPop()) {
        unawaited(navigator.maybePop());
        return KeyEventResult.handled;
      }
      if (!settingsOpen && exitContentSelection()) {
        return KeyEventResult.handled;
      }
      if (settingsOpen || contentTab != 0 || page != 1) {
        setState(() {
          if (settingsOpen)
            settingsOpen = false;
          else if (contentTab != 0)
            contentTab = 0;
          else
            page = 1;
        });
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey != LogicalKeyboardKey.keyV ||
        !keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    pasteWindowClipboard();
    return KeyEventResult.handled;
  }

  Future<void> pasteWindowClipboard() async {
    if (_windowPasting) return;
    _windowPasting = true;
    final focus = FocusManager.instance.primaryFocus;
    final editor = focus?.context?.findAncestorStateOfType<EditableTextState>();
    try {
      final kind = await SystemBridge.clipboardKind();
      if (!mounted) return;
      if (kind == 'text' &&
          editor != null &&
          editor.mounted &&
          editor.widget.focusNode.hasFocus &&
          !editor.widget.readOnly) {
        await editor.pasteText(SelectionChangedCause.keyboard);
      } else if (kind != 'empty') {
        await perform(c.stageClipboard);
      }
    } catch (error) {
      if (mounted) notice(shortError('$error'));
    } finally {
      _windowPasting = false;
    }
  }

  Future<void> loadSystemDeviceName() async {
    try {
      final value = await c.systemDeviceName();
      if (!mounted ||
          _nameEdited ||
          _hasComposingText(name.value) ||
          c.profile?.name.isNotEmpty == true ||
          name.text.isNotEmpty) {
        return;
      }
      name.text = value;
    } catch (_) {
      // The editable field remains available if the system name cannot be read.
    }
  }

  void refresh() {
    if (ui.detailsRequest != _detailsRequest) {
      _detailsRequest = ui.detailsRequest;
      scheduleRequestedDetails();
    }
    recentPhotos.setVisible(
      loggedIn &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    if (_nativeLocalDragActive != c.nativeLocalDragActive) {
      _nativeLocalDragActive = c.nativeLocalDragActive;
      if (!_nativeLocalDragActive) scheduleReceipt();
    }
    if (_nativeSendNavigationSerial != c.nativeSendNavigationSerial) {
      _nativeSendNavigationSerial = c.nativeSendNavigationSerial;
      if (loggedIn &&
          !working &&
          !settingsOpen &&
          _queueRouteVisible &&
          !_receiptOpen) {
        page = 1;
      }
    }
    if (_receiptPresentedExternally != c.receiptPresentedExternally) {
      _receiptPresentedExternally = c.receiptPresentedExternally;
      if (!_receiptPresentedExternally) scheduleReceipt();
    }
    if (syncNativeReceiptDismissals()) {
      _receiptVersion.value++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ui.pendingReceipts.isEmpty) {
          _closeNativeDismissedReceipt?.call();
        }
      });
    }
    if (_receiptWindowFloating != c.receiptWindowFloating) {
      _receiptWindowFloating = c.receiptWindowFloating;
      _receiptVersion.value++;
      if (_receiptWindowFloating) scheduleReceipt();
    }
    if (loggedIn && c.notificationOpenSerial != _notificationOpenSerial) {
      _notificationOpenSerial = c.notificationOpenSerial;
      ui.notificationSerial = _notificationOpenSerial;
      settingsOpen = false;
      page = c.notificationOpenTarget == 'shared' ? 1 : 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _receiptOpen || ui.composeOpen) return;
        Navigator.of(context).popUntil((route) => route.isFirst);
        collectReceipts();
        scheduleReceipt();
      });
    }
    if (c.receiptSerial != ui.receiptSerial) {
      ui.receiptSerial = c.receiptSerial;
      collectReceipts();
      _receiptVersion.value++;
      scheduleReceipt();
    }
    final receiptSnapshot = c.pendingReceipts.values
        .map(
          (e) =>
              '${e.id}:${e.status}:${e.progress}:${e.receivedBytes}:${e.localPath}:${e.error}:${e.relayConfirmationPending}',
        )
        .join('|');
    if (receiptSnapshot != _receiptSnapshot) {
      _receiptSnapshot = receiptSnapshot;
      collectReceipts();
      _receiptVersion.value++;
    }
    if ((c.sharedText != _sharedSnapshot ||
            ui.sharedHistory.scope != _sharedScope) &&
        !_hasComposingText(sharedText.value)) {
      final offset = sharedText.selection.extentOffset;
      final synchronized = TextEditingValue(
        text: c.sharedText,
        selection: TextSelection.collapsed(
          offset: offset.clamp(0, c.sharedText.length),
        ),
      );
      ui.sharedHistory.synchronize(synchronized, _sharedScope);
      _applyingSharedHistory = true;
      sharedText.value = synchronized;
      _applyingSharedHistory = false;
      _sharedSnapshot = c.sharedText;
    }
    final stagedCount = c.stagedFiles.length + c.stagedTexts.length;
    if (stagedCount > _lastStagedCount && loggedIn) {
      page = 1;
      settingsOpen = false;
      final added = stagedCount - _lastStagedCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notice('已添加 $added 项');
      });
    }
    _lastStagedCount = stagedCount;
    if (!_initialCenterApplied &&
        !_addressEdited &&
        (c.profile != null || c.rememberedCenter.isNotEmpty)) {
      address.text = c.profile?.baseUrl ?? c.rememberedCenter;
      development = address.text.startsWith('http:');
      _initialCenterApplied = true;
      if (!_nameEdited &&
          !_hasComposingText(name.value) &&
          c.profile?.name.isNotEmpty == true) {
        name.text = c.profile!.name;
      }
    }
    selected.removeWhere((id) => !c.historyDock.any((item) => item.id == id));
    if (mounted) setState(() {});
  }

  void sharedEdited() {
    if (!_applyingSharedHistory && !_hasComposingText(sharedText.value)) {
      ui.sharedHistory.record(sharedText.value);
      if (mounted) setState(() {});
    }
    if (!_hasComposingText(sharedText.value) &&
        sharedText.text != c.sharedText) {
      _sharedSnapshot = sharedText.text;
      c.setSharedTextDraft(sharedText.text);
    }
  }

  void changeSharedHistory({required bool redo}) {
    if (_hasComposingText(sharedText.value)) return;
    final value = redo ? ui.sharedHistory.redo() : ui.sharedHistory.undo();
    if (value == null) return;
    _applyingSharedHistory = true;
    sharedText.value = value;
    _applyingSharedHistory = false;
    sharedFocus.requestFocus();
    setState(() {});
  }

  void collectReceipts({bool includeLatest = true}) {
    syncNativeReceiptDismissals();
    ui.pendingReceipts.addAll(c.pendingReceipts);
    final latest = c.latestReceipt;
    if (includeLatest && latest != null && latest.id != 'group-shared-text') {
      ui.pendingReceipts[latest.id] = latest;
    }
    ui.pendingReceipt = ui.pendingReceipts.values.lastOrNull;
  }

  bool syncNativeReceiptDismissals() {
    final before = ui.pendingReceipts.length;
    ui.pendingReceipts.removeWhere(
      (id, _) =>
          c.nativeDismissedReceiptIds.contains(id) &&
          !c.pendingReceipts.containsKey(id),
    );
    ui.pendingReceipt = ui.pendingReceipts.values.lastOrNull;
    return before != ui.pendingReceipts.length;
  }

  void scheduleReceipt() {
    if (_receiptScheduled ||
        _receiptOpen ||
        c.nativeLocalDragActive ||
        ui.pendingReceipts.isEmpty ||
        c.receiptPresentedExternally)
      return;
    _receiptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _receiptScheduled = false;
      if (!mounted ||
          c.nativeLocalDragActive ||
          c.receiptPresentedExternally ||
          !loggedIn ||
          !c.receiptWindowFloating &&
              (_homeRoute?.isCurrent != true ||
                  selecting ||
                  ui.composeOpen ||
                  ui.readerId.isNotEmpty)) {
        return;
      }
      presentReceipt();
    });
    // route.completed can resolve after the final animation frame; a queued
    // next batch must not wait for an unrelated input to produce another frame.
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> presentReceipt() async {
    if (_receiptOpen || ui.pendingReceipts.isEmpty) return;
    _receiptOpen = true;
    final dismissed = <String>{};
    var dismissedSerial = c.receiptSerial;
    var capturedDismissal = false;
    void captureDismissal() {
      if (capturedDismissal) return;
      capturedDismissal = true;
      dismissed.addAll(ui.pendingReceipts.keys);
      dismissedSerial = c.receiptSerial;
    }

    void close() {
      if (capturedDismissal) return;
      captureDismissal();
      Navigator.of(context).pop();
    }

    Widget trackDismissal(Widget child) => PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) captureDismissal();
      },
      child: child,
    );

    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialog) => ValueListenableBuilder<int>(
        valueListenable: _receiptVersion,
        builder: (_, _, _) {
          final item = ui.pendingReceipt;
          if (item == null) return const SizedBox.shrink();
          if (ui.pendingReceipts.length > 1) {
            return trackDismissal(
              ReceivedBatchPreview(
                embedded: c.receiptWindowFloating,
                onExpand: c.receiptWindowFloating
                    ? () => perform(SystemBridge.expandReceivedWindow)
                    : null,
                entries: ui.pendingReceipts.values.toList(),
                onClose: close,
                itemBuilder: (entry, footer) =>
                    entryCard(entry, selectionEnabled: false, footer: footer),
                onCopy: (entry) =>
                    perform(() => c.copyDockText(entry), done: '已复制'),
                onView: (entry) => entry.kind == 'text'
                    ? readText(entry)
                    : perform(() => openFile(entry)),
              ),
            );
          }
          final device =
              c.devices
                  .where((peer) => peer['deviceId'] == item.source)
                  .firstOrNull ??
              <String, dynamic>{};
          return trackDismissal(
            ReceivedContentPreview(
              embedded: c.receiptWindowFloating,
              onExpand: c.receiptWindowFloating
                  ? () => perform(SystemBridge.expandReceivedWindow)
                  : null,
              entry: item,
              sender: sourceName(item.source),
              platformIcon: deviceIcon(device),
              onClose: close,
              onCopy: () => perform(() => c.copyDockText(item), done: '已复制'),
              onOpen: () => receiptAction(item),
              dragSurface: (child) => dragSurface(
                item,
                child,
                contextual: false,
                key: const ValueKey('receipt-drag-surface'),
              ),
            ),
          );
        },
      ),
    );
    _closeNativeDismissedReceipt = () {
      if (ui.pendingReceipts.isNotEmpty) return;
      // Capture the now-empty batch before completing the route. A later
      // arrival must not be captured by route.popped's asynchronous callback.
      captureDismissal();
      if (route.isActive) route.navigator?.removeRoute(route);
    };
    // Escape/back/barrier dismiss the same visible batch as the close button.
    route.popped.then((_) => captureDismissal());
    await Navigator.of(context).push(route);
    await route.completed;
    _closeNativeDismissedReceipt = null;
    if (!mounted) return;
    _receiptOpen = false;
    c.dismissReceipts(dismissed, throughSerial: dismissedSerial);
    for (final id in dismissed) {
      if (!c.pendingReceipts.containsKey(id)) ui.pendingReceipts.remove(id);
    }
    ui.pendingReceipts.addAll(c.pendingReceipts);
    ui.pendingReceipt = ui.pendingReceipts.values.lastOrNull;
    scheduleReceipt();
    if (ui.pendingReceipts.isNotEmpty || c.receiptSerial != dismissedSerial)
      return;
    if ((Platform.isWindows || Platform.isAndroid) && dismissed.isNotEmpty) {
      // Drain native notices belonging to the closed batch before sampling its
      // native generation; late Dart arrivals are checked again after the IPC.
      await c.notificationIdle;
      await SystemBridge.receivedWindowState();
      if (!mounted) return;
      if (c.receiptSerial != dismissedSerial ||
          c.pendingReceipts.isNotEmpty ||
          ui.pendingReceipts.isNotEmpty)
        return;
      await SystemBridge.dismissReceivedWindow(
        arrivalGeneration: SystemBridge.receiptArrivalGeneration,
      ).catchError((Object error) {
        if (mounted) notice(shortError('$error'));
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    recentPhotos.setVisible(loggedIn && state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) refreshDevices();
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      if (settingsOpen) unawaited(refreshAllFilesAccess());
      c.refreshNativeDock().catchError((Object _) {});
      c
          .refreshReceiveNotifications(request: loggedIn)
          .catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) {
      FocusManager.instance.removeEarlyKeyEventHandler(windowPasteKey);
    }
    _nativePasteRequests?.cancel();
    c.removeListener(refresh);
    recentPhotos.removeListener(refreshPhotoSuggestions);
    recentPhotos.dispose();
    ui.routes.unsubscribe(this);
    ui.page = page;
    ui.contentTab = contentTab;
    ui.settingsOpen = settingsOpen;
    ui.development = development;
    ui.showKey = showKey;
    ui.retentionInDays = retentionInDays;
    ui.cleanupCategories = Set.of(cleanupCategories);
    ui.cleanupSizeRule = cleanupSizeRule;
    ui.clipboardChoice = clipboardChoice;
    for (final entry in formControllers.entries) {
      ui.fields[entry.key] = entry.value.value;
    }
    draftFocus.dispose();
    sharedFocus.dispose();
    targetScroll.dispose();
    queueScroll.dispose();
    sharedText.removeListener(sharedEdited);
    sharedText.dispose();
    _receiptVersion.dispose();
    for (final timer in _sentFeedbackTimers.values) {
      timer.cancel();
    }
    for (final controller in [
      address,
      name,
      secret,
      text,
      relayLimit,
      retention,
      cleanupSize,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> perform(Future<void> Function() action, {String? done}) async {
    if (working) return;
    setState(() => working = true);
    try {
      await action();
      if (mounted && done != null) notice(done);
    } catch (error) {
      if (mounted) notice(shortError('$error'));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void refreshPhotoSuggestions() {
    if (mounted) setState(() {});
  }

  Widget photoSuggestions() => RecentPhotosView(
    photos: recentPhotos.items,
    enabled: !working,
    onAdd: (id) => perform(
      () => recentPhotos.add(id, (path) => c.stageInputs([path], [])),
    ),
    onDismiss: () => perform(
      () => recentPhotos.dismiss(
        recentPhotos.items.map((item) => item.id).toList(),
      ),
    ),
  );

  Future<void> showPhotoSuggestions() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => SafeArea(
      top: false,
      child: SizedBox(
        height: 190,
        child: AnimatedBuilder(
          animation: recentPhotos,
          builder: (_, _) => recentPhotos.items.isEmpty
              ? const Center(child: Text('没有新图片'))
              : photoSuggestions(),
        ),
      ),
    ),
  );

  void notice(String value) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(value), duration: const Duration(seconds: 2)),
  );
  String shortError(String value) {
    if (value.contains('SocketException') ||
        value.contains('TimeoutException') ||
        value.contains('HandshakeException')) {
      return '连接失败，请重试';
    }
    final plain = value.replaceFirst(
      RegExp(r'^(Bad state:|FormatException:|Exception:)\s*'),
      '',
    );
    return plain.length > 70 ? '${plain.substring(0, 70)}…' : plain;
  }

  String sourceName(String id) => id == c.profile?.deviceId
      ? (c.profile!.name.isEmpty ? '本机' : c.profile!.name)
      : c.devices.where((d) => d['deviceId'] == id).firstOrNull?['name'] ??
            '其他设备';
  String statusLabel(DockEntry item) => item.status == 'received'
      ? (item.outgoing ? '已送达' : '已保存')
      : item.kind == 'text' && item.status == 'ready'
      ? '已接收'
      : statuses[item.status] ?? item.status;
  void openSettings() {
    relayLimit.text = '${c.profile?.relayConfirmMiB ?? 32}';
    name.text = c.profile?.name ?? name.text;
    _nameEdited = false;
    clipboardChoice = c.clipboardEnabled
        ? c.clipboardTarget
        : peers.any((peer) => peer['deviceId'] == clipboardChoice)
        ? clipboardChoice
        : target;
    final hours = c.savedFileRetentionHours;
    retentionInDays = hours % 24 == 0;
    retention.text = '${retentionInDays ? hours ~/ 24 : hours}';
    final cleanup = c.savedFileCleanupFilter;
    cleanupCategories = Set.of(cleanup.categories);
    cleanupSizeRule = cleanup.sizeRule;
    cleanupSize.text = (cleanup.sizeMiB * 1048576 / 1000).toString();
    setState(() => settingsOpen = true);
    if (Platform.isAndroid) unawaited(refreshAllFilesAccess());
  }

  Future<void> refreshAllFilesAccess() async {
    final allowed = await ReceiveDestination.allFilesAccess();
    if (mounted) setState(() => _allFilesAccess = allowed);
  }

  Future<void> useDownloadsDirectory() async {
    final destination = await ReceiveDestination.downloads();
    await c.changeReceiveDirectory(
      destination['location']!,
      destination['label']!,
    );
  }

  bool get fileSelectionActive =>
      contentTab == 2 &&
      (page == 0 || MediaQuery.sizeOf(context).width >= 900) &&
      (_savedFilesKey.currentState?.selectionActive ?? false);

  bool exitContentSelection() {
    if (fileSelectionActive &&
        _savedFilesKey.currentState!.exitSelectionIfActive()) {
      return true;
    }
    if (!selecting && !ui.multiSend) return false;
    setState(() {
      if (selecting) {
        selecting = false;
        selected.clear();
      } else {
        ui.multiSend = false;
        ui.sendTargets.clear();
      }
    });
    return true;
  }

  Future<void> chooseLocalIp() async {
    final address = await showLocalIpMenu(context, c.localIpAddresses);
    if (mounted && address != null)
      await perform(() => c.stageInputs([], [address]));
  }

  @override
  Widget build(BuildContext context) {
    if (!peers.any((d) => d['deviceId'] == target)) {
      target = peers.firstOrNull?['deviceId'];
    }
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final window = PopScope(
      canPop:
          !settingsOpen &&
          !selecting &&
          !ui.multiSend &&
          !fileSelectionActive &&
          page == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (!settingsOpen && exitContentSelection()) return;
          setState(() {
            settingsOpen = false;
            page = 1;
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: wide ? kToolbarHeight : 48,
          titleSpacing: wide ? 20 : 16,
          leading: settingsOpen
              ? BackButton(
                  onPressed: () => setState(() => settingsOpen = false),
                )
              : null,
          title: Row(
            children: [
              if (settingsOpen)
                const Text(
                  '设置',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                )
              else
                TextButton(
                  key: const ValueKey('local-ip-menu'),
                  onPressed: working ? null : chooseLocalIp,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: wide ? 8 : 4,
                    ),
                    minimumSize: const Size(0, 40),
                    foregroundColor: Ui.colors(context).ink,
                  ),
                  child: const Text(
                    'GlobalSend',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                  ),
                ),
              if (wide && loggedIn && !settingsOpen) ...[
                const SizedBox(width: 12),
                TextButton.icon(
                  key: const ValueKey('add-text'),
                  onPressed: working ? null : composeText,
                  icon: const AppIcon(Icons.notes_rounded, size: 19),
                  label: const Text('文本'),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  key: const ValueKey('add-clipboard'),
                  onPressed: working ? null : () => perform(c.stageClipboard),
                  icon: const AppIcon(Icons.content_paste_rounded, size: 19),
                  label: const Text('剪贴板'),
                ),
              ],
            ],
          ),
          actions: [
            if (!loggedIn)
              IconButton(
                tooltip: '外观',
                icon: const AppIcon(Icons.settings_outlined, size: 20),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: const Text('外观'),
                    content: const SizedBox(
                      width: 360,
                      child: AppearancePicker(),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialog),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ),
              ),
            if (wide && loggedIn && !settingsOpen)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: SizedBox(
                  key: const ValueKey('desktop-content-navigation'),
                  width: (MediaQuery.sizeOf(context).width - 56) * 11 / 21,
                  child: Row(
                    children: [
                      Expanded(child: desktopContentTabs()),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: c.connection,
                        child: connectionBadge(compact: true),
                      ),
                      IconButton(
                        tooltip: '设置',
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                        padding: const EdgeInsets.all(10),
                        onPressed: openSettings,
                        icon: const AppIcon(Icons.settings_outlined, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            if (!loggedIn &&
                (c.profile?.deviceId.isNotEmpty == true ||
                    c.savedFiles.isNotEmpty))
              IconButton(
                tooltip: '文件库',
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => SavedFilesScreen(controller: c),
                  ),
                ),
                icon: const AppIcon(Icons.folder_open_outlined, size: 22),
              ),
            if (!wide && loggedIn && !settingsOpen)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(message: c.connection, child: connectionBadge()),
              ),
            if (!wide && loggedIn && !settingsOpen)
              IconButton(
                tooltip: '设置',
                onPressed: openSettings,
                icon: const AppIcon(Icons.settings_outlined, size: 22),
              ),
          ],
        ),
        body: Stack(
          children: [
            SafeArea(
              top: false,
              child: Column(
                children: [
                  if (working) const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        fit: StackFit.expand,
                        children: [
                          ...previousChildren,
                          if (currentChild != null) currentChild,
                        ],
                      ),
                      transitionBuilder: (child, animation) {
                        final key =
                            (child.key as ValueKey?)?.value.toString() ?? '';
                        final mobile = key.startsWith('workspace-mobile-');
                        return FadeTransition(
                          opacity: animation,
                          child: mobile
                              ? SlideTransition(
                                  position: Tween<Offset>(
                                    begin: Offset(
                                      key.endsWith('-send') ? -.05 : .05,
                                      0,
                                    ),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                )
                              : child,
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey(
                          !loggedIn
                              ? 'connect-page'
                              : settingsOpen
                              ? 'settings-page'
                              : wide
                              ? 'workspace-page'
                              : 'workspace-mobile-${page == 1 ? 'send' : 'content-$contentTab'}',
                        ),
                        child: !loggedIn
                            ? connectionPage()
                            : settingsOpen
                            ? settingsPage()
                            : wide
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  0,
                                  20,
                                  20,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 10,
                                      child: workspacePane(sendPage()),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      flex: 11,
                                      child: workspacePane(
                                        contentPane(),
                                        joined: true,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : page == 0
                            ? contentPane()
                            : sendPage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: loggedIn && !settingsOpen && !wide
            ? NavigationBar(
                height: 68,
                selectedIndex: page == 1 ? 0 : contentTab + 1,
                onDestinationSelected: (value) => setState(() {
                  page = value == 0 ? 1 : 0;
                  if (value != 0) contentTab = value - 1;
                  selecting = false;
                  selected.clear();
                }),
                destinations: [
                  NavigationDestination(
                    key: _nativeSendNavigationKey,
                    icon: const AppIcon(Icons.north_east),
                    label: '发送',
                  ),
                  const NavigationDestination(
                    icon: AppIcon(Icons.inbox_outlined),
                    selectedIcon: AppIcon(Icons.inbox),
                    label: '接收',
                  ),
                  const NavigationDestination(
                    icon: AppIcon(Icons.history),
                    label: '历史',
                  ),
                  const NavigationDestination(
                    icon: AppIcon(Icons.folder_open_outlined),
                    label: '文件',
                  ),
                ],
              )
            : null,
      ),
    );
    if (!Platform.isAndroid && !Platform.isWindows) return window;
    return NativeQueueDropHost(
      target: _nativeQueueKey,
      enabled:
          loggedIn &&
          !working &&
          !settingsOpen &&
          _queueRouteVisible &&
          !_receiptOpen &&
          (wide || page == 1),
      sendNavigationTarget: _nativeSendNavigationKey,
      sendNavigationEnabled:
          Platform.isAndroid &&
          loggedIn &&
          !working &&
          !settingsOpen &&
          !wide &&
          page == 0 &&
          _queueRouteVisible &&
          !_receiptOpen,
      child: window,
    );
  }

  Widget connectionBadge({bool compact = false}) {
    if (c.connected)
      return Semantics(
        label: '已连接',
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Ui.colors(context).softGreen,
            borderRadius: Ui.fieldRadius,
          ),
          child: AppIcon(
            Icons.link_rounded,
            size: 20,
            color: Ui.colors(context).green,
          ),
        ),
      );
    final reconnecting =
        c.connection.contains('重连') ||
        c.connection.contains('连接中') ||
        c.connection.startsWith('正在');
    final color = c.connected
        ? Ui.colors(context).green
        : const Color(0xff9a6b20);
    if (compact)
      return Semantics(
        label: reconnecting ? '连接中' : '未连接',
        child: SizedBox.square(
          dimension: 44,
          child: Center(
            child: AppIcon(
              reconnecting ? Icons.sync_rounded : Icons.cloud_off_outlined,
              size: 20,
              color: color,
            ),
          ),
        ),
      );
    return Container(
      key: const ValueKey('connection-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            c.connected
                ? Icons.cloud_done_outlined
                : reconnecting
                ? Icons.sync_rounded
                : Icons.cloud_off_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            c.connected
                ? '已连接'
                : reconnecting
                ? '连接中'
                : '未连接',
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget connectionPage() => LayoutBuilder(
    builder: (context, bounds) {
      final split = bounds.maxWidth >= 680;
      final blocked = c.credentialProblem != null;
      Widget deviceName() => UiField(
        label: '设备名称',
        child: TextField(
          key: const ValueKey('setup-device-name'),
          controller: name,
          enabled: !working,
          readOnly: blocked,
          onChanged: (_) => _nameEdited = true,
          maxLength: 80,
          decoration: const InputDecoration(counterText: ''),
        ),
      );
      Widget password() => UiField(
        label: '组密码',
        child: TextField(
          key: const ValueKey('group-password'),
          controller: secret,
          enabled: !working,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          obscureText: !showKey,
          decoration: InputDecoration(
            hintText: '至少 10 位',
            suffixIcon: IconButton(
              tooltip: showKey ? '隐藏密码' : '显示密码',
              onPressed: () => setState(() => showKey = !showKey),
              icon: AppIcon(
                showKey
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
              ),
            ),
          ),
          onSubmitted: (_) => join(),
        ),
      );
      Widget recoveryNotice() => Container(
        key: const ValueKey('credential-recovery-notice'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Ui.colors(context).softGreen,
          borderRadius: Ui.cardRadius,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon(
              Icons.key_off_outlined,
              color: Ui.colors(context).green,
              size: 24,
            ),
            SizedBox(height: 12),
            Text(
              '连接暂不可用',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 8),
            Text(
              '本机文件和记录已保留。',
              style: TextStyle(
                fontSize: 14,
                color: Ui.colors(context).muted,
                height: 1.5,
              ),
            ),
          ],
        ),
      );
      return SingleChildScrollView(
        key: const ValueKey('connection-scroll'),
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(split ? 32 : 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      blocked ? '恢复连接' : '连接设备',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 24),
                    UiField(
                      label: '服务器',
                      child: TextField(
                        key: const ValueKey('server-address'),
                        controller: address,
                        enabled: !working,
                        readOnly: blocked,
                        onChanged: (_) => setState(() => _addressEdited = true),
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (split)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: blocked ? recoveryNotice() : deviceName(),
                          ),
                          const SizedBox(width: 24),
                          Expanded(child: blocked ? deviceName() : password()),
                        ],
                      )
                    else ...[
                      if (blocked) ...[
                        recoveryNotice(),
                        const SizedBox(height: 24),
                      ],
                      deviceName(),
                      if (!blocked) ...[const SizedBox(height: 16), password()],
                    ],
                    if (!blocked &&
                        address.text.trim().startsWith('http:')) ...[
                      const SizedBox(height: 16),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许 HTTP'),
                        value: development,
                        onChanged: (value) =>
                            setState(() => development = value),
                      ),
                    ],
                    if (!blocked &&
                        c.message.isNotEmpty &&
                        RegExp('失败|失效|错误|不兼容').hasMatch(c.message)) ...[
                      const SizedBox(height: 16),
                      Text(
                        shortError(c.message),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 14,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            key: const ValueKey('connect-primary'),
                            onPressed: working
                                ? null
                                : blocked
                                ? retryOriginalCredentials
                                : join,
                            child: Text(blocked ? '重试连接' : '连接'),
                          ),
                        ),
                        if (blocked) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton(
                              key: const ValueKey('credential-reenroll'),
                              onPressed: working
                                  ? null
                                  : confirmCredentialEnrollment,
                              child: const Text('输入组密码'),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          key: const ValueKey('setup-server-settings'),
                          onPressed: working ? null : showServerSettings,
                          icon: const AppIcon(Icons.dns_outlined, size: 18),
                          label: const Text('服务器设置'),
                        ),
                        if (blocked) ...[
                          TextButton.icon(
                            key: const ValueKey('credential-diagnostics'),
                            onPressed: showCredentialDiagnostics,
                            icon: const AppIcon(
                              Icons.info_outline_rounded,
                              size: 18,
                            ),
                            label: const Text('诊断信息'),
                          ),
                          TextButton(
                            onPressed: working
                                ? null
                                : () {
                                    c.credentialProblem = null;
                                    c.message = '';
                                    c.changed();
                                  },
                            child: const Text('连接其他服务器'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Future<void> showCredentialDiagnostics() => showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (dialog) => AlertDialog(
      title: const Text('诊断信息'),
      content: SizedBox(
        width: 480,
        child: dialogScroll(
          SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText(
                  c.credentialProblem!.diagnostic,
                  style: const TextStyle(fontSize: 14, height: 1.55),
                ),
                const SizedBox(height: 24),
                const Text('登录信息暂不可用。可以重试连接，或重新输入组密码。'),
              ],
            ),
          ),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> showServerSettings() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: const Text('服务器设置'),
          content: SizedBox(
            width: 480,
            child: dialogScroll(
              SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (c.profiles.isNotEmpty) ...[
                      UiField(
                        label: '已保存服务器',
                        child: DropdownButtonFormField<String>(
                          icon: const AppIcon(Icons.arrow_drop_down),
                          isExpanded: true,
                          decoration: const InputDecoration(),
                          items: c.profiles
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p.key,
                                  child: Text(
                                    p.baseUrl,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: working
                              ? null
                              : (key) {
                                  final p = c.profiles.firstWhere(
                                    (p) => p.key == key,
                                  );
                                  update(() {
                                    address.text = p.baseUrl;
                                    development = p.baseUrl.startsWith('http:');
                                  });
                                },
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('允许 HTTP'),
                      value: development,
                      onChanged: (value) => update(() => development = value),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> join() => perform(() async {
    final base = normalizeServer(address.text, allowHttp: development);
    if (c.api == null || c.profile?.baseUrl != base) {
      await c.connect(base, development: development);
    }
    address.text = base;
    if (c.api?.token.isNotEmpty != true) {
      await c.enrollGroup(name.text.trim(), secret.text);
    }
    secret.clear();
    c.message = '';
    setState(() {
      settingsOpen = false;
      page = 1;
    });
  });

  Future<void> retryOriginalCredentials() => perform(() async {
    final profile = c.profile!;
    await c.connect(
      profile.baseUrl,
      development: profile.baseUrl.startsWith('http:'),
    );
  });

  Future<void> confirmCredentialEnrollment() async {
    final password = TextEditingController();
    String? error;
    final route = DialogRoute<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: const Text('输入组密码'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UiField(
                  label: '组密码',
                  child: TextField(
                    key: const ValueKey('credential-recovery-password'),
                    controller: password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      hintText: '至少 10 位',
                      errorText: error,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('credential-recovery-confirm'),
              onPressed: () {
                if (password.text.runes.length < 10 ||
                    password.text.runes.length > 256 ||
                    password.text != password.text.trim() ||
                    RegExp(r'[\x00-\x1f\x7f]').hasMatch(password.text)) {
                  update(() => error = '请输入 10–256 字符的组密码');
                } else {
                  Navigator.of(dialog).pop(password.text);
                }
              },
              child: const Text('连接'),
            ),
          ],
        ),
      ),
    );
    final key = await Navigator.of(context).push(route);
    await route.completed;
    password.clear();
    password.dispose();
    if (key == null || !mounted) return;
    await perform(
      () => c.recoverCredentialEnrollment(
        c.profile?.name ?? name.text.trim(),
        key,
      ),
    );
  }

  Widget section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: UiSection(title: title, children: children, padding: 16),
  );
  Widget targetPicker() => UiField(
    label: '发送到',
    child: DropdownButtonFormField<String>(
      icon: const AppIcon(Icons.arrow_drop_down),
      key: ValueKey('target-$target'),
      initialValue: target,
      isExpanded: true,
      decoration: const InputDecoration(),
      items: peers
          .map(
            (d) => DropdownMenuItem<String>(
              value: d['deviceId'],
              child: Row(
                children: [
                  AppIcon(deviceIcon(d), size: 19),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(d['name'], overflow: TextOverflow.ellipsis),
                  ),
                  if (d['online'] == true)
                    AppIcon(
                      Icons.circle,
                      size: 6,
                      color: Ui.colors(context).green,
                    ),
                ],
              ),
            ),
          )
          .toList(),
      onChanged: working
          ? null
          : (value) {
              setState(() => target = value);
            },
    ),
  );

  Widget sendPage() => LayoutBuilder(
    builder: (context, bounds) {
      final desktop = MediaQuery.sizeOf(context).width >= 900;
      final shared = sharedEditor(expanded: desktop);
      final tools = Row(
        children: [
          actionTile('文本', Icons.notes_rounded, composeText, key: 'add-text'),
          const SizedBox(width: 8),
          actionTile(
            '剪贴板',
            Icons.content_paste_rounded,
            () => perform(c.stageClipboard),
            key: 'add-clipboard',
          ),
          const SizedBox(width: 6),
          actionTile(
            '文件',
            Icons.insert_drive_file_outlined,
            pickFiles,
            key: 'add-file',
          ),
          const SizedBox(width: 6),
          actionTile(
            '媒体',
            Icons.photo_library_outlined,
            () => Theme.of(context).platform == TargetPlatform.android
                ? perform(DockPlatform.pickMedia)
                : pickFiles(type: FileType.media),
            key: 'add-media',
          ),
        ],
      );
      if (desktop) {
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: c.failedOutgoingFiles.isEmpty ? 180 : 212,
                child: queuePanel(),
              ),
              const SizedBox(height: 10),
              targetDevices(),
              const SizedBox(height: 10),
              Expanded(flex: 5, child: shared),
            ],
          ),
        );
      }
      // This element tree does not change when Android's keyboard resizes it.
      return SingleChildScrollView(
        key: const ValueKey('send-workspace-scroll'),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            tools,
            const SizedBox(height: 12),
            SizedBox(
              height: c.failedOutgoingFiles.isEmpty ? 180 : 212,
              child: queuePanel(),
            ),
            const SizedBox(height: 12),
            targetDevices(),
            const SizedBox(height: 12),
            shared,
          ],
        ),
      );
    },
  );

  Widget desktopContentTabs() => SizedBox(
    key: const ValueKey('content-tabs'),
    height: kToolbarHeight,
    child: Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            for (final (index, label) in const ['接收', '已发送', '文件库'].indexed)
              Expanded(
                child: Semantics(
                  key: ValueKey(
                    index == 1
                        ? 'sent-history'
                        : index == 2
                        ? 'open-library'
                        : 'receive-tab',
                  ),
                  selected: contentTab == index,
                  button: true,
                  child: InkWell(
                    key: ValueKey('content-tab-$index'),
                    onTap: () => setState(() {
                      contentTab = index;
                      selecting = false;
                      selected.clear();
                    }),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(12),
                    ),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: contentTab == index
                            ? Ui.colors(context).softGreen
                            : Colors.transparent,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(12),
                        ),
                        border: contentTab == index
                            ? Border(
                                bottom: BorderSide(
                                  color: Ui.colors(context).green,
                                  width: 2,
                                ),
                              )
                            : null,
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: contentTab == index
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: contentTab == index
                              ? Ui.colors(context).green
                              : Ui.colors(context).muted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget contentPane() {
    final compact = MediaQuery.sizeOf(context).width < 900;
    final content = switch (contentTab) {
      1 => sentPage(),
      2 => SavedFilesScreen(
        key: _savedFilesKey,
        controller: c,
        embedded: true,
        onSelectionChanged: () {
          if (mounted) setState(() {});
        },
      ),
      _ => receivePage(),
    };
    if (compact) return content;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(.04, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey('content-$contentTab'), child: content),
    );
  }

  Widget sentPage() {
    final items = mergeContentCards(
      c.historyDock.where((item) => item.outgoing),
    );
    return items.isEmpty
        ? const UiEmpty(icon: Icons.history, title: '暂无发送记录')
        : Column(
            children: [
              UiContentToolbar(
                key: const ValueKey('sent-toolbar'),
                children: [
                  Text(
                    selecting
                        ? '${selected.length}/${items.length} 项'
                        : '${items.length} 项',
                    style: TextStyle(
                      fontSize: 12,
                      color: Ui.colors(context).muted,
                    ),
                  ),
                  BulkFileDrag(
                    key: const ValueKey('sent-drag-all'),
                    paths: items
                        .where(
                          (item) =>
                              item.kind == 'file' &&
                              item.localPath.isNotEmpty &&
                              (!selecting || selected.contains(item.id)),
                        )
                        .map((item) => item.localPath)
                        .toList(),
                    enabled: !working,
                    onError: (error) => notice(shortError('$error')),
                  ),
                  if (selecting)
                    TextButton(
                      key: const ValueKey('sent-select-all'),
                      onPressed: () => setState(() {
                        if (items.every((item) => selected.contains(item.id))) {
                          selected.clear();
                        } else {
                          selected.addAll(items.map((item) => item.id));
                        }
                      }),
                      child: Text(
                        items.every((item) => selected.contains(item.id))
                            ? '取消全选'
                            : '全选',
                      ),
                    ),
                  if (selecting)
                    TextButton(
                      key: const ValueKey('sent-delete-selected'),
                      onPressed: selected.isEmpty || working
                          ? null
                          : deleteSelected,
                      child: const Text('删除'),
                    ),
                  TextButton(
                    key: const ValueKey('sent-multi-select'),
                    onPressed: () => setState(() {
                      selecting = !selecting;
                      selected.clear();
                    }),
                    child: Text(selecting ? '取消' : '多选'),
                  ),
                ],
              ),
              Expanded(
                child: GridView.builder(
                  key: const ValueKey('sent-grid'),
                  padding: const EdgeInsets.all(12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    mainAxisExtent: cardExtent(),
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, index) => entryCard(items[index]),
                ),
              ),
            ],
          );
  }

  double cardExtent() =>
      230 + math.max(0, MediaQuery.textScalerOf(context).scale(14) - 14) * 8;

  Widget workspacePane(Widget child, {bool joined = false}) => DecoratedBox(
    key: joined ? const ValueKey('desktop-content-pane') : null,
    decoration: BoxDecoration(
      color: Ui.colors(context).surface,
      border: Border.all(color: Ui.colors(context).border),
      borderRadius: joined
          ? const BorderRadius.vertical(bottom: Radius.circular(20))
          : BorderRadius.circular(20),
    ),
    child: ClipRRect(
      borderRadius: joined
          ? const BorderRadius.vertical(bottom: Radius.circular(20))
          : BorderRadius.circular(20),
      child: child,
    ),
  );

  Widget actionTile(
    String label,
    IconData icon,
    VoidCallback onTap, {
    required String key,
    bool quiet = false,
  }) => Expanded(
    child: TextButton(
      key: ValueKey(key),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        backgroundColor: quiet
            ? Ui.colors(context).background
            : Ui.colors(context).softGreen,
        shape: const RoundedRectangleBorder(borderRadius: Ui.fieldRadius),
      ),
      onPressed: working ? null : onTap,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(icon, size: 16),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    ),
  );

  Widget queuePanel() {
    final count = c.stagedFiles.length + c.stagedTexts.length;
    final failed = c.failedOutgoingFiles;
    final active = c.dock
        .where(
          (item) =>
              item.outgoing &&
              item.kind == 'file' &&
              ![
                'received',
                'sent',
                'canceled',
                'rejected',
                'expired',
              ].contains(item.status),
        )
        .toList();
    return KeyedSubtree(
      key: _nativeQueueKey,
      child: DragTarget<DockEntry>(
        onWillAcceptWithDetails: (_) => !working,
        onAcceptWithDetails: (details) => perform(
          () => details.data is BulkFileEntry
              ? c.stageInputs((details.data as BulkFileEntry).paths, [])
              : details.data.id == 'group-shared-text-drag'
              ? c.stageInputs([], [details.data.text])
              : c.stageHistoryEntry(details.data),
        ),
        builder: (context, candidates, rejected) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: working ? null : composeText,
          child: Container(
            key: const ValueKey('send-queue'),
            decoration: BoxDecoration(
              color: Ui.colors(context).input,
              borderRadius: Ui.fieldRadius,
              border: Border.all(
                color: candidates.isNotEmpty || c.nativeQueueDragActive
                    ? Ui.colors(context).green
                    : Ui.colors(context).border,
                width: candidates.isNotEmpty || c.nativeQueueDragActive ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                  child: Row(
                    children: [
                      Text(
                        '待发送${count == 0 ? '' : ' · $count'}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      if (count > 0 && recentPhotos.items.isNotEmpty)
                        IconButton(
                          tooltip: '新图片',
                          onPressed: working ? null : showPhotoSuggestions,
                          icon: Badge.count(
                            count: recentPhotos.items.length,
                            child: const AppIcon(
                              Icons.add_photo_alternate_outlined,
                              size: 19,
                            ),
                          ),
                        ),
                      if (count > 0)
                        IconButton(
                          key: const ValueKey('clear-staged'),
                          tooltip: '清空待发送',
                          onPressed: working
                              ? null
                              : () => perform(c.clearStaged),
                          icon: const AppIcon(
                            Icons.clear_all_rounded,
                            size: 19,
                          ),
                        ),
                      TextButton.icon(
                        key: const ValueKey('add-files-visible'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(40, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: working ? null : pickFiles,
                        icon: const AppIcon(Icons.add, size: 17),
                        label: const Text('添加文件'),
                      ),
                      PopupMenuButton<String>(
                        key: const ValueKey('add-files-menu'),
                        tooltip: '添加文件夹',
                        icon: const AppIcon(
                          Icons.create_new_folder_outlined,
                          size: 19,
                        ),
                        onSelected: (action) =>
                            action == 'folder' ? pickFolder() : pickFiles(),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'files', child: Text('添加文件')),
                          PopupMenuItem(value: 'folder', child: Text('添加文件夹')),
                        ],
                      ),
                    ],
                  ),
                ),
                if (failed.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        TextButton(
                          key: const ValueKey('clear-failed-outgoing'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(40, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => failedQueueAction(retry: false),
                          child: const Text('清除所有失败文件'),
                        ),
                        const Spacer(),
                        TextButton(
                          key: const ValueKey('retry-failed-outgoing'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(40, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => failedQueueAction(retry: true),
                          child: const Text('重试所有'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: count == 0 && active.isEmpty
                            ? recentPhotos.items.isNotEmpty
                                  ? photoSuggestions()
                                  : Center(
                                      child: Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Text(
                                          '点击输入文本，或拖入文件',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Ui.colors(context).muted,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ),
                                    )
                            : Listener(
                                onPointerSignal: (event) {
                                  if (event is PointerScrollEvent &&
                                      event.scrollDelta.dx == 0 &&
                                      event.scrollDelta.dy != 0 &&
                                      queueScroll.hasClients) {
                                    GestureBinding
                                        .instance
                                        .pointerSignalResolver
                                        .register(
                                          event,
                                          (_) => queueScroll.jumpTo(
                                            (queueScroll.offset +
                                                    event.scrollDelta.dy)
                                                .clamp(
                                                  0.0,
                                                  queueScroll
                                                      .position
                                                      .maxScrollExtent,
                                                ),
                                          ),
                                        );
                                  }
                                },
                                child: Scrollbar(
                                  controller: queueScroll,
                                  thumbVisibility: true,
                                  child: ListView.separated(
                                    key: const ValueKey('send-queue-list'),
                                    controller: queueScroll,
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.fromLTRB(
                                      10,
                                      0,
                                      10,
                                      10,
                                    ),
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(width: 8),
                                    itemCount: count + active.length,
                                    itemBuilder: (_, index) {
                                      final tile = index < c.stagedFiles.length
                                          ? stagedTile(
                                              path: c.stagedFiles[index],
                                            )
                                          : index < count
                                          ? stagedTile(
                                              textIndex:
                                                  index - c.stagedFiles.length,
                                            )
                                          : activeTransferTile(
                                              active[index - count],
                                            );
                                      return AspectRatio(
                                        aspectRatio: 1,
                                        child: tile,
                                      );
                                    },
                                  ),
                                ),
                              ),
                      ),
                      if (candidates.isNotEmpty || c.nativeQueueDragActive)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Ui.colors(context).softGreen
                                    .withValues(alpha: .92),
                                borderRadius: Ui.fieldRadius,
                              ),
                              child: Text(
                                '松手，加入待发',
                                style: TextStyle(
                                  color: Ui.colors(context).green,
                                  fontSize: 16,
                                ),
                              ),
                            ),
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

  Widget stagedTile({String? path, int? textIndex}) {
    final isText = textIndex != null;
    final value = isText ? c.stagedTexts[textIndex] : '';
    final title = isText ? value.replaceAll('\n', ' ') : safeName(path!);
    return Material(
      color: Ui.colors(context).surface,
      borderRadius: Ui.cardRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isText
            ? () => composeText(index: textIndex)
            : () => openStagedFile(path!),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (!isText && c.stagedDirectoryNames.containsKey(path))
                    Center(
                      child: AppIcon(
                        Icons.folder_outlined,
                        size: 36,
                        color: Ui.colors(context).green,
                      ),
                    )
                  else
                    ContentPreview(
                      location: path ?? '',
                      name: isText ? '文本' : safeName(path!),
                      text: isText ? value : null,
                      compact: true,
                      maxTextLines: isText ? 4 : 2,
                      topInset: isText ? 24 : 0,
                    ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: IconButton(
                        tooltip: '移除',
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          backgroundColor: Ui.colors(context).surface
                              .withValues(alpha: .9),
                          minimumSize: const Size(28, 28),
                        ),
                        onPressed: working
                            ? null
                            : () {
                                if (isText) {
                                  c.stagedTexts.removeAt(textIndex);
                                  c.changed();
                                } else
                                  perform(() => c.removeStagedFile(path!));
                              },
                        icon: const AppIcon(Icons.close, size: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!isText)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> failedQueueAction({required bool retry}) async {
    try {
      if (retry) {
        await c.retryFailedOutgoingFiles();
      } else {
        await c.clearFailedOutgoingFiles();
      }
    } catch (error) {
      if (mounted) notice(shortError('$error'));
    }
  }

  Widget activeTransferTile(DockEntry item) => Material(
    color: Ui.colors(context).surface,
    borderRadius: Ui.cardRadius,
    child: InkWell(
      onTap: () => fileAction('details', item),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIcon(
                  Icons.north_east,
                  size: 22,
                  color: Ui.colors(context).green,
                ),
                const Spacer(),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  item.transferBytesPerSecond > 0
                      ? '${formatSize(item.transferBytesPerSecond.round())}/s'
                      : statusLabel(item),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    color: Ui.colors(context).muted,
                  ),
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: item.progress.clamp(0, 1),
                  minHeight: 3,
                ),
              ],
            ),
          ),
          if (c.failedOutgoingFiles.any((entry) => entry.id == item.id))
            Positioned(
              right: 3,
              top: 3,
              child: IconButton(
                key: ValueKey('retry-outgoing-${item.id}'),
                tooltip: '重试',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                onPressed: () => transferControl('retry', item),
                icon: const AppIcon(Icons.refresh, size: 19),
              ),
            ),
        ],
      ),
    ),
  );

  Widget targetDevices() {
    final peers = c.sendablePeers;
    final count = c.stagedFiles.length + c.stagedTexts.length;
    final scaled = MediaQuery.textScalerOf(context).scale(14);
    final extent = math.max(80.0, 20 + 6 + scaled * 1.35 * 2 + 16);
    final selectedIds = ui.sendTargets
        .where((id) => c.stagedTargetStates[id] != 'sent')
        .toList();
    final selectedCount = selectedIds.length;
    final summary = selectedIds.map(sourceName).join('、');
    final toolStyle = TextButton.styleFrom(
      minimumSize: const Size(48, 40),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: ui.multiSend && selectedCount > 0
                  ? Semantics(
                      label: '发送目标：$summary',
                      child: Tooltip(
                        message: summary,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            '目标：$summary',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    )
                  : Text(
                      '设备 ' + peers.length.toString(),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            IconButton(
              key: const ValueKey('refresh-devices'),
              tooltip: '刷新设备',
              style: IconButton.styleFrom(
                minimumSize: const Size(40, 40),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: refreshingDevices
                  ? null
                  : () => refreshDevices(manual: true),
              icon: refreshingDevices
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : const AppIcon(Icons.refresh_rounded, size: 20),
            ),
            TextButton(
              key: const ValueKey('multi-send-toggle'),
              style: toolStyle,
              onPressed: sendingTargets
                  ? null
                  : () => setState(() {
                      ui.multiSend = !ui.multiSend;
                      ui.sendTargets.clear();
                    }),
              child: Text(ui.multiSend ? '取消' : '多选'),
            ),
            if (ui.multiSend && selectedCount > 0)
              Tooltip(
                message: '发送到：$summary',
                child: FilledButton(
                  key: const ValueKey('send-selected'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(72, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: count == 0 || sendingTargets ? null : sendSelected,
                  child: Text('发送 $selectedCount 台'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: extent + 8,
          child: peers.isEmpty
              ? Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Ui.colors(context).input,
                    borderRadius: Ui.fieldRadius,
                  ),
                  child: Text(
                    '暂无其他设备',
                    style: TextStyle(
                      fontSize: 14,
                      color: Ui.colors(context).muted,
                    ),
                  ),
                )
              : Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent &&
                        event.scrollDelta.dx == 0 &&
                        event.scrollDelta.dy != 0 &&
                        targetScroll.hasClients) {
                      GestureBinding.instance.pointerSignalResolver.register(
                        event,
                        (_) => targetScroll.jumpTo(
                          (targetScroll.offset + event.scrollDelta.dy).clamp(
                            0.0,
                            targetScroll.position.maxScrollExtent,
                          ),
                        ),
                      );
                    }
                  },
                  child: Scrollbar(
                    controller: targetScroll,
                    thumbVisibility: true,
                    child: ListView.separated(
                      key: const ValueKey('target-devices'),
                      controller: targetScroll,
                      padding: const EdgeInsets.only(bottom: 8),
                      scrollDirection: Axis.horizontal,
                      itemCount: peers.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (_, index) {
                        final device = peers[index],
                            id = device['deviceId'] as String;
                        final state = c.stagedTargetStates[id];
                        final offline = device['online'] != true;
                        final sent =
                            state == 'sent' &&
                            _sentFeedbackTimers.containsKey(id);
                        final checked =
                            ui.multiSend &&
                            ui.sendTargets.contains(id) &&
                            !sent;
                        final pending = state == 'queued' || state == 'sending';
                        final fullName = device['name'] as String;
                        return SizedBox(
                          width: extent,
                          height: extent,
                          child: Tooltip(
                            message: fullName,
                            child: Semantics(
                              button: true,
                              label: fullName,
                              selected: checked,
                              value: sent
                                  ? '已发送'
                                  : offline
                                  ? '暂离线'
                                  : '在线',
                              child: Material(
                                color: checked
                                    ? Ui.colors(context).softGreen
                                    : Ui.colors(context).input,
                                shape: RoundedRectangleBorder(
                                  borderRadius: Ui.fieldRadius,
                                  side: BorderSide(
                                    color: checked
                                        ? Ui.colors(context).green
                                        : Ui.colors(context).border,
                                    width: checked ? 1.5 : 1,
                                  ),
                                ),
                                child: InkWell(
                                  key: ValueKey('target-$id'),
                                  borderRadius: Ui.fieldRadius,
                                  onLongPress: () =>
                                      Navigator.of(context).push<void>(
                                        MaterialPageRoute(
                                          builder: (_) => ReachabilityScreen(
                                            monitor: c.reachability,
                                            deviceId: id,
                                            deviceName: fullName,
                                            onRefresh: () =>
                                                c.refreshConnectionChecks(
                                                  deviceId: id,
                                                ),
                                          ),
                                        ),
                                      ),
                                  onTap:
                                      pending ||
                                          (!ui.multiSend &&
                                              (sendingTargets || count == 0))
                                      ? null
                                      : () {
                                          if (ui.multiSend) {
                                            setState(() {
                                              ui.sendTargets.contains(id)
                                                  ? ui.sendTargets.remove(id)
                                                  : ui.sendTargets.add(id);
                                            });
                                          } else {
                                            sendOne(id);
                                          }
                                        },
                                  child: Stack(
                                    children: [
                                      Positioned.fill(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 8,
                                          ),
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              SizedBox(
                                                height: 24,
                                                child: sent
                                                    ? Text(
                                                        '已发送',
                                                        style: TextStyle(
                                                          fontSize: 13,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: Ui.colors(
                                                            context,
                                                          ).green,
                                                        ),
                                                      )
                                                    : offline
                                                    ? Text(
                                                        '暂离线',
                                                        style: TextStyle(
                                                          fontSize: 13,
                                                          color: Ui.colors(
                                                            context,
                                                          ).muted,
                                                        ),
                                                      )
                                                    : AppIcon(
                                                        deviceIcon(device),
                                                        size: 24,
                                                        color: checked
                                                            ? Ui.colors(context)
                                                                  .green
                                                            : Ui.colors(context)
                                                                  .muted,
                                                      ),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                fullName,
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  height: 1.35,
                                                  fontWeight: checked
                                                      ? FontWeight.w600
                                                      : FontWeight.w400,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      if (pending)
                                        const Positioned(
                                          top: 8,
                                          right: 8,
                                          child: SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                            ),
                                          ),
                                        )
                                      else if (checked)
                                        Positioned(
                                          top: 8,
                                          right: 8,
                                          child: AppIcon(
                                            Icons.check_circle,
                                            size: 16,
                                            color: Ui.colors(context).green,
                                          ),
                                        )
                                      else if (state == 'failed')
                                        const Positioned(
                                          top: 8,
                                          right: 8,
                                          child: AppIcon(
                                            Icons.error_outline,
                                            size: 16,
                                            color: Color(0xffb3553f),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> sendOne(String id) async {
    if (sendingTargets || working) return;
    setState(() => sendingTargets = true);
    try {
      await c.sendStaged(id);
      if (mounted) showSentFeedback([id]);
    } catch (error) {
      if (mounted) notice(shortError('$error'));
    } finally {
      if (mounted) setState(() => sendingTargets = false);
    }
  }

  Future<void> sendSelected() async {
    if (sendingTargets || ui.sendTargets.isEmpty) return;
    final targets = ui.sendTargets.toList();
    setState(() {
      sendingTargets = true;
      ui.multiSend = false;
      ui.sendTargets.clear();
    });
    try {
      await c.sendStagedToMany(targets);
      if (mounted) showSentFeedback(targets);
    } catch (error) {
      if (mounted) notice(shortError('$error'));
    } finally {
      if (mounted) setState(() => sendingTargets = false);
    }
  }

  void showSentFeedback(Iterable<String> ids) {
    for (final id in ids) {
      if (c.stagedTargetStates[id] != 'sent') continue;
      _sentFeedbackTimers.remove(id)?.cancel();
      _sentFeedbackTimers[id] = Timer(const Duration(seconds: 3), () {
        _sentFeedbackTimers.remove(id);
        if (mounted) setState(() {});
      });
    }
    setState(() {});
  }

  Widget sharedEditor({bool expanded = false}) {
    final unsynced =
        c.sharedTextDirty &&
        (c.sharedTextStatus.contains('失败') ||
            c.sharedTextStatus.contains('离线') ||
            c.sharedTextStatus.contains('暂未连接'));
    final field = ValueListenableBuilder<TextEditingValue>(
      valueListenable: sharedText,
      builder: (_, value, _) {
        final selection = value.selection;
        final selectedText = selection.isValid && !selection.isCollapsed;
        final entry = DockEntry(
          id: 'group-shared-text-drag',
          kind: 'text',
          title: '组内共享',
          source: c.profile?.deviceId ?? '',
          text: selectedText ? selection.textInside(value.text) : value.text,
        );
        return ContentDragSurface(
          entry: entry,
          enabled: value.text.isNotEmpty,
          selectedText: selectedText,
          onExport: (kind) =>
              perform(() => c.dragOut(entry, pointerKind: kind)),
          child: EditableTextSelectionSurface(
            onBlankTap: (point) {
              final editable = sharedFocus.context
                  ?.findAncestorStateOfType<EditableTextState>();
              final offset =
                  editable?.renderEditable.getPositionForPoint(point).offset ??
                  sharedText.text.length;
              sharedFocus.requestFocus();
              sharedText.selection = TextSelection.collapsed(offset: offset);
            },
            child: Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.keyZ, control: true):
                    UndoTextIntent(SelectionChangedCause.keyboard),
                SingleActivator(LogicalKeyboardKey.keyY, control: true):
                    RedoTextIntent(SelectionChangedCause.keyboard),
                SingleActivator(
                  LogicalKeyboardKey.keyZ,
                  control: true,
                  shift: true,
                ): RedoTextIntent(
                  SelectionChangedCause.keyboard,
                ),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  UndoTextIntent: CallbackAction<UndoTextIntent>(
                    onInvoke: (_) {
                      changeSharedHistory(redo: false);
                      return null;
                    },
                  ),
                  RedoTextIntent: CallbackAction<RedoTextIntent>(
                    onInvoke: (_) {
                      changeSharedHistory(redo: true);
                      return null;
                    },
                  ),
                },
                child: TextField(
                  key: const ValueKey('shared-text-input'),
                  controller: sharedText,
                  focusNode: sharedFocus,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 14, height: 1.5),
                  enabled: c.sharedTextSupported,
                  decoration: InputDecoration(
                    hintText: '组内共同编辑',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: Ui.colors(context).muted,
                    ),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.fromLTRB(14, 8, 14, 12),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return Container(
      key: const ValueKey('shared-text-panel'),
      decoration: BoxDecoration(
        color: Ui.colors(context).input,
        borderRadius: Ui.fieldRadius,
        border: Border.all(
          color: unsynced || c.sharedTextConflict
              ? Theme.of(context).colorScheme.error
              : Ui.colors(context).border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 0),
            child: Row(
              children: [
                AppIcon(
                  Icons.edit_note_rounded,
                  size: 18,
                  color: Ui.colors(context).muted,
                ),
                const SizedBox(width: 6),
                const Text(
                  '组内共享',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  key: const ValueKey('shared-undo'),
                  tooltip: '撤销',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: c.sharedTextSupported && ui.sharedHistory.canUndo
                      ? () => changeSharedHistory(redo: false)
                      : null,
                  icon: const AppIcon(Icons.undo_rounded),
                ),
                IconButton(
                  key: const ValueKey('shared-redo'),
                  tooltip: '重做',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: c.sharedTextSupported && ui.sharedHistory.canRedo
                      ? () => changeSharedHistory(redo: true)
                      : null,
                  icon: const AppIcon(Icons.redo_rounded),
                ),
                if (unsynced)
                  Text(
                    '未同步',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
          if (expanded)
            Expanded(child: field)
          else
            SizedBox(height: 140, child: field),
          if (c.sharedTextConflict)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('其他设备也在编辑', style: TextStyle(fontSize: 12)),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: c.useRemoteSharedText,
                        child: const Text('用最新内容'),
                      ),
                      TextButton(
                        onPressed: c.retrySharedText,
                        child: const Text('保留我的'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (unsynced && !c.sharedTextConflict)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: c.retrySharedText,
                child: const Text('重试'),
              ),
            ),
        ],
      ),
    );
  }

  void openLibrary() => setState(() {
    contentTab = 2;
    selecting = false;
    selected.clear();
    page = 0;
  });

  Future<void> composeText({int? index, bool restoring = false}) async {
    if (!restoring && index != null) text.text = c.stagedTexts[index];
    ui.composeOpen = true;
    ui.composeIndex = index;
    final route = DialogRoute<String>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _ComposeTextDialog(controller: text),
    );
    final value = await Navigator.of(context).push(route);
    await route.completed;
    if (!mounted) return;
    ui.composeOpen = false;
    ui.composeIndex = null;
    scheduleReceipt();
    if (value == null || value.trim().isEmpty) return;
    await perform(() async {
      if (index != null && index < c.stagedTexts.length) {
        c.stagedTexts[index] = value;
        c.changed();
      } else {
        await c.stageInputs([], [value]);
      }
      text.clear();
    });
  }

  Future<void> openStagedFile(String path) => openFile(
    DockEntry(
      id: path,
      kind: 'file',
      title: safeName(path),
      source: '',
      localPath: path,
    ),
  );

  Future<void> pickFolder() => perform(c.chooseSendDirectory);

  void openSentHistory() => setState(() {
    contentTab = 1;
    selecting = false;
    selected.clear();
    page = 0;
  });

  Future<void> pickFiles({FileType type = FileType.any}) => perform(() async {
    final picked = await FilePicker.pickFiles(type: type);
    if (picked.length > 32) throw const FormatException('每次最多选择 32 个文件');
    final paths = <String>[];
    for (final item in picked) {
      if (item.path != null) {
        paths.add(item.path!);
        continue;
      }
      final size = await item.length();
      if (size == null || size > (c.info['limits']['maxFileSize'] as int)) {
        throw const FileSystemException('文件无法读取或过大');
      }
      final folder = Directory(
        '${(await appDataDirectory()).path}/outbox/${newId()}',
      );
      await folder.create(recursive: true);
      final file = File('${folder.path}/${safeName(item.name)}');
      final sink = file.openWrite();
      try {
        await sink.addStream(item.readAsByteStream());
        await sink.flush();
      } finally {
        await sink.close();
      }
      paths.add(file.path);
    }
    if (paths.isNotEmpty) await c.stageInputs(paths, []);
  });

  Widget receivePage() {
    final items = mergeContentCards(
      c.historyDock.where((item) => !item.outgoing),
    )..sort(compareReceivedNewestFirst);
    final batches = <String, List<DockEntry>>{};
    final cards = <DockEntry>[];
    for (final item in items) {
      if (!selecting &&
          item.kind == 'file' &&
          (item.status == 'offered' ||
              item.relayConfirmationPending && item.relayPendingBeforeAccept)) {
        (batches[item.transferId] ??= []).add(item);
      } else {
        cards.add(item);
      }
    }
    return Column(
      children: [
        UiContentToolbar(
          key: const ValueKey('receive-toolbar'),
          children: [
            Text(
              selecting
                  ? '${selected.length}/${items.length} 项'
                  : '${items.length} 项',
              style: TextStyle(fontSize: 12, color: Ui.colors(context).muted),
            ),
            BulkFileDrag(
              key: const ValueKey('receive-drag-all'),
              paths: items
                  .where(
                    (item) =>
                        item.kind == 'file' &&
                        item.localPath.isNotEmpty &&
                        (!selecting || selected.contains(item.id)),
                  )
                  .map((item) => item.localPath)
                  .toList(),
              enabled: !working,
              onError: (error) => notice(shortError('$error')),
            ),
            if (selecting)
              TextButton(
                key: const ValueKey('receive-copy-selected'),
                onPressed:
                    items.any(
                      (item) =>
                          item.kind == 'text' && selected.contains(item.id),
                    )
                    ? copySelected
                    : null,
                child: Text(
                  '复制 ${items.where((item) => item.kind == 'text' && selected.contains(item.id)).length} 项',
                ),
              ),
            if (selecting)
              TextButton(
                key: const ValueKey('receive-select-all'),
                onPressed: () => setState(() {
                  if (items.every((item) => selected.contains(item.id))) {
                    selected.clear();
                  } else {
                    selected.addAll(items.map((item) => item.id));
                  }
                }),
                child: Text(
                  items.every((item) => selected.contains(item.id))
                      ? '取消全选'
                      : '全选',
                ),
              ),
            if (selecting)
              TextButton(
                key: const ValueKey('receive-delete-selected'),
                onPressed: selected.isEmpty || working ? null : deleteSelected,
                child: const Text('删除'),
              ),
            if (items.isNotEmpty)
              TextButton(
                key: const ValueKey('receive-multi-select'),
                onPressed: () {
                  setState(() {
                    selecting = !selecting;
                    selected.clear();
                  });
                  if (!selecting) scheduleReceipt();
                },
                child: Text(selecting ? '取消' : '多选'),
              ),
          ],
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: c.safeReconcile,
            child: CustomScrollView(
              key: const ValueKey('receive-scroll'),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (items.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(
                            Icons.inbox_outlined,
                            size: 44,
                            color: Ui.colors(context).muted,
                          ),
                          SizedBox(height: 14),
                          Text(
                            '暂无接收',
                            style: TextStyle(color: Ui.colors(context).muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (batches.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    sliver: SliverList.list(
                      children: batches.values.map(offerCard).toList(),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  sliver: SliverGrid(
                    key: const ValueKey('receive-grid'),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      mainAxisExtent: cardExtent(),
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => entryCard(cards[index]),
                      childCount: cards.length,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget offerCard(List<DockEntry> batch) {
    final first = batch.first,
        size = batch.fold<int>(0, (sum, item) => sum + item.size);
    final relay = batch.any(
      (item) =>
          item.relayConfirmationPending || item.offerRoutePreference == 'relay',
    );
    return section('${sourceName(first.source)} · ${batch.length} 个文件', [
      for (final item in batch)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              AppIcon(
                Icons.description_outlined,
                size: 19,
                color: Ui.colors(context).muted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatSize(item.size),
                style: TextStyle(fontSize: 12, color: Ui.colors(context).muted),
              ),
            ],
          ),
        ),
      const SizedBox(height: 6),
      Text(
        '${relay ? '需中继 · ' : ''}${formatSize(size)}',
        style: TextStyle(fontSize: 13, color: Ui.colors(context).muted),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          FilledButton(
            onPressed: working
                ? null
                : () => perform(
                    () => c.approveReceive(
                      first,
                      batch.map((item) => item.fileId).toList(),
                    ),
                  ),
            child: const Text('接收'),
          ),
          if (batch.length > 1)
            TextButton(
              onPressed: working ? null : () => reviewBatch(batch),
              child: const Text('选择'),
            ),
          const Spacer(),
          TextButton(
            onPressed: working
                ? null
                : () => perform(() => c.accept(first, false)),
            child: const Text('拒绝'),
          ),
        ],
      ),
    ]);
  }

  Future<void> transferControl(String action, DockEntry item) async {
    try {
      if (action == 'pause') await c.pause(item);
      if (action == 'resume') await c.resume(item);
      if (action == 'cancel') await c.cancel(item);
      if (action == 'retry') await c.retry(item);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> receiptAction(DockEntry item) async {
    final action = IncomingReceiptState(item).primaryAction;
    if (['pause', 'resume', 'retry'].contains(action))
      return transferControl(action, item);
    if (action == 'approveRelay') return perform(() => c.approveRelay(item));
    if (action == 'receive')
      return perform(
        () => item.status == 'offered' ? c.accept(item, true) : c.receive(item),
      );
    return perform(() => openFile(item));
  }

  Widget transferControls(DockEntry item) => TextButtonTheme(
    data: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(40, 36),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    child: Wrap(
      spacing: 0,
      children: [
        if (item.locallyPaused)
          TextButton(
            onPressed: () => transferControl('resume', item),
            child: const Text('继续'),
          )
        else if (item.status != 'failed')
          TextButton(
            onPressed: () => transferControl('pause', item),
            child: const Text('暂停'),
          ),
        if (item.status == 'failed')
          TextButton(
            onPressed: () => transferControl('retry', item),
            child: const Text('重试'),
          ),
        TextButton(
          onPressed: () => transferControl('cancel', item),
          child: const Text('取消'),
        ),
      ],
    ),
  );

  Widget entryCard(
    DockEntry item, {
    bool selectionEnabled = true,
    Widget? footer,
  }) {
    final selectingItem = selectionEnabled && selecting;
    final android = Theme.of(context).platform == TargetPlatform.android;
    final draggable =
        item.kind == 'text' ||
        item.localPath.isNotEmpty &&
            (item.sourceReference.isEmpty ||
                Theme.of(context).platform == TargetPlatform.windows);
    final localHistory = c.isLocalHistory(item);
    final needsAction =
        !localHistory &&
        (item.relayConfirmationPending ||
            item.status == 'failed' ||
            !item.outgoing &&
                item.status == 'ready' &&
                item.kind == 'file' &&
                item.localPath.isEmpty);
    final active = [
      'uploading',
      'downloading',
      'directSending',
    ].contains(item.status);
    void open() {
      if (item.sourceReference.isNotEmpty)
        fileAction('details', item);
      else if (item.kind == 'text')
        readText(item);
      else if (item.localPath.isNotEmpty)
        perform(() => openFile(item));
      else
        fileAction('details', item);
    }

    final card = CompactContentCard(
      entry: item,
      sender: item.outgoing && item.targetDeviceId.isNotEmpty
          ? sourceName(item.targetDeviceId)
          : item.sourceLabel.isNotEmpty
          ? item.sourceLabel
          : sourceName(item.source),
      timestamp: entryTime(item),
      onOpen: open,
      onCopy: item.kind == 'text'
          ? () => perform(() => c.copyDockText(item))
          : null,
      copyKey: ValueKey(
        footer == null ? 'copy-${item.id}' : 'receipt-copy-${item.id}',
      ),
      selecting: selectingItem,
      selected: selected.contains(item.id),
      onToggle: () => setState(
        () => selected.contains(item.id)
            ? selected.remove(item.id)
            : selected.add(item.id),
      ),
      menu: PopupMenuButton<String>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        iconSize: 20,
        constraints: const BoxConstraints(minWidth: 140),
        icon: const AppIcon(Icons.more_horiz),
        onSelected: (action) => fileAction(action, item),
        itemBuilder: (_) => entryMenu(item),
      ),
      status: item.status == 'failed'
          ? '传输失败'
          : item.locallyPaused
          ? '已暂停'
          : '',
      speed: active && item.transferBytesPerSecond > 0
          ? '${formatSize(item.transferBytesPerSecond.round())}/s'
          : '',
      action: c.canControlTransfer(item) && !item.relayConfirmationPending
          ? transferControls(item)
          : needsAction
          ? TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(36, 32),
                padding: const EdgeInsets.symmetric(horizontal: 5),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: working
                  ? null
                  : () => perform(
                      () => item.relayConfirmationPending
                          ? c.approveRelay(item)
                          : item.status == 'failed'
                          ? c.retry(item)
                          : c.receive(item),
                    ),
              child: Text(
                item.relayConfirmationPending
                    ? '中继'
                    : item.status == 'failed'
                    ? '重试'
                    : '保存',
              ),
            )
          : null,
    );
    if (selectingItem && !android)
      return KeyedSubtree(key: ValueKey('select-${item.id}'), child: card);
    final surface = dragSurface(
      item,
      card,
      key: ValueKey('${draggable ? 'drag' : 'entry'}-${item.id}'),
      contextual: false,
      onExport: android && selectionEnabled
          ? (kind) => dragContentSelection(item)
          : null,
    );
    // Keep the Android recognizer mounted when the first held pointer enters
    // selection. Later holds export the selected batch; taps alone change it.
    return android && selectionEnabled
        ? KeyedSubtree(key: ValueKey('select-${item.id}'), child: surface)
        : surface;
  }

  Future<void> dragContentSelection(DockEntry item) => perform(() async {
    if (!selecting) {
      setState(() {
        selecting = true;
        selected
          ..clear()
          ..add(item.id);
      });
    }
    final entries =
        mergeContentCards(
              c.historyDock.where((entry) => entry.outgoing == item.outgoing),
            )
            .where(
              (entry) =>
                  selected.contains(entry.id) &&
                  (entry.kind == 'text' || entry.localPath.isNotEmpty),
            )
            .toList();
    // An empty selection can still drag its held source without selecting it.
    if (entries.isEmpty) entries.add(item);
    await DockPlatform.startDrag(
      paths: entries
          .where((entry) => entry.kind == 'file')
          .map((entry) => entry.localPath)
          .where((path) => path.isNotEmpty)
          .toSet()
          .toList(),
      texts: entries
          .where((entry) => entry.kind == 'text')
          .map((entry) => entry.text)
          .toList(),
      label: '${entries.length} 项',
    );
  });

  List<PopupMenuEntry<String>> entryMenu(DockEntry item) {
    final directory = item.sourceReference.isNotEmpty;
    final localHistory = c.isLocalHistory(item);
    final cancelable =
        !localHistory &&
        item.kind == 'file' &&
        ![
          'received',
          'sent',
          'canceled',
          'rejected',
          'expired',
        ].contains(item.status);
    return [
      if (item.kind == 'text') ...[
        PopupMenuItem(
          value: 'view',
          child: Text(item.outgoing ? '编辑文本' : '查看文本'),
        ),
        const PopupMenuItem(value: 'copy', child: Text('复制')),
      ],
      if (item.localPath.isNotEmpty)
        const PopupMenuItem(value: 'openExternal', child: Text('打开')),
      if (item.localPath.isNotEmpty && Platform.isWindows)
        const PopupMenuItem(value: 'locate', child: Text('定位文件')),
      if (item.kind == 'text' || item.localPath.isNotEmpty || directory)
        const PopupMenuItem(value: 'requeue', child: Text('加入待发送')),
      if (FileShareBridge.supported &&
          (item.kind == 'text' || item.localPath.isNotEmpty))
        const PopupMenuItem(value: 'share', child: Text('分享')),
      if (cancelable && item.locallyPaused)
        const PopupMenuItem(value: 'resume', child: Text('继续传输')),
      if (cancelable && !item.locallyPaused && item.status != 'failed')
        const PopupMenuItem(value: 'pause', child: Text('暂停传输')),
      if (!localHistory && item.outgoing && c.sources.containsKey(item.fileId))
        const PopupMenuItem(value: 'resend', child: Text('换路径重发')),
      if (!localHistory &&
          !item.outgoing &&
          item.status == 'failed' &&
          item.offerRoutePreference == 'auto')
        const PopupMenuItem(value: 'auto', child: Text('自动重试')),
      if (cancelable) const PopupMenuItem(value: 'cancel', child: Text('取消传输')),
      const PopupMenuItem(value: 'delete', child: Text('删除')),
      const PopupMenuItem(value: 'details', child: Text('详情')),
    ];
  }

  Future<void> showEntryMenu(DockEntry item, Offset position) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: entryMenu(item),
    );
    if (result != null && mounted) await fileAction(result, item);
  }

  Widget dragSurface(
    DockEntry item,
    Widget child, {
    Key? key,
    bool contextual = true,
    Future<void> Function(String kind)? onExport,
  }) {
    final windows = Theme.of(context).platform == TargetPlatform.windows;
    final draggable =
        item.kind == 'text' ||
        item.localPath.isNotEmpty && (item.sourceReference.isEmpty || windows);
    return MouseRegion(
      cursor: draggable ? SystemMouseCursors.grab : SystemMouseCursors.click,
      child: ContentDragSurface(
        key: key,
        entry: item,
        enabled: draggable && !working,
        onExport:
            onExport ??
            (kind) => perform(() => c.dragOut(item, pointerKind: kind)),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: contextual
              ? () => item.kind == 'text'
                    ? readText(item)
                    : item.localPath.isNotEmpty
                    ? perform(() => openFile(item))
                    : fileAction('details', item)
              : null,
          onSecondaryTapDown: (details) {
            if (!ContentDragSurface.allowsContextMenu(context, details.kind)) {
              return;
            }
            if (!isTextSelectionPosition(
              details.globalPosition,
              View.of(context).viewId,
            )) {
              showEntryMenu(item, details.globalPosition);
            }
          },
          child: child,
        ),
      ),
    );
  }

  String entryTime(DockEntry item) {
    final millis = item.outgoing
        ? item.createdAtMillis
        : item.receivedAtMillis > 0
        ? item.receivedAtMillis
        : item.createdAtMillis;
    return millis == 0
        ? ''
        : compactTime(DateTime.fromMillisecondsSinceEpoch(millis));
  }

  String previewText(String value) {
    final lines = value.split('\n').take(4).join('\n');
    return lines.length > 400 ? '${lines.substring(0, 400)}…' : lines;
  }

  Future<void> copySelected() => perform(() async {
    final values = mergeContentCards(c.historyDock).reversed
        .where((item) => item.kind == 'text' && selected.contains(item.id))
        .map((item) => item.text)
        .toList();
    await SystemBridge.copy(values.join('\n\n'), private: true);
    setState(() {
      selected.clear();
      selecting = false;
    });
    scheduleReceipt();
  }, done: '已复制');
  Future<void> deleteSelected() => perform(() async {
    final items = c.historyDock
        .where(
          (item) =>
              item.outgoing == (contentTab == 1) && selected.contains(item.id),
        )
        .toList();
    for (final item in items) {
      await c.removeHistoryEntries([item]);
      c.dismissReceipts([item.id]);
      ui.pendingReceipts.remove(item.id);
    }
    if (!mounted) return;
    setState(() {
      selected.clear();
      selecting = false;
      ui.pendingReceipt = ui.pendingReceipts.values.lastOrNull;
      _receiptVersion.value++;
    });
    scheduleReceipt();
  }, done: '已删除');
  Future<void> readText(DockEntry item) async {
    ui.readerId = item.id;
    await showTextViewer(
      context,
      title: item.outgoing
          ? '已发送文字'
          : item.sourceLabel.isNotEmpty
          ? item.sourceLabel
          : sourceName(item.source),
      text: item.text,
      editable: item.outgoing,
      initialValue: item.outgoing ? ui.readerDrafts[item.id] : null,
      onDraftChanged: item.outgoing
          ? (value) {
              if (value.text == item.text) {
                ui.readerDrafts.remove(item.id);
              } else {
                ui.readerDrafts[item.id] = value;
              }
            }
          : null,
      onSave: item.outgoing
          ? (value) async {
              await c.editSentText(item, value);
              ui.readerDrafts.remove(item.id);
            }
          : null,
    );
    if (!mounted) return;
    ui.readerId = '';
    scheduleReceipt();
  }

  Future<void> openFile(DockEntry item) async {
    if (item.isDirectory) {
      await ReceivedFileAccess.openExternal(item.localPath);
      return;
    }
    if (await showSavedImagePreview(
      context,
      path: item.localPath,
      title: item.title,
    )) {
      return;
    }
    if (!mounted) return;
    if (isTextPreviewFile(item.title)) {
      final source = await ReceivedFileAccess.open(item.localPath);
      try {
        if (!mounted) return;
        if (await showTextFilePreview(
          context,
          path: source.file.path,
          title: item.title,
          onOpenExternal: () => ReceivedFileAccess.openExternal(item.localPath),
        )) {
          return;
        }
      } finally {
        await source.close();
      }
    }
    await ReceivedFileAccess.openExternal(item.localPath);
  }

  Future<void> fileAction(String action, DockEntry item) async {
    if (['pause', 'resume', 'cancel'].contains(action)) {
      await transferControl(action, item);
      return;
    }
    if (action == 'requeue') {
      await perform(() => c.stageHistoryEntry(item));
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    if (action == 'view') {
      await readText(item);
      return;
    }
    if (action == 'copy') {
      await perform(() => c.copyDockText(item), done: '已复制');
      return;
    }
    if (action == 'share') {
      await perform(
        () => FileShareBridge.share(
          paths: item.kind == 'file' && item.localPath.isNotEmpty
              ? [item.localPath]
              : const [],
          text: item.kind == 'text' ? item.text : null,
        ),
      );
      return;
    }
    if (action == 'delete') {
      await perform(() => c.removeHistoryEntries([item]), done: '已删除');
      if (!c.historyDock.contains(item)) {
        c.dismissReceipts([item.id]);
        ui.pendingReceipts.remove(item.id);
        ui.pendingReceipt = ui.pendingReceipts.values.lastOrNull;
        _receiptVersion.value++;
        if (ui.pendingReceipts.isEmpty && _receiptOpen && mounted)
          Navigator.of(context).pop();
      }
      return;
    }
    if (action == 'openExternal') {
      await perform(() => ReceivedFileAccess.openExternal(item.localPath));
      return;
    }
    if (action == 'resend') {
      await resendSheet(item);
      return;
    }
    if (action == 'details') {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialog) => AnimatedBuilder(
          animation: c,
          builder: (_, __) => AlertDialog(
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const ValueKey('transfer-details-close'),
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(dialog),
                  icon: const AppIcon(Icons.close, size: 20),
                ),
              ],
            ),
            content: dialogScroll(
              SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      '${item.sourceReference.isNotEmpty ? '源文件夹\n' : ''}${item.kind == 'text' ? '${item.text.runes.length} 字符' : formatSize(item.size)}\n${entryTime(item)}\n${sourceName(item.outgoing ? item.targetDeviceId : item.source)}\n${statusLabel(item)} · ${routeLabels[item.route] ?? item.route}\n${item.sourceReference.isNotEmpty
                          ? '${item.sourceReference}\n'
                          : item.localPath.isEmpty
                          ? ''
                          : '${item.localPath}\n'}${item.routeDetail}${item.error.isEmpty ? '' : '\n${item.error}'}',
                    ),
                    if (item.receiveFailure && !item.outgoing) ...[
                      const SizedBox(height: 16),
                      Text(
                        '接收目录',
                        style: TextStyle(
                          fontSize: 13,
                          color: Ui.colors(context).muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        c.receiveDirectoryLabel.isEmpty
                            ? '默认目录'
                            : c.receiveDirectoryLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => perform(c.chooseReceiveDirectory),
                            child: const Text('更改目录'),
                          ),
                          if (c.hasCustomReceiveDirectory)
                            TextButton(
                              onPressed: () => perform(c.clearReceiveDirectory),
                              child: const Text('使用默认目录'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actionsAlignment: MainAxisAlignment.spaceBetween,
            actions: [
              if (c.canControlTransfer(item)) ...[
                TextButton(
                  key: const ValueKey('transfer-details-cancel'),
                  onPressed: () => transferControl('cancel', item),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('取消传输'),
                ),
                FilledButton(
                  key: const ValueKey('transfer-details-primary'),
                  onPressed: () => transferControl(
                    item.locallyPaused
                        ? 'resume'
                        : item.status == 'failed'
                        ? 'retry'
                        : 'pause',
                    item,
                  ),
                  child: Text(
                    item.locallyPaused
                        ? '继续'
                        : item.status == 'failed'
                        ? '重试'
                        : '暂停',
                  ),
                ),
              ],
            ],
          ),
        ),
      );
      return;
    }
    await perform(() async {
      if (action == 'cancel') await c.cancel(item);
      if (action == 'auto') await c.receive(item, routeOverride: 'auto');
      if (action == 'locate') {
        await SystemBridge.revealFile(
          item.sourceReference.isNotEmpty
              ? item.sourceReference
              : item.localPath,
        );
      }
    });
  }

  /// Modal content scrolls normally without an automatic desktop thumb. The
  /// queue and device strips keep their explicitly requested scrollbars.
  Widget dialogScroll(Widget child) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: child,
  );

  Future<void> resendSheet(DockEntry item) async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '重新发送 · ${formatSize(item.size)}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final mode in ['auto', 'lan', 'public', 'relay'])
              ListTile(
                title: Text(routeLabels[mode]!),
                onTap: () => Navigator.pop(sheet, mode),
              ),
          ],
        ),
      ),
    );
    if (mode != null) await perform(() => c.resendWithRoute(item, mode));
  }

  Future<void> reviewBatch(List<DockEntry> batch) async {
    final checked = batch.map((item) => item.fileId).toSet();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '选择文件',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final item in batch)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: checked.contains(item.fileId),
                        title: Text(item.title),
                        subtitle: Text(formatSize(item.size)),
                        onChanged: (value) => update(() {
                          value == true
                              ? checked.add(item.fileId)
                              : checked.remove(item.fileId);
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(sheet, checked.toList()),
                  child: Text('接收 ${checked.length} 项'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '未选文件将拒绝',
                style: TextStyle(fontSize: 12, color: Ui.colors(context).muted),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) {
      await perform(() => c.approveReceive(batch.first, result));
    }
  }

  Widget routePicker(bool sending) => UiField(
    label: sending ? '发送方式' : '接收方式',
    child: DropdownButtonFormField<String>(
      icon: const AppIcon(Icons.arrow_drop_down),
      key: ValueKey(
        '${c.profile!.key}-$sending-${sending ? c.profile!.sendRoutePreference : c.profile!.receiveRoutePreference}',
      ),
      initialValue: sending
          ? c.profile!.sendRoutePreference
          : c.profile!.receiveRoutePreference,
      decoration: const InputDecoration(),
      items: ['auto', 'lan', 'public', 'relay']
          .map(
            (mode) =>
                DropdownMenuItem(value: mode, child: Text(routeLabels[mode]!)),
          )
          .toList(),
      onChanged: working
          ? null
          : (mode) =>
                perform(() => c.setRoutePreference(mode!, sending: sending)),
    ),
  );

  IconData deviceIcon(Map<String, dynamic> device) =>
      switch ((device['platform'] as String? ?? '').toLowerCase()) {
        'windows' || 'linux' => Icons.computer_outlined,
        'macos' => Icons.laptop_mac_outlined,
        'web' => Icons.web_outlined,
        'ipad' || 'ipados' || 'tablet' => Icons.tablet_mac_outlined,
        'android' || 'ios' || 'iphone' => Icons.phone_android_outlined,
        _ => Icons.devices_outlined,
      };

  Widget settingsSection(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: UiSection(title: title, children: children),
  );

  Widget deviceTile(Map<String, dynamic> device) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: AppIcon(deviceIcon(device), size: 22),
    title: Text(device['name'], maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: device['online'] == true ? null : const Text('离线'),
    trailing: IconButton(
      tooltip: '移除设备',
      onPressed: working ? null : () => removeDevice(device),
      icon: const AppIcon(Icons.link_off, size: 20),
    ),
  );

  Widget clipboardSettings() {
    final active = c.clipboardEnabled ? c.clipboardTarget : null;
    if (!c.clipboardEnabled &&
        !peers.any((peer) => peer['deviceId'] == clipboardChoice)) {
      clipboardChoice = peers.firstOrNull?['deviceId'];
    }
    final choice = active ?? clipboardChoice;
    final online = peers.any((peer) => peer['deviceId'] == choice);
    return Column(
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('clipboard-sync'),
          contentPadding: EdgeInsets.zero,
          hoverColor: Colors.transparent,
          tileColor: Colors.transparent,
          title: const Text('同步剪贴板'),
          value: c.clipboardEnabled,
          onChanged: working || !c.clipboardEnabled && !online
              ? null
              : (value) => perform(
                  () => c.setClipboardSync(value, value ? choice! : ''),
                ),
        ),
        if (choice != null)
          UiField(
            label: '同步到',
            child: DropdownButtonFormField<String>(
              icon: const AppIcon(Icons.arrow_drop_down),
              key: ValueKey('clipboard-target-$choice'),
              initialValue: choice,
              isExpanded: true,
              decoration: const InputDecoration(),
              items: [
                for (final device in peers)
                  DropdownMenuItem(
                    value: device['deviceId'] as String,
                    child: Text(
                      device['name'],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (active != null && !online)
                  DropdownMenuItem(
                    value: active,
                    enabled: false,
                    child: Text(
                      '${sourceName(active)} · 离线',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: working
                  ? null
                  : (value) {
                      if (value == null || value == choice) return;
                      if (c.clipboardEnabled) {
                        perform(() => c.setClipboardSync(true, value));
                      } else {
                        setState(() => clipboardChoice = value);
                      }
                    },
            ),
          ),
      ],
    );
  }

  bool get cleanupFilterChanged {
    final saved = c.savedFileCleanupFilter;
    return saved.categories.length != cleanupCategories.length ||
        !saved.categories.containsAll(cleanupCategories) ||
        saved.sizeRule != cleanupSizeRule ||
        cleanupSizeRule != SavedFileSizeRule.any &&
            double.tryParse(cleanupSize.text) != saved.sizeMiB * 1048576 / 1000;
  }

  Widget cleanupFilterFields() => ValueListenableBuilder<TextEditingValue>(
    valueListenable: cleanupSize,
    builder: (_, value, child) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 18),
        Text(
          '清理类别',
          style: TextStyle(fontSize: 13, color: Ui.colors(context).muted),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final category in SavedFileCategory.values)
              FilterChip(
                label: Text(
                  const {
                    SavedFileCategory.image: '图片',
                    SavedFileCategory.video: '视频',
                    SavedFileCategory.audio: '音频',
                    SavedFileCategory.text: '文本',
                    SavedFileCategory.archive: '压缩包',
                    SavedFileCategory.other: '其他',
                  }[category]!,
                ),
                selected: cleanupCategories.contains(category),
                onSelected: working
                    ? null
                    : (selected) => setState(() {
                        selected
                            ? cleanupCategories.add(category)
                            : cleanupCategories.remove(category);
                      }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: UiField(
                label: '清理文件大小',
                child: DropdownButtonFormField<SavedFileSizeRule>(
                  icon: const AppIcon(Icons.arrow_drop_down),
                  key: ValueKey('cleanup-size-rule-$cleanupSizeRule'),
                  initialValue: cleanupSizeRule,
                  isExpanded: true,
                  decoration: const InputDecoration(),
                  items: const [
                    DropdownMenuItem(
                      value: SavedFileSizeRule.any,
                      child: Text('不限'),
                    ),
                    DropdownMenuItem(
                      value: SavedFileSizeRule.greater,
                      child: Text('大于'),
                    ),
                    DropdownMenuItem(
                      value: SavedFileSizeRule.smaller,
                      child: Text('小于'),
                    ),
                    DropdownMenuItem(
                      value: SavedFileSizeRule.atMost,
                      child: Text('不大于'),
                    ),
                  ],
                  onChanged: working
                      ? null
                      : (value) => setState(() => cleanupSizeRule = value!),
                ),
              ),
            ),
            if (cleanupSizeRule != SavedFileSizeRule.any) ...[
              const SizedBox(width: 10),
              Expanded(
                child: UiField(
                  label: '大小',
                  child: TextField(
                    key: const ValueKey('cleanup-size-input'),
                    controller: cleanupSize,
                    enabled: !working,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(suffixText: 'KB'),
                    onSubmitted: (_) => saveCleanupFilter(),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (cleanupFilterChanged)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('save-cleanup-filter'),
              style: TextButton.styleFrom(
                disabledForegroundColor: Ui.colors(context).muted,
              ),
              onPressed: working || !cleanupFilterChanged
                  ? null
                  : saveCleanupFilter,
              child: const Text('保存筛选'),
            ),
          ),
      ],
    ),
  );

  Widget settingsPage() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          settingsSection('外观', [const AppearancePicker()]),
          settingsSection('本机', [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: name,
              builder: (_, value, child) => UiField(
                label: '设备名称',
                child: TextField(
                  key: const ValueKey('device-name-input'),
                  controller: name,
                  enabled: !working,
                  onChanged: (_) => _nameEdited = true,
                  maxLength: 80,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    counterText: '',
                    suffixIcon: value.text.trim() != c.profile!.name || renaming
                        ? TextButton(
                            key: const ValueKey('save-device-name'),
                            style: TextButton.styleFrom(
                              disabledForegroundColor: Ui.colors(context).muted,
                            ),
                            onPressed:
                                working ||
                                    _hasComposingText(value) ||
                                    value.text.trim().isEmpty ||
                                    value.text.trim() == c.profile!.name
                                ? null
                                : saveDeviceName,
                            child: Text(renaming ? '保存中…' : '保存'),
                          )
                        : null,
                  ),
                  onSubmitted: (_) => saveDeviceName(),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('system-device-name'),
                onPressed: working
                    ? null
                    : () => perform(() async {
                        final value = await c.useSystemDeviceName();
                        if (mounted) {
                          name.text = value;
                          _nameEdited = false;
                        }
                      }, done: '已保存'),
                child: const Text('使用系统名称'),
              ),
            ),
          ]),
          settingsSection('连接', [
            UiField(
              label: '服务器',
              child: TextField(
                controller: address,
                enabled: !working,
                minLines: 1,
                maxLines: 3,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: working ? null : switchServer,
                child: const Text('切换服务器'),
              ),
            ),
            if (c.profiles.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: UiField(
                  label: '已保存服务器',
                  child: DropdownButtonFormField<String>(
                    icon: const AppIcon(Icons.arrow_drop_down),
                    key: ValueKey('saved-server-${c.profile!.key}'),
                    initialValue: c.profiles.any((p) => p.key == c.profile!.key)
                        ? c.profile!.key
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(),
                    items: c.profiles
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.key,
                            child: Text(
                              p.baseUrl,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: working
                        ? null
                        : (key) {
                            final p = c.profiles.firstWhere(
                              (p) => p.key == key,
                            );
                            address.text = p.baseUrl;
                            development = p.baseUrl.startsWith('http:');
                            switchServer();
                          },
                  ),
                ),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('连接检测'),
              trailing: const AppIcon(Icons.chevron_right, size: 20),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ReachabilityScreen(
                    monitor: c.reachability,
                    onRefresh: c.refreshConnectionChecks,
                  ),
                ),
              ),
            ),
          ]),
          settingsSection('传输', [
            if (c.backgroundReceiveAvailable) ...[
              SwitchListTile.adaptive(
                key: const ValueKey('background-receive'),
                contentPadding: EdgeInsets.zero,
                title: const Text('后台接收'),
                subtitle: Text(c.backgroundReceiveStatus),
                value: c.backgroundReceiveEnabled,
                onChanged: working
                    ? null
                    : (value) => perform(() => c.setBackgroundEnabled(value)),
              ),
              ListTile(
                key: const ValueKey('background-battery-settings'),
                contentPadding: EdgeInsets.zero,
                title: const Text('电池限制'),
                subtitle: Text(
                  c.backgroundBatteryUnrestricted ? '不受限' : '由系统管理',
                ),
                trailing: const AppIcon(Icons.chevron_right),
                onTap: working
                    ? null
                    : () => perform(c.openBackgroundBatterySettings),
              ),
            ],
            if (c.receiveNotificationsAvailable)
              ListTile(
                key: const ValueKey('receive-notifications'),
                contentPadding: EdgeInsets.zero,
                title: const Text('接收通知'),
                subtitle: Text(c.receiveNotificationsEnabled ? '已开启' : '未开启'),
                trailing: const AppIcon(Icons.chevron_right, size: 20),
                onTap: working
                    ? null
                    : () => perform(
                        () => c.refreshReceiveNotifications(
                          request: true,
                          explicit: true,
                        ),
                      ),
              ),
            if (c.receivePopupAvailable)
              ListTile(
                key: const ValueKey('receive-heads-up'),
                contentPadding: EdgeInsets.zero,
                title: const Text('悬浮通知'),
                subtitle: Text(
                  !c.receiveNotificationsEnabled
                      ? '未开启通知'
                      : c.receiveHeadsUpAllowed
                      ? '已开启'
                      : '请允许横幅显示',
                ),
                trailing: TextButton(
                  onPressed: working
                      ? null
                      : () => perform(c.openReceiveNotificationSettings),
                  child: const Text('设置'),
                ),
              ),
            if (c.receivePopupAvailable)
              SwitchListTile.adaptive(
                key: const ValueKey('receive-popup'),
                contentPadding: EdgeInsets.zero,
                title: const Text('后台弹出'),
                subtitle: Row(
                  children: [
                    Expanded(child: Text(c.receivePopupStatus)),
                    if (c.receivePopupEnabled && !c.receivePopupAllowed)
                      TextButton(
                        key: const ValueKey('receive-popup-permission'),
                        onPressed: working
                            ? null
                            : () => perform(c.openReceivePopupSettings),
                        child: const Text('授权'),
                      ),
                  ],
                ),
                value: c.receivePopupEnabled,
                onChanged: working
                    ? null
                    : (value) => perform(() => c.setReceivePopupEnabled(value)),
              ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              hoverColor: Colors.transparent,
              tileColor: Colors.transparent,
              title: const Text('自动接收'),
              value: c.profile!.autoReceive,
              onChanged: working
                  ? null
                  : (value) => perform(() => c.setAutoReceive(value)),
            ),
            if (recentPhotos.supported)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('新图片建议'),
                subtitle: recentPhotos.problem == null
                    ? null
                    : Text(recentPhotos.problem!),
                value: recentPhotos.enabled,
                onChanged: working
                    ? null
                    : (value) => perform(() => recentPhotos.setEnabled(value)),
              ),
            if (recentPhotos.supported &&
                !recentPhotos.permissionGranted &&
                recentPhotos.problem != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: working
                      ? null
                      : () => perform(recentPhotos.openSettings),
                  child: const Text('照片权限'),
                ),
              ),
            const SizedBox(height: 12),
            routePicker(true),
            const SizedBox(height: 16),
            routePicker(false),
            const SizedBox(height: 16),
            UiField(
              label: '传输并发数',
              child: DropdownButtonFormField<int>(
                icon: const AppIcon(Icons.arrow_drop_down),
                key: ValueKey('transfer-concurrency-${c.transferConcurrency}'),
                initialValue: c.transferConcurrency,
                decoration: const InputDecoration(),
                items: List.generate(
                  16,
                  (index) => DropdownMenuItem(
                    value: index + 1,
                    child: Text('${index + 1}'),
                  ),
                ),
                onChanged: working
                    ? null
                    : (value) =>
                          perform(() => c.setTransferConcurrency(value!)),
              ),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: relayLimit,
              builder: (_, value, child) => UiField(
                label: '中继确认阈值',
                child: TextField(
                  controller: relayLimit,
                  enabled: !working,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    suffixText: 'MiB',
                    suffixIcon:
                        int.tryParse(value.text) != c.profile!.relayConfirmMiB
                        ? TextButton(
                            key: const ValueKey('save-relay-limit'),
                            style: TextButton.styleFrom(
                              disabledForegroundColor: Ui.colors(context).muted,
                            ),
                            onPressed:
                                working ||
                                    int.tryParse(value.text) ==
                                        c.profile!.relayConfirmMiB
                                ? null
                                : saveRelayLimit,
                            child: const Text('保存'),
                          )
                        : null,
                  ),
                  onSubmitted: (_) => saveRelayLimit(),
                ),
              ),
            ),
            if (Platform.isAndroid)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                hoverColor: Colors.transparent,
                tileColor: Colors.transparent,
                title: const Text('允许蜂窝传输'),
                value: c.cellularUploads,
                onChanged: working || !c.profile!.baseUrl.startsWith('https:')
                    ? null
                    : (value) => perform(() => c.setCellularAllowed(value)),
              ),
            if (Platform.isWindows) clipboardSettings(),
          ]),
          settingsSection('存储', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('接收位置'),
              subtitle: Text(
                c.receiveDirectoryMigrationStatus.isNotEmpty
                    ? c.receiveDirectoryMigrationStatus
                    : c.hasCustomReceiveDirectory
                    ? c.receiveDirectoryLabel
                    : '应用目录',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton(
                key: const ValueKey('change-receive-directory'),
                onPressed: working
                    ? null
                    : () => perform(c.chooseReceiveDirectory),
                child: const Text('更改'),
              ),
            ),
            if (c.hasCustomReceiveDirectory)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: working
                      ? null
                      : () => perform(c.clearReceiveDirectory, done: '已恢复默认'),
                  child: const Text('恢复默认'),
                ),
              ),
            if (Platform.isAndroid)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    key: const ValueKey('receive-downloads-directory'),
                    onPressed: working
                        ? null
                        : () => perform(useDownloadsDirectory),
                    child: const Text('Download/GlobalSend'),
                  ),
                  TextButton(
                    key: const ValueKey('manage-all-files-access'),
                    onPressed: working
                        ? null
                        : () =>
                              perform(ReceiveDestination.openAllFilesSettings),
                    child: Text(
                      _allFilesAccess == true ? '所有文件权限已开启' : '管理所有文件权限',
                    ),
                  ),
                ],
              ),
            if (c.receiveDirectoryCleanupPending > 0)
              TextButton(
                onPressed: working
                    ? null
                    : () => perform(c.finishReceiveDirectoryCleanup),
                child: Text('清理旧位置剩余文件（${c.receiveDirectoryCleanupPending}）'),
              ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: retention,
                    builder: (_, value, child) {
                      final hours =
                          (int.tryParse(value.text) ?? 0) *
                          (retentionInDays ? 24 : 1);
                      return UiField(
                        label: '文件保留',
                        child: TextField(
                          key: const ValueKey('file-retention-input'),
                          controller: retention,
                          enabled: !working,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            suffixIcon: hours != c.savedFileRetentionHours
                                ? TextButton(
                                    key: const ValueKey('save-file-retention'),
                                    style: TextButton.styleFrom(
                                      disabledForegroundColor: const Color(
                                        0xff738176,
                                      ),
                                    ),
                                    onPressed:
                                        working ||
                                            hours < 1 ||
                                            hours == c.savedFileRetentionHours
                                        ? null
                                        : saveFileRetention,
                                    child: const Text('保存'),
                                  )
                                : null,
                          ),
                          onSubmitted: (_) => saveFileRetention(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 120,
                  child: UiField(
                    label: '单位',
                    child: DropdownButtonFormField<bool>(
                      icon: const AppIcon(Icons.arrow_drop_down),
                      key: ValueKey('retention-unit-$retentionInDays'),
                      initialValue: retentionInDays,
                      isExpanded: true,
                      decoration: const InputDecoration(),
                      items: const [
                        DropdownMenuItem(value: true, child: Text('天')),
                        DropdownMenuItem(value: false, child: Text('小时')),
                      ],
                      onChanged: working
                          ? null
                          : (value) => setState(() => retentionInDays = value!),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '到期后删除收到的文件',
              style: TextStyle(fontSize: 12, color: Ui.colors(context).muted),
            ),
            cleanupFilterFields(),
          ]),
          settingsSection('分组', [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('退出当前组'),
              trailing: const AppIcon(Icons.logout_rounded, size: 20),
              onTap: working ? null : signOut,
            ),
          ]),
          Material(
            color: Ui.colors(context).surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Ui.colors(context).border),
            ),
            clipBehavior: Clip.antiAlias,
            child: AppExpansionTile(
              key: const ValueKey('settings-more'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              collapsedShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 4,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              title: Text(
                '关于与诊断',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              children: [
                ListTile(
                  title: const Text('连接信息'),
                  subtitle: Text(c.connection),
                  onTap: () => showDialog<void>(
                    context: context,
                    barrierDismissible: true,
                    builder: (dialog) => AlertDialog(
                      title: const Text('连接信息'),
                      content: dialogScroll(
                        SingleChildScrollView(
                          child: SelectableText(
                            '${c.profile!.baseUrl}\n${c.peerStatus}${c.message.isEmpty ? '' : '\n${c.message}'}',
                          ),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialog),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (Platform.isAndroid && c.cellularUploads)
                  ListTile(
                    title: const Text('检查蜂窝连接'),
                    onTap: () => perform(() async {
                      final result = await NetworkBridge.probe(
                        '${c.profile!.baseUrl}/api/v1/info',
                        cellular: true,
                      );
                      if (mounted) {
                        await showDialog<void>(
                          context: context,
                          barrierDismissible: true,
                          builder: (dialog) => AlertDialog(
                            title: const Text('蜂窝连接'),
                            content: SelectableText('$result'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialog),
                                child: const Text('关闭'),
                              ),
                            ],
                          ),
                        );
                      }
                    }),
                  ),
                ListTile(
                  title: const Text('开源许可'),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'GlobalSend',
                    applicationVersion: '1.0.0',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Future<void> saveDeviceName() async {
    final next = name.text.trim();
    if (_hasComposingText(name.value)) return;
    if (next.isEmpty) {
      notice('请输入设备名称');
      return;
    }
    if (working || next == c.profile!.name) return;
    setState(() => renaming = true);
    try {
      await perform(() => c.renameDevice(next), done: '已保存');
    } finally {
      if (mounted) setState(() => renaming = false);
    }
  }

  Future<void> saveRelayLimit() => perform(
    () => c.setRelayConfirmMiB(int.tryParse(relayLimit.text) ?? 0),
    done: '已保存',
  );

  Future<void> saveFileRetention() async {
    final hours =
        (int.tryParse(retention.text) ?? 0) * (retentionInDays ? 24 : 1);
    if (hours < 1) {
      notice('至少保留 1 小时');
      return;
    }
    await perform(() => c.setSavedFileRetentionHours(hours), done: '已保存');
  }

  Future<void> saveCleanupFilter() async {
    final size = cleanupSizeRule == SavedFileSizeRule.any
        ? 0.0
        : double.tryParse(cleanupSize.text);
    if (size == null || !size.isFinite || size < 0) {
      notice('请输入有效的 KB 大小');
      return;
    }
    await perform(
      () => c.setSavedFileCleanupFilter(
        SavedFileCleanupFilter(
          categories: Set.of(cleanupCategories),
          sizeRule: cleanupSizeRule,
          sizeMiB: size * 1000 / 1048576,
        ),
      ),
      done: '已保存',
    );
  }

  Future<void> switchServer() async {
    if (address.text != c.profile?.baseUrl &&
        (text.text.isNotEmpty ||
            c.busyFiles.isNotEmpty ||
            c.stagedFiles.isNotEmpty ||
            c.stagedTexts.isNotEmpty)) {
      if (!await confirm('切换服务器？', '未发送内容将清空，当前传输会停止。', '切换')) return;
    }
    await perform(() async {
      await c.connect(
        address.text,
        development: development || address.text.startsWith('http:'),
      );
      text.clear();
      secret.clear();
      target = null;
      if (!loggedIn) settingsOpen = false;
    });
  }

  Future<bool> confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> removeDevice(Map<String, dynamic> device) async {
    if (await confirm('移除 ${device['name']}？', '对方可使用组密码重新加入。', '移除')) {
      await perform(() => c.revoke(device['deviceId']), done: '已移除');
    }
  }

  Future<void> signOut() async {
    if (await confirm('退出组？', '未完成的传输会停止，已保存文件保留。', '退出')) {
      await perform(() async {
        await c.signOutLocal();
        text.clear();
        secret.clear();
        target = null;
        settingsOpen = false;
      });
    }
  }
}

class NativeDropFeedback extends StatelessWidget {
  const NativeDropFeedback({
    super.key,
    required this.child,
    required this.active,
    required this.importing,
  });
  final Widget child;
  final bool active, importing;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      child,
      if (active || importing)
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              key: const ValueKey('native-drop-feedback'),
              padding: const EdgeInsets.all(20),
              alignment: Alignment.center,
              color: Ui.colors(context).input.withValues(alpha: .91),
              child: CustomPaint(
                painter: _DashedDropBorder(Ui.colors(context).muted),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (importing)
                        const CircularProgressIndicator(strokeWidth: 2),
                      if (!importing)
                        AppIcon(
                          Icons.file_download_outlined,
                          size: 38,
                          color: Ui.colors(context).muted,
                        ),
                      if (importing) const SizedBox(height: 14),
                      if (!importing) const SizedBox(height: 14),
                      Text(
                        importing ? '正在添加…' : '松手',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          decoration: TextDecoration.none,
                          color: Ui.colors(context).ink,
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _DashedDropBorder extends CustomPainter {
  const _DashedDropBorder(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20)),
      );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    for (final metric in path.computeMetrics()) {
      for (double distance = 0; distance < metric.length; distance += 15) {
        canvas.drawPath(
          metric.extractPath(distance, math.min(distance + 8, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashedDropBorder oldDelegate) =>
      color != oldDelegate.color;
}

class _ComposeTextDialog extends StatefulWidget {
  const _ComposeTextDialog({required this.controller});
  final TextEditingController controller;
  @override
  State<_ComposeTextDialog> createState() => _ComposeTextDialogState();
}

class _ComposeTextDialogState extends State<_ComposeTextDialog> {
  final focus = FocusNode();
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  void submit() {
    if (!_hasComposingText(widget.controller.value) &&
        widget.controller.text.trim().isNotEmpty) {
      Navigator.pop(context, widget.controller.text);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Ui.colors(context).surface,
    insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: SizedBox(
        height: Ui.editorSize(context).height,
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (_, value, _) => CallbackShortcuts(
            bindings: {
              if (!_hasComposingText(value)) ...{
                const SingleActivator(LogicalKeyboardKey.enter, control: true):
                    submit,
                const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                    submit,
              },
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                  child: Row(
                    children: [
                      const Text(
                        '添加文本',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const AppIcon(Icons.close, size: 20),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: TextField(
                    key: const ValueKey('draft-input'),
                    controller: widget.controller,
                    focusNode: focus,
                    autofocus: true,
                    expands: true,
                    minLines: null,
                    maxLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(fontSize: 16, height: 1.55),
                    decoration: const InputDecoration(
                      hintText: '输入或粘贴文字…',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.all(20),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Row(
                    children: [
                      Text(
                        '${value.text.runes.length} 字符',
                        style: TextStyle(
                          fontSize: 13,
                          color: Ui.colors(context).muted,
                        ),
                      ),
                      const Spacer(),
                      FilledButton(
                        key: const ValueKey('stage-text'),
                        onPressed:
                            value.text.trim().isEmpty ||
                                _hasComposingText(value)
                            ? null
                            : submit,
                        child: const Text('加入待发送'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
