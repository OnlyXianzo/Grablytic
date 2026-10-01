import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/features/home/screens/playlist_selection_screen.dart';
import 'package:grablytic/features/home/screens/share_overlay_screen.dart';
import 'package:grablytic/providers/engine_status_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

Future<SharedPreferences> _prefs({
  Map<String, Object> initial = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    'onboardingCompleted': true,
    ...initial,
  });
  return SharedPreferences.getInstance();
}

void main() {
  group('ShareOverlayScreen URL extraction', () {
    test('extractUrl parses plain URL', () {
      expect(
        ShareOverlayScreen.extractUrl(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
    });

    test('extractUrl parses embedded URL from share text', () {
      expect(
        ShareOverlayScreen.extractUrl(
          'Check this out: https://youtu.be/dQw4w9WgXcQ from YouTube!',
        ),
        'https://youtu.be/dQw4w9WgXcQ',
      );
    });

    test('extractUrl returns null for invalid or empty text', () {
      expect(ShareOverlayScreen.extractUrl(null), isNull);
      expect(ShareOverlayScreen.extractUrl(''), isNull);
      expect(
        ShareOverlayScreen.extractUrl('Just plain text without link'),
        isNull,
      );
    });
  });

  group('ShareOverlayScreen rendering', () {
    testWidgets('renders FormatPickerScreen for standard video link', (
      tester,
    ) async {
      final prefs = await _prefs();
      final mockEngine = MockEngineService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            engineStatusProvider.overrideWith(
              (ref) => Future.value(const EngineStatus(ready: true)),
            ),
          ],
          child: const MaterialApp(
            home: ShareOverlayScreen(
              initialUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(FormatPickerScreen), findsOneWidget);
    });

    testWidgets('renders PlaylistSelectionScreen for playlist link', (
      tester,
    ) async {
      final prefs = await _prefs();
      final mockEngine = MockEngineService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            engineStatusProvider.overrideWith(
              (ref) => Future.value(const EngineStatus(ready: true)),
            ),
          ],
          child: const MaterialApp(
            home: ShareOverlayScreen(
              initialUrl: 'https://www.youtube.com/playlist?list=PL123456',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PlaylistSelectionScreen), findsOneWidget);
    });

    testWidgets('shows empty state when no URL resolved', (tester) async {
      final prefs = await _prefs();
      final mockEngine = MockEngineService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            engineStatusProvider.overrideWith(
              (ref) => Future.value(const EngineStatus(ready: true)),
            ),
          ],
          child: const MaterialApp(home: ShareOverlayScreen(initialUrl: null)),
        ),
      );
      // Wait for the timeout to elapse
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pumpAndSettle();

      expect(find.text('No valid link received'), findsOneWidget);
    });

    testWidgets(
      'auto-starts download without showing picker when shareBehavior=auto',
      (tester) async {
        final prefs = await _prefs(initial: {'share_behavior': 'auto'});
        final mockEngine = MockEngineService();

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              engineProvider.overrideWithValue(mockEngine),
              engineStatusProvider.overrideWith(
                (ref) => Future.value(const EngineStatus(ready: true)),
              ),
            ],
            child: const MaterialApp(
              home: ShareOverlayScreen(
                initialUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));

        // Picker UI should NOT be shown
        expect(find.byType(FormatPickerScreen), findsNothing);
        expect(find.textContaining('Auto-starting download'), findsOneWidget);

        // Drain SnackBar timer
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('triggers error notification when auto-start fails', (
      tester,
    ) async {
      final prefs = await _prefs(initial: {'share_behavior': 'auto'});
      final mockEngine = _FailingStartMockEngine();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            engineStatusProvider.overrideWith(
              (ref) => Future.value(const EngineStatus(ready: true)),
            ),
          ],
          child: const MaterialApp(
            home: ShareOverlayScreen(
              initialUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(mockEngine.errorNotifications, isNotEmpty);
      expect(
        mockEngine.errorNotifications.first['error'],
        contains('Format extraction failed'),
      );

      // Drain SnackBar timer
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });
}

class _FailingStartMockEngine extends MockEngineService {
  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    return {
      'success': false,
      'error_type': 'ERROR_EXTRACTION',
      'error_message': 'Format extraction failed: unsupported URL',
    };
  }
}
