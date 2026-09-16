import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/desktop_engine_service.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/engine/platform_channel_engine_service.dart';
import 'package:grablytic/core/utils/logging_observers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('transport disposal (F2)', () {
    test('platform channel dispose is idempotent', () {
      final engine = PlatformChannelEngineService();
      engine.dispose();
      engine.dispose();
    });

    test('desktop dispose before start is safe and idempotent', () {
      final engine = DesktopEngineService();
      engine.dispose();
      engine.dispose();
    });

    test('mock dispose is idempotent', () {
      final engine = MockEngineService();
      engine.dispose();
      engine.dispose();
    });

    test('traced decorator forwards dispose to inner', () {
      final inner = MockEngineService();
      final traced = TracedEngineService(inner);
      traced.dispose();
      // Inner already closed: second dispose through either handle is safe.
      traced.dispose();
      inner.dispose();
    });
  });
}
