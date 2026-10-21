import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/github_reporter.dart';

void main() {
  group('GithubReporter.sanitizeForReport', () {
    test('removes URLs, local paths and header credentials', () {
      final value = GithubReporter.sanitizeForReport(
        'failed at https://example.test/private?token=supersecret\n'
        'Authorization: Bearer private-token-value\n'
        'file=/home/alice/Private/video.mp4',
      );
      expect(value, isNot(contains('example.test')));
      expect(value, isNot(contains('supersecret')));
      expect(value, isNot(contains('private-token-value')));
      expect(value, isNot(contains('/home/alice')));
      expect(value, contains('[URL removed]'));
      expect(value, contains('[local path removed]'));
      expect(value, contains('***REDACTED***'));
    });

    test('bounds diagnostics to the requested tail size', () {
      final value = GithubReporter.sanitizeForReport('a' * 100, maxLength: 20);
      expect(value.length, lessThanOrEqualTo(50));
      expect(value, contains('earlier content omitted'));
    });

    test('does not return original text when sanitization fails', () {
      // The public helper accepts only strings, so exercise its fail-closed
      // bound behavior with a deliberately tiny/negative requested limit.
      final value = GithubReporter.sanitizeForReport('sensitive', maxLength: -1);
      expect(value, isNot(contains('sensitive')));
    });
  });
}
