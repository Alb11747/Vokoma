/// `1:02:03` or `2:03`.
String formatDuration(Duration d) {
  final negative = d.isNegative;
  final total = d.abs().inSeconds;
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  final text = '${h > 0 ? '$h:' : ''}$mm:${s.toString().padLeft(2, '0')}';
  return negative ? '-$text' : text;
}

/// `1.4 GB`, `350 MB`, `12 KB`.
String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}
