String compactTime(DateTime date, {DateTime? now}) {
  final local = date.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final midnight = DateTime(today.year, today.month, today.day);
  final yesterday = DateTime(midnight.year, midnight.month, midnight.day - 1);
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (!local.isBefore(yesterday)) return time;
  return '${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')} $time';
}
