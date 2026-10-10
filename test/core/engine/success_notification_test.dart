import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/engine/platform_channel_engine_service.dart';
import 'package:grablytic/core/utils/logging_observers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.theonly.grablytic/engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PlatformChannelEngineService engine;

  setUp(() => engine = PlatformChannelEngineService());
  tearDown(() {
    engine.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'success notification sends the native method and exact payload',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'granted': true};
      });
      await engine.showSuccessNotification(
        downloadId: 'download-1',
        title: 'Complete ✓',
        message: 'Saved video',
      );
      expect(calls.single.method, 'notification/show_success');
      expect(calls.single.arguments, {
        'download_id': 'download-1',
        'title': 'Complete ✓',
        'message': 'Saved video',
      });
    },
  );

  for (final error in [
    PlatformException(code: 'PERMISSION_DENIED'),
    MissingPluginException('unsupported'),
  ]) {
    test('success notification tolerates ${error.runtimeType}', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => throw error);
      await expectLater(
        engine.showSuccessNotification(downloadId: '1', title: '', message: ''),
        completes,
      );
    });
  }

  test('tracing forwards each notification to the mock unchanged', () async {
    final inner = MockEngineService();
    addTearDown(inner.dispose);
    final traced = TracedEngineService(inner);
    for (final id in ['one', 'two']) {
      await traced.showSuccessNotification(
        downloadId: id,
        title: 'Finished $id',
        message: 'Saved $id',
      );
    }
    expect(inner.successNotifications, [
      {'download_id': 'one', 'title': 'Finished one', 'message': 'Saved one'},
      {'download_id': 'two', 'title': 'Finished two', 'message': 'Saved two'},
    ]);
    expect(inner.errorNotifications, isEmpty);
  });
}
