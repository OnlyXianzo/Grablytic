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

/// Checks whether [input] resembles a URL (scheme + host or standard web domain format).
/// Used by input bars to differentiate direct media URLs from plain-text search queries.
bool looksLikeUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains(' ')) return false;

  final uri = Uri.tryParse(trimmed);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) {
    return true;
  }

  // Support domain-like patterns without scheme (e.g. youtube.com/watch?v=..., youtu.be/abc)
  if (RegExp(r'^(www\.)?[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(/.*)?$').hasMatch(trimmed)) {
    return true;
  }

  return false;
}

