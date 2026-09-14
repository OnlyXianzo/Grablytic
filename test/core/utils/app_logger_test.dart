import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/app_logger.dart';
import 'package:grablytic/core/utils/log_buffer.dart';

void main() {
  group('AppLogger redaction (SEC-02)', () {
    late LogBuffer buffer;

    setUp(() {
      buffer = LogBuffer();
      AppLogger.initBuffer(buffer);
    });

    test('masks sig query param in buffer entries', () {
      AppLogger.info(
          'User submitted URL: https://m.youtube.com/watch?v=abc&sig=SECRET123&x=1');
      final line = buffer.entries.last.message;
      expect(line, isNot(contains('SECRET123')));
      expect(line, contains('***REDACTED***'));
      expect(line, contains('v=abc'));
    });

    test('masks lsig and signature params', () {
      AppLogger.info('GET https://x.test/v?lsig=HUNTER2');
      AppLogger.info('auth signature=TOPSECRET ok');
      expect(buffer.entries[buffer.entries.length - 2].message,
          isNot(contains('HUNTER2')));
      expect(buffer.entries.last.message, isNot(contains('TOPSECRET')));
    });

    test('still masks tokens, cookies and passwords', () {
      AppLogger.info('token=ABCDEF cookie=CHOCCHIP password=hunter3');
      final line = buffer.entries.last.message;
      expect(line, isNot(contains('ABCDEF')));
      expect(line, isNot(contains('CHOCCHIP')));
      expect(line, isNot(contains('hunter3')));
    });

    test('leaves benign text untouched', () {
      const msg = 'Download finished: 123e4567 (12 MB)';
      AppLogger.info(msg);
      expect(buffer.entries.last.message, msg);
    });
  });
}
