import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:grablytic/core/database/download_history_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    await DownloadHistoryDb.instance.closeForTesting();
    tempDir = await Directory.systemTemp.createTemp('download_history_fts_');
    DownloadHistoryDb.dbPathForTesting = p.join(tempDir.path, 'history.db');
  });

  tearDown(() async {
    await DownloadHistoryDb.instance.closeForTesting();
    DownloadHistoryDb.dbPathForTesting = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('FTS4 searches title and URL tokens case-insensitively', () async {
    final db = DownloadHistoryDb.instance;
    await db.insert(
      DownloadRecord(
        id: 'title-hit',
        url: 'https://video.test/watch/one',
        title: 'A very special phrase',
        timestamp: '2026-10-01T00:00:00.000Z',
      ),
    );
    await db.insert(
      DownloadRecord(
        id: 'url-hit',
        url: 'https://archive.test/Special/clip',
        title: 'Another recording',
        timestamp: '2026-10-02T00:00:00.000Z',
        status: 'completed',
      ),
    );
    await db.insert(
      DownloadRecord(
        id: 'miss',
        url: 'https://video.test/other',
        title: 'Not a match',
        timestamp: '2026-10-03T00:00:00.000Z',
      ),
    );

    final hits = await db.getAll(search: 'SPECIAL');
    expect(hits.map((record) => record.id).toSet(), {'title-hit', 'url-hit'});
    final phrase = await db.getAll(search: 'special phrase');
    expect(phrase.map((record) => record.id), ['title-hit']);
    final filtered = await db.getAll(
      search: 'special',
      statusFilter: 'completed',
      limit: 1,
    );
    expect(filtered.map((record) => record.id), ['url-hit']);
  });

  test('insert update and delete keep FTS index synchronized', () async {
    final db = DownloadHistoryDb.instance;
    await db.insert(
      DownloadRecord(
        id: 'same-id',
        url: 'https://video.test/first',
        title: 'before update',
        timestamp: '2026-10-01T00:00:00.000Z',
      ),
    );
    expect(await db.getAll(search: 'before'), hasLength(1));

    await db.insert(
      DownloadRecord(
        id: 'same-id',
        url: 'https://video.test/second',
        title: 'after update',
        timestamp: '2026-10-02T00:00:00.000Z',
      ),
    );
    expect(await db.getAll(search: 'before'), isEmpty);
    expect(await db.getAll(search: 'first'), isEmpty);
    expect(
      (await db.getAll(search: 'after')).single.url,
      'https://video.test/second',
    );
    expect(await db.getAll(search: 'second'), hasLength(1));

    await db.delete('same-id');
    expect(await db.getAll(search: 'after'), isEmpty);
  });

  test('stale index falls back to LIKE instead of hiding history', () async {
    final db = DownloadHistoryDb.instance;
    await db.insert(
      DownloadRecord(
        id: 'stale-index',
        url: 'https://video.test/stale-index',
        title: 'Recoverable history entry',
        timestamp: '2026-10-01T00:00:00.000Z',
      ),
    );
    final fts4Available = db.fts4EnabledForTesting;
    if (!fts4Available) {
      // Some host SQLite builds omit FTS4; the supported fallback must still
      // return the complete history row instead of failing the query.
      expect((await db.getAll(search: 'Recoverable')).single.id, 'stale-index');
      return;
    }

    final rawDb = await db.database;
    await rawDb.delete('downloads_fts');
    await db.closeForTesting();
    await db.database;

    expect(db.fts4EnabledForTesting, isFalse);
    expect((await db.getAll(search: 'Recoverable')).single.id, 'stale-index');
  });

  test('v5 upgrade rebuilds the FTS index for existing downloads', () async {
    final path = DownloadHistoryDb.dbPathForTesting!;
    final oldDb = await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE downloads (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            status TEXT,
            progress REAL
          )
        ''');
      },
    );
    await oldDb.insert('downloads', {
      'id': 'pre-index',
      'url': 'https://video.test/legacy-token',
      'title': 'Legacy item',
      'timestamp': '2026-10-01T00:00:00.000Z',
      'status': 'completed',
      'progress': 1.0,
    });
    await oldDb.close();

    final hits = await DownloadHistoryDb.instance.getAll(
      search: 'legacy-token',
    );
    expect(hits.map((record) => record.id), ['pre-index']);
    // v7 normalises the timestamps to UTC ISO-8601 with an offset.
    expect(await (await DownloadHistoryDb.instance.database).getVersion(), 7);
  });
}
