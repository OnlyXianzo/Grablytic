import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../utils/config_secrets.dart';

class DownloadRecord {
  final String id;
  final String url;
  final String title;
  final String? platform;
  final String? format;
  final String? quality;
  final int? fileSize;
  final String? filePath;
  final String status;
  final double progress;
  final String timestamp;
  final String? thumbnailUrl;
  /// Local thumbnail sidecar file path (writethumbnail output kept next to
  /// the media file). Preferred over [thumbnailUrl] for Library rendering:
  /// offline-friendly and no tracking-pixel network call per row.
  final String? thumbnailPath;
  final String? configJson;
  final int? queuePosition;
  final int attempts;
  final String? lastErrorType;
  final String? lastErrorMessage;
  final int bytesDownloaded;
  final int? totalBytes;
  final String? updatedAt;

  DownloadRecord({
    required this.id,
    required this.url,
    required this.title,
    this.platform,
    this.format,
    this.quality,
    this.fileSize,
    this.filePath,
    this.status = 'pending',
    this.progress = 0,
    String? timestamp,
    this.thumbnailUrl,
    this.thumbnailPath,
    this.configJson,
    this.queuePosition,
    this.attempts = 0,
    this.lastErrorType,
    this.lastErrorMessage,
    this.bytesDownloaded = 0,
    this.totalBytes,
    this.updatedAt,
  }) : timestamp = timestamp ?? utcNowIso();

  Map<String, dynamic> toMap() => {
        'id': id,
        'url': url,
        'title': title,
        'platform': platform,
        'format': format,
        'quality': quality,
        'fileSize': fileSize,
        'filePath': filePath,
        'status': status,
        'progress': progress,
        'timestamp': timestamp,
        'thumbnailUrl': thumbnailUrl,
        'thumbnailPath': thumbnailPath,
        'configJson': stripProxyFieldsFromJson(configJson),
        'queuePosition': queuePosition,
        'attempts': attempts,
        'lastErrorType': lastErrorType,
        'lastErrorMessage': lastErrorMessage,
        'bytesDownloaded': bytesDownloaded,
        'totalBytes': totalBytes,
        'updatedAt': updatedAt,
      };

  factory DownloadRecord.fromMap(Map<String, dynamic> map) => DownloadRecord(
        id: map['id'] as String,
        url: map['url'] as String,
        title: map['title'] as String,
        platform: map['platform'] as String?,
        format: map['format'] as String?,
        quality: map['quality'] as String?,
        fileSize: map['fileSize'] as int?,
        filePath: map['filePath'] as String?,
        status: map['status'] as String? ?? 'pending',
        progress: (map['progress'] as num?)?.toDouble() ?? 0,
        timestamp: map['timestamp'] as String?,
        thumbnailUrl: map['thumbnailUrl'] as String?,
        thumbnailPath: map['thumbnailPath'] as String?,
        configJson: stripProxyFieldsFromJson(map['configJson'] as String?),
        queuePosition: map['queuePosition'] as int?,
        attempts: map['attempts'] as int? ?? 0,
        lastErrorType: map['lastErrorType'] as String?,
        lastErrorMessage: map['lastErrorMessage'] as String?,
        bytesDownloaded: map['bytesDownloaded'] as int? ?? 0,
        totalBytes: map['totalBytes'] as int?,
        updatedAt: map['updatedAt'] as String?,
      );

  /// Sentinel for "not supplied" in [copyWith].
  ///
  /// Without it every nullable parameter used `x ?? this.x`, so a
  /// caller could never set a nullable field back to null: a successful
  /// retry could not clear the previous error, a deleted file could not
  /// clear [filePath], and a promoted item could not clear
  /// [queuePosition].
  static const Object _unset = Object();

