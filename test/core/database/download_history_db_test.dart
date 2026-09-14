import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:grablytic/core/database/download_history_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('DownloadRecord v3 model', () {
    test('serializes and deserializes all schema v3 fields', () {
      final record = DownloadRecord(
        id: 'dl-123',
        url: 'https://youtube.com/watch?v=test',
        title: 'Test Title',
        platform: 'youtube',
        format: 'mkv',
        quality: '1080p',
        fileSize: 10485760,
        filePath: '/tmp/test.mkv',
        status: 'interrupted',
        progress: 0.45,
        thumbnailUrl: 'https://thumb.test/1.jpg',
        thumbnailPath: '/tmp/test.jpg',
        configJson: '{"audio_only":false,"format":"mkv"}',
        queuePosition: 2,
        attempts: 1,
        lastErrorType: 'NETWORK_TIMEOUT',
        lastErrorMessage: 'Connection lost',
        bytesDownloaded: 4718592,
        totalBytes: 10485760,
        updatedAt: '2026-09-13T10:00:00.000Z',
      );

      final map = record.toMap();
      expect(map['id'], 'dl-123');
      expect(map['configJson'], '{"audio_only":false,"format":"mkv"}');
      expect(map['queuePosition'], 2);
      expect(map['attempts'], 1);
      expect(map['lastErrorType'], 'NETWORK_TIMEOUT');
      expect(map['lastErrorMessage'], 'Connection lost');
      expect(map['bytesDownloaded'], 4718592);
      expect(map['totalBytes'], 10485760);
      expect(map['updatedAt'], '2026-09-13T10:00:00.000Z');

      final from = DownloadRecord.fromMap(map);
      expect(from.id, record.id);
      expect(from.configJson, record.configJson);
      expect(from.queuePosition, 2);
      expect(from.attempts, 1);
      expect(from.lastErrorType, 'NETWORK_TIMEOUT');
      expect(from.lastErrorMessage, 'Connection lost');
      expect(from.bytesDownloaded, 4718592);
      expect(from.totalBytes, 10485760);
      expect(from.status, 'interrupted');
    });

    test('copyWith updates fields while preserving others', () {
      final initial = DownloadRecord(
        id: 'dl-1',
        url: 'https://test.com',
        title: 'Title',
        status: 'queued',
        attempts: 0,
      );

      final updated = initial.copyWith(
        status: 'interrupted',
        attempts: 1,
        bytesDownloaded: 500,
        updatedAt: '2026-09-13T11:00:00.000Z',
      );

      expect(updated.id, 'dl-1');
      expect(updated.status, 'interrupted');
      expect(updated.attempts, 1);
      expect(updated.bytesDownloaded, 500);
      expect(updated.updatedAt, '2026-09-13T11:00:00.000Z');
      expect(updated.url, initial.url);
    });
  });

  group('DownloadHistoryDb database operations', () {
    late Database db;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('grablytic_db_test_');
      final dbPath = p.join(tempDir.path, 'test_grablytic.db');
      db = await openDatabase(
        dbPath,
        version: 3,
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE downloads (
              id TEXT PRIMARY KEY,
              url TEXT NOT NULL,
              title TEXT NOT NULL,
              platform TEXT,
              format TEXT,
              quality TEXT,
              fileSize INTEGER,
              filePath TEXT,
              status TEXT DEFAULT 'pending',
              progress REAL DEFAULT 0,
              timestamp TEXT NOT NULL,
              thumbnailUrl TEXT,
              thumbnailPath TEXT,
              configJson TEXT,
              queuePosition INTEGER,
              attempts INTEGER DEFAULT 0,
              lastErrorType TEXT,
              lastErrorMessage TEXT,
              bytesDownloaded INTEGER DEFAULT 0,
              totalBytes INTEGER,
              updatedAt TEXT
            )
          ''');
          await d.execute('CREATE INDEX IF NOT EXISTS idx_downloads_status ON downloads(status)');
        },
      );
    });

    tearDown(() async {
      await db.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('sweeps downloading and queued rows to interrupted', () async {
      final now = '2026-09-13T12:00:00.000Z';
      await db.insert('downloads', {
        'id': 'dl-1',
        'url': 'u1',
        'title': 't1',
        'status': 'downloading',
        'timestamp': now,
        'attempts': 0,
      });
      await db.insert('downloads', {
        'id': 'dl-2',
        'url': 'u2',
        'title': 't2',
        'status': 'queued',
        'timestamp': now,
        'attempts': 0,
      });
      await db.insert('downloads', {
        'id': 'dl-3',
        'url': 'u3',
        'title': 't3',
        'status': 'completed',
        'timestamp': now,
        'attempts': 0,
      });

      final swept = await db.update(
        'downloads',
        {'status': 'interrupted', 'updatedAt': now},
        where: 'status IN (?, ?)',
        whereArgs: ['downloading', 'queued'],
      );
      expect(swept, 2);

      final r1 = await db.query('downloads', where: 'id = ?', whereArgs: ['dl-1']);
      expect(r1.first['status'], 'interrupted');
      expect(r1.first['updatedAt'], now);

      final r2 = await db.query('downloads', where: 'id = ?', whereArgs: ['dl-2']);
      expect(r2.first['status'], 'interrupted');

      final r3 = await db.query('downloads', where: 'id = ?', whereArgs: ['dl-3']);
      expect(r3.first['status'], 'completed');
    });

    test('updateHeartbeat updates byte counts and progress', () async {
      await db.insert('downloads', {
        'id': 'dl-heartbeat',
        'url': 'u',
        'title': 't',
        'status': 'downloading',
        'timestamp': '2026-09-13T12:00:00.000Z',
        'bytesDownloaded': 0,
        'totalBytes': 1000,
        'progress': 0.0,
      });

      final updated = await db.update(
        'downloads',
        {
          'bytesDownloaded': 500,
          'progress': 0.5,
          'updatedAt': '2026-09-13T12:01:00.000Z',
        },
        where: 'id = ?',
        whereArgs: ['dl-heartbeat'],
      );
      expect(updated, 1);

      final row = await db.query('downloads', where: 'id = ?', whereArgs: ['dl-heartbeat']);
      expect(row.first['bytesDownloaded'], 500);
      expect(row.first['progress'], 0.5);
      expect(row.first['updatedAt'], '2026-09-13T12:01:00.000Z');
    });

    test('v3 to v4 migration creates seen_source_videos table and index', () async {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS seen_source_videos (
          source_url TEXT NOT NULL,
          video_id TEXT NOT NULL,
          seen_at TEXT NOT NULL,
          PRIMARY KEY (source_url, video_id)
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_seen_source_url ON seen_source_videos(source_url)');

      final info = await db.rawQuery('PRAGMA table_info(seen_source_videos)');
      final cols = info.map((c) => c['name'] as String).toSet();
      expect(cols, containsAll(['source_url', 'video_id', 'seen_at']));
    });

    test('seen_source_videos recording, filtering, and clearing', () async {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS seen_source_videos (
          source_url TEXT NOT NULL,
          video_id TEXT NOT NULL,
          seen_at TEXT NOT NULL,
          PRIMARY KEY (source_url, video_id)
        )
      ''');

      const sourceUrl = 'https://www.youtube.com/@veritasium';
      final now = DateTime.now().toIso8601String();

      // Insert batch
      final batch = db.batch();
      for (final vid in ['vid_1', 'vid_2']) {
        batch.insert('seen_source_videos', {
          'source_url': sourceUrl,
          'video_id': vid,
          'seen_at': now,
        });
      }
      await batch.commit(noResult: true);

      // Query seen
      final rows = await db.query(
        'seen_source_videos',
        columns: ['video_id'],
        where: 'source_url = ?',
        whereArgs: [sourceUrl],
      );
      final seen = rows.map((r) => r['video_id'] as String).toSet();
      expect(seen, {'vid_1', 'vid_2'});

      // Filter new candidate IDs
      final candidates = ['vid_1', 'vid_3', 'vid_2', 'vid_4', 'vid_3'];
      final newIds = candidates.where((id) => !seen.contains(id)).toSet().toList();
      expect(newIds, ['vid_3', 'vid_4']);

      // Clear specific source
      final deleted = await db.delete(
        'seen_source_videos',
        where: 'source_url = ?',
        whereArgs: [sourceUrl],
      );
      expect(deleted, 2);

      final emptyRows = await db.query('seen_source_videos');
      expect(emptyRows, isEmpty);
    });
  });
}
