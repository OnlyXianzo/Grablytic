import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truestream/features/onboarding/screens/onboarding_screen.dart';
import 'package:truestream/features/onboarding/widgets/onboarding_permissions_step.dart';
import 'package:truestream/providers/settings_provider.dart';
import 'package:truestream/core/engine/engine_provider.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';

/// Configurable fake: supported/granted matrices per permission + call
/// counters proving accept fires the system request exactly once and
/// reject never fires it.
class _FakeOnboardingEngine extends MockEngineService {
  Map<String, dynamic> notifStatus;
  Map<String, dynamic> batteryStatus;
  Map<String, dynamic> notifRequestResult;
  int notifRequests = 0;
  int batteryRequests = 0;
  int settingsLaunches = 0;

  _FakeOnboardingEngine({
    this.notifStatus = const {'success': true, 'supported': true},
    this.batteryStatus = const {
      'success': true,
      'supported': true,
      'exempt': false
    },
    this.notifRequestResult = const {'success': true, 'granted': true},
  });

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() async =>
      notifStatus;

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() async =>
      batteryStatus;

  @override
  Future<Map<String, dynamic>> requestNotificationPermission() async {
    notifRequests++;
    return notifRequestResult;
  }

  @override
  Future<Map<String, dynamic>> requestBatteryExemption() async {
    batteryRequests++;
    batteryStatus = {'success': true, 'supported': true, 'exempt': true};
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> openNotificationSettings() async {
    settingsLaunches++;
    return {'success': true, 'launched': true};
  }
}

Future<SharedPreferences> _prefs(
    [Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

Widget _stepHarness({
  required SharedPreferences prefs,
  required _FakeOnboardingEngine engine,
  VoidCallback? onFinished,
}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      engineProvider.overrideWith((ref) => engine),
    ],
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: OnboardingPermissionsStep(
          onFinished: onFinished ?? () {},
        ),
      ),
    ),
  );
}

Future<void> _settleStatuses(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// The permissions step scrolls: bring the target into view before tapping,
/// the same way a real user would scroll to it.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
}

