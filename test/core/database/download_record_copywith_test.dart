import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/database/download_history_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DownloadRecord.copyWith can clear a nullable field', () {
    final base = DownloadRecord(
      id: 'a',
      url: 'https://example.com/v',
      title: 'Video',
      filePath: '/tmp/video.mp4',
      lastErrorType: 'ERROR_DOWNLOAD',
      lastErrorMessage: 'boom',
      thumbnailPath: '/tmp/thumb.jpg',
      queuePosition: 3,
      totalBytes: 100,
    );

    test('omitted parameters keep the current value', () {
      final next = base.copyWith(status: 'completed');
      expect(next.filePath, '/tmp/video.mp4');
      expect(next.lastErrorType, 'ERROR_DOWNLOAD');
      expect(next.queuePosition, 3);
    });

    test('an explicit null clears the field', () {
      final next = base.copyWith(
        status: 'completed',
        lastErrorType: null,
        lastErrorMessage: null,
        filePath: null,
        thumbnailPath: null,
        queuePosition: null,
        totalBytes: null,
      );
      expect(next.lastErrorType, isNull);
      expect(next.lastErrorMessage, isNull);
      expect(next.filePath, isNull);
      expect(next.thumbnailPath, isNull);
      expect(next.queuePosition, isNull);
      expect(next.totalBytes, isNull);
      expect(next.status, 'completed');
    });
  });

  group('timestamps are stored as UTC', () {
    test('the default timestamp carries a UTC marker', () {
      final record = DownloadRecord(
        id: 'b',
        url: 'https://example.com/v',
        title: 'Video',
      );
      expect(record.timestamp.endsWith('Z'), isTrue);
      expect(DateTime.parse(record.timestamp).isUtc, isTrue);
    });

    test('utcNowIso is UTC', () {
      expect(utcNowIso().endsWith('Z'), isTrue);
      expect(DateTime.parse(utcNowIso()).isUtc, isTrue);
    });
  });
}
