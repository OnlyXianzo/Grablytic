import 'dart:math';

/// Formats the given number of bytes into a human-readable string representation (e.g., KB, MB, GB).
String formatBytes(int bytes, [int decimals = 2]) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'];
  final i = (log(bytes) / log(1024)).floor();
  // Bound check for suffixes
  final suffixIndex = i < suffixes.length ? i : suffixes.length - 1;
  final size = bytes / pow(1024, suffixIndex);

  if (size == size.toInt()) {
    return '${size.toInt()} ${suffixes[suffixIndex]}';
  }

  var formatted = size.toStringAsFixed(decimals);
  if (formatted.contains('.')) {
    while (formatted.endsWith('0')) {
      formatted = formatted.substring(0, formatted.length - 1);
    }
    if (formatted.endsWith('.')) {
      formatted = formatted.substring(0, formatted.length - 1);
    }
  }
  return '$formatted ${suffixes[suffixIndex]}';
}
