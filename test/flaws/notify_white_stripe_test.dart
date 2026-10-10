import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('notify white-stripe flaw', () {
    test('home_screen uses notification_helper instead of raw SnackBar', () {
      final file = File('lib/features/home/screens/home_screen.dart');
      expect(file.existsSync(), isTrue, reason: 'home_screen.dart must exist');
      final content = file.readAsStringSync();
      // Flaw: raw ScaffoldMessenger SnackBar without inverseSurface shows white stripe
      // Expect the file to use showAppNotification or notification_helper
      final usesHelper = content.contains('notification_helper') || content.contains('showAppNotification');
      final usesRawSnackBar = content.contains('ScaffoldMessenger.of(context).showSnackBar');
      // Fail if raw SnackBar still present without helper
      expect(usesHelper, isTrue, reason: 'home_screen should use notification_helper/showAppNotification to avoid white stripe');
      // After fix, raw is replaced; this documents the flaw
      if (usesHelper) {
        expect(usesRawSnackBar, isFalse, reason: 'After fix, raw SnackBar should be removed from home_screen');
      }
    });

    test('link_saver_screen uses notification_helper', () {
      final file = File('lib/features/home/screens/link_saver_screen.dart');
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      final usesHelper = content.contains('notification_helper') || content.contains('showAppNotification');
      expect(usesHelper, isTrue, reason: 'link_saver should use notification_helper');
    });

    test('offline_queue_banner uses notification_helper', () {
      final file = File('lib/features/home/widgets/offline_queue_banner.dart');
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      final usesHelper = content.contains('notification_helper') || content.contains('showAppNotification');
      expect(usesHelper, isTrue, reason: 'offline_queue_banner should use notification_helper');
    });
  });
}
