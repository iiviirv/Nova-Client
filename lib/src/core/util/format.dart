/// Small formatting helpers shared across screens.
class Fmt {
  const Fmt._();

  /// Human-readable byte count (e.g. `1.4 MB`).
  static String bytes(num value) {
    if (value <= 0) return '0 B';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    double v = value.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    final String n = v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '$n ${units[i]}';
  }

  /// Human-readable throughput (e.g. `1.4 MB/s`).
  static String bps(num bytesPerSec) => '${bytes(bytesPerSec)}/s';

  /// `m:ss` clock for elapsed/remaining seconds.
  static String clock(int seconds) {
    if (seconds < 0) seconds = 0;
    final int m = seconds ~/ 60;
    final int s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
