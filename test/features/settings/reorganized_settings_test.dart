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

    testWidgets('Renders category list and sub-menus with key settings',
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

      // Top Header + category list (folder hierarchy)
      expect(find.text('Settings'), findsWidgets);
      for (final category in [
        'General',
        'Permissions',
        'Appearance',
        'Storage',
        'Network and speed',
        'Media and subtitles',
        'Automation',
        'Cookies',
        'Packages & Updates',
        'System & Diagnostics',
      ]) {
        expect(find.text(category), findsOneWidget);
      }
      // Options live inside sub-menus, not on the root.
      expect(find.text('Wi-Fi Only Downloads'), findsNothing);

      // Network sub-menu holds the network options.
      await tester.tap(find.text('Network and speed'));
      await tester.pumpAndSettle();
      expect(find.text('Wi-Fi Only Downloads'), findsOneWidget);
      expect(find.text('Turbo download mode'), findsOneWidget);
      expect(find.text('Use aria2c accelerator'), findsOneWidget);
      expect(find.text('Quality presets'), findsOneWidget);
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

      // Wi-Fi lives in Network and speed now.
      final netCat = find.text('Network and speed');
      await tester.scrollUntilVisible(netCat, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(netCat);
      await tester.pumpAndSettle();
      final wifiTile = find.text('Wi-Fi Only Downloads');
      expect(wifiTile, findsOneWidget);

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

      await tester.tap(find.text('Automation'));
      await tester.pumpAndSettle();
      final obsTile = find.text('Observed Sources');
      await tester.scrollUntilVisible(obsTile, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(obsTile, findsOneWidget);

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

      // Proxy row (Network) opens a dialog and saves to the 'proxy' key.
      final netCat = find.text('Network and speed');
      await tester.scrollUntilVisible(netCat, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(netCat);
      await tester.pumpAndSettle();
      final proxyTile = find.text('Proxy server');
      expect(proxyTile, findsOneWidget);
      await tester.tap(proxyTile);
      await tester.pumpAndSettle();
      expect(find.text('Proxy URL'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'http://proxy:8080');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(prefs.getString('proxy'), 'http://proxy:8080');

      // Verbose switch (System) flips the existing 'verbose' key.
      await tester.pageBack();
      await tester.pumpAndSettle();
      final sysCat = find.text('System & Diagnostics');
      await tester.scrollUntilVisible(sysCat, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(sysCat);
      await tester.pumpAndSettle();
      final verboseTile = find.text('Detailed engine logging');
      expect(verboseTile, findsOneWidget);
      expect(prefs.getBool('verbose') ?? false, isFalse);
      await tester.tap(verboseTile);
      await tester.pumpAndSettle();
      expect(prefs.getBool('verbose'), isTrue);

      // Update channel dialog (Packages) writes the 'updateChannel' key.
      await tester.pageBack();
      await tester.pumpAndSettle();
      final pkgCat = find.text('Packages & Updates');
      await tester.scrollUntilVisible(pkgCat, 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(pkgCat);
      await tester.pumpAndSettle();
      final channelTile = find.text('Update channel');
      expect(channelTile, findsOneWidget);
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
