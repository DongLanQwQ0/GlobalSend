/// Local sending frequency keyed by device identity, never device name/group.
class DeviceUsage {
  final operations = <String, Set<String>>{};
  void restore(Map<String, dynamic> data) {
    operations.clear();
    for (final entry in data.entries) {
      operations[entry.key] = Set<String>.from(entry.value as List);
    }
  }

  Map<String, dynamic> toJson() => {
    for (final entry in operations.entries) entry.key: entry.value.toList(),
  };
  bool record(String device, String operation) =>
      operations.putIfAbsent(device, () => <String>{}).add(operation);
  List<Map<String, dynamic>> rank(Iterable<Map<String, dynamic>> peers) {
    final unique = {for (final peer in peers) peer['deviceId'] as String: peer};
    final order = unique.keys.toList();
    final indexes = {for (var i = 0; i < order.length; i++) order[i]: i};
    order.sort((a, b) {
      final count = (operations[b]?.length ?? 0).compareTo(
        operations[a]?.length ?? 0,
      );
      return count != 0 ? count : indexes[a]!.compareTo(indexes[b]!);
    });
    return [for (final id in order) unique[id]!];
  }
}
