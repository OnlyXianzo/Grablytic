import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/log_entry.dart';
import 'package:grablytic/core/utils/log_buffer.dart';

LogEntry _entry({
  DateTime? timestamp,
  LogLevel level = LogLevel.info,
  String logger = 'test',
  String message = 'test message',
  String source = 'ui',
  String? exception,
  String? downloadId,
}) {
  return LogEntry(
    timestamp: timestamp ?? DateTime(2026, 7, 6),
    level: level,
    logger: logger,
    message: message,
    source: source,
    exception: exception,
    downloadId: downloadId,
  );
}

void main() {
  group('LogBuffer basics', () {
    test('starts empty', () {
      final buffer = LogBuffer();
      expect(buffer.entries, isEmpty);
    });

    test('adding log entries stores them', () {
      final buffer = LogBuffer();
      buffer.add(_entry(message: 'first'));
      buffer.add(_entry(message: 'second'));

      expect(buffer.entries, hasLength(2));
      expect(buffer.entries[0].message, 'first');
      expect(buffer.entries[1].message, 'second');
    });

    test('entries getter returns an unmodifiable list', () {
      final buffer = LogBuffer();
      buffer.add(_entry());

      expect(() => buffer.entries.add(_entry()), throwsUnsupportedError);
      expect(() => buffer.entries.removeAt(0), throwsUnsupportedError);
    });

    test('stream emits each added entry', () async {
      final buffer = LogBuffer();
      final emitted = <LogEntry>[];

      buffer.stream.listen(emitted.add);
      buffer.add(_entry(message: 'a'));
      buffer.add(_entry(message: 'b'));

      // Pump microtasks so the broadcast stream delivers synchronously.
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(2));
      expect(emitted[0].message, 'a');
      expect(emitted[1].message, 'b');
    });
  });

  group('circular buffer eviction', () {
    test('removes oldest entry when maxEntries is exceeded', () {
      final buffer = LogBuffer(maxEntries: 3);
      buffer.add(_entry(message: '1'));
      buffer.add(_entry(message: '2'));
      buffer.add(_entry(message: '3'));
      expect(buffer.entries, hasLength(3));

      buffer.add(_entry(message: '4'));
      expect(buffer.entries, hasLength(3));
      expect(buffer.entries.map((e) => e.message).toList(), equals(['2', '3', '4']));
    });

    test('evicts multiple entries when many are added', () {
      final buffer = LogBuffer(maxEntries: 5);
      for (var i = 1; i <= 10; i++) {
        buffer.add(_entry(message: '$i'));
      }

      expect(buffer.entries, hasLength(5));
      expect(buffer.entries.first.message, '6');
      expect(buffer.entries.last.message, '10');
    });
  });

  group('setMinLevel filter', () {
    test('allows entries at or above the minimum level', () {
      final buffer = LogBuffer();
      buffer.setMinLevel(LogLevel.warn);

      buffer.add(_entry(level: LogLevel.debug, message: 'debug'));
      buffer.add(_entry(level: LogLevel.info, message: 'info'));
      buffer.add(_entry(level: LogLevel.warn, message: 'warn'));
      buffer.add(_entry(level: LogLevel.error, message: 'error'));
      buffer.add(_entry(level: LogLevel.fatal, message: 'fatal'));

      expect(buffer.entries, hasLength(3));
      expect(buffer.entries.map((e) => e.message).toList(),
          equals(['warn', 'error', 'fatal']));
    });

    test('allows all levels at LogLevel.debug', () {
      final buffer = LogBuffer();
      buffer.setMinLevel(LogLevel.debug);

      buffer.add(_entry(level: LogLevel.debug));
      buffer.add(_entry(level: LogLevel.fatal));

      expect(buffer.entries, hasLength(2));
    });

    test('does not store entries below min level', () {
      final buffer = LogBuffer();
      buffer.setMinLevel(LogLevel.error);

      buffer.add(_entry(level: LogLevel.info));
      buffer.add(_entry(level: LogLevel.error));
      buffer.add(_entry(level: LogLevel.fatal));

      expect(buffer.entries, hasLength(2));
    });
  });

  group('setTagFilter', () {
    test('stores only entries whose logger contains the tag', () {
      final buffer = LogBuffer();
      buffer.setTagFilter('http');

      buffer.add(_entry(logger: 'http.client', message: 'req'));
      buffer.add(_entry(logger: 'http.server', message: 'resp'));
      buffer.add(_entry(logger: 'db.conn', message: 'query'));

      expect(buffer.entries, hasLength(2));
      expect(buffer.entries.every((e) => e.logger.contains('http')), isTrue);
    });

    test('setting tag to null disables filtering', () {
      final buffer = LogBuffer();
      buffer.setTagFilter('http');
      buffer.add(_entry(logger: 'db.conn', message: 'query'));
      expect(buffer.entries, isEmpty);

      buffer.setTagFilter(null);
      buffer.add(_entry(logger: 'db.conn', message: 'query'));
      expect(buffer.entries, hasLength(1));
    });
  });

  group('setSearchFilter', () {
    test('stores only entries whose message contains the query (case-insensitive)', () {
      final buffer = LogBuffer();
      buffer.setSearchFilter('timeout');

      buffer.add(_entry(message: 'request timeout after 30s'));
      buffer.add(_entry(message: 'connection closed'));
      buffer.add(_entry(message: 'TimEOut occurred'));

      expect(buffer.entries, hasLength(2));
    });

    test('setting search to null disables filtering', () {
      final buffer = LogBuffer();
      buffer.setSearchFilter('error');
      buffer.add(_entry(message: 'hello'));
      expect(buffer.entries, isEmpty);

      buffer.setSearchFilter(null);
      buffer.add(_entry(message: 'hello'));
      expect(buffer.entries, hasLength(1));
    });
  });

  group('setSourceFilter', () {
    test('stores only entries matching the source', () {
      final buffer = LogBuffer();
      buffer.setSourceFilter('engine');

      buffer.add(_entry(source: 'engine', message: 'e1'));
      buffer.add(_entry(source: 'ui', message: 'u1'));
      buffer.add(_entry(source: 'engine', message: 'e2'));
      buffer.add(_entry(source: 'ui', message: 'u2'));

      expect(buffer.entries, hasLength(2));
      expect(buffer.entries.every((e) => e.source == 'engine'), isTrue);
    });

    test('setting source to null disables filtering', () {
      final buffer = LogBuffer();
      buffer.setSourceFilter('engine');
      buffer.add(_entry(source: 'ui'));
      expect(buffer.entries, isEmpty);

      buffer.setSourceFilter(null);
      buffer.add(_entry(source: 'ui'));
      expect(buffer.entries, hasLength(1));
    });
  });

  group('combined add-time filters', () {
    test('applies minLevel, tag, search, and source simultaneously', () {
      final buffer = LogBuffer();
      buffer.setMinLevel(LogLevel.warn);
      buffer.setTagFilter('http');
      buffer.setSearchFilter('fail');
      buffer.setSourceFilter('engine');

      buffer.add(_entry(level: LogLevel.warn, logger: 'http.client',
          message: 'request failed', source: 'engine'));
      buffer.add(_entry(level: LogLevel.info, logger: 'http.client',
          message: 'request failed', source: 'engine'));
      buffer.add(_entry(level: LogLevel.warn, logger: 'db',
          message: 'connection failed', source: 'engine'));
      buffer.add(_entry(level: LogLevel.warn, logger: 'http.client',
          message: 'success', source: 'engine'));
      buffer.add(_entry(level: LogLevel.warn, logger: 'http.client',
          message: 'request failed', source: 'ui'));

      expect(buffer.entries, hasLength(1));
      expect(buffer.entries.single.message, 'request failed');
    });
  });

  group('filtered()', () {
    late LogBuffer buffer;

    setUp(() {
      buffer = LogBuffer(maxEntries: 100);
      buffer.add(_entry(level: LogLevel.debug, logger: 'http.client',
          message: 'starting request', source: 'engine'));
      buffer.add(_entry(level: LogLevel.info, logger: 'http.client',
          message: '200 OK', source: 'engine'));
      buffer.add(_entry(level: LogLevel.warn, logger: 'http.client',
          message: 'slow response', source: 'engine'));
      buffer.add(_entry(level: LogLevel.error, logger: 'http.client',
          message: 'connection timeout', source: 'engine'));
      buffer.add(_entry(level: LogLevel.info, logger: 'ui',
          message: 'paint finished', source: 'ui'));
      buffer.add(_entry(level: LogLevel.error, logger: 'ui',
          message: 'widget build failed', source: 'ui'));
    });

    test('returns all entries when no filters are applied', () {
      expect(buffer.filtered(), hasLength(6));
    });

    test('filters by minLevel', () {
      expect(buffer.filtered(minLevel: LogLevel.warn), hasLength(3));
      expect(buffer.filtered(minLevel: LogLevel.error), hasLength(2));
      expect(buffer.filtered(minLevel: LogLevel.fatal), isEmpty);
    });

    test('filters by tag (logger contains)', () {
      expect(buffer.filtered(tag: 'ui'), hasLength(2));
      expect(buffer.filtered(tag: 'http'), hasLength(4));
      expect(buffer.filtered(tag: 'nonexistent'), isEmpty);
    });

    test('filters by search (message contains, case-insensitive)', () {
      expect(buffer.filtered(search: 'timeout'), hasLength(1));
      expect(buffer.filtered(search: 'failed'), hasLength(1));
      expect(buffer.filtered(search: 'STARTING'), hasLength(1));
    });

    test('filters by source', () {
      expect(buffer.filtered(source: 'engine'), hasLength(4));
      expect(buffer.filtered(source: 'ui'), hasLength(2));
    });

    test('combines minLevel and source filter', () {
      final result = buffer.filtered(minLevel: LogLevel.warn, source: 'engine');
      expect(result, hasLength(2));
      expect(result.every((e) => e.source == 'engine'), isTrue);
      expect(result.every((e) => e.level.index >= LogLevel.warn.index), isTrue);
    });

    test('combines all filter parameters', () {
      final result = buffer.filtered(
        minLevel: LogLevel.info,
        tag: 'http',
        search: 'response',
        source: 'engine',
      );
      expect(result, hasLength(1));
      expect(result.single.message, 'slow response');
    });

    test('limit returns at most N entries from the end', () {
      expect(buffer.filtered(limit: 3), hasLength(3));
      expect(buffer.filtered(limit: 3).last.message, 'widget build failed');

      // limit larger than result returns all
      expect(buffer.filtered(limit: 100), hasLength(6));
    });

    test('limit combined with filters', () {
      final result = buffer.filtered(minLevel: LogLevel.error, limit: 1);
      expect(result, hasLength(1));
      expect(result.single.message, 'widget build failed');
    });

    test('filtered returns entries despite add-time filter settings', () {
      // setMinLevel on the buffer itself — entries already in buffer
      // were added before the filter change, so they remain.
      buffer.setMinLevel(LogLevel.warn);

      // filtered() should still see all 6 stored entries, applying its own
      // minLevel parameter (not the buffer's _minLevel).
      expect(buffer.filtered(minLevel: LogLevel.debug), hasLength(6));
    });
  });

  group('clear', () {
    test('empties the entries list', () {
      final buffer = LogBuffer();
      buffer.add(_entry());
      buffer.add(_entry());
      expect(buffer.entries, isNotEmpty);

      buffer.clear();
      expect(buffer.entries, isEmpty);
    });

    test('does not close the stream', () async {
      final buffer = LogBuffer();
      buffer.add(_entry(message: 'before'));
      buffer.clear();

      var gotNewEntry = false;
      buffer.stream.listen((_) => gotNewEntry = true);
      buffer.add(_entry(message: 'after'));

      await Future<void>.delayed(Duration.zero);
      expect(gotNewEntry, isTrue);
    });
  });

  group('dispose', () {
    test('closes the stream', () async {
      final buffer = LogBuffer();
      buffer.dispose();

      expect(
        () => buffer.add(_entry()),
        throwsA(isA<Error>()),
      );
    });

    test('multiple dispose calls do not throw', () {
      final buffer = LogBuffer();
      buffer.dispose();
      expect(() => buffer.dispose(), returnsNormally);
    });
  });

  group('filtered with downloadId', () {
    test('returns only entries matching the specified downloadId', () {
      final buffer = LogBuffer();
      buffer.add(_entry(message: 'dl1-start', downloadId: 'dl-1'));
      buffer.add(_entry(message: 'dl2-start', downloadId: 'dl-2'));
      buffer.add(_entry(message: 'global-log'));
      buffer.add(_entry(message: 'dl1-progress', downloadId: 'dl-1'));

      final dl1Entries = buffer.filtered(downloadId: 'dl-1');
      expect(dl1Entries, hasLength(2));
      expect(dl1Entries.map((e) => e.message).toList(),
          equals(['dl1-start', 'dl1-progress']));

      final dl2Entries = buffer.filtered(downloadId: 'dl-2');
      expect(dl2Entries, hasLength(1));
      expect(dl2Entries.single.message, equals('dl2-start'));

      final nonExistent = buffer.filtered(downloadId: 'non-existent');
      expect(nonExistent, isEmpty);
    });

    test('combines downloadId filter with minLevel and search', () {
      final buffer = LogBuffer();
      buffer.add(_entry(
          level: LogLevel.info,
          message: 'dl1 info msg',
          downloadId: 'dl-1'));
      buffer.add(_entry(
          level: LogLevel.warn,
          message: 'dl1 warn failure',
          downloadId: 'dl-1'));
      buffer.add(_entry(
          level: LogLevel.error,
          message: 'dl1 error crash',
          downloadId: 'dl-1'));
      buffer.add(_entry(
          level: LogLevel.error,
          message: 'dl2 error crash',
          downloadId: 'dl-2'));

      final res = buffer.filtered(
        downloadId: 'dl-1',
        minLevel: LogLevel.warn,
        search: 'crash',
      );
      expect(res, hasLength(1));
      expect(res.single.message, equals('dl1 error crash'));
    });
  });

  group('getEntriesForDownload', () {
    test('returns empty list for unknown downloadId', () {
      final buffer = LogBuffer();
      expect(buffer.getEntriesForDownload('unknown'), isEmpty);
    });

    test('returns scoped entries for downloadId', () {
      final buffer = LogBuffer();
      buffer.add(_entry(message: 'a', downloadId: 'dl-1'));
      buffer.add(_entry(message: 'b', downloadId: 'dl-2'));
      buffer.add(_entry(message: 'c', downloadId: 'dl-1'));

      final entries = buffer.getEntriesForDownload('dl-1');
      expect(entries, hasLength(2));
      expect(entries.map((e) => e.message).toList(), equals(['a', 'c']));
    });

    test('respects minLevel parameter', () {
      final buffer = LogBuffer();
      buffer.add(_entry(
          level: LogLevel.debug, message: 'dbg', downloadId: 'dl-1'));
      buffer.add(_entry(
          level: LogLevel.info, message: 'inf', downloadId: 'dl-1'));
      buffer.add(_entry(
          level: LogLevel.warn, message: 'wrn', downloadId: 'dl-1'));

      final entries =
          buffer.getEntriesForDownload('dl-1', minLevel: LogLevel.info);
      expect(entries, hasLength(2));
      expect(entries.map((e) => e.message).toList(), equals(['inf', 'wrn']));
    });

    test('respects limit parameter returning latest entries', () {
      final buffer = LogBuffer();
      for (var i = 1; i <= 5; i++) {
        buffer.add(_entry(message: 'msg-$i', downloadId: 'dl-1'));
      }

      final entries = buffer.getEntriesForDownload('dl-1', limit: 3);
      expect(entries, hasLength(3));
      expect(entries.map((e) => e.message).toList(),
          equals(['msg-3', 'msg-4', 'msg-5']));
    });
  });

  group('per-download eviction and retention', () {
    test('enforces maxEntriesPerDownload capping per download', () {
      final buffer = LogBuffer(maxEntriesPerDownload: 3);
      for (var i = 1; i <= 5; i++) {
        buffer.add(_entry(message: 'dl1-$i', downloadId: 'dl-1'));
      }
      buffer.add(_entry(message: 'dl2-1', downloadId: 'dl-2'));

      final dl1Entries = buffer.getEntriesForDownload('dl-1');
      expect(dl1Entries, hasLength(3));
      expect(dl1Entries.map((e) => e.message).toList(),
          equals(['dl1-3', 'dl1-4', 'dl1-5']));

      final dl2Entries = buffer.getEntriesForDownload('dl-2');
      expect(dl2Entries, hasLength(1));
      expect(dl2Entries.single.message, equals('dl2-1'));
    });

    test('enforces maxRetainedDownloads via LRU eviction', () {
      final buffer = LogBuffer(maxRetainedDownloads: 2);
      buffer.add(_entry(message: 'dl1-1', downloadId: 'dl-1'));
      buffer.add(_entry(message: 'dl2-1', downloadId: 'dl-2'));

      expect(buffer.getEntriesForDownload('dl-1'), isNotEmpty);
      expect(buffer.getEntriesForDownload('dl-2'), isNotEmpty);

      // Adding a 3rd download exceeds maxRetainedDownloads (2), evicting oldest (dl-1)
      buffer.add(_entry(message: 'dl3-1', downloadId: 'dl-3'));

      expect(buffer.getEntriesForDownload('dl-1'), isEmpty);
      expect(buffer.getEntriesForDownload('dl-2'), isNotEmpty);
      expect(buffer.getEntriesForDownload('dl-3'), isNotEmpty);
    });

    test('retains download logs even when global buffer overflows', () {
      final buffer = LogBuffer(
        maxEntries: 3,
        maxEntriesPerDownload: 50,
        maxRetainedDownloads: 10,
      );

      // Add 2 logs for download-1
      buffer.add(_entry(message: 'dl1-start', downloadId: 'dl-1'));
      buffer.add(_entry(message: 'dl1-done', downloadId: 'dl-1'));

      // Overflow global buffer with 5 generic logs
      for (var i = 1; i <= 5; i++) {
        buffer.add(_entry(message: 'global-$i'));
      }

      // Global buffer only has the last 3 entries
      expect(buffer.entries, hasLength(3));
      expect(buffer.entries.map((e) => e.message).toList(),
          equals(['global-3', 'global-4', 'global-5']));

      // But download-1 entries are still retained!
      final dl1Logs = buffer.getEntriesForDownload('dl-1');
      expect(dl1Logs, hasLength(2));
      expect(dl1Logs.map((e) => e.message).toList(),
          equals(['dl1-start', 'dl1-done']));

      // And filtered(downloadId: 'dl-1') retrieves them
      final filteredDl1 = buffer.filtered(downloadId: 'dl-1');
      expect(filteredDl1, hasLength(2));
      expect(filteredDl1.map((e) => e.message).toList(),
          equals(['dl1-start', 'dl1-done']));
    });
  });

  group('streamForDownload', () {
    test('emits only entries matching downloadId', () async {
      final buffer = LogBuffer();
      final emitted = <LogEntry>[];
      final sub = buffer.streamForDownload('dl-stream').listen(emitted.add);

      buffer.add(_entry(message: 'ignore me'));
      buffer.add(_entry(message: 'other dl', downloadId: 'dl-other'));
      buffer.add(_entry(message: 'stream entry 1', downloadId: 'dl-stream'));
      buffer.add(_entry(message: 'stream entry 2', downloadId: 'dl-stream'));

      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(2));
      expect(emitted[0].message, equals('stream entry 1'));
      expect(emitted[1].message, equals('stream entry 2'));

      await sub.cancel();
    });
  });

  group('clearDownload and clear', () {
    test('clearDownload removes only the targeted download entries', () {
      final buffer = LogBuffer();
      buffer.add(_entry(message: 'dl1', downloadId: 'dl-1'));
      buffer.add(_entry(message: 'dl2', downloadId: 'dl-2'));

      expect(buffer.getEntriesForDownload('dl-1'), hasLength(1));
      expect(buffer.getEntriesForDownload('dl-2'), hasLength(1));

      buffer.clearDownload('dl-1');

      expect(buffer.getEntriesForDownload('dl-1'), isEmpty);
      expect(buffer.getEntriesForDownload('dl-2'), hasLength(1));
    });

    test('clear empties both global entries and per-download storage', () {
      final buffer = LogBuffer();
      buffer.add(_entry(message: 'dl1', downloadId: 'dl-1'));
      buffer.add(_entry(message: 'global'));

      expect(buffer.entries, hasLength(2));
      expect(buffer.getEntriesForDownload('dl-1'), hasLength(1));

      buffer.clear();

      expect(buffer.entries, isEmpty);
      expect(buffer.getEntriesForDownload('dl-1'), isEmpty);
    });
  });
}
