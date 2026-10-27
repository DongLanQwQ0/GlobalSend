import 'models.dart';
import 'received_order.dart';

/// Display state for one incoming file. The transfer and receipt keep the same
/// entry identity from offer through completion; no second progress record.
class IncomingReceiptState {
  const IncomingReceiptState(this.entry);
  final DockEntry entry;

  bool get incomingFile => entry.kind == 'file' && !entry.outgoing;
  bool get pending =>
      incomingFile &&
      (const {
            'offered',
            'accepted',
            'uploading',
            'downloading',
          }.contains(entry.status) ||
          entry.status == 'ready' && entry.localPath.isEmpty);
  bool get paused => incomingFile && entry.status == 'paused';
  bool get failed => incomingFile && entry.status == 'failed';
  bool get canceled => incomingFile && entry.status == 'canceled';
  bool get showProgress => pending || paused;
  double? get progressValue =>
      pending && entry.progress <= 0 ? null : entry.progress.clamp(0.0, 1.0);
  bool get canExport =>
      entry.kind == 'text' ||
      entry.localPath.isNotEmpty && !pending && !paused && !failed && !canceled;

  String get label {
    if (!incomingFile) return '';
    if (failed) return '接收失败';
    if (paused) return '已暂停';
    if (canceled) return '已取消';
    if (entry.relayConfirmationPending) return '需要确认中继';
    if (!pending) return '';
    if (entry.status == 'offered') return '待接收';
    if (entry.route == 'pending' || entry.status == 'accepted') return '连接中';
    if (entry.status == 'uploading') return '等待发送方';
    if (entry.status == 'ready') return '待接收';
    return entry.progress > 0
        ? '接收中 ${(entry.progress.clamp(0, 1) * 100).floor()}%'
        : '接收中';
  }

  String get primaryAction {
    if (failed) return 'retry';
    if (paused) return 'resume';
    if (entry.relayConfirmationPending) return 'approveRelay';
    if (pending && const {'offered', 'ready'}.contains(entry.status)) {
      return 'receive';
    }
    if (pending) return 'pause';
    return 'open';
  }

  String get primaryLabel => switch (primaryAction) {
    'retry' => '重试',
    'resume' => '继续',
    'approveRelay' => '中继',
    'receive' => '接收',
    'pause' => '暂停',
    _ => '打开',
  };
}

/// New receipts enter at the front; updates finish in the slot the user is
/// already looking at. History pages keep their separate receipt-time sort.
List<String> receiptDisplayOrder(
  List<String> previous,
  Iterable<DockEntry> entries,
) {
  final sorted = entries.toList()..sort(compareReceivedNewestFirst);
  final ids = sorted.map((entry) => entry.id).toSet();
  return [
    for (final entry in sorted)
      if (!previous.contains(entry.id)) entry.id,
    for (final id in previous)
      if (ids.contains(id)) id,
  ];
}
