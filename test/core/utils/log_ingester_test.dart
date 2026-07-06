import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/utils/log_entry.dart';
import 'package:truestream/core/utils/log_buffer.dart';
import 'package:truestream/core/utils/log_ingester.dart';

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
    });

    group('malformed events', () {
      test('are silently dropped (missing ts field)', () async {
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
