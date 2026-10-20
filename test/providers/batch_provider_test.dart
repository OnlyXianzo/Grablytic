import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/batch_provider.dart';
import 'package:grablytic/providers/preset_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _RecordingEngine extends MockEngineService {
  final List<Map<String, dynamic>> configs = [];

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    configs.add(Map<String, dynamic>.from(config));
    return {'success': true};
  }
}

class _ScriptedEngine extends MockEngineService {
  final Set<String> failUrls = {};
  final Map<String, Map<String, String>> failures = {};
  final List<Map<String, dynamic>> configs = [];
  int calls = 0;

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    calls++;
    configs.add(Map<String, dynamic>.from(config));
    if (failUrls.contains(url)) {
      final failure = failures[url] ??
          const {
            'error_type': 'ERROR_NETWORK',
            'error_message': 'empty media response',
          };
      return {'success': false, ...failure};
    }
    return {'success': true};
  }
}

class _ThrowingEngine extends MockEngineService {
  final Set<String> throwUrls = {};
  int calls = 0;

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    calls++;
    if (throwUrls.contains(url)) throw Exception('engine boom');
    return {'success': true};
  }
}

/// Starts a download that never settles, so the item stays `downloading`
/// for the duration of the test.
class _HangingEngine extends MockEngineService {
  final List<String> cancelled = [];

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) {
    return Completer<Map<String, dynamic>>().future;
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) async {
    cancelled.add(downloadId);
    return {'success': true, 'download_id': downloadId, 'cancelled': true};
  }
}

