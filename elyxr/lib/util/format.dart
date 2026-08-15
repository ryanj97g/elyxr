// Human numbers, in plain words. The trove speaks in bytes; people don't.

/// Compact size like the readouts on the glass: `284K`, `41.2M`, `1.4G`.
String fmtSize(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1e9).toStringAsFixed(1)}G';
  if (bytes >= 1000000) return '${(bytes / 1e6).round()}M';
  if (bytes >= 1000) return '${(bytes / 1e3).round()}K';
  return '${bytes}B';
}

/// GB with one decimal, for capacity readouts: `68.4`.
String fmtGb(int bytes) => (bytes / 1e9).toStringAsFixed(1);

/// A whole-file count phrased for a person: "1 file", "12 files".
String fmtCount(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

/// A track length as a clock reads it: `3:07`, and `1:04:22` once it runs past
/// an hour. A dash when the file never said how long it was, so the column stays
/// aligned instead of going blank.
String fmtDuration(int? seconds) {
  if (seconds == null || seconds <= 0) return '–';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
