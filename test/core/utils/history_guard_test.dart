import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/database/download_history_db.dart';
import 'package:grablytic/core/utils/history_guard.dart';

DownloadRecord _r(String url, {String status = 'completed', String format = 'mkv'}) =>
    DownloadRecord(id: url.hashCode.toString(), url: url, title: 't', status: status, format: format);

void main() {
  group('extractVideoId', () {
    test('parses watch, short, shorts, embed, live forms', () {
      expect(extractVideoId('https://www.youtube.com/watch?v=ABC123_-xY'), 'ABC123_-xY');
      expect(extractVideoId('https://youtu.be/ABC123_-xY'), 'ABC123_-xY');
      expect(extractVideoId('https://www.youtube.com/shorts/ABC123_-xY'), 'ABC123_-xY');
      expect(extractVideoId('https://www.youtube.com/embed/ABC123_-xY'), 'ABC123_-xY');
      expect(extractVideoId('https://www.youtube.com/live/ABC123_-xY'), 'ABC123_-xY');
    });

    test('non-youtube and garbage yield null', () {
      expect(extractVideoId('https://example.com/video/1'), isNull);
      expect(extractVideoId('not a url at all'), isNull);
      expect(extractVideoId('https://www.youtube.com/results?search_query=x'), isNull);
    });
  });

  group('isSameVideo', () {
    test('exact and trailing-slash URLs match', () {
      expect(isSameVideo('https://x.test/v', 'https://x.test/v'), isTrue);
      expect(isSameVideo('https://x.test/v/', 'https://x.test/v'), isTrue);
      expect(isSameVideo('https://x.test/a', 'https://x.test/b'), isFalse);
    });

    test('same youtube id across forms matches (audio-vs-video case)', () {
      expect(
        isSameVideo('https://www.youtube.com/watch?v=ABC123_-xY', 'https://youtu.be/ABC123_-xY'),
        isTrue,
      );
      expect(
        isSameVideo('https://www.youtube.com/watch?v=AAA', 'https://www.youtube.com/watch?v=BBB'),
        isFalse,
      );
    });
  });

  group('findDuplicate', () {
    test('finds completed dup, ignores pending', () {
      final records = [
        _r('https://youtu.be/ABC123_-xY', status: 'pending'),
        _r('https://www.youtube.com/watch?v=ABC123_-xY', format: 'opus'),
      ];
      final dup = findDuplicate(records, 'https://www.youtube.com/watch?v=ABC123_-xY&t=10s');
      expect(dup, isNotNull);
      expect(dup!.format, 'opus');
    });

    test('returns null when no completed match', () {
      expect(findDuplicate([_r('https://x.test/a', status: 'pending')], 'https://x.test/a'), isNull);
      expect(findDuplicate([], 'https://x.test/a'), isNull);
    });
  });
}
