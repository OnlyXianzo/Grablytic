import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/utils/offline_link_queue.dart';
import 'package:grablytic/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('T20: Queue Reminder Interval Presets and Helpers', () {
    test('contains expected presets with 180 min default', () {
      expect(
        queueReminderIntervalPresets,
        containsAll([60, 180, 360, 720, 1440]),
      );
      expect(formatQueueReminderInterval(60), '1 hour');
      expect(formatQueueReminderInterval(180), '3 hours (default)');
      expect(formatQueueReminderInterval(360), '6 hours');
      expect(formatQueueReminderInterval(720), '12 hours');
      expect(formatQueueReminderInterval(1440), '24 hours');
      expect(formatQueueReminderInterval(30), '30 min');
    });
  });

  group('T20: AppSettings Queue Reminder State & Persistence', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('default is opt-in (disabled, 180m interval)', () {
      final notifier = SettingsNotifier(prefs);
      expect(notifier.state.queueReminderEnabled, isFalse);
      expect(notifier.state.queueReminderIntervalMinutes, 180);
    });

    test('toggling queue reminder persists to SharedPreferences', () {
      final notifier = SettingsNotifier(prefs);
      notifier.setQueueReminderEnabled(true);
      expect(notifier.state.queueReminderEnabled, isTrue);
      expect(prefs.getBool('queueReminderEnabled'), isTrue);

      notifier.setQueueReminderIntervalMinutes(360);
      expect(notifier.state.queueReminderIntervalMinutes, 360);
      expect(prefs.getInt('queueReminderIntervalMinutes'), 360);

      notifier.setQueueReminderEnabled(false);
      expect(notifier.state.queueReminderEnabled, isFalse);
      expect(prefs.getBool('queueReminderEnabled'), isFalse);
    });

    test('restores saved reminder preferences across restarts', () {
      prefs.setBool('queueReminderEnabled', true);
      prefs.setInt('queueReminderIntervalMinutes', 720);

      final notifier = SettingsNotifier(prefs);
      expect(notifier.state.queueReminderEnabled, isTrue);
      expect(notifier.state.queueReminderIntervalMinutes, 720);
    });
  });

  group('T20: Offline Queue Count & Reminders Engine Sync', () {
    late SharedPreferences prefs;
    late MockEngineService mockEngine;
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mockEngine = MockEngineService();

      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          engineProvider.overrideWithValue(mockEngine),
        ],
      );
    });

    tearDown(() {
      container.dispose();
    });

    test(
      'saving and clearing queue updates cached offlineQueueCount',
      () async {
        final store = container.read(offlineQueueStoreProvider);
        expect(prefs.getInt(offlineQueueCountKey), isNull);

        await store.addLink('https://youtube.com/watch?v=item1');
        expect(prefs.getInt(offlineQueueCountKey), 1);

        await store.addLink('https://youtube.com/watch?v=item2');
        expect(prefs.getInt(offlineQueueCountKey), 2);

        await store.clear();
        expect(prefs.getInt(offlineQueueCountKey), 0);
      },
    );

    test(
      'permission helper requests notification permission on opt-in',
      () async {
        // Permission initially not granted in mock
        final granted = await requestQueueReminderPermission(
          container.read(engineProvider),
        );
        expect(
          granted,
          isTrue,
        ); // MockEngineService returns granted: true on request
      },
    );
  });
}