  DownloadRecord copyWith({
    String? id,
    String? url,
    String? title,
    String? platform,
    String? format,
    String? quality,
    int? fileSize,
    Object? filePath = _unset,
    String? status,
    double? progress,
    String? timestamp,
    String? thumbnailUrl,
    Object? thumbnailPath = _unset,
    Object? configJson = _unset,
    Object? queuePosition = _unset,
    int? attempts,
    Object? lastErrorType = _unset,
    Object? lastErrorMessage = _unset,
    int? bytesDownloaded,
    Object? totalBytes = _unset,
    Object? updatedAt = _unset,
  }) =>
      DownloadRecord(
        id: id ?? this.id,
        url: url ?? this.url,
        title: title ?? this.title,
        platform: platform ?? this.platform,
        format: format ?? this.format,
        quality: quality ?? this.quality,
        fileSize: fileSize ?? this.fileSize,
        filePath: identical(filePath, _unset)
            ? this.filePath
            : filePath as String?,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        timestamp: timestamp ?? this.timestamp,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        thumbnailPath: identical(thumbnailPath, _unset)
            ? this.thumbnailPath
            : thumbnailPath as String?,
        configJson: identical(configJson, _unset)
            ? this.configJson
            : configJson as String?,
        queuePosition: identical(queuePosition, _unset)
            ? this.queuePosition
            : queuePosition as int?,
        attempts: attempts ?? this.attempts,
        lastErrorType: identical(lastErrorType, _unset)
            ? this.lastErrorType
            : lastErrorType as String?,
        lastErrorMessage: identical(lastErrorMessage, _unset)
            ? this.lastErrorMessage
            : lastErrorMessage as String?,
        bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
        totalBytes: identical(totalBytes, _unset)
            ? this.totalBytes
            : totalBytes as int?,
        updatedAt: identical(updatedAt, _unset)
            ? this.updatedAt
            : updatedAt as String?,
      );

  Map<String, dynamic> toJson() => toMap();
  factory DownloadRecord.fromJson(String source) =>
      DownloadRecord.fromMap(jsonDecode(source) as Map<String, dynamic>);
}

/// Single source of truth for persisting a timestamp.
///
/// UTC ISO-8601 with an explicit offset. Local ISO strings have no
/// zone, so lexicographic ordering of them is only correct while the
/// device stays in one timezone; the history table also mixed in UTC
/// strings written by the Android sweeper, so one column held two
/// conventions.
String utcNowIso() => DateTime.now().toUtc().toIso8601String();

/// Converts a local [DateTime] to the persisted UTC representation.
String toUtcIso(DateTime value) => value.toUtc().toIso8601String();

class DownloadHistoryDb {
  DownloadHistoryDb._();
  static final DownloadHistoryDb instance = DownloadHistoryDb._();

  Database? _db;
  bool _fts4Enabled = false;

  @visibleForTesting
  bool get fts4EnabledForTesting => _fts4Enabled;

  /// Test-only database path override. When set, [_initDb] skips
  /// path_provider (unavailable in unit tests). Null in production.
  @visibleForTesting
  static String? dbPathForTesting;

