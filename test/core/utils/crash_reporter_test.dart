import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/crash_reporter.dart';
import 'package:grablytic/core/utils/github_reporter.dart';
import 'package:grablytic/core/utils/pending_report.dart';

/// A reporter that never touches the network.
class _FakeGithubReporter extends GithubReporter {
  _FakeGithubReporter({
    this.postable = false,
    this.createdUrl,
    this.duplicateUrl,
    this.throwOnCreate = false,
  });

  final bool postable;
  final String? createdUrl;
  final String? duplicateUrl;
  final bool throwOnCreate;

  int createCalls = 0;
  int searchCalls = 0;
  String? lastTitle;
  String? lastBody;

  @override
  bool get canPost => postable;

  @override
  Future<String?> findDuplicate(String fp) async {
    searchCalls++;
    return duplicateUrl;
  }

  @override
  Future<String?> createIssue({
    required String title,
    required String body,
    List<String> labels = const ['bug', 'auto-report'],
  }) async {
    createCalls++;
    lastTitle = title;
    lastBody = body;
    if (throwOnCreate) throw StateError('boom');
    return createdUrl;
  }
}

void main() {
  late Directory dir;
  late PendingReportStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grablytic_crash');
    store = PendingReportStore(dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
    CrashReporter.instance = null;
  });

  CrashReporter build({
    GithubReporter? github,
    Future<bool> Function()? autoReport,
    DateTime Function()? clock,
  }) {
    return CrashReporter(
      store: store,
      reporterFactory: () => github ?? _FakeGithubReporter(),
      clock: clock,
      prefsLoader:
          autoReport == null ? null : CrashReporter.viewFromPrefs(autoReport),
    );
  }

  group('capture', () {
    test('records a crash with a fingerprint and a redacted body', () async {
      final reporter = build();
      final error = StateError('download failed token=supersecret');
      final report = await reporter.recordCrash(
        error,
        StackTrace.fromString('#0      main (package:grablytic/main.dart:1:1)'),
      );

      expect(report, isNotNull);
      expect(report!.fingerprint, isNotEmpty);
      expect(report.isCrash, isTrue);
      expect(report.category, ReportCategory.crash);
      expect(report.body, isNot(contains('supersecret')));
      expect(report.body, contains('fingerprint:'));
      expect(report.errorType, 'StateError');
      expect(await store.list(), hasLength(1));
    });

    test('the same crash twice is one report with a count', () async {
      final reporter = build();
      final error = StateError('same');
      final stack = StackTrace.fromString('#0      a (package:x/y.dart:1:1)');

      await reporter.recordCrash(error, stack);
      final second = await reporter.recordCrash(error, stack);

      expect(await store.list(), hasLength(1));
      expect(second!.occurrences, 2);
    });

    test('a different crash is a second report', () async {
      final reporter = build();
      await reporter.recordCrash(StateError('one'), null);
      await reporter.recordCrash(ArgumentError('two'), null);

      expect(await store.list(), hasLength(2));
    });

    test('never throws when the store is missing', () async {
      final reporter = CrashReporter(store: null);
      expect(await reporter.recordCrash(StateError('x'), null), isNull);
      expect(reporter.available, isFalse);
    });

    test('capturing never contacts GitHub', () async {
      final github = _FakeGithubReporter(postable: true, createdUrl: 'u');
      final reporter = build(github: github);

      await reporter.recordCrash(StateError('x'), null);

      expect(github.createCalls, 0);
      expect(github.searchCalls, 0,
          reason: 'the fatal path must not wait for a network round trip');
    });

    test('an unexpected engine exit is recorded with its exit code', () async {
      final reporter = build();
      final report = await reporter.recordCrash(EngineExitError(137), null);

      expect(report!.errorType, 'EngineExitError');
      expect(report.summary, contains('137'));
      expect(report.isCrash, isTrue);
    });

    test('a stack-less crash still records', () async {
      final reporter = build();
      final report = await reporter.recordCrash(StateError('no stack'), null);
      expect(report, isNotNull);
      expect(report!.body, contains('None captured'));
    });
  });

  group('manual reports', () {
    test('builds from the form and keeps the user words', () async {
      final reporter = build();
      final report = await reporter.buildManual(
        summary: 'The download stalled at 40%',
        category: ReportCategory.download,
      );

      expect(report, isNotNull);
      expect(report!.summary, contains('stalled at 40%'));
      expect(report.category, ReportCategory.download);
      expect(report.title, startsWith('[Download failed]'));
      expect(report.isCrash, isFalse);
    });

    test('redacts secrets typed into the form', () async {
      final reporter = build();
      final report = await reporter.buildManual(
        summary: 'failed at https://x/y?sig=leaked123',
        category: ReportCategory.other,
      );
      expect(report!.body, isNot(contains('leaked123')));
    });

    test('an empty summary builds nothing', () async {
      final reporter = build();
      expect(
        await reporter.buildManual(summary: '   ', category: ReportCategory.other),
        isNull,
      );
    });

    test('the preview is the title plus the body', () async {
      final reporter = build();
      final report = await reporter.buildManual(
        summary: 'crash on open',
        category: ReportCategory.interface,
      );
      final preview = reporter.preview(report!);
      expect(preview, contains(report.title));
      expect(preview, contains('### What happened'));
    });
  });

  group('submission', () {
    test('created: file, remove from the queue, report the URL', () async {
      final github = _FakeGithubReporter(
        postable: true,
        createdUrl: 'https://github.com/o/r/issues/7',
      );
      final reporter = build(github: github);
      final report = (await reporter.recordCrash(StateError('x'), null))!;

      final outcome = await reporter.submit(report);

      expect(outcome.status, ReportSubmission.created);
      expect(outcome.url, contains('/issues/7'));
      expect(await store.list(), isEmpty, reason: 'filed reports are not queued');
      expect(github.lastBody, contains('### What happened'));
    });

    test('duplicate: no new issue, queue cleared', () async {
      final github = _FakeGithubReporter(
        postable: true,
        duplicateUrl: 'https://github.com/o/r/issues/3',
      );
      final reporter = build(github: github);
      final report = (await reporter.recordCrash(StateError('x'), null))!;

      final outcome = await reporter.submit(report);

      expect(outcome.status, ReportSubmission.duplicate);
      expect(outcome.url, contains('/issues/3'));
      expect(github.createCalls, 0);
      expect(await store.list(), isEmpty);
    });

    test('no token: a prefilled URL, never a claim of success', () async {
      final reporter = build(github: _FakeGithubReporter(postable: false));
      final report = (await reporter.recordCrash(StateError('x'), null))!;

      final outcome = await reporter.submit(report);

      expect(outcome.status, ReportSubmission.needsBrowser);
      expect(outcome.url, startsWith('https://github.com/'));
      expect(outcome.url, contains('issues/new'));
      expect(outcome.url, contains('title='));
      expect(
        await store.list(),
        hasLength(1),
        reason: 'we cannot confirm a browser submission, so the report stays',
      );
    });

    test('network failure: keeps the report and counts the attempt', () async {
      final github = _FakeGithubReporter(postable: true);
      final reporter = build(github: github);
      final report = (await reporter.recordCrash(StateError('x'), null))!;

      final outcome = await reporter.submit(report);

      expect(outcome.status, ReportSubmission.failed);
      final stored = (await store.list()).single;
      expect(stored.attempts, 1);
      expect(stored.body, contains('### What happened'),
          reason: 'the user text survives a failure');
    });

    test('an exception during submit is a failure, not a crash', () async {
      final github = _FakeGithubReporter(postable: true, throwOnCreate: true);
      final reporter = build(github: github);
      final report = (await reporter.recordCrash(StateError('x'), null))!;

      final outcome = await reporter.submit(report);
      expect(outcome.status, ReportSubmission.failed);
    });

    test('with no store at all, submit fails cleanly', () async {
      final reporter = CrashReporter(store: null);
      final outcome = await reporter.submit(PendingReport(
        id: 'x',
        fingerprint: 'fp',
        category: ReportCategory.other,
        title: 't',
        summary: 's',
        body: 'b',
        createdAt: DateTime(2026),
        source: 'manual',
      ));
      expect(outcome.status, ReportSubmission.failed);
    });
  });

  group('recovery prompt rules', () {
    test('a crash from an earlier session is offered', () async {
      final crashTime = DateTime.now();
      await build(clock: () => crashTime).recordCrash(StateError('old'), null);

      // A new process: the session clock is later than the report.
      final next =
          build(clock: () => crashTime.add(const Duration(minutes: 5)));
      expect(await next.promptCandidate(), isNotNull);
    });

    test('a crash from this session is not offered', () async {
      final reporter = build();
      await reporter.recordCrash(StateError('fresh'), null);
      expect(await reporter.promptCandidate(), isNull);
    });

    test('manual reports are never offered as crashes', () async {
      final reporter = build(
        clock: () => DateTime.now().add(const Duration(days: 1)),
      );
      await reporter.buildManual(
        summary: 'typed by hand',
        category: ReportCategory.other,
      );
      expect(await reporter.promptCandidate(), isNull);
    });

    test('the prompt respects its cooldown', () async {
      var now = DateTime.now();
      final reporter = build(clock: () => now);
      final report = (await reporter.recordCrash(StateError('x'), null))!;

      // Pretend the crash happened in a previous session.
      now = now.add(const Duration(days: 1));
      final later = CrashReporter(
        store: store,
        reporterFactory: () => _FakeGithubReporter(),
        clock: () => now,
      );
      expect(await later.promptCandidate(), isNotNull);
      await later.markPrompted(report.id);

      expect(await later.promptCandidate(), isNull,
          reason: 'asked recently — do not ask again yet');

      now = now.add(PendingReportStore.promptCooldown + const Duration(hours: 1));
      expect(await later.promptCandidate(), isNotNull);
    });
  });

  group('opt-in behaviour', () {
    test('off by default', () async {
      final reporter = build();
      expect(await reporter.autoReportingEnabled(), isFalse);
    });

    test('an opted-out queue is never sent', () async {
      final github = _FakeGithubReporter(postable: true, createdUrl: 'u');
      final reporter = build(github: github, autoReport: () async => false);
      await reporter.recordCrash(StateError('x'), null);

      await reporter.submitQueuedIfOptedIn();

      expect(github.createCalls, 0);
      expect(await store.list(), hasLength(1));
    });

    test('an opted-in queue is sent and cleared', () async {
      final github = _FakeGithubReporter(
        postable: true,
        createdUrl: 'https://github.com/o/r/issues/9',
      );
      final reporter = build(github: github, autoReport: () async => true);
      await reporter.recordCrash(StateError('x'), null);

      await reporter.submitQueuedIfOptedIn();

      expect(github.createCalls, 1);
      expect(await store.list(), isEmpty);
    });

    test('a failing submission stops the loop', () async {
      final github = _FakeGithubReporter(postable: true); // createIssue → null
      final reporter = build(github: github, autoReport: () async => true);
      await reporter.recordCrash(StateError('one'), null);
      await reporter.recordCrash(ArgumentError('two'), null);

      await reporter.submitQueuedIfOptedIn();

      expect(github.createCalls, 1, reason: 'do not burn the queue on a dead network');
      expect(await store.list(), hasLength(2));
    });
  });

  group('pending and dismiss', () {
    test('pending lists what is queued, dismiss removes one', () async {
      final reporter = build();
      final report = (await reporter.recordCrash(StateError('x'), null))!;

      expect(await reporter.pending(), hasLength(1));
      await reporter.dismiss(report.id);
      expect(await reporter.pending(), isEmpty);
    });
  });
}
