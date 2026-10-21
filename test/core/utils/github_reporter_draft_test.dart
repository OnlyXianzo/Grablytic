import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/github_reporter.dart';

/// The crash handler calls [GithubReporter.draftCrash] and nothing else, so
/// this file is mostly about the promise that preparing a report cannot
/// reach the network, plus the prefilled-URL fallback that replaces a token
/// in a release build.
void main() {
  group('drafting', () {
    test('builds a titled, fingerprinted, unsubmitted draft', () async {
      final draft = await GithubReporter().draftCrash(
        StateError('download stalled'),
        StackTrace.fromString('#0 main (package:grablytic/main.dart:1:1)'),
      );

      expect(draft.fingerprint, hasLength(8));
      expect(draft.title, contains(draft.fingerprint));
      expect(draft.title, contains('StateError'));
      expect(draft.body, contains('### Summary'));
      expect(draft.body, contains('fingerprint:'));
    });

    test('survives a null stack', () async {
      final draft = await GithubReporter().draftCrash(StateError('x'), null);
      expect(draft.body, contains('### Stack trace'));
    });

    test('the same failure drafts the same fingerprint', () async {
      final reporter = GithubReporter();
      final a = await reporter.draftCrash(StateError('same'), null);
      final b = await reporter.draftCrash(StateError('same'), null);
      expect(a.fingerprint, b.fingerprint);
    });

    test('a draft is redacted before it is stored anywhere', () async {
      final draft = await GithubReporter().draftCrash(
        StateError('failed at https://x/y?token=supersecret\n'
            'Authorization: Bearer abcdefghijklmnop'),
        null,
      );

      expect(draft.body, isNot(contains('supersecret')));
      expect(draft.body, isNot(contains('abcdefghijklmnop')));
    });

    test('manual drafts carry the user words and a title', () async {
      final draft = await GithubReporter().draftManual(
        userSummary: 'The download stopped at 40%',
      );

      expect(draft.title, contains('The download stopped at 40%'));
      expect(draft.body, contains('The download stopped at 40%'));
    });
  });

  group('submission without a token', () {
    test('a stock build says manualNeeded instead of pretending', () async {
      final draft = await GithubReporter().draftCrash(StateError('x'), null);
      final result = await GithubReporter().submitDraft(draft);

      expect(GithubReporter().canPost, isFalse);
      expect(result.status, GithubReportStatus.manualNeeded);
      expect(result.url, isNull);
      expect(result.body, draft.body);
    });
  });

  group('reportCrash still works end to end', () {
    test('returns the same status submitDraft would', () async {
      final result = await GithubReporter()
          .reportCrash(StateError('whole pipeline'), StackTrace.empty);
      expect(result.status, GithubReportStatus.manualNeeded);
      expect(result.title, isNotEmpty);
    });
  });

  group('issueUrl', () {
    test('points at the project repo with the draft text', () async {
      final draft = await GithubReporter().draftCrash(StateError('boom'), null);
      final uri = GithubReporter().issueUrl(
        title: draft.title,
        body: draft.body,
        labels: const ['bug', 'crash'],
      );

      expect(uri.toString(),
          startsWith('https://github.com/OnlyXianzo/Grablytic/issues/new?'));
      expect(uri.queryParameters['title'], draft.title);
      expect(uri.queryParameters['labels'], 'bug,crash');
      expect(uri.queryParameters['body'], contains('### Summary'));
    });

    test('a custom repo is honoured', () {
      final uri = GithubReporter(owner: 'me', repo: 'fork')
          .issueUrl(title: 't', body: 'b');
      expect(uri.toString(), contains('github.com/me/fork/issues/new'));
    });

    test('an over-long body is left out, the page still opens', () {
      final uri = GithubReporter().issueUrl(title: 'big', body: 'x' * 20000);

      expect(uri.toString().length, lessThanOrEqualTo(7500));
      expect(uri.queryParameters.containsKey('body'), isFalse);
      expect(uri.queryParameters['title'], 'big');
    });

    test('a body full of secrets is redacted inside the URL', () {
      final uri = GithubReporter().issueUrl(
        title: 'x',
        body: 'Authorization: Bearer abcdefghijklmnop',
      );
      expect(uri.toString(), isNot(contains('abcdefghijklmnop')));
    });
  });
}
