/// Size-capped chunked log rotation (T11).
///
/// Pure, synchronously testable policy: 1 MB per chunk, each sealed chunk
/// opens with a `grablytic logs - <Date & Time>` header. File IO stays in
/// [AppLogger] on its serialized [_flushChain] (never UI-blocking); this
/// file only decides names, headers, and rotation boundaries.
class LogRotation {
  /// Max bytes per active chunk before sealing (1 MB).
  static const int chunkMaxBytes = 1 * 1024 * 1024;

  /// Active chunk file name.
  static const String activeName = 'app_logs.txt';

  /// Sealed chunk prefix: `app_logs-YYYY-MM-DD-HH-mm-ss.txt`.
  static String sealedName([DateTime? at]) {
    final now = at ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    String four(int n) => n.toString().padLeft(4, '0');
    return 'app_logs-${four(now.year)}-${two(now.month)}-${two(now.day)}-'
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}.txt';
  }

  /// First line of every fresh chunk (T11 spec).
  static String header([DateTime? at]) {
    final now = at ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    String four(int n) => n.toString().padLeft(4, '0');
    return 'grablytic logs - ${four(now.year)}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}\n';
  }

  /// Safety valve (T12): a single session never holds rotation past this.
  static const int forceRotateBytes = 4 * 1024 * 1024;

  /// First line of a chunk that continues an in-flight session (T12).
  static String continuedHeader([DateTime? at]) {
    final now = at ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    String four(int n) => n.toString().padLeft(4, '0');
    return 'grablytic logs - ${four(now.year)}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)} (continued)\n';
  }

  /// True when appending [incomingBytes] to a file of [currentBytes] would
  /// exceed the chunk cap.
  static bool shouldRotate(int currentBytes, int incomingBytes) =>
      currentBytes + incomingBytes > chunkMaxBytes;

  /// T12: defer sealing while any video session is active, unless the chunk
  /// already hit the 4 MB force valve.
  static bool shouldDefer(
    int currentBytes,
    int incomingBytes, {
    required bool hasActiveSessions,
  }) =>
      hasActiveSessions &&
      shouldRotate(currentBytes, incomingBytes) &&
      currentBytes < forceRotateBytes;

  /// True for sealed-chunk names produced by [sealedName].
  static bool isSealedChunk(String fileName) {
    if (!fileName.startsWith('app_logs-') || !fileName.endsWith('.txt')) {
      return false;
    }
    return RegExp(
      r'^app_logs-\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}\.txt$',
    ).hasMatch(fileName);
  }
}
