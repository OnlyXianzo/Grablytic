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
}
