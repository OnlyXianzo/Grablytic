import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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
  }) : timestamp = timestamp ?? DateTime.now().toIso8601String();

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
        'configJson': configJson,
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
        configJson: map['configJson'] as String?,
        queuePosition: map['queuePosition'] as int?,
        attempts: map['attempts'] as int? ?? 0,
        lastErrorType: map['lastErrorType'] as String?,
        lastErrorMessage: map['lastErrorMessage'] as String?,
        bytesDownloaded: map['bytesDownloaded'] as int? ?? 0,
        totalBytes: map['totalBytes'] as int?,
        updatedAt: map['updatedAt'] as String?,
      );

  DownloadRecord copyWith({
    String? id,
    String? url,
    String? title,
    String? platform,
    String? format,
    String? quality,
    int? fileSize,
    String? filePath,
    String? status,
    double? progress,
    String? timestamp,
    String? thumbnailUrl,
    String? thumbnailPath,
    String? configJson,
    int? queuePosition,
    int? attempts,
    String? lastErrorType,
    String? lastErrorMessage,
    int? bytesDownloaded,
    int? totalBytes,
    String? updatedAt,
  }) =>
      DownloadRecord(
        id: id ?? this.id,
        url: url ?? this.url,
        title: title ?? this.title,
        platform: platform ?? this.platform,
        format: format ?? this.format,
        quality: quality ?? this.quality,
        fileSize: fileSize ?? this.fileSize,
        filePath: filePath ?? this.filePath,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        timestamp: timestamp ?? this.timestamp,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
        configJson: configJson ?? this.configJson,
        queuePosition: queuePosition ?? this.queuePosition,
        attempts: attempts ?? this.attempts,
        lastErrorType: lastErrorType ?? this.lastErrorType,
        lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
        bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
        totalBytes: totalBytes ?? this.totalBytes,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => toMap();
  factory DownloadRecord.fromJson(String source) =>
      DownloadRecord.fromMap(jsonDecode(source) as Map<String, dynamic>);
}

class DownloadHistoryDb {
  DownloadHistoryDb._();
  static final DownloadHistoryDb instance = DownloadHistoryDb._();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'truestream.db');
    return openDatabase(
      path,
      version: 3,
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
      },
    );
  }

  Future<int> insert(DownloadRecord record) async {
    final db = await database;
    return db.insert('downloads', record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
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

  /// Sweeps any lingering active/queued downloads in SQLite to 'interrupted'
  /// on process death / app startup. Returns the number of affected rows.
  Future<int> sweepActiveToInterrupted({String? now}) async {
    final db = await database;
    final timestamp = now ?? DateTime.now().toIso8601String();
    return db.update(
      'downloads',
      {
        'status': 'interrupted',
        'updatedAt': timestamp,
      },
      where: 'status IN (?, ?)',
      whereArgs: ['downloading', 'queued'],
    );
  }

  /// Interrupted records for startup recovery sweep / retry.
  Future<List<DownloadRecord>> getInterrupted({int limit = 50}) async {
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
    final timestamp = now ?? DateTime.now().toIso8601String();
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
    final timestamp = now ?? DateTime.now().toIso8601String();
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
}
