import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/features/settings/screens/settings_screen.dart';
import 'package:grablytic/features/settings/screens/observed_sources_screen.dart';
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
  group('Reorganized Settings Screen Tests', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
        'hasSeenBatteryPrompt': true,
        'wifiOnly': false,
        'turboMode': true,
        'aria2cEnabled': false,
        'downloadArchive': false,
      });
      prefs = await SharedPreferences.getInstance();
    });

    testWidgets('Renders all organized Material 3 sections and key settings',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top Header
      expect(find.text('Settings'), findsWidgets);

      // Section 1: General & Interface
      expect(find.text('General & Interface'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Library Grid View'), findsOneWidget);
      expect(find.text('Download Completion Alerts'), findsOneWidget);
      expect(find.text('Auto-start Download on Share'), findsOneWidget);

      // Scroll to Directories & Storage
      final dirSection = find.text('Directories & Storage');
      await tester.scrollUntilVisible(dirSection, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(dirSection, findsOneWidget);
      expect(find.text('Download folder'), findsOneWidget);
      expect(find.text('Skip already-downloaded videos'), findsOneWidget);

      // Scroll to Network & Acceleration
      final netSection = find.text('Network & Acceleration');
      await tester.scrollUntilVisible(netSection, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(netSection, findsOneWidget);
      expect(find.text('Wi-Fi Only Downloads'), findsOneWidget);
      expect(find.text('Turbo download mode'), findsOneWidget);
      expect(find.text('Use aria2c accelerator'), findsOneWidget);
      expect(find.text('Quality presets'), findsOneWidget);

      // Scroll to Media & Subtitles
      final mediaSection = find.text('Media & Subtitles');
      await tester.scrollUntilVisible(mediaSection, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(mediaSection, findsOneWidget);
      expect(find.text('Subtitles'), findsOneWidget);
      expect(find.text('SponsorBlock'), findsOneWidget);
      expect(find.text('Split video by chapters'), findsOneWidget);

      // Scroll to Automation & Scheduling
      final autoSection = find.text('Automation & Scheduling');
      await tester.scrollUntilVisible(autoSection, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(autoSection, findsOneWidget);
      expect(find.text('Scheduled downloads'), findsOneWidget);
      expect(find.text('Observed Sources'), findsOneWidget);
      expect(find.text('Custom download commands'), findsOneWidget);

      // Scroll to Accounts & Authentication
      final authSection = find.text('Accounts & Authentication');
      await tester.scrollUntilVisible(authSection, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(authSection, findsOneWidget);
      expect(find.text('Logins for members-only videos'), findsOneWidget);

      // Scroll to System & Diagnostics / Packages
      final pkgHeader = find.text('Packages');
      await tester.scrollUntilVisible(pkgHeader, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(pkgHeader, findsOneWidget);
      expect(find.text('App logs & diagnostics'), findsOneWidget);
      expect(find.text('About Grablytic'), findsOneWidget);
    });

    testWidgets('Toggling switch updates SharedPreferences key',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find Wi-Fi switch
      final wifiTile = find.text('Wi-Fi Only Downloads');
      await tester.scrollUntilVisible(wifiTile, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(prefs.getBool('wifiOnly') ?? false, isFalse);
      await tester.tap(wifiTile);
      await tester.pumpAndSettle();
      expect(prefs.getBool('wifiOnly'), isTrue);
    });

    testWidgets('Observed Sources navigates to ObservedSourcesScreen',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final obsTile = find.text('Observed Sources');
      await tester.scrollUntilVisible(obsTile, 200, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      await tester.tap(obsTile);
      await tester.pumpAndSettle();

      expect(find.byType(ObservedSourcesScreen), findsOneWidget);
    });

    testWidgets('Proxy, verbose, and update channel rows are present and work',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWith((ref) => MockEngineService()),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Proxy row opens a dialog and saves to the existing 'proxy' key.
      final proxyTile = find.text('Proxy server');
      await tester.scrollUntilVisible(proxyTile, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(proxyTile);
      await tester.pumpAndSettle();
      expect(find.text('Proxy URL'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'http://proxy:8080');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(prefs.getString('proxy'), 'http://proxy:8080');

      // Verbose switch flips the existing 'verbose' key.
      final verboseTile = find.text('Detailed engine logging');
      await tester.scrollUntilVisible(verboseTile, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(prefs.getBool('verbose') ?? false, isFalse);
      await tester.tap(verboseTile);
      await tester.pumpAndSettle();
      expect(prefs.getBool('verbose'), isTrue);

      // Update channel dialog writes the existing 'updateChannel' key.
      final channelTile = find.text('Update channel');
      await tester.scrollUntilVisible(channelTile, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(channelTile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('nightly'));
      await tester.pumpAndSettle();
      expect(prefs.getString('updateChannel'), 'nightly');
    });

    test('Storage keys survive the regroup unchanged', () async {
      await prefs.setString('proxy', 'http://proxy:8080');
      await prefs.setBool('verbose', true);
      await prefs.setString('updateChannel', 'nightly');
      await prefs.setBool('downloadArchive', true);
      await prefs.setBool('archiveByFolder', false);
      await prefs.setInt('aria2cChunks', 12);
      await prefs.setString('aria2cMaxSpeed', '10M');
      await prefs.setString('qualityCeiling', '720p');
      await prefs.setBool('wifiOnly', true);

      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      final s = container.read(settingsProvider);
      expect(s.proxy, 'http://proxy:8080');
      expect(s.verbose, isTrue);
      expect(s.updateChannel, 'nightly');
      expect(s.downloadArchive, isTrue);
      expect(s.archiveByFolder, isFalse);
      expect(s.aria2cChunks, 12);
      expect(s.aria2cMaxSpeed, '10M');
      expect(s.qualityCeiling, '720p');
      expect(s.wifiOnly, isTrue);
    });
  });
}
