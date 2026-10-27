import 'package:flutter/material.dart';

import 'models.dart';
import 'saved_files.dart';
import 'shared_edit_history.dart';

/// In-memory UI drafts survive unloading the hidden Windows window.
/// No server passwords or message drafts are written to disk here.
class SendUiSession {
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
  SavedFileSizeRule cleanupSizeRule = SavedFileSizeRule.atMost;
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
}
