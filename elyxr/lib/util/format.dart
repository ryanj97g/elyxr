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
