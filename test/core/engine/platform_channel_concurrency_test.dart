import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';
import 'package:truestream/core/engine/platform_channel_engine_service.dart';
import 'package:truestream/providers/download_provider.dart';

/// Item-2 effect proof: the Android platform-channel path for the queue
/// gate uses the same method names / arg shapes as the desktop JSON-RPC
/// side (`download/queue_status`, `download/set_concurrency`), parses the
/// Kotlin JSON envelope, never throws, and `syncConcurrency` forwards the
/// Settings slider value to the engine.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.theonly.truestream/engine');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'download/queue_status':
          return jsonEncode({
            'success': true,
            'active': ['a-1'],
            'queued': ['q-1'],
            'max_concurrent': 1,
          });
        case 'download/set_concurrency':
          final args = (call.arguments as Map?) ?? {};
          final n = (args['max_concurrent'] as int?) ?? 2;
          return jsonEncode({
            'success': true,
            'max_concurrent': n.clamp(1, 5),
          });
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('queueStatus invokes download/queue_status and parses envelope', () async {
    final engine = PlatformChannelEngineService();
    final res = await engine.queueStatus();
    expect(calls.single.method, 'download/queue_status');
    expect(res['success'], isTrue);
    expect(res['active'], ['a-1']);
    expect(res['queued'], ['q-1']);
    expect(res['max_concurrent'], 1);
  });

  test('setConcurrency sends max_concurrent and returns new limit', () async {
    final engine = PlatformChannelEngineService();
    final res = await engine.setConcurrency(1);
    expect(calls.single.method, 'download/set_concurrency');
    final args = Map<String, dynamic>.from(calls.single.arguments as Map);
    expect(args['max_concurrent'], 1);
    expect(res['success'], isTrue);
    expect(res['max_concurrent'], 1);
  });

  test('platform methods never throw when the native side errors', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'ERROR_QUEUE_FAILED');
    });
    final engine = PlatformChannelEngineService();
    expect((await engine.queueStatus())['success'], isFalse);
    expect((await engine.setConcurrency(3))['success'], isFalse);
  });

  test('syncConcurrency forwards the slider value to the engine', () async {
    final mock = _RecordingEngine();
    final notifier = DownloadNotifier(mock);
    await notifier.syncConcurrency(4);
    expect(mock.setConcurrencyCalls, [4]);
  });
}

class _RecordingEngine extends MockEngineService {
  final setConcurrencyCalls = <int>[];

  @override
  Future<Map<String, dynamic>> setConcurrency(int maxConcurrent) async {
    setConcurrencyCalls.add(maxConcurrent);
    return super.setConcurrency(maxConcurrent);
  }
}