  /// Test-only teardown: closes and drops the cached handle so the next
  /// test can point [dbPathForTesting] at a fresh temp file.
  @visibleForTesting
  Future<void> closeForTesting() async {
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    _fts4Enabled = false;
  }

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    // ?? short-circuits: path_provider is never touched in unit tests.
    final path = dbPathForTesting ??
        p.join((await getApplicationDocumentsDirectory()).path,
            'grablytic.db');
    final db = await openDatabase(
      path,
      version: 7,
      onCreate: (db, version) async {
        await db.execute('''
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
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_downloads_status ON downloads(status)');
        await db.execute('''
          CREATE TABLE seen_source_videos (
            source_url TEXT NOT NULL,
            video_id TEXT NOT NULL,
            seen_at TEXT NOT NULL,
            PRIMARY KEY (source_url, video_id)
          )
        ''');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_seen_source_url ON seen_source_videos(source_url)');
        await _createDownloadsFts4(db, rebuild: true);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 → v2: local thumbnail sidecar path (task 03 thumbnails). PRAGMA
        // table_info guard keeps this idempotent for partial upgrades.
        if (oldVersion < 2) {
          final cols = await db.rawQuery('PRAGMA table_info(downloads)');
          final names = cols.map((c) => c['name'] as String?).toSet();
          if (!names.contains('thumbnailPath')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN thumbnailPath TEXT');
          }
        }
        // v2 → v3: DB-driven resume columns.
        if (oldVersion < 3) {
          final cols = await db.rawQuery('PRAGMA table_info(downloads)');
          final names = cols.map((c) => c['name'] as String?).toSet();
          if (!names.contains('configJson')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN configJson TEXT');
          }
          if (!names.contains('queuePosition')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN queuePosition INTEGER');
          }
          if (!names.contains('attempts')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN attempts INTEGER DEFAULT 0');
          }
          if (!names.contains('lastErrorType')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN lastErrorType TEXT');
          }
          if (!names.contains('lastErrorMessage')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN lastErrorMessage TEXT');
          }
          if (!names.contains('bytesDownloaded')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN bytesDownloaded INTEGER DEFAULT 0');
          }
          if (!names.contains('totalBytes')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN totalBytes INTEGER');
          }
          if (!names.contains('updatedAt')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN updatedAt TEXT');
          }
          await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_downloads_status ON downloads(status)');
        }
        // v3 → v4: observed sources background scheduler deduplication ledger.
        if (oldVersion < 4) {
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
        }
        if (oldVersion < 6) {
          await _createDownloadsFts4(db, rebuild: true);
        }
        if (oldVersion < 7) {
          // v6 → v7: timestamps become UTC ISO-8601 with an explicit
          // offset. Rows written before this stored LOCAL ISO strings
          // without a zone ("2026-10-19T21:30:00.000"), which sort
          // correctly only while the device stays in one timezone and
          // never crosses DST. The Kotlin sweeper wrote UTC strings into
          // the same column, so one column held two conventions.
          //
          // `updatedAt` was added by the v2 → v3 step, so a database
          // that was CREATED at v3 or later by an older build can lack
          // the column. Without it the normalisation query fails and
          // NOTHING is normalised — the migration silently does
          // nothing. Add the column when it is missing, so every
          // database converges on the same shape.
          final cols = await db.rawQuery('PRAGMA table_info(downloads)');
          final names = cols.map((c) => c['name'] as String?).toSet();
          if (!names.contains('updatedAt')) {
            await db.execute('ALTER TABLE downloads ADD COLUMN updatedAt TEXT');
          }
          await _normalizeTimestampsToUtc(db);
        }
      },
    );
    await _stripLegacyProxyConfigs(db);
    _fts4Enabled = await _validateDownloadsFts4(db);
    return db;
  }

  Future<void> _stripLegacyProxyConfigs(Database db) async {
    try {
      final rows = await db.query(
        'downloads',
        columns: ['id', 'configJson'],
        where: 'configJson IS NOT NULL',
      );
      final batch = db.batch();
      var changed = false;
      for (final row in rows) {
        final oldValue = row['configJson'] as String?;
        final safeValue = stripProxyFieldsFromJson(oldValue);
        if (safeValue != oldValue) {
          batch.update(
            'downloads',
            {'configJson': safeValue},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          changed = true;
        }
      }
      if (changed) await batch.commit(noResult: true);
    } catch (_) {
      // A damaged legacy config must not prevent the history DB from opening.
    }
  }

  Future<void> _createDownloadsFts4(Database db, {required bool rebuild}) async {
    try {
      await db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS downloads_fts USING fts4(title, url)',
      );
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS downloads_fts_after_insert
        AFTER INSERT ON downloads
        BEGIN
          INSERT OR REPLACE INTO downloads_fts(docid, title, url)
          VALUES (new.rowid, new.title, new.url);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS downloads_fts_after_update
        AFTER UPDATE OF title, url ON downloads
        BEGIN
          DELETE FROM downloads_fts WHERE docid = old.rowid;
          INSERT OR REPLACE INTO downloads_fts(docid, title, url)
          VALUES (new.rowid, new.title, new.url);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS downloads_fts_after_delete
        AFTER DELETE ON downloads
        BEGIN
          DELETE FROM downloads_fts WHERE docid = old.rowid;
        END
      ''');
      if (rebuild) {
        await db.execute('DELETE FROM downloads_fts');
        await db.execute('''
          INSERT INTO downloads_fts(docid, title, url)
          SELECT rowid, title, url FROM downloads
        ''');
      }
      _fts4Enabled = await _validateDownloadsFts4(db);
    } catch (_) {
      _fts4Enabled = false;
    }
  }

