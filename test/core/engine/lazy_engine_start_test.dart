import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_start_signal.dart';
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
    // The start signal is process-global; a previous test's start must not
    // leak into the next one.
    resetEngineStartSignal();
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

    // The replayed config goes out as soon as the paths land — before the
    // call that triggered the start — so the engine is configured for the
    // work it is about to be asked to do.
    final order = calls.map((c) => c.method).toList();
    expect(order, [
      'paths/set',
      'download/set_concurrency',
      'download/queue_status',
    ]);
    final args = Map<String, dynamic>.from(calls[1].arguments as Map);
    expect(args['max_concurrent'], 4);
  });

  test('with no paths at all the call goes through to native', () async {
    final engine = PlatformChannelEngineService();
    final res = await engine.setConcurrency(4);
    // Nothing to start the engine with, so native's own verdict (here: a
    // mocked success) is what the caller sees.
    expect(res['deferred'], isNull);
    expect(calls.map((c) => c.method), ['download/set_concurrency']);
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

  test('a paths change during the first start is not dropped (#97)', () async {
    final gate = Completer<void>();
    final sent = <Map<String, dynamic>>[];
    install(onPathsSet: (call) async {
      sent.add(Map<String, dynamic>.from(call.arguments as Map));
      if (sent.length == 1) await gate.future;
      return null;
    });

    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());
    // First Python call: starts the apply, which the mock holds open.
    final started = engine.queueStatus();
    // Settings writes a new download folder while that call is in flight.
    final changed = engine.setPaths({...paths(), 'output_dir': '/new/dir'});
    await Future<void>.delayed(Duration.zero);

    gate.complete();
    await started;
    await changed;

    expect(sent, hasLength(2), reason: 'the change must be sent too');
    expect(sent.first['output_dir'], paths()['output_dir']);
    expect(sent.last['output_dir'], '/new/dir',
        reason: 'the last write is what the engine gets');
  });

  test('applying the paths reports the engine as started (#91)', () async {
    expect(engineHasStarted, isFalse);
    addTearDown(resetEngineStartSignal);

    final engine = PlatformChannelEngineService();
    await engine.setPaths(paths());
    await engine.queueStatus();

    expect(engineHasStarted, isTrue);
  });
}
