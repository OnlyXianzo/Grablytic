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

void main() {
  group('Grablytic App', () {
    testWidgets('App renders onboarding text', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': false,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
          ],
          child: const GrablyticApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Grablytic'), findsOneWidget);
    });

    testWidgets('Settings screen renders key sections',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
      });
      final prefs = await SharedPreferences.getInstance();

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
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final settingsIcon = find.byIcon(Icons.settings);
      expect(settingsIcon, findsOneWidget);

      await tester.tap(settingsIcon);
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Wi-Fi Only Downloads'), findsOneWidget);
      expect(find.text('Download folder'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('About Grablytic'), findsOneWidget);
    });

    testWidgets('Navigation switches between tabs correctly',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
      });
      final prefs = await SharedPreferences.getInstance();

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
      await tester.pumpAndSettle(const Duration(seconds: 3));

      expect(find.text('Download'), findsWidgets);
      expect(find.text('Library'), findsWidgets);

      final libraryIcon = find.byIcon(Icons.folder_open);
      expect(libraryIcon, findsOneWidget);
      await tester.tap(libraryIcon);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.text('Library'), findsWidgets);

      final settingsIcon = find.byIcon(Icons.settings);
      expect(settingsIcon, findsOneWidget);
      await tester.tap(settingsIcon);
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.text('Settings'), findsWidgets);
    });
  });
}
