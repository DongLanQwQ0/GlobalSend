import 'package:flutter/material.dart';

import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'saved_files.dart';
import 'shared_edit_history.dart';

/// In-memory UI drafts survive unloading the hidden Windows window.
/// Update handoff persists only content drafts, never connection credentials.
class SendUiSession {
  VoidCallback? captureUpdateDrafts;
  String sharedDraftScope = '', sharedDraft = '';
  final sharedHistory = SharedEditHistory();
  final fields = <String, TextEditingValue>{};
  final readerDrafts = <String, TextEditingValue>{};
  final routes = RouteObserver<ModalRoute<dynamic>>();
  // Keep the existing page identities: 1 sends, 0 shows local content.
  int page = 1;
  int contentTab = 0;
  bool settingsOpen = false, composeOpen = false;
  bool multiSend = false;
  bool development = false, showKey = false, retentionInDays = true;
  Set<SavedFileCategory> cleanupCategories = Set.of(
    SavedFileCleanupFilter().categories,
  );
  SavedFileSizeRule cleanupSizeRule = SavedFileSizeRule.smaller;
  String? clipboardChoice;
  final sendTargets = <String>{};
  int? composeIndex;
  String readerId = '';
  String? detailsId;
  int detailsRequest = 0;
  int? receiptSerial;
  int notificationSerial = 0;
  DockEntry? pendingReceipt;
  final pendingReceipts = <String, DockEntry>{};

  Future<void> saveUpdateDrafts(File file) async {
    captureUpdateDrafts?.call();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'schema': 1,
        'page': page,
        'contentTab': contentTab,
        'composeOpen': composeOpen,
        'composeIndex': composeIndex,
        if (fields['compose'] case final value?) 'compose': value.toJSON(),
        'readerId': readerId,
        'readerDrafts': {
          for (final entry in readerDrafts.entries)
            entry.key: entry.value.toJSON(),
        },
        'sharedDraftScope': sharedDraftScope,
        'sharedDraft': sharedDraft,
      }),
      flush: true,
    );
  }

  Future<bool> loadUpdateDrafts(File file) async {
    if (!await file.exists()) return false;
    final value = jsonDecode(await file.readAsString()) as Map;
    page = value['page'] as int? ?? 1;
    contentTab = value['contentTab'] as int? ?? 0;
    composeOpen = value['composeOpen'] == true;
    composeIndex = value['composeIndex'] as int?;
    if (value['compose'] is Map)
      fields['compose'] = TextEditingValue.fromJSON(
        Map<String, dynamic>.from(value['compose']),
      );
    readerId = value['readerId'] as String? ?? '';
    for (final entry in (value['readerDrafts'] as Map? ?? {}).entries) {
      readerDrafts[entry.key as String] = TextEditingValue.fromJSON(
        Map<String, dynamic>.from(entry.value),
      );
    }
    sharedDraftScope = value['sharedDraftScope'] as String? ?? '';
    sharedDraft = value['sharedDraft'] as String? ?? '';
    await file
        .delete(); // Consume once; later updates capture the current state.
    return true;
  }
}
