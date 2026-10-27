import 'models.dart';

/// A transfer reserves a position while receiving; completion replaces that
/// placeholder with its actual receipt time. Refreshes do not invent a time.
int receivedOrderTime(DockEntry entry) =>
    entry.receivedAtMillis > 0 ? entry.receivedAtMillis : entry.createdAtMillis;

int compareReceivedNewestFirst(DockEntry a, DockEntry b) {
  final time = receivedOrderTime(b).compareTo(receivedOrderTime(a));
  return time != 0 ? time : a.id.compareTo(b.id);
}
