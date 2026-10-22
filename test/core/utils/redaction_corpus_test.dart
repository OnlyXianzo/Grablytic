import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/github_reporter.dart';

/// SEC-001: the Dart half of the redaction contract.
///
/// The cases come from `test/fixtures/redaction_corpus.json`, which
/// `engine/tests/test_report_redaction.py` runs as well. Both scrubbers feed
/// one sink — a public GitHub issue — and they drifted once already, so the
/// invariant is written down once and asserted from both languages.
void main() {
  final corpus =
      jsonDecode(File('test/fixtures/redaction_corpus.json').readAsStringSync())
          as Map<String, dynamic>;
  final cases = (corpus['cases'] as List).cast<Map<String, dynamic>>();

  group('shared redaction corpus', () {
    test('the corpus is not empty', () {
      expect(cases.length, greaterThanOrEqualTo(10));
    });

    for (final testCase in cases) {
      test(testCase['name'] as String, () {
        final out = GithubReporter.sanitizeForReport(testCase['input'] as String);
        for (final secret in (testCase['must_not_contain'] as List).cast<String>()) {
          expect(out, isNot(contains(secret)), reason: 'leaked "$secret" in: $out');
        }
        for (final keep in ((testCase['must_contain'] as List?) ?? []).cast<String>()) {
          expect(out, contains(keep), reason: 'lost "$keep" in: $out');
        }
      });
    }
  });

  group('cookie shapes that a Python traceback formats', () {
    const secret = 'SUPERSECRETVALUE';

    test('cookiejar repr keeps the fields and loses the value', () {
      final out = GithubReporter.sanitizeForReport(
        "Cookie(version=0, name='SID', value='$secret', domain='.youtube.com')",
      );
      expect(out, isNot(contains(secret)));
      expect(out, contains("name='SID'"));
      expect(out, contains("value='***REDACTED***'"));
    });

    test('cookiejar str form', () {
      final out =
          GithubReporter.sanitizeForReport('<Cookie SID=$secret for .youtube.com/>');
      expect(out, isNot(contains(secret)));
      expect(out, contains('for .youtube.com'));
    });

    test('netscape row', () {
      final out = GithubReporter.sanitizeForReport(
        '.youtube.com\tTRUE\t/\tTRUE\t0\tSID\t$secret',
      );
      expect(out, isNot(contains(secret)));
      expect(out, contains('SID'));
    });

    test('a value= outside a cookie object is left alone', () {
      const text = "config value='keep-me' was rejected";
      expect(GithubReporter.sanitizeForReport(text), text);
    });
  });

  group('local paths in every spelling', () {
    for (final path in [
      r"open('C:\Users\bob\Videos\x.mp4') failed",
      r"open('C:\\Users\\bob\\Videos\\x.mp4') failed",
      "open('C:/Users/bob/Videos/x.mp4') failed",
    ]) {
      test(path, () {
        final out = GithubReporter.sanitizeForReport(path);
        expect(out, isNot(contains('bob')));
        expect(out, isNot(contains('Users')));
        expect(out, contains('failed'));
      });
    }
  });
}
