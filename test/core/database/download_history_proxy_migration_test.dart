import 'dart:convert';
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
    tempDir = await Directory.systemTemp.createTemp('proxy_history_migration_');
    DownloadHistoryDb.dbPathForTesting = p.join(tempDir.path, 'history.db');
  });

  tearDown(() async {
    await DownloadHistoryDb.instance.closeForTesting();
    DownloadHistoryDb.dbPathForTesting = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('new history writes scrub nested proxy fields', () {
    final record = DownloadRecord(
      id: 'new-proxy',
      url: 'https://video.test/new',
      title: 'New item',
      configJson: jsonEncode({
        'format': 'best',
        'proxy': 'http://user:pw@proxy.test:8080',
        'nested': {'proxy_password': 'pw', 'keep': true},
      }),
    );
    expect(jsonDecode(record.toMap()['configJson'] as String), {
      'format': 'best',
      'nested': {'keep': true},
    });
  });

  test(
    'v4 upgrade removes persisted proxy credentials and keeps other config',
    () async {
      final dbPath = DownloadHistoryDb.dbPathForTesting!;
      final oldDb = await openDatabase(
        dbPath,
        version: 4,
        onCreate: (db, version) async {
          await db.execute('''
          CREATE TABLE downloads (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            configJson TEXT
          )
        ''');
        },
      );
      await oldDb.insert('downloads', {
        'id': 'old-1',
        'url': 'https://video.test/1',
        'title': 'Old item',
        'timestamp': '2026-10-01T00:00:00.000Z',
        'configJson': jsonEncode({
          'format': 'best',
          'proxy': 'http://user:pw@proxy.test:8080',
        }),
      });
      await oldDb.close();

      final record = await DownloadHistoryDb.instance.getById('old-1');
      expect(record, isNotNull);
      expect(jsonDecode(record!.configJson!), {'format': 'best'});
      // v7 normalises the timestamps to UTC ISO-8601 with an offset.
      expect(
        await (await DownloadHistoryDb.instance.database).getVersion(),
        DownloadHistoryDb.schemaVersion,
      );
    },
  );
}
