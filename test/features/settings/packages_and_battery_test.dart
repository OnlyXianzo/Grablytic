import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/main.dart';
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

class _BatteryTestEngineService extends MockEngineService {
  bool batteryPromptRequested = false;

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() async {
    return {'success': true, 'supported': true, 'exempt': false};
  }

  @override
  Future<Map<String, dynamic>> requestBatteryExemption() async {
    batteryPromptRequested = true;
    return {'success': true, 'supported': true};
  }

  @override
  Future<Map<String, dynamic>> bootstrap() async {
    return {
      'success': true,
      'yt_dlp_version': '2025.06.06',
      'ffmpeg_ok': true,
      'ffmpeg_version': '6.0',
      'js_runtime': 'deno',
      'js_runtime_version': '1.40.0',
      'aria2c_ok': true,
      'aria2c_version': '1.37.0',
      'binaries': [
        {
          'name': 'yt-dlp',
          'ok': true,
          'version': '2025.06.06',
          'source': 'bundled',
          'detail': 'Bundled Python package',
        },
        {
          'name': 'FFmpeg',
          'ok': true,
          'version': '6.0',
          'source': 'system',
          'detail': 'Found in PATH',
        },
        {
          'name': 'aria2c',
          'ok': true,
          'version': '1.37.0',
          'source': 'bundled',
          'detail': 'Bundled native binary',
        },
        {
          'name': 'Deno',
          'ok': true,
          'version': '1.40.0',
          'source': 'downloaded',
          'detail': 'Downloaded in bin dir',
        },
      ],
      'update_components': <String>[],
    };
  }
}

void main() {
  group('Packages Section Tests', () {
    testWidgets('Settings screen renders Packages card with all 4 packages',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final testEngine = _BatteryTestEngineService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => testEngine),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll to Packages card
      final packagesHeader = find.text('Packages');
      expect(packagesHeader, findsOneWidget);
      await tester.scrollUntilVisible(packagesHeader, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      // Verify the 4 packages are visible
      expect(find.text('yt-dlp'), findsWidgets);
      expect(find.text('FFmpeg'), findsWidgets);
      expect(find.text('aria2c'), findsWidgets);
      expect(find.text('Deno'), findsWidgets);

      // Verify "Check All Packages" button is present
      expect(find.text('Check All Packages'), findsOneWidget);

      // Tap on aria2c package to open detail sheet
      final aria2cFinder = find.widgetWithText(InkWell, 'aria2c');
      expect(aria2cFinder, findsOneWidget);
      await tester.tap(aria2cFinder);
      await tester.pumpAndSettle();

      // Verify details bottom sheet appears with Check Again button and version
      expect(find.text('Check Again'), findsOneWidget);
      expect(find.text('DETECTED VERSION'), findsOneWidget);

      // Tap Check Again button in modal sheet
      await tester.tap(find.text('Check Again'));
      await tester.pumpAndSettle();

      // Sheet should dismiss and snackbar should be displayed
      expect(find.text('Check Again'), findsNothing);
      expect(find.text('Re-checked aria2c status.'), findsOneWidget);
    });
  });

  group('Battery Optimization Tests', () {
    testWidgets('AppShell shows Battery dialog on startup if unhandled and exempt is false',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
        'hasSeenBatteryPrompt': false,
      });
      final prefs = await SharedPreferences.getInstance();
      final testEngine = _BatteryTestEngineService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => testEngine),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const GrablyticApp(),
        ),
      );
      await tester.pumpAndSettle();

      // When running on Android host (Termux), Platform.isAndroid is true
      if (Platform.isAndroid) {
        expect(find.text('Background Downloads'), findsOneWidget);
        expect(find.text('Skip'), findsOneWidget);
        expect(find.text('Enable'), findsOneWidget);

        // Tap Skip
        await tester.tap(find.text('Skip'));
        await tester.pumpAndSettle();

        // Dialog should be gone
        expect(find.text('Background Downloads'), findsNothing);

        // hasSeenBatteryPrompt should now be true
        expect(prefs.getBool('hasSeenBatteryPrompt'), isTrue);
      }
    });

    testWidgets('Settings screen contains battery optimization tile in Advanced',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
      });
      final prefs = await SharedPreferences.getInstance();
      final testEngine = _BatteryTestEngineService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => testEngine),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll down to Unrestricted background
      final batteryTile = find.text('Unrestricted background');
      await tester.scrollUntilVisible(batteryTile, 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(batteryTile, findsOneWidget);
    });
  });
}
