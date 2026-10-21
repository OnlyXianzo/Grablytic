import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/crash_reports.dart';
import 'package:grablytic/core/utils/github_reporter.dart';
import 'package:grablytic/core/utils/pending_report.dart';

import '../../support/memory_report_store.dart';

/// A reporter that cannot reach the network by construction.
class _FakeGithubReporter extends GithubReporter {
  _FakeGithubReporter({this.postable = false, this.createdUrl});

  final bool postable;
  final String? createdUrl;

  int createCalls = 0;
  int searchCalls = 0;

  @override
  bool get canPost => postable;

  @override
  Future<String?> findDuplicate(String fp) async {
    searchCalls++;
    return null;
  }

  @override
  Future<String?> createIssue({
    required String title,
    required String body,
    List<String> labels = const ['bug', 'auto-report'],
  }) async {
    createCalls++;
    return createdUrl;
  }

  @override
  Future<GithubReportDraft> draftCrash(
    Object error,
    StackTrace? stack, {
    Map<String, dynamic> context = const {},
    String? appVersion,
  }) async =>
      GithubReportDraft(
        fingerprint: 'fp-${error.runtimeType}',
        title: '[Auto-report] ${error.runtimeType}',
        body: '### Summary\nAutomated crash report (unhandled exception).\n'
            '<!-- fingerprint: fp-${error.runtimeType} -->',
      );
}