Future<ProviderContainer> _container(
  MockEngineService engine, {
  Map<String, Object> mockPrefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(mockPrefs);
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

BatchItem _item(String id) =>
    BatchItem(url: 'https://instagram.com/p/$id/', title: 'reel $id');

void main() {
  test('batch snapshot ceiling fans out to every item', () async {
    final engine = _RecordingEngine();
    final container = await _container(engine);

    container.read(batchProvider.notifier).startBatch(
      [_item('A'), _item('B')],
      qualityCeiling: '480p',
    );
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, hasLength(2));
    expect(
      engine.configs.map((c) => c['quality_ceiling']),
      ['480p', '480p'],
    );
  });

  test('mid-queue preset change cannot split a snapshotted batch', () async {
    final engine = _RecordingEngine();
    final container = await _container(engine);

    container.read(batchProvider.notifier).startBatch(
      [_item('A'), _item('B')],
      qualityCeiling: '480p',
    );
    // User flips the global preset while the batch is running.
    container.read(presetsProvider.notifier).setActivePreset('preset_720p');
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, hasLength(2));
    expect(
      engine.configs.map((c) => c['quality_ceiling']),
      ['480p', '480p'],
    );
  });

  test('null snapshot follows the live active preset', () async {
    final engine = _RecordingEngine();
    final container = await _container(engine);

    // Default active preset is preset_1080p.
    container.read(batchProvider.notifier).startBatch([_item('A')]);
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, hasLength(1));
    expect(engine.configs.single['quality_ceiling'], '1080p');
    expect(container.read(batchProvider).qualityCeiling, isNull);
  });

  test('failed items record the engine error type and message', () async {
    final engine = _ScriptedEngine();
    final container = await _container(engine);
    engine.failUrls.add('https://instagram.com/p/A/');
    engine.failures['https://instagram.com/p/A/'] = const {
      'error_type': 'ERROR_FORMAT_UNAVAILABLE',
      'error_message': 'no video formats found',
    };

    container.read(batchProvider.notifier).startBatch([_item('A'), _item('B')]);
    await Future.delayed(const Duration(milliseconds: 100));

    final items = container.read(batchProvider).items;
    expect(items[0].status, BatchItemStatus.failed);
    expect(items[0].lastErrorType, 'ERROR_FORMAT_UNAVAILABLE');
    expect(items[0].lastErrorMessage, 'no video formats found');
    expect(items[1].status, BatchItemStatus.completed);
    expect(items[1].lastErrorType, isNull);
  });

  test('batchFailureLabel triages no-video vs transient failures', () {
    const photo = BatchItem(
      url: 'u1',
      title: 'photo',
      status: BatchItemStatus.failed,
      lastErrorType: 'ERROR_FORMAT_UNAVAILABLE',
      lastErrorMessage: 'no video formats found',
    );
    const private = BatchItem(
      url: 'u2',
      title: 'private',
      status: BatchItemStatus.failed,
      lastErrorType: 'ERROR_PRIVATE',
      lastErrorMessage: 'this video is private',
    );
    const transient = BatchItem(
      url: 'u3',
      title: 'transient',
      status: BatchItemStatus.failed,
      lastErrorType: 'ERROR_NETWORK',
      lastErrorMessage: 'empty media response',
    );
    const bare = BatchItem(
      url: 'u4',
      title: 'bare',
      status: BatchItemStatus.failed,
    );

    expect(batchFailureLabel(photo), 'no video — skipped');
    expect(batchItemSkipped(photo), isTrue);
    expect(batchFailureLabel(private), 'no video — skipped');
    expect(batchItemSkipped(private), isTrue);
    expect(batchFailureLabel(transient), 'empty media response');
    expect(batchItemSkipped(transient), isFalse);
    expect(batchFailureLabel(bare), 'Failed');
  });

  test('retryFailed retries only failed items and keeps completed',
      () async {
    final engine = _ScriptedEngine();
    final container = await _container(engine);
    engine.failUrls.add('https://instagram.com/p/A/');

    container.read(batchProvider.notifier).startBatch(
      [_item('A'), _item('B')],
      qualityCeiling: '480p',
    );
    await Future.delayed(const Duration(milliseconds: 100));
    expect(engine.calls, 2);
    expect(
      container.read(batchProvider).items.map((i) => i.status),
      [BatchItemStatus.failed, BatchItemStatus.completed],
    );

    // Transient failure clears: retry must pick up only the failed item.
    engine.failUrls.clear();
    container.read(batchProvider.notifier).retryFailed();
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.calls, 3);
    final items = container.read(batchProvider).items;
    expect(items[0].status, BatchItemStatus.completed);
    expect(items[0].lastErrorType, isNull);
    expect(items[0].lastErrorMessage, isNull);
    expect(items[1].status, BatchItemStatus.completed);
    // Retry reuses the snapshotted ceiling, not the live preset.
    expect(
      engine.configs.map((c) => c['quality_ceiling']),
      ['480p', '480p', '480p'],
    );
    expect(container.read(batchProvider).qualityCeiling, '480p');
    expect(container.read(batchProvider).isRunning, isFalse);
  });

  test('retryFailed while running is a no-op (no double dispatch)', () async {
    final engine = _ScriptedEngine();
    final container = await _container(engine);
    engine.failUrls.add('https://instagram.com/p/A/');

    container.read(batchProvider.notifier).startBatch([_item('A'), _item('B')]);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(engine.calls, 2);

    engine.failUrls.clear();
    final notifier = container.read(batchProvider.notifier);
    notifier.retryFailed();
    notifier.retryFailed(); // still running — must not dispatch again.
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.calls, 3);
    expect(
      container.read(batchProvider).items.map((i) => i.status),
      [BatchItemStatus.completed, BatchItemStatus.completed],
    );
    expect(container.read(batchProvider).isRunning, isFalse);
  });

  test('engine throw marks the item failed with the error text', () async {
    final engine = _ThrowingEngine();
    final container = await _container(engine);
    engine.throwUrls.add('https://instagram.com/p/A/');

    container.read(batchProvider.notifier).startBatch([_item('A'), _item('B')]);
    await Future.delayed(const Duration(milliseconds: 100));

    final items = container.read(batchProvider).items;
    expect(items[0].status, BatchItemStatus.failed);
    expect(items[0].lastErrorType, isNull);
    expect(items[0].lastErrorMessage, contains('engine boom'));
    expect(batchFailureLabel(items[0]), contains('engine boom'));
    expect(batchItemSkipped(items[0]), isFalse);
    expect(items[1].status, BatchItemStatus.completed);
  });

  test('retryFailed is a no-op with nothing failed', () async {
    final engine = _RecordingEngine();
    final container = await _container(engine);

    container.read(batchProvider.notifier).startBatch([_item('A')]);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(engine.configs, hasLength(1));

    container.read(batchProvider.notifier).retryFailed();
    await Future.delayed(const Duration(milliseconds: 50));
    expect(engine.configs, hasLength(1));
    expect(container.read(batchProvider).isRunning, isFalse);
  });

  test('outside the schedule window the queue parks without a spinner',
      () async {
    final engine = _RecordingEngine();
    // Enabled with no permitted weekdays: isWithinScheduleWindow is false
    // whatever day the suite runs on.
    final container = await _container(
      engine,
      mockPrefs: {'scheduleEnabled': true, 'scheduleDays': <String>[]},
    );

    container.read(batchProvider.notifier).startBatch([_item('A'), _item('B')]);
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, isEmpty, reason: 'nothing may start off-window');
    final state = container.read(batchProvider);
    expect(state.isRunning, isFalse);
    expect(state.scheduleBlocked, isTrue);
    // The old code marked the first item downloading and then bailed, so it
    // hung as a spinner that retryFailed would not touch.
    expect(
      state.items.map((i) => i.status),
      everyElement(BatchItemStatus.pending),
    );

    container.read(batchProvider.notifier).retryFailed();
    await Future.delayed(const Duration(milliseconds: 50));
    expect(engine.configs, isEmpty);
  });

  test('leaving the window then ticking resumes the parked queue', () async {
    final engine = _RecordingEngine();
    final container = await _container(
      engine,
      mockPrefs: {'scheduleEnabled': true, 'scheduleDays': <String>[]},
    );

    container.read(batchProvider.notifier).startBatch([_item('A')]);
    await Future.delayed(const Duration(milliseconds: 100));
    expect(engine.configs, isEmpty);

    container.read(settingsProvider.notifier).setScheduleEnabled(false);
    container.read(batchProvider.notifier).processNext();
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, hasLength(1));
    expect(container.read(batchProvider).scheduleBlocked, isFalse);
  });

  test('a cancel during the skip-existing pre-filter wins over dispatch',
      () async {
    final engine = _RecordingEngine();
    final container = await _container(engine);

    // startBatch → _prefilterAlreadyHave is async, so the first dispatch has
    // not happened yet. Cancelling in that gap must stick: the pre-filter
    // rewrites state.items afterwards, and a cancel it dropped would send a
    // URL the user had just removed to the engine.
    container.read(batchProvider.notifier).startBatch([_item('A')]);
    container.read(batchProvider.notifier).cancelItem(0);
    await Future.delayed(const Duration(milliseconds: 100));

    expect(engine.configs, isEmpty);
    expect(
      container.read(batchProvider).items.single.status,
      BatchItemStatus.failed,
    );
  });

  test('cancelling a downloading item also stops the engine', () async {
    final engine = _HangingEngine();
    final container = await _container(engine);

    container.read(batchProvider.notifier).startBatch([_item('A')]);
    await Future.delayed(const Duration(milliseconds: 100));

    final item = container.read(batchProvider).items.single;
    expect(item.status, BatchItemStatus.downloading);
    final engineId = item.downloadId;
    expect(engineId, isNotNull);

    container.read(batchProvider.notifier).cancelItem(0);
    await Future.delayed(const Duration(milliseconds: 50));

    // The engine id is reserved before the status change, so a cancel that
    // lands here can still reach the running transfer.
    expect(engine.cancelled, [engineId]);
    expect(
      container.read(batchProvider).items.single.status,
      BatchItemStatus.failed,
    );
  });

  test('retryFailed clears the stale engine id', () async {
    final engine = _HangingEngine();
    final container = await _container(engine);

    container.read(batchProvider.notifier).startBatch([_item('A')]);
    await Future.delayed(const Duration(milliseconds: 100));
    container.read(batchProvider.notifier).cancelItem(0);
    await Future.delayed(const Duration(milliseconds: 50));

    container.read(batchProvider.notifier).retryFailed();
    await Future.delayed(const Duration(milliseconds: 50));

    final item = container.read(batchProvider).items.single;
    expect(item.downloadId, isNot(engine.cancelled.first));
  });
}
