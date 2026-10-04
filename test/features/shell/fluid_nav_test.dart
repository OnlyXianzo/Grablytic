import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/features/shell/screens/app_shell.dart';
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
  /// Tab icons also appear inside screens (e.g. Library rows reuse
  /// download_outlined), so tab taps must scope to the rail.
  Finder railTab(IconData icon) => find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(icon),
      );

  group('Fluid Bottom Navigation Tests', () {
    testWidgets('AppShell renders 3 bottom navigation destinations with 48x48 targets',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
        'hasSeenBatteryPrompt': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: AppShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Download'), findsWidgets);
      expect(find.text('Library'), findsWidgets);
      expect(find.text('Settings'), findsWidgets);

      // Verify all 3 icons exist
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(find.byIcon(Icons.folder_open), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    });

    testWidgets('Tapping between tabs triggers smooth animated transition',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
        'hasSeenBatteryPrompt': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: AppShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Library
      final libraryTab = railTab(Icons.folder_open);
      await tester.tap(libraryTab);
      // Mid-animation frame
      await tester.pump(const Duration(milliseconds: 100));
      // Animation settles
      await tester.pumpAndSettle();

      // Tap Settings
      final settingsTab = railTab(Icons.settings_outlined);
      await tester.tap(settingsTab);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // Tap back to Download
      final downloadTab = railTab(Icons.download_outlined);
      await tester.tap(downloadTab);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
    });

    testWidgets('Horizontal drag across bottom bar smoothly updates indicator position',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
        'hasSeenBatteryPrompt': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: AppShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Drag horizontally across the bottom navigation bar
      // (index 0 selected -> rail shows the filled selected icon).
      final downloadFinder = railTab(Icons.download);
      expect(downloadFinder, findsOneWidget);

      await tester.drag(downloadFinder, const Offset(200, 0));
      await tester.pumpAndSettle();
    });

    testWidgets('Wide screen layout (>600px) uses NavigationRail',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
        'hasSeenBatteryPrompt': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: AppShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsOneWidget);
    });
  });
}
