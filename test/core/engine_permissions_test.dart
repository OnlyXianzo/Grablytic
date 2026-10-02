import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';

void main() {
  group('MockEngineService background permissions (unsupported)', () {
    test('reports unsupported battery, notification prompt flow, never throws',
        () async {
      final engine = MockEngineService();
      expect((await engine.batteryExemptionStatus())['supported'], isFalse);
      expect((await engine.requestBatteryExemption())['supported'], isFalse);
      // Notifications are supported in the mock via a grant seam.
      expect(
          (await engine.notificationPermissionStatus())['granted'], isFalse);
      expect(
          (await engine.requestNotificationPermission())['granted'], isTrue);
      expect(
          (await engine.notificationPermissionStatus())['granted'], isTrue);
      engine.dispose();
    });
  });
}