void main() {
  group('OnboardingPermissionsStep', () {
    testWidgets('ask state: per-card Allow/Skip; Allow fires one request',
        (tester) async {
      final prefs = await _prefs();
      final engine = _FakeOnboardingEngine();
      await tester.pumpWidget(_stepHarness(prefs: prefs, engine: engine));
      await _settleStatuses(tester);

      // Each permission is its own explained choice — no blanket button.
      expect(find.text('Download alerts'), findsOneWidget);
      expect(find.text('Unrestricted background'), findsOneWidget);
      expect(find.text('Download location'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Allow'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Enable'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Got it'), findsOneWidget);

      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Allow'));
      await _settleStatuses(tester);

      expect(engine.notifRequests, 1);
      expect(
        find.text('On — you\'ll get completion alerts.'),
        findsOneWidget,
      );
      // Granted card drops its buttons.
      expect(find.widgetWithText(ElevatedButton, 'Allow'), findsNothing);
    });

    testWidgets('Skip paths never fire a system request',
        (tester) async {
      final prefs = await _prefs();
      final engine = _FakeOnboardingEngine();
      await tester.pumpWidget(_stepHarness(prefs: prefs, engine: engine));
      await _settleStatuses(tester);

      final skipFinder = find.widgetWithText(TextButton, 'Skip');
      expect(skipFinder, findsNWidgets(3));

      // Re-query after each tap: a skipped card drops its buttons, so
      // indices shift — always take the current first.
      await _tapVisible(tester, skipFinder.first); // notifications Skip
      await tester.pump();
      await _tapVisible(tester, skipFinder.first); // battery Skip
      await tester.pump();

      expect(engine.notifRequests, 0);
      expect(engine.batteryRequests, 0);
      expect(
        find.text('Skipped — enable anytime in Settings.'),
        findsNWidgets(2),
      );
      // Battery choice (even Skip) marks the prompt seen so AppShell
      // never double-asks after onboarding.
      expect(prefs.getBool('hasSeenBatteryPrompt'), isTrue);
    });

    testWidgets('denied request offers settings recovery, never re-fires',
        (tester) async {
      final prefs = await _prefs();
      final engine = _FakeOnboardingEngine(
        notifRequestResult: const {'success': true, 'granted': false},
      );
      await tester.pumpWidget(_stepHarness(prefs: prefs, engine: engine));
      await _settleStatuses(tester);

      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Allow'));
      await _settleStatuses(tester);

      expect(engine.notifRequests, 1);
      expect(find.widgetWithText(ElevatedButton, 'Allow'), findsNothing);
      expect(
        find.widgetWithText(ElevatedButton, 'Open settings'),
        findsOneWidget,
      );

      await _tapVisible(
        tester,
        find.widgetWithText(ElevatedButton, 'Open settings'),
      );
      await tester.pump();
      expect(engine.settingsLaunches, 1);
      // Recovery path does not re-fire the dead system prompt.
      expect(engine.notifRequests, 1);
    });

    testWidgets('pre-granted / unsupported shows confirmed state, no buttons',
        (tester) async {
      final prefs = await _prefs();
      final engine = _FakeOnboardingEngine(
        notifStatus: const {
          'success': true,
          'supported': true,
          'granted': true
        },
        batteryStatus: const {'success': false, 'supported': false},
      );
      await tester.pumpWidget(_stepHarness(prefs: prefs, engine: engine));
      await _settleStatuses(tester);

      expect(
        find.text('On — you\'ll get completion alerts.'),
        findsOneWidget,
      );
      expect(find.text('Not needed on this device.'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Allow'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Enable'), findsNothing);
    });

    testWidgets('battery Enable records choice; Continue always finishes',
        (tester) async {
      final prefs = await _prefs();
      final engine = _FakeOnboardingEngine();
      var finished = false;
      await tester.pumpWidget(_stepHarness(
        prefs: prefs,
        engine: engine,
        onFinished: () => finished = true,
      ));
      await _settleStatuses(tester);

      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Enable'));
      await _settleStatuses(tester);

      expect(engine.batteryRequests, 1);
      expect(prefs.getBool('hasSeenBatteryPrompt'), isTrue);

      // Denial never blocks: Continue is tappable with zero grants.
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Continue'));
      await tester.pump();
      expect(finished, isTrue);
    });

    testWidgets('storage card is informational acknowledge', (tester) async {
      final prefs = await _prefs();
      final engine = _FakeOnboardingEngine();
      await tester.pumpWidget(_stepHarness(prefs: prefs, engine: engine));
      await _settleStatuses(tester);

      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Got it'));
      await tester.pump();
      expect(
        find.text('Got it — Downloads / TrueStream.'),
        findsOneWidget,
      );
      // Acknowledging storage fires no system request at all.
      expect(engine.notifRequests, 0);
      expect(engine.batteryRequests, 0);
    });
  });

  group('OnboardingScreen permissions beat (integration)', () {
    testWidgets('tap-through reaches permissions step; Continue completes',
        (tester) async {
      final prefs = await _prefs();
      final engine = _FakeOnboardingEngine();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => engine),
          ],
          child: const MaterialApp(home: OnboardingScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      // Beats 1-3: tap anywhere to advance.
      await tester.tap(find.text('TrueStream'));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.tap(find.text('1,000+ sources'));
      await tester.pump(const Duration(milliseconds: 900));
      // Beat 3 → tap the headline to reach beat 4.
      await tester.tap(find.text('Self-Contained Power'));
      await tester.pump(const Duration(milliseconds: 1300));

      // Beat 4 now advances to the permissions beat (was Get Started).
      expect(find.widgetWithText(ElevatedButton, 'Continue'), findsOneWidget);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Continue'));
      await tester.pump(const Duration(milliseconds: 900));
      await _settleStatuses(tester);

      expect(find.text('A couple of quick choices'), findsOneWidget);
      expect(find.text('Download alerts'), findsOneWidget);

      // Skip everything, Continue still completes first-run onboarding.
      for (var i = 0; i < 3; i++) {
        await _tapVisible(tester, find.widgetWithText(TextButton, 'Skip').first);
        await tester.pump();
      }
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Continue'));
      await tester.pump();

      expect(prefs.getBool('onboardingCompleted'), isTrue);
      expect(prefs.getBool('hasSeenBatteryPrompt'), isTrue);
      expect(engine.notifRequests, 0);
    });
  });
}
