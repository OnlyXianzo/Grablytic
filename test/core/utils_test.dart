import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/utils.dart';

void main() {
  group('formatBytes', () {
    test('handles zero and negative values', () {
      expect(formatBytes(0), equals('0 B'));
      expect(formatBytes(-100), equals('0 B'));
    });

    test('formats bytes without suffixes', () {
      expect(formatBytes(500), equals('500 B'));
    });

    test('formats KB', () {
      expect(formatBytes(1024), equals('1 KB'));
      expect(formatBytes(1536), equals('1.5 KB'));
    });

    test('formats MB', () {
      expect(formatBytes(1024 * 1024), equals('1 MB'));
      expect(formatBytes((1024 * 1024 * 1.25).toInt()), equals('1.25 MB'));
    });

    test('formats GB', () {
      expect(formatBytes(1024 * 1024 * 1024), equals('1 GB'));
    });

    test('respects custom decimal places', () {
      expect(formatBytes((1024 * 1.3333).toInt(), 1), equals('1.3 KB'));
      expect(formatBytes((1024 * 1.3333).toInt(), 3), equals('1.333 KB'));
    });
  });

  group('looksLikeUrl', () {
    test('recognizes standard http and https URLs', () {
      expect(looksLikeUrl('https://youtube.com/watch?v=dQw4w9WgXcQ'), isTrue);
      expect(looksLikeUrl('http://example.com/audio.mp3'), isTrue);
      expect(looksLikeUrl('https://soundcloud.com/artist/track'), isTrue);
    });

    test('recognizes domain without scheme', () {
      expect(looksLikeUrl('www.youtube.com/watch?v=dQw4w9WgXcQ'), isTrue);
      expect(looksLikeUrl('youtu.be/dQw4w9WgXcQ'), isTrue);
      expect(looksLikeUrl('youtube.com/watch?v=dQw4w9WgXcQ'), isTrue);
      expect(looksLikeUrl('m.youtube.com/video'), isTrue);
    });

    test('rejects search queries and plain text', () {
      expect(looksLikeUrl('rick astley never gonna give you up'), isFalse);
      expect(looksLikeUrl('lofi hip hop beats to relax'), isFalse);
      expect(looksLikeUrl('classical piano cover'), isFalse);
      expect(looksLikeUrl('beethoven'), isFalse);
      expect(looksLikeUrl('   '), isFalse);
      expect(looksLikeUrl(''), isFalse);
    });
  });
}