void main() {
  late MemoryReportStore store;

  setUp(() => store = MemoryReportStore());

  CrashReports build({
    GithubReporter? github,
    Future<bool> Function()? autoSend,
    DateTime Function()? clock,
  }) {
    return CrashReports(
      store: store,
      reporterFactory: () => github ?? _FakeGithubReporter(),
      autoSendLoader: autoSend,
      clock: clock,
    );
  }

  group('capture', () {
    test('saves a crash even with automatic reporting off', () async {
      final reports = build(autoSend: () async => false);
      final report = await reports.capture(StateError('boom'), null);

      expect(report, isNotNull);
      expect(report!.isCrash, isTrue);
      expect(report.category, ReportCategory.crash);
      expect(await store.list(), hasLength(1),
          reason: 'this is the regression: an opted-out install lost the '
              'crash entirely, so the next launch had nothing to offer');
    });

    test('capture never contacts GitHub', () async {
      final github = _FakeGithubReporter(postable: true, createdUrl: 'u');
      await build(github: github).capture(StateError('x'), null);

      expect(github.createCalls, 0);
      expect(github.searchCalls, 0,
          reason: 'the fatal path must not wait for a network round trip');
    });

    test('the same crash twice is one report with a count', () async {
      final reports = build();
      await reports.capture(StateError('same'), null);
      final second = await reports.capture(StateError('same'), null);

      expect(await store.list(), hasLength(1));
      expect(second!.occurrences, 2);
    });

    test('a different error is a second report', () async {
      final reports = build();
      await reports.capture(StateError('one'), null);
      await reports.capture(ArgumentError('two'), null);
      expect(await store.list(), hasLength(2));
    });

    test('an unexpected engine exit is captured as a crash', () async {
      final report = await build().capture(EngineExitError(137), null);

      expect(report!.summary, contains('137'));
      expect(report.isCrash, isTrue);
    });

    test('the stored summary is redacted, not just the body', () async {
      final report = await build().capture(
        StateError('failed at https://host/private?token=supersecret\n'
            'Authorization: Bearer abcdefghijklmnop'),
        null,
      );

      expect(report!.summary, isNot(contains('supersecret')));
      expect(report.summary, isNot(contains('abcdefghijklmnop')));
      expect(report.summary, isNot(contains('host/private')));
      expect(report.summary, isNotEmpty);
    });

    test('no store means capture is a no-op, not a throw', () async {
      final reports = CrashReports(store: null);
      expect(await reports.capture(StateError('x'), null), isNull);
      expect(reports.available, isFalse);
    });
  });

  group('recovery prompt rules', () {
    test('a crash from an earlier session is offered', () async {
      final crashTime = DateTime.now();
      await build(clock: () => crashTime).capture(StateError('old'), null);

      // A new process: the session clock is later than the report.
      final next = build(clock: () => crashTime.add(const Duration(minutes: 5)));
      expect(await next.promptCandidate(), isNotNull);
    });

    test('a crash from this session is not offered', () async {
      final crashTime = DateTime.now();
      final reports = build(clock: () => crashTime);
      await reports.capture(StateError('fresh'), null);

      // Same clock, same process: this is not a recovery.
      expect(await reports.promptCandidate(), isNull);
    });

    test('manual reports are never offered as crashes', () async {
      final crashTime = DateTime.now();
      await store.add(PendingReport(
        id: 'manual',
        fingerprint: 'fp',
        category: ReportCategory.other,
        title: 't',
        summary: 's',
        body: 'b',
        createdAt: crashTime.subtract(const Duration(days: 1)),
        source: 'manual',
      ));

      expect(await build(clock: () => crashTime).promptCandidate(), isNull);
    });

    test('the offer respects its cooldown', () async {
      var now = DateTime.now();
      final reports = build(clock: () => now);
      final report = (await reports.capture(StateError('x'), null))!;

      now = now.add(const Duration(days: 1));
      final next = build(clock: () => now);
      expect(await next.promptCandidate(), isNotNull);

      await next.markPrompted(report.id);
      expect(await next.promptCandidate(), isNull,
          reason: 'asked recently — do not ask again yet');

      now = now.add(PendingReportStore.promptCooldown + const Duration(hours: 1));
      expect(await next.promptCandidate(), isNotNull);
    });
  });

  group('opt-in submission', () {
    test('off by default', () async {
      expect(await build().autoSendEnabled(), isFalse);
    });

    test('an opted-out queue is never sent', () async {
      final github = _FakeGithubReporter(postable: true, createdUrl: 'u');
      final reports = build(github: github, autoSend: () async => false);
      await reports.capture(StateError('x'), null);

      await reports.submitQueuedIfOptedIn();

      expect(github.createCalls, 0);
      expect(await store.list(), hasLength(1));
    });

    test('opted in but no token: nothing is attempted', () async {
      final github = _FakeGithubReporter(postable: false);
      final reports = build(github: github, autoSend: () async => true);
      await reports.capture(StateError('x'), null);

      await reports.submitQueuedIfOptedIn();

      expect(github.createCalls, 0);
      expect(github.searchCalls, 0);
      expect(await store.list(), hasLength(1),
          reason: 'the user can still send it from the form');
    });

    test('opted in with a token: the queue is filed and cleared', () async {
      final github = _FakeGithubReporter(
        postable: true,
        createdUrl: 'https://github.com/o/r/issues/9',
      );
      final reports = build(github: github, autoSend: () async => true);
      await reports.capture(StateError('x'), null);

      await reports.submitQueuedIfOptedIn();

      expect(github.createCalls, 1);
      expect(await store.list(), isEmpty);
    });

    test('a failure stops the loop instead of burning the queue', () async {
      final github = _FakeGithubReporter(postable: true); // createIssue → null
      final reports = build(github: github, autoSend: () async => true);
      await reports.capture(StateError('one'), null);
      await reports.capture(ArgumentError('two'), null);

      await reports.submitQueuedIfOptedIn();

      expect(github.createCalls, 1, reason: 'one attempt, then stop');
      expect(await store.list(), hasLength(2), reason: 'nothing is discarded');
      expect((await store.list()).map((r) => r.attempts).reduce((a, b) => a + b),
          1);
    });
  });

  group('queue management', () {
    test('pending, byId and dismiss work off the same queue', () async {
      final reports = build();
      final report = (await reports.capture(StateError('x'), null))!;

      expect(await reports.pending(), hasLength(1));
      expect(await reports.byId(report.id), isNotNull);

      await reports.dismiss(report.id);
      expect(await reports.pending(), isEmpty);
    });
  });
}
