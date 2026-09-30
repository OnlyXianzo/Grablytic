import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:grablytic/core/database/download_history_db.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/batch_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

DownloadRecord _completed(String url) => DownloadRecord(
      id: 'rec-${url.hashCode}',
      url: url,
      title: 'already have',
      status: 'completed',
    );

class _RecordingEngine extends MockEngineService {
  final List<String> urls = [];

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    urls.add(url);
    return {'success': true};
  }
}

Future<ProviderContainer> _container(_RecordingEngine engine) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      engineProvider.overrideWithValue(engine),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Waits until the batch queue drains (or [timeout] elapses).
Future<void> _drain(ProviderContainer container) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (container.read(batchProvider).isRunning) {
    if (DateTime.now().isAfter(deadline)) break;
    await Future.delayed(const Duration(milliseconds: 20));
  }
  // Let trailing .then() continuations settle.
  await Future.delayed(const Duration(milliseconds: 50));
}

void main() {
  group('markAlreadyHaveItems (pure)', () {
    final dup = _completed('https://www.youtube.com/watch?v=ABC123_-xY');

    test('marks canonical dup completed with suffix, leaves fresh pending',
        () {
      final items = [
        const BatchItem(
            url: 'https://youtu.be/ABC123_-xY', title: 'same video short'),
        const BatchItem(url: 'https://x.test/fresh', title: 'fresh video'),
      ];
      final out = markAlreadyHaveItems(items, [dup]);
      expect(out[0].status, BatchItemStatus.completed);
      expect(out[0].progress, 1.0);
      expect(out[0].title, 'same video short (already have)');
      expect(out[1].status, BatchItemStatus.pending);
      expect(out[1].title, 'fresh video');
    });

    test('ignores non-completed records and non-pending items', () {
      final pending = _completed('https://x.test/a').copyWith(status: 'pending');
      final items = [
        const BatchItem(url: 'https://x.test/a', title: 'a'),
        const BatchItem(
            url: 'https://x.test/a',
            title: 'b',
            status: BatchItemStatus.failed),
      ];
      final out = markAlreadyHaveItems(items, [pending]);
      expect(out[0].status, BatchItemStatus.pending);
      expect(out[1].status, BatchItemStatus.failed);
      expect(out[1].title, 'b');
    });

    test('idempotent: never double-suffixes', () {
      const item = BatchItem(
          url: 'https://youtu.be/ABC123_-xY', title: 'v (already have)');
      final once = markAlreadyHaveItems([item], [dup]);
      expect(once.single.title, 'v (already have)');
    });

    test('empty inputs pass through', () {
      expect(markAlreadyHaveItems(const [], [dup]), isEmpty);
      const item = BatchItem(url: 'https://x.test/a', title: 'a');
      expect(markAlreadyHaveItems([item], const []).single.status,
          BatchItemStatus.pending);
    });
  });

  group('BatchNotifier skipExisting pre-filter', () {
    late Directory tmp;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      tmp = await Directory.systemTemp.createTemp('batch_dedupe');
      DownloadHistoryDb.dbPathForTesting = p.join(tmp.path, 'test.db');
    });

    tearDown(() async {
      await DownloadHistoryDb.instance.closeForTesting();
      DownloadHistoryDb.dbPathForTesting = null;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('dup is pre-marked and never dispatched to the engine', () async {
      await DownloadHistoryDb.instance.insert(
        _completed('https://www.youtube.com/watch?v=ABC123_-xY'),
      );
      final engine = _RecordingEngine();
      final container = await _container(engine);

      container.read(batchProvider.notifier).startBatch([
        const BatchItem(
            url: 'https://youtu.be/ABC123_-xY', title: 'already downloaded'),
        const BatchItem(url: 'https://x.test/fresh', title: 'fresh video'),
      ]);
      await _drain(container);

      expect(engine.urls, ['https://x.test/fresh']);
      final items = container.read(batchProvider).items;
      expect(items[0].status, BatchItemStatus.completed);
      expect(items[0].title, 'already downloaded (already have)');
      expect(items[1].status, BatchItemStatus.completed);
      expect(items[1].title, 'fresh video');
      expect(container.read(batchProvider).skipExisting, isTrue);
    });

    test('skipExisting:false dispatches everything', () async {
      await DownloadHistoryDb.instance.insert(
        _completed('https://www.youtube.com/watch?v=ABC123_-xY'),
      );
      final engine = _RecordingEngine();
      final container = await _container(engine);

      container.read(batchProvider.notifier).startBatch(
        [
          const BatchItem(
              url: 'https://youtu.be/ABC123_-xY', title: 'already downloaded'),
          const BatchItem(url: 'https://x.test/fresh', title: 'fresh video'),
        ],
        skipExisting: false,
      );
      await _drain(container);

      expect(
        engine.urls,
        ['https://youtu.be/ABC123_-xY', 'https://x.test/fresh'],
      );
      expect(container.read(batchProvider).skipExisting, isFalse);
    });

    test('empty history proceeds unfiltered', () async {
      final engine = _RecordingEngine();
      final container = await _container(engine);

      container.read(batchProvider.notifier).startBatch([
        const BatchItem(url: 'https://x.test/a', title: 'a'),
      ]);
      await _drain(container);

      expect(engine.urls, ['https://x.test/a']);
    });
  });
}
