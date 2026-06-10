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
      version: 1,
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
            thumbnailUrl TEXT
          )
        ''');
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

    final whereStr = where.isNotEmpty ? 'WHERE ${where.join(' AND ')}' : '';
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

  Future<int> clearAll() async {
    final db = await database;
    return db.delete('downloads');
  }
}
