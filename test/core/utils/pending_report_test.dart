import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/pending_report.dart';

/// The queue is what makes a crash survivable: it is written by a process
/// that is about to die and read by the next one. Everything here is about
/// it behaving under bad conditions — corrupt files, a full queue, a half
/// finished write.
void main() {
  late Directory dir;
  late PendingReportStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('grablytic_reports');
    store = PendingReportStore(dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  PendingReport report({
    String id = 'r1',
    String fingerprint = 'fp1',
    String source = 'auto',
    DateTime? at,
    String body = 'body',
  }) {
    return PendingReport(
      id: id,
      fingerprint: fingerprint,
      category: ReportCategory.crash,
      title: 'title',
      summary: 'summary',
      body: body,
      createdAt: at ?? DateTime(2026, 10, 21, 10),
      source: source,
    );
  }

  test('starts empty', () async {
    expect(await store.list(), isEmpty);
  });

  test('round-trips a report', () async {
    await store.add(report(body: 'hello\nworld'));
    final all = await store.list();

    expect(all, hasLength(1));
    expect(all.single.body, 'hello\nworld');
    expect(all.single.category, ReportCategory.crash);
    expect(all.single.isCrash, isTrue);
  });

  test('lists newest first', () async {
    await store.add(report(id: 'old', fingerprint: 'a', at: DateTime(2026, 1, 1)));
    await store.add(report(id: 'new', fingerprint: 'b', at: DateTime(2026, 6, 1)));

    expect((await store.list()).map((r) => r.id), ['new', 'old']);
  });

  group('dedup', () {
    test('the same fingerprint collapses into one file with a count', () async {
      await store.add(report(id: 'r1'));
      final second = await store.add(report(id: 'r2'));

      expect(await store.list(), hasLength(1));
      expect(second!.occurrences, 2);
      expect(second.id, 'r1', reason: 'the original file is kept');
    });

    test('a different fingerprint is a separate report', () async {
      await store.add(report(id: 'r1', fingerprint: 'fp1'));
      await store.add(report(id: 'r2', fingerprint: 'fp2'));
      expect(await store.list(), hasLength(2));
    });

    test('a repeat after the dedup window is filed again', () async {
      final old = DateTime.now().subtract(const Duration(days: 30));
      await store.add(report(id: 'r1', fingerprint: 'fp1', at: old));
      await store.add(report(id: 'r2', fingerprint: 'fp1'));

      expect(await store.list(), hasLength(2));
    });

    test('an empty fingerprint never collapses', () async {
      await store.add(report(id: 'r1', fingerprint: ''));
      await store.add(report(id: 'r2', fingerprint: ''));
      expect(await store.list(), hasLength(2));
    });
  });

  group('bounds', () {
    test('keeps at most maxReports, dropping the oldest', () async {
      for (var i = 0; i < PendingReportStore.maxReports + 2; i++) {
        await store.add(
          report(
            id: 'r$i',
            fingerprint: 'fp$i',
            at: DateTime(2026, 1, 1).add(Duration(hours: i)),
          ),
        );
      }

      final all = await store.list();
      expect(all, hasLength(PendingReportStore.maxReports));
      expect(all.map((r) => r.id), isNot(contains('r0')));
      expect(all.map((r) => r.id), contains('r4'));
    });

    test('a huge body is truncated rather than rejected', () async {
      final huge = 'x' * (PendingReportStore.maxBodyChars + 500);
      await store.add(report(body: huge));

      final stored = (await store.list()).single;
      expect(stored.body.length,
          lessThanOrEqualTo(PendingReportStore.maxBodyChars + 40));
      expect(stored.body, contains('[... truncated ...]'));
    });
  });

  group('robustness', () {
    test('a corrupt file is skipped, valid ones still load', () async {
      await store.add(report(id: 'good'));
      await File('${dir.path}/broken.json').writeAsString('{not json');

      expect((await store.list()).map((r) => r.id), ['good']);
    });

    test('a half-written tmp file is never read as a report', () async {
      await File('${dir.path}/r9.json.tmp').writeAsString('{"id":"r9"');
      expect(await store.list(), isEmpty);
    });

    test('a missing directory lists empty instead of throwing', () async {
      await dir.delete(recursive: true);
      expect(await store.list(), isEmpty);
    });

    test('remove deletes one report only', () async {
      await store.add(report(id: 'a', fingerprint: 'fa'));
      await store.add(report(id: 'b', fingerprint: 'fb'));

      await store.remove('a');
      expect((await store.list()).map((r) => r.id), ['b']);
    });

    test('removing something absent is a no-op', () async {
      await store.remove('nope');
      expect(await store.list(), isEmpty);
    });

    test('markAttempt and markPrompted survive a reload', () async {
      await store.add(report(id: 'r1'));
      await store.markAttempt('r1');
      await store.markPrompted('r1');

      final stored = (await store.list()).single;
      expect(stored.attempts, 1);
      expect(stored.lastPromptAt, isNotNull);
    });

    test('a report written by a future version still loads', () async {
      await File('${dir.path}/future.json').writeAsString(jsonEncode({
        'id': 'future',
        'fingerprint': 'fp',
        'category': 'Download failure',
        'title': 't',
        'summary': 's',
        'body': 'b',
        'created_at': '2026-10-21T00:00:00.000Z',
        'source': 'manual',
        'unknown_field': {'nested': true},
      }));

      final stored = (await store.list()).single;
      expect(stored.category, ReportCategory.download);
      expect(stored.source, 'manual');
    });

    test('an unknown category falls back instead of dropping the report',
        () async {
      await File('${dir.path}/weird.json').writeAsString(jsonEncode({
        'id': 'weird',
        'body': 'b',
        'created_at': '2026-10-21T00:00:00.000Z',
        'category': 'Something new in 2027',
      }));

      expect((await store.list()).single.category, ReportCategory.other);
    });
  });

  group('open', () {
    test('returns null without an app directory', () async {
      expect(await PendingReportStore.open(null), isNull);
      expect(await PendingReportStore.open(''), isNull);
    });

    test('creates the reports directory under the app directory', () async {
      final opened = await PendingReportStore.open(dir.path);
      expect(opened, isNotNull);
      expect(Directory('${dir.path}/reports').existsSync(), isTrue);
    });
  });
}
