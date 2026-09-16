import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/log_entry.dart';
import 'package:grablytic/core/utils/log_buffer.dart';
import 'package:grablytic/core/utils/log_ingester.dart';

void main() {
  group('LogIngester', () {
    late LogBuffer buffer;
    late LogIngester ingester;
    late StreamController<Map<String, dynamic>> controller;

    setUp(() {
      buffer = LogBuffer();
      ingester = LogIngester(buffer);
      controller = StreamController<Map<String, dynamic>>.broadcast();
    });

    tearDown(() async {
      await controller.close();
    });

    group('start', () {
      test('subscribes to the engine log stream', () async {
        expect(controller.hasListener, isFalse);

        ingester.start(controller.stream);

        expect(controller.hasListener, isTrue);
      });

      test('handles multiple events in sequence', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': '2026-07-06T10:00:00',
          'level': 'INFO',
          'logger': 'engine',
          'message': 'startup complete',
        });
        controller.add({
          'type': 'log',
          'ts': '2026-07-06T10:00:01',
          'level': 'ERROR',
          'logger': 'downloader',
          'message': 'fetch failed',
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, hasLength(2));
        expect(buffer.entries[0].message, 'startup complete');
        expect(buffer.entries[1].message, 'fetch failed');
        expect(buffer.entries[1].level, LogLevel.error);
      });
    });

    group('_handleLogEvent', () {
      test('parses type:log events and adds them to the buffer', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': '2026-07-06T12:34:56.789',
          'level': 'WARN',
          'logger': 'extractor',
          'message': 'missing audio track',
          'context': {'track_id': 3},
          'trace_id': 'tr-007',
          'duration_ms': 890,
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, hasLength(1));
        final entry = buffer.entries.single;
        expect(entry.timestamp, DateTime(2026, 7, 6, 12, 34, 56, 789));
        expect(entry.level, LogLevel.warn);
        expect(entry.logger, 'extractor');
        expect(entry.message, 'missing audio track');
        expect(entry.context, {'track_id': 3});
        expect(entry.traceId, 'tr-007');
        expect(entry.durationMs, 890);
        expect(entry.source, 'engine');
      });

      test('applies buffer filters set before ingestion', () async {
        buffer.setMinLevel(LogLevel.error);
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': '2026-07-06T00:00:00',
          'message': 'not important',
        });
        controller.add({
          'type': 'log',
          'ts': '2026-07-06T00:00:01',
          'level': 'ERROR',
          'message': 'real problem',
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, hasLength(1));
        expect(buffer.entries.single.message, 'real problem');
      });

      test('ingests engine JSON with download_id and correlates to scoped buffer', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': '2026-07-06T12:00:00',
          'level': 'INFO',
          'logger': 'downloader',
          'message': 'download started',
          'download_id': 'dl-ingest-001',
        });
        controller.add({
          'type': 'log',
          'ts': '2026-07-06T12:00:01',
          'level': 'INFO',
          'logger': 'downloader',
          'message': 'other download started',
          'download_id': 'dl-ingest-002',
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, hasLength(2));
        expect(buffer.getEntriesForDownload('dl-ingest-001'), hasLength(1));
        expect(buffer.getEntriesForDownload('dl-ingest-001').single.message,
            equals('download started'));
        expect(buffer.getEntriesForDownload('dl-ingest-001').single.downloadId,
            equals('dl-ingest-001'));
        expect(buffer.filtered(downloadId: 'dl-ingest-001'), hasLength(1));
      });

      test('correlates download_id from context and extra maps', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': '2026-07-06T12:00:00',
          'level': 'INFO',
          'logger': 'downloader',
          'message': 'context download',
          'context': {'download_id': 'dl-ctx-99'},
        });
        controller.add({
          'type': 'log',
          'ts': '2026-07-06T12:00:01',
          'level': 'INFO',
          'logger': 'downloader',
          'message': 'extra download',
          'extra': {'download_id': 'dl-extra-88'},
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.getEntriesForDownload('dl-ctx-99'), hasLength(1));
        expect(buffer.getEntriesForDownload('dl-ctx-99').single.message,
            equals('context download'));
        expect(buffer.getEntriesForDownload('dl-extra-88'), hasLength(1));
        expect(buffer.getEntriesForDownload('dl-extra-88').single.message,
            equals('extra download'));
      });
    });

    group('debug flood gate (Loop-1 hang fix)', () {
      test('DEBUG engine entries are file-only, never buffered', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': '2026-07-06T12:00:00',
          'level': 'DEBUG',
          'logger': 'downloader',
          'message': '[download] 43.2% of 3.79GiB at 10MiB/s',
          'download_id': 'dl-debug-1',
        });
        controller.add({
          'type': 'log',
          'ts': '2026-07-06T12:00:01',
          'level': 'INFO',
          'logger': 'downloader',
          'message': 'milestone',
          'download_id': 'dl-debug-1',
        });

        await Future<void>.delayed(Duration.zero);

        // UI buffer (overlays/sheets/lists rebuild off this) sees INFO only.
        expect(buffer.entries, hasLength(1));
        expect(buffer.entries.single.message, 'milestone');
        expect(buffer.getEntriesForDownload('dl-debug-1'), hasLength(1));
      });
    });

    group('malformed events', () {      test('are silently dropped (missing ts field)', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'message': 'no timestamp',
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, isEmpty);
      });

      test('are silently dropped (null ts field)', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': null,
          'message': 'null timestamp',
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, isEmpty);
      });

      test('are silently dropped (invalid date string)', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': 'not-a-date',
          'message': 'bad date',
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, isEmpty);
      });
    });

    group('non-log events', () {
      test('are ignored when type is not "log"', () async {
        ingester.start(controller.stream);

        controller.add({'type': 'progress', 'percent': 75});
        controller.add({'type': 'status', 'state': 'running'});
        controller.add({'type': 'result', 'success': true});

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, isEmpty);
      });

      test('are ignored when type field is absent', () async {
        ingester.start(controller.stream);

        controller.add({'message': 'hello'});

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, isEmpty);
      });
    });

    group('secret redaction (engine-origin entries)', () {
      test('redacts tokens, sigs and proxy userinfo in message+exception', () async {
        ingester.start(controller.stream);

        controller.add({
          'type': 'log',
          'ts': '2026-07-06T12:00:00',
          'level': 'INFO',
          'logger': 'downloader',
          'message': 'fetch https://vid.test/watch?v=1&sig=S3CR3T with token=abc123',
          'exception': 'proxy auth failed for http://user:p4ss@proxy.test:8080',
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, hasLength(1));
        final entry = buffer.entries.single;
        expect(entry.message, isNot(contains('S3CR3T')));
        expect(entry.message, isNot(contains('abc123')));
        expect(entry.message, contains('***REDACTED***'));
        expect(entry.exception, isNot(contains('p4ss')));
      });
    });

    group('stop', () {
      test('cancels the subscription', () async {
        ingester.start(controller.stream);
        expect(controller.hasListener, isTrue);

        ingester.stop();

        // Give the cancellation event time to propagate.
        await Future<void>.delayed(Duration.zero);

        expect(controller.hasListener, isFalse);
      });

      test('subsequent events are not processed after stop', () async {
        ingester.start(controller.stream);
        ingester.stop();

        controller.add({
          'type': 'log',
          'ts': '2026-07-06T00:00:00',
          'message': 'should not appear',
        });

        await Future<void>.delayed(Duration.zero);

        expect(buffer.entries, isEmpty);
      });

      test('is safe to call without a prior start', () {
        expect(() => ingester.stop(), returnsNormally);
      });

      test('is safe to call multiple times', () {
        ingester.start(controller.stream);
        ingester.stop();
        expect(() => ingester.stop(), returnsNormally);
      });
    });
  });
}
