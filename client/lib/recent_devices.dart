/// Session-only discovery grace. Offline records never become online probes.
class RecentDevices {
  static const grace = Duration(seconds: 30);
  final Map<String, int> deadlines = {};

  bool available(Map<String, dynamic> device, int now) =>
      device['revoked'] != true &&
      (device['online'] == true || (deadlines[device['deviceId']] ?? 0) > now);

  List<Map<String, dynamic>> merge(
    List<Map<String, dynamic>> previous,
    List<Map<String, dynamic>> snapshot,
    int now,
  ) {
    final old = {for (final device in previous) device['deviceId']: device};
    final incoming = {
      for (final device in snapshot) device['deviceId']: device,
    };
    final result = <Map<String, dynamic>>[];
    for (final id in {...incoming.keys, ...old.keys}) {
      final next = incoming[id], before = old[id];
      if (next?['revoked'] == true) {
        deadlines.remove(id);
        continue;
      }
      if (next?['online'] == true) {
        deadlines.remove(id);
        result.add(Map<String, dynamic>.from(next!));
        continue;
      }
      if (before?['online'] == true) {
        deadlines.putIfAbsent(id as String, () => now + grace.inMilliseconds);
      }
      if ((deadlines[id] ?? 0) > now && before != null) {
        result.add({
          ...before,
          ...?next,
          'online': false,
          'peer': next?['peer'] ?? before['peer'],
          'rtc': next?['rtc'] ?? before['rtc'],
        });
      } else {
        deadlines.remove(id);
        if (next != null) result.add({...next, 'peer': null, 'rtc': null});
      }
    }
    return result;
  }

  void clear() => deadlines.clear();
}
