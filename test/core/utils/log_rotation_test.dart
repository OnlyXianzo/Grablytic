import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/log_rotation.dart';

void main() {
  group('LogRotation (T11 1 MB chunked rotation)', () {
    test('chunk cap is exactly 1 MB', () {
      expect(LogRotation.chunkMaxBytes, 1 * 1024 * 1024);
    });

    test('every chunk opens with the spec header', () {
      final h = LogRotation.header(DateTime(2026, 10, 2, 3, 4, 5));
      expect(h.startsWith('grablytic logs - '), true);
      expect(h, contains('2026-10-02'));
      expect(h.endsWith('\n'), true);
    });

    test('rotates only when the incoming batch would exceed the cap', () {
      expect(LogRotation.shouldRotate(0, 10), false);
      expect(
        LogRotation.shouldRotate(LogRotation.chunkMaxBytes - 10, 11),
        true,
      );
      expect(LogRotation.shouldRotate(LogRotation.chunkMaxBytes, 1), true);
    });

    test('sealed names are filename-safe and recognized', () {
      final name = LogRotation.sealedName(DateTime(2026, 10, 2, 3, 4, 5));
      expect(name.contains(':'), false);
      expect(name.endsWith('.txt'), true);
      expect(LogRotation.isSealedChunk(name), true);
      expect(LogRotation.isSealedChunk('app_logs.txt'), false);
      expect(LogRotation.isSealedChunk('log_2026-10-02.txt'), false);
    });
  });
}
