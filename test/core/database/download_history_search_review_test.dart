import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/database/download_history_db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Regressions for the second-pass review (2026-10-20).
///
/// * #65 — the LIKE fallback did not escape its input, so the same search
///   box had two grammars: FTS quoted the term, the fallback passed `%`
///   and `_` through as wildcards.
/// * #66 — `timestamp` is the ORDER BY of every listing and was not
///   indexed, so each page was a full scan plus a temporary sort.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    await DownloadHistoryDb.instance.closeForTesting();
    tempDir = await Directory.systemTemp.createTemp('download_history_review_');
    DownloadHistoryDb.dbPathForTesting = p.join(tempDir.path, 'history.db');
  });

  tearDown(() async {
    await DownloadHistoryDb.instance.closeForTesting();
    DownloadHistoryDb.dbPathForTesting = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> seed() async {
    final db = DownloadHistoryDb.instance;
    final rows = <String, String>{
      'percent': '100% real',
      'underscore': 'a_b clip',
      'decoy': 'axb clip',
      'plain': 'nothing special',
    };
    var day = 1;
    for (final entry in rows.entries) {
      await db.insert(
        DownloadRecord(
          id: entry.key,
          url: 'https://video.test/${entry.key}',
          title: entry.value,
          timestamp: '2026-10-0${day}T00:00:00.000Z',
          status: 'completed',
        ),
      );
      day++;
    }
  }

  test('LIKE fallback treats % as a literal, not a wildcard', () async {
    await seed();
    final db = DownloadHistoryDb.instance;
    db.fts4EnabledForTesting = false;

    final hits = await db.getAll(search: '100%');
    expect(hits.map((r) => r.id), ['percent']);

    // A bare wildcard matches nothing, because nothing contains a '%'.
    final bare = await db.getAll(search: '%');
    expect(bare.map((r) => r.id), ['percent']);
  });

  test('LIKE fallback treats _ as a literal, not a single-char wildcard',
      () async {
    await seed();
    final db = DownloadHistoryDb.instance;
    db.fts4EnabledForTesting = false;

    final hits = await db.getAll(search: 'a_b');
    expect(hits.map((r) => r.id), ['underscore']);
    expect(hits.map((r) => r.id), isNot(contains('decoy')));
  });

  test('LIKE fallback still matches ordinary substrings', () async {
    await seed();
    final db = DownloadHistoryDb.instance;
    db.fts4EnabledForTesting = false;

    final hits = await db.getAll(search: 'clip');
    expect(hits.map((r) => r.id).toSet(), {'underscore', 'decoy'});
  });

  test('v8 migration creates the listing indexes', () async {
    await seed();
    final db = await DownloadHistoryDb.instance.database;
    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'downloads'",
    );
    final names = indexes.map((r) => r['name'] as String?).toSet();
    expect(names, contains('idx_downloads_timestamp'));
    expect(names, contains('idx_downloads_status_timestamp'));
    // The pre-existing one is still there.
    expect(names, contains('idx_downloads_status'));
  });

  test('listing stays ordered newest-first with the index in place', () async {
    await seed();
    final rows = await DownloadHistoryDb.instance.getAll(limit: 10);
    final timestamps = rows.map((r) => r.timestamp).toList();
    final sorted = [...timestamps]..sort();
    expect(timestamps, sorted.reversed.toList());
  });
}
