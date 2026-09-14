import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';

void main() {
  group('MockEngineService background permissions (unsupported)', () {
    test('reports unsupported, never throws', () async {
      final engine = MockEngineService();
      expect((await engine.batteryExemptionStatus())['supported'], isFalse);
      expect((await engine.requestBatteryExemption())['supported'], isFalse);
      expect((await engine.notificationPermissionStatus())['supported'], isFalse);
      expect((await engine.requestNotificationPermission())['supported'], isFalse);
      engine.dispose();
    });
  });
}
