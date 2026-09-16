import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/features/settings/screens/settings_screen.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';

class _NoopResumeNotifier extends ResumeNotifier {
  _NoopResumeNotifier(super.ref);

  @override
  Future<void> scan() async {
    state = const AsyncValue.data([]);
  }
}

void main() {
  group('_Aria2cSpeedField Widget & Lifecycle Tests', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
        'hasSeenBatteryPrompt': true,
        'aria2cEnabled': true,
        'aria2cMaxSpeed': '10M',
      });
      prefs = await SharedPreferences.getInstance();
    });

    Widget createSubject(ProviderContainer container) {
      return UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SettingsScreen(),
        ),
      );
    }

    testWidgets('Renders initial value and preserves controller instance across typing',
        (WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          engineProvider.overrideWith((ref) => MockEngineService()),
          resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(createSubject(container));
      await tester.pumpAndSettle();

      final speedTile = find.text('aria2c speed limit');
      await tester.scrollUntilVisible(speedTile, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(find.text('10M'), findsOneWidget);

      final textFieldFinder = find.byType(TextField);
      TextField textField = tester.widget(textFieldFinder);
      final initialController = textField.controller;
      expect(initialController, isNotNull);
      expect(initialController!.text, '10M');

      // Enter text '25M'
      await tester.enterText(textFieldFinder, '25M');
      await tester.pump();

      // Controller must be the identical instance (not re-allocated in build)
      textField = tester.widget(textFieldFinder);
      expect(identical(textField.controller, initialController), isTrue,
          reason: 'Controller was re-created on rebuild instead of preserved in State');
      expect(container.read(settingsProvider).aria2cMaxSpeed, '25M');
    });

    testWidgets('External provider change updates text and cursor without stomp',
        (WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          engineProvider.overrideWith((ref) => MockEngineService()),
          resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(createSubject(container));
      await tester.pumpAndSettle();

      final speedTile = find.text('aria2c speed limit');
      await tester.scrollUntilVisible(speedTile, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      container.read(settingsProvider.notifier).setAria2cMaxSpeed('50M');
      await tester.pump();

      final textFieldFinder = find.byType(TextField);
      final TextField textField = tester.widget(textFieldFinder);
      expect(textField.controller!.text, '50M');
      expect(textField.controller!.selection.baseOffset, 3);
    });

    testWidgets('Toggling aria2cEnabled off unmounts field and cleans up',
        (WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          engineProvider.overrideWith((ref) => MockEngineService()),
          resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(createSubject(container));
      await tester.pumpAndSettle();

      expect(find.text('aria2c speed limit'), findsWidgets);

      container.read(settingsProvider.notifier).setAria2cEnabled(false);
      await tester.pumpAndSettle();

      expect(find.text('aria2c speed limit'), findsNothing);
    });
  });
}
