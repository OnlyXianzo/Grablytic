import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/main.dart';
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

ProviderScope _buildApp({
  required SharedPreferences prefs,
  required bool onboardingCompleted,
}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      engineProvider.overrideWith((ref) => MockEngineService()),
      resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
    ],
    child: const GrablyticApp(),
  );
}

void main() {
  group('Frame Rate Audit', () {
    testWidgets('P4-012: Onboarding screen frame rate', (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': false,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(1080, 1920));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const GrablyticApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(find.text('Grablytic'), findsOneWidget);
      expect(find.text('Tap anywhere to continue'), findsOneWidget);
    });

    testWidgets('P4-012: Home screen frame rate', (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(1080, 1920));
      await tester.pumpWidget(_buildApp(prefs: prefs, onboardingCompleted: true));
      await tester.pump(const Duration(seconds: 2));

      expect(tester.takeException(), isNull);
      expect(find.text('Enter link......'), findsWidgets);
    });

    testWidgets('P4-012: Settings screen frame rate', (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(1080, 1920));
      await tester.pumpWidget(_buildApp(prefs: prefs, onboardingCompleted: true));
      await tester.pump(const Duration(seconds: 2));

      final settingsIcon = find.byIcon(Icons.settings);
      expect(settingsIcon, findsOneWidget);
      await tester.tap(settingsIcon);
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Wi-Fi Only Downloads'), findsOneWidget);
    });

    testWidgets('P4-012: Library screen frame rate', (tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(1080, 1920));
      await tester.pumpWidget(_buildApp(prefs: prefs, onboardingCompleted: true));
      await tester.pump(const Duration(seconds: 2));

      final libraryIcon = find.byIcon(Icons.folder_open);
      expect(libraryIcon, findsOneWidget);
      await tester.tap(libraryIcon);
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(find.text('Library'), findsWidgets);
    });
  });
}
