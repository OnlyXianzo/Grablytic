import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truestream/core/engine/engine_provider.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';
import 'package:truestream/features/library/screens/library_screen.dart';
import 'package:truestream/providers/download_provider.dart';
import 'package:truestream/providers/settings_provider.dart';

void main() {
  group('LibraryScreen failed download rendering', () {
    late SharedPreferences prefs;
    late MockEngineService mockEngine;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mockEngine = MockEngineService();
    });

    testWidgets('renders FAILED section with error message and retry button in list view',
        (WidgetTester tester) async {
      final failedItem = DownloadItem(
        id: 'dl-err-1',
        title: 'Test Failed Video',
        url: 'https://example.com/video',
        status: 'error',
        errorMessage: 'ffmpeg not found. Please install or provide the path',
        errorType: 'ERROR_FFMPEG',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            downloadProvider.overrideWith((ref) {
              final notifier = DownloadNotifier(mockEngine);
              notifier.addDownload(failedItem);
              return notifier;
            }),
          ],
          child: const MaterialApp(
            home: LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify the screen does NOT show "No downloads yet"
      expect(find.text('No downloads yet'), findsNothing);

      // Verify the FAILED section header is displayed
      expect(find.text('FAILED'), findsOneWidget);

      // Verify the failed item title and error message are visible
      expect(find.text('Test Failed Video'), findsOneWidget);
      expect(
        find.text('ffmpeg not found. Please install or provide the path'),
        findsOneWidget,
      );

      // Verify the retry button is present
      final retryBtn = find.byTooltip('Retry');
      expect(retryBtn, findsOneWidget);
    });

    testWidgets('renders failed item in grid view without blank view',
        (WidgetTester tester) async {
      final failedItem = DownloadItem(
        id: 'dl-err-2',
        title: 'Test Grid Failed Video',
        url: 'https://example.com/video2',
        status: 'error',
        errorMessage: 'Connection timed out',
        errorType: 'ERROR_NETWORK',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            downloadProvider.overrideWith((ref) {
              final notifier = DownloadNotifier(mockEngine);
              notifier.addDownload(failedItem);
              return notifier;
            }),
          ],
          child: const MaterialApp(
            home: LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to grid view
      final gridToggle = find.byTooltip('Grid view');
      expect(gridToggle, findsOneWidget);
      await tester.tap(gridToggle);
      await tester.pumpAndSettle();

      // Verify failed item is displayed in grid view
      expect(find.text('Test Grid Failed Video'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Connection timed out'), findsOneWidget);
      expect(find.byTooltip('Retry'), findsOneWidget);
    });

    testWidgets('renders downloading item with stageLabel in grid view instead of N/A',
        (WidgetTester tester) async {
      final downloadingItem = DownloadItem(
        id: 'dl-stage-1',
        title: 'Test Stage Video',
        url: 'https://example.com/stage-video',
        status: 'downloading',
        progress: 0.99,
        stage: 'merging',
        stageLabel: 'Merging streams...',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            downloadProvider.overrideWith((ref) {
              final notifier = DownloadNotifier(mockEngine);
              notifier.addDownload(downloadingItem);
              return notifier;
            }),
          ],
          child: const MaterialApp(
            home: LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to grid view
      final gridToggle = find.byTooltip('Grid view');
      expect(gridToggle, findsOneWidget);
      await tester.tap(gridToggle);
      await tester.pumpAndSettle();

      // Verify item title and stage label are rendered, and "N/A" is NEVER displayed
      expect(find.text('Test Stage Video'), findsOneWidget);
      expect(find.text('Merging streams...'), findsOneWidget);
      expect(find.text('N/A'), findsNothing);
    });

    testWidgets('renders downloading item with stageLabel and speed in list view',
        (WidgetTester tester) async {
      final downloadingItem = DownloadItem(
        id: 'dl-stage-2',
        title: 'Test Speed Video',
        url: 'https://example.com/speed-video',
        status: 'downloading',
        progress: 0.5,
        downloadedBytes: 5242880, // 5 MB
        totalBytes: 10485760, // 10 MB
        speed: 2097152, // 2 MB/s
        stage: 'converting_thumbnail',
        stageLabel: 'Converting thumbnail...',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            downloadProvider.overrideWith((ref) {
              final notifier = DownloadNotifier(mockEngine);
              notifier.addDownload(downloadingItem);
              return notifier;
            }),
          ],
          child: const MaterialApp(
            home: LibraryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Test Speed Video'), findsOneWidget);
      expect(find.text('Converting thumbnail...'), findsOneWidget);
      expect(find.text('50 % downloading'), findsOneWidget);
      expect(find.textContaining('2.0 MB/s'), findsOneWidget);
    });
  });
}
