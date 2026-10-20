import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/platform_channel_engine_service.dart';

/// Finding #84 — the engine must not come up until something asks for it.
///
/// `setPaths` used to cross the bridge the moment the provider graph was
/// built, and on Android `paths/set` is what imports `grablytic_engine`
/// (and with it yt-dlp: 40.5 MiB, ~480 modules). These tests pin the new
/// ordering contract:
///
///   1. `setPaths` on its own sends NOTHING — the paths are held.
///   2. The first Python-bound call sends `paths/set` first, then itself.
///   3. A concurrency change that arrives before that is parked and
///      replayed afterwards, not lost to `ERR_ENGINE_UNAVAILABLE`.
///   4. Calls that are pure Kotlin never start the engine at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.theonly.grablytic/engine');
  late List<MethodCall> calls;

  void install({
    Future<Object?> Function(MethodCall call)? onPathsSet,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'paths/set':
          if (onPathsSet != null) return onPathsSet(call);
          return null;
        case 'download/queue_status':
          return jsonEncode({'success': true, 'max_concurrent': 2});
        case 'download/set_concurrency':
          final args = (call.arguments as Map?) ?? {};
          return jsonEncode({
            'success': true,
            'max_concurrent': args['max_concurrent'],
          });
        case 'schedule/sync':
        case 'queue_reminder/sync':
          return jsonEncode({'success': true});
        default:
          return null;
      }
    });
  }

  setUp(() {
    calls = <MethodCall>[];
    install();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Map<String, dynamic> paths() => {
    'data_dir': '/data/app',
    'cache_dir': '/data/cache',
    'output_dir': '/storage/emulated/0/Download/Grablytic',
  };

  test('setPaths alone does not touch the native layer', () async {
    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());
    expect(calls, isEmpty);
  });

  test('the first engine call applies paths before itself', () async {
    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());

    final res = await engine.queueStatus();

    expect(calls.map((c) => c.method), ['paths/set', 'download/queue_status']);
    expect(res['success'], isTrue);
    final sent = Map<String, dynamic>.from(calls.first.arguments as Map);
    expect(sent['data_dir'], '/data/app');
  });

  test('paths are applied once, not per call', () async {
    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());

    await engine.queueStatus();
    await engine.queueStatus();

    expect(calls.where((c) => c.method == 'paths/set').length, 1);
  });

  test('a concurrency change before the engine exists is replayed', () async {
    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());

    final parked = await engine.setConcurrency(4);
    expect(parked['success'], isTrue);
    expect(parked['deferred'], isTrue);
    expect(parked['max_concurrent'], 4);
    expect(calls, isEmpty);

    await engine.queueStatus();

    final order = calls.map((c) => c.method).toList();
    expect(order, [
      'paths/set',
      'download/queue_status',
      'download/set_concurrency',
    ]);
    final args = Map<String, dynamic>.from(calls.last.arguments as Map);
    expect(args['max_concurrent'], 4);
  });

  test('only the newest parked concurrency value is replayed', () async {
    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());

    await engine.setConcurrency(2);
    await engine.setConcurrency(5);
    await engine.queueStatus();

    final replays =
        calls.where((c) => c.method == 'download/set_concurrency').toList();
    expect(replays.length, 1);
    expect((replays.single.arguments as Map)['max_concurrent'], 5);
  });

  test('pure-Kotlin calls never start the engine', () async {
    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());

    await engine.syncSchedule(enabled: true, intervalMinutes: 60);
    await engine.syncQueueReminder(enabled: true, intervalMinutes: 180);

    expect(
      calls.map((c) => c.method),
      ['schedule/sync', 'queue_reminder/sync'],
    );
  });

  test('a failed paths/set is reported and retried by the next call', () async {
    var attempts = 0;
    install(
      onPathsSet: (_) async {
        attempts++;
        if (attempts == 1) {
          throw PlatformException(code: 'ERROR_INVALID_PATH');
        }
        return null;
      },
    );

    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());

    final failed = await engine.queueStatus();
    expect(failed['success'], isFalse);
    expect(failed['error_type'], 'ERROR_ENGINE_UNAVAILABLE');
    expect(
      calls.map((c) => c.method),
      ['paths/set'],
      reason: 'the failed start must not fall through to the engine call',
    );

    final retried = await engine.queueStatus();
    expect(retried['success'], isTrue);
    expect(attempts, 2);
    expect(calls.map((c) => c.method), [
      'paths/set',
      'paths/set',
      'download/queue_status',
    ]);
  });

  test('setPaths after startup re-sends immediately', () async {
    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());
    await engine.queueStatus();
    calls.clear();

    await engine.setPaths({...paths(), 'output_dir': '/new/dir'});

    expect(calls.map((c) => c.method), ['paths/set']);
    expect(
      (calls.single.arguments as Map)['output_dir'],
      '/new/dir',
    );
  });
}