  Future<bool> _validateDownloadsFts4(Database db) async {
    try {
      final objects = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type IN ('table','trigger')",
      );
      final names = objects.map((r) => r['name'] as String?).whereType<String>().toSet();
      if (!names.contains('downloads_fts') ||
          !names.contains('downloads_fts_after_insert') ||
          !names.contains('downloads_fts_after_update') ||
          !names.contains('downloads_fts_after_delete')) {
        return false;
      }
      final mismatches = await db.rawQuery('''
        SELECT COUNT(*) AS n
        FROM downloads d LEFT JOIN downloads_fts f ON f.docid = d.rowid
        WHERE f.docid IS NULL OR f.title IS NOT d.title OR f.url IS NOT d.url
      ''');
      final orphans = await db.rawQuery('''
        SELECT COUNT(*) AS n
        FROM downloads_fts f LEFT JOIN downloads d ON d.rowid = f.docid
        WHERE d.rowid IS NULL
      ''');
      return (mismatches.first['n'] as int? ?? 1) == 0 &&
          (orphans.first['n'] as int? ?? 1) == 0;
    } catch (_) {
      return false;
    }
  }

  /// Rewrites local ISO timestamps as UTC ISO-8601.
  ///
  /// Only rows whose value has no zone marker are touched, so an
  /// already-UTC row is left alone and the migration is idempotent.
  Future<void> _normalizeTimestampsToUtc(Database db) async {
    try {
      // Only the columns that EXIST: a query for a missing column
      // throws, and the whole migration would then be a no-op.
      final cols = await db.rawQuery('PRAGMA table_info(downloads)');
      final names = cols.map((c) => c['name'] as String?).toSet();
      final targets = <String>[
        for (final column in const ['timestamp', 'updatedAt'])
          if (names.contains(column)) column,
      ];
      if (targets.isEmpty) return;
      final rows = await db.query(
        'downloads',
        columns: ['id', ...targets],
      );
      if (rows.isEmpty) return;
      final batch = db.batch();
      var changed = 0;
      for (final row in rows) {
        for (final column in targets) {
          final value = row[column] as String?;
          if (value == null || value.isEmpty) continue;
          if (value.endsWith('Z') || value.endsWith('+00:00')) continue;
          final parsed = DateTime.tryParse(value);
          if (parsed == null) continue;
          batch.update(
            'downloads',
            {column: parsed.toUtc().toIso8601String()},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          changed++;
        }
      }
      if (changed > 0) await batch.commit(noResult: true);
    } catch (_) {
      // A failed normalisation must never block the app from starting.
    }
  }

  /// Upsert by primary key.
  ///
  /// UPDATE-then-INSERT, never `ConflictAlgorithm.replace` and never a
  /// manual delete+insert. REPLACE deletes the old row and inserts a new
  /// one: the rowid changes, the `downloads_fts` delete trigger fires
  /// and the FTS index is rebuilt for the row, and any column the caller
  /// does not supply is reset to its default. `ON CONFLICT DO UPDATE`
  /// would be the natural SQL, but it needs SQLite 3.24 (API 30) while
  /// this app supports API 24 and sqflite runs on the PLATFORM SQLite,
  /// so the two-step form is the portable equivalent.
  Future<int> insert(DownloadRecord record) async {
    final db = await database;
    return db.transaction((txn) async {
      final updated = await txn.update(
        'downloads',
        record.toMap(),
        where: 'id = ?',
        whereArgs: [record.id],
      );
      if (updated > 0) return updated;
      return txn.insert('downloads', record.toMap());
    });
  }

  Future<int> update(DownloadRecord record) async {
    final db = await database;
    return db.update('downloads', record.toMap(),
        where: 'id = ?', whereArgs: [record.id]);
  }

  Future<int> delete(String id) async {
    final db = await database;
    return db.delete('downloads', where: 'id = ?', whereArgs: [id]);
  }

  /// Sweeps every non-terminal download in SQLite to 'interrupted' on
  /// process death / app startup. 'pending' rows (default-constructed
  /// items persisted before admission) and 'cancelling' rows would
  /// otherwise survive as zombies — never resumed, never shown.
  /// Returns the number of affected rows.
  Future<int> sweepActiveToInterrupted({String? now}) async {
    final db = await database;
    final timestamp = now ?? utcNowIso();
    return db.update(
      'downloads',
      {
        'status': 'interrupted',
        'updatedAt': timestamp,
      },
      where: 'status IN (?, ?, ?, ?)',
      whereArgs: ['downloading', 'queued', 'pending', 'cancelling'],
    );
  }

  /// Interrupted records for startup recovery sweep / retry. Null [limit]
  /// returns the whole backlog (callers page or cap admission themselves).
  Future<List<DownloadRecord>> getInterrupted({int? limit}) async {
    final db = await database;
    final rows = await db.query(
      'downloads',
      where: 'status = ?',
      whereArgs: ['interrupted'],
      orderBy: 'queuePosition ASC, timestamp ASC',
      limit: limit,
    );
    return rows.map((r) => DownloadRecord.fromMap(r)).toList();
  }

  /// Throttled heartbeat to persist download progress and byte counters.
  Future<int> updateHeartbeat(
    String id, {
    required int bytesDownloaded,
    int? totalBytes,
    required double progress,
    String? now,
  }) async {
    final db = await database;
    final timestamp = now ?? utcNowIso();
    final values = <String, dynamic>{
      'bytesDownloaded': bytesDownloaded,
      'progress': progress,
      'updatedAt': timestamp,
    };
    if (totalBytes != null && totalBytes > 0) {
      values['totalBytes'] = totalBytes;
      values['fileSize'] = totalBytes;
    }
    return db.update('downloads', values, where: 'id = ?', whereArgs: [id]);
  }

  /// Mark a specific download as interrupted.
  Future<int> markInterrupted(String id, {String? now}) async {
    final db = await database;
    final timestamp = now ?? utcNowIso();
    return db.update(
      'downloads',
      {
        'status': 'interrupted',
        'updatedAt': timestamp,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<DownloadRecord>> getAll({
    String? search,
    String? statusFilter,
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    if (search != null && search.isNotEmpty && _fts4Enabled) {
      final escaped = search.replaceAll('"', '""');
      final match = '"$escaped"';
      final where = <String>['downloads_fts MATCH ?'];
      final args = <dynamic>[match];
      if (statusFilter != null) {
        where.add('d.status = ?');
        args.add(statusFilter);
      }
      final limitSql = limit != null ? ' LIMIT ?' : (offset != null ? ' LIMIT -1' : '');
      final offsetSql = offset == null ? '' : ' OFFSET ?';
      if (limit != null) args.add(limit);
      if (offset != null) args.add(offset);
      try {
        final rows = await db.rawQuery('''
          SELECT d.* FROM downloads d
          JOIN downloads_fts f ON f.docid = d.rowid
          WHERE ${where.join(' AND ')}
          ORDER BY d.timestamp DESC$limitSql$offsetSql
        ''', args);
        return rows.map((r) => DownloadRecord.fromMap(r)).toList();
      } catch (_) {
        _fts4Enabled = false;
      }
    }

    final where = <String>[];
    final args = <dynamic>[];
    if (search != null && search.isNotEmpty) {
      where.add('(title LIKE ? OR url LIKE ?)');
      args.addAll(['%$search%', '%$search%']);
    }
    if (statusFilter != null) {
      where.add('status = ?');
      args.add(statusFilter);
    }
    final rows = await db.query(
      'downloads',
      where: where.isNotEmpty ? where.join(' AND ') : null,
      whereArgs: args.isNotEmpty ? args : null,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) => DownloadRecord.fromMap(r)).toList();
  }

  Future<DownloadRecord?> getById(String id) async {
    final db = await database;
    final rows = await db.query('downloads', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return DownloadRecord.fromMap(rows.first);
  }

  /// Completed records for pre-flight duplicate / overwrite checks.
  /// Video-id matching happens in Dart (history_guard) — no migration.
  Future<List<DownloadRecord>> getCompleted({int limit = 500}) async {
    final db = await database;
    final rows = await db.query(
      'downloads',
      where: 'status = ?',
      whereArgs: ['completed'],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map((r) => DownloadRecord.fromMap(r)).toList();
  }

  Future<int> clearAll() async {
    final db = await database;
    return db.delete('downloads');
  }

  /// Pending records for background scheduler execution or queued startup.
  Future<List<DownloadRecord>> getPending({int limit = 50}) async {
    final db = await database;
    final rows = await db.query(
      'downloads',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'queuePosition ASC, timestamp ASC',
      limit: limit,
    );
    return rows.map((r) => DownloadRecord.fromMap(r)).toList();
  }

  /// Seen video IDs recorded for a given observed source URL.
  Future<Set<String>> getSeenSourceVideoIds(String sourceUrl) async {
    final db = await database;
    final rows = await db.query(
      'seen_source_videos',
      columns: ['video_id'],
      where: 'source_url = ?',
      whereArgs: [sourceUrl],
    );
    return rows.map((r) => r['video_id'] as String).toSet();
  }

  /// Bulk records video IDs as seen for an observed source URL.
  Future<void> recordSeenSourceVideos(
    String sourceUrl,
    List<String> videoIds, {
    String? now,
  }) async {
    if (videoIds.isEmpty) return;
    final db = await database;
    final timestamp = now ?? utcNowIso();
    final batch = db.batch();
    for (final vid in videoIds) {
      batch.insert(
        'seen_source_videos',
        {
          'source_url': sourceUrl,
          'video_id': vid,
          'seen_at': timestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Returns only candidate video IDs that have not yet been seen for this source URL.
  Future<List<String>> filterNewSourceVideoIds(
    String sourceUrl,
    List<String> candidateVideoIds,
  ) async {
    if (candidateVideoIds.isEmpty) return const [];
    final seen = await getSeenSourceVideoIds(sourceUrl);
    final result = <String>[];
    final added = <String>{};
    for (final id in candidateVideoIds) {
      if (!seen.contains(id) && added.add(id)) {
        result.add(id);
      }
    }
    return result;
  }

  /// Clears seen records (optionally for a specific source URL, or all).
  Future<int> clearSeenSourceVideos({String? sourceUrl}) async {
    final db = await database;
    if (sourceUrl != null) {
      return db.delete(
        'seen_source_videos',
        where: 'source_url = ?',
        whereArgs: [sourceUrl],
      );
    }
    return db.delete('seen_source_videos');
  }
}
