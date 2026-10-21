import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/github_reporter.dart';

/// The prefilled URL is the submission path on a release build, so it has
/// to point at the right repository and carry redacted text. Nothing here
/// makes a network call.
void main() {
  group('issueUrl', () {
    test('targets the project repo with title, body and labels', () {
      final uri = GithubReporter().issueUrl(
        title: '[Crash] StateError: boom',
        body: '### What happened\nboom',
        labels: const ['bug', 'crash'],
      );
      final text = uri.toString();

      expect(text, startsWith('https://github.com/OnlyXianzo/Grablytic/issues/new?'));
      expect(uri.queryParameters['title'], '[Crash] StateError: boom');
      expect(uri.queryParameters['body'], contains('### What happened'));
      expect(uri.queryParameters['labels'], 'bug,crash');
    });

    test('a custom repo is honoured', () {
      final uri = GithubReporter(owner: 'me', repo: 'fork')
          .issueUrl(title: 't', body: 'b');
      expect(uri.toString(), contains('github.com/me/fork/issues/new'));
    });

    test('secrets are redacted before they reach the URL', () {
      final uri = GithubReporter().issueUrl(
        title: 'failed',
        body: 'Authorization: Bearer abcdefghijklmnop\nhttps://x/y?token=leak',
      );
      final text = uri.toString();

      expect(text, isNot(contains('abcdefghijklmnop')));
      expect(text, isNot(contains('leak')));
    });

    test('an over-long body is dropped rather than truncated mid-word', () {
      final uri = GithubReporter().issueUrl(
        title: 'big log',
        body: 'x' * 20000,
        labels: const ['bug'],
      );
      final text = uri.toString();

      expect(text.length, lessThanOrEqualTo(7500));
      expect(uri.queryParameters.containsKey('body'), isFalse);
      expect(uri.queryParameters['title'], 'big log');
      expect(uri.queryParameters['labels'], 'bug');
    });

    test('an empty body is fine (the log viewer only prefills a link)', () {
      final uri = GithubReporter().issueUrl(title: 'Bug report', body: '');
      expect(uri.toString(), contains('issues/new'));
    });
  });

  group('canPost', () {
    test('a stock build has no token, so it cannot post', () {
      // The environment in a test run has no --dart-define token.
      expect(GithubReporter().canPost, isFalse);
    });

    test('an explicitly supplied token allows posting', () {
      expect(GithubReporter(token: 'test-token-not-real').canPost, isTrue);
    });

    test('an empty token is treated as absent', () {
      expect(GithubReporter(token: '').canPost, isFalse);
    });
  });

  group('reportFingerprint', () {
    test('is stable for the same input', () {
      expect(
        reportFingerprint('StateError', '#0 main'),
        reportFingerprint('StateError', '#0 main'),
      );
    });

    test('differs when the frame differs', () {
      expect(
        reportFingerprint('StateError', '#0 main'),
        isNot(reportFingerprint('StateError', '#1 other')),
      );
    });

    test('differs when only the type differs', () {
      expect(
        reportFingerprint('StateError', '#0 main'),
        isNot(reportFingerprint('ArgumentError', '#0 main')),
      );
    });

    test('accepts a missing frame', () {
      expect(reportFingerprint('StateError'), hasLength(8));
    });

    test('the instance method matches the top-level function', () {
      final reporter = GithubReporter();
      expect(
        reporter.fingerprint('label', '#0 frame'),
        reportFingerprint('label', '#0 frame'),
      );
    });

    test('is short lowercase hex', () {
      expect(reportFingerprint('a', 'b'), matches(RegExp(r'^[0-9a-f]{8}$')));
    });
  });
}
