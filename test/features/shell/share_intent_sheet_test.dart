import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truestream/core/engine/engine_provider.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';
import 'package:truestream/features/home/screens/format_picker_screen.dart';
import 'package:truestream/features/home/widgets/share_intent_sheet.dart';
import 'package:truestream/providers/engine_status_provider.dart';
import 'package:truestream/providers/settings_provider.dart';

const _sharedUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

/// Mock engine returning a thumbnail so the metadata header's Image branch
/// is exercised (the base mock returns thumbnail_url: null).
class _ThumbnailMockEngine extends MockEngineService {
  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    final base = await super.getFormats(url: url, config: config);
    return {
      ...base,
      'thumbnail_url': 'https://img.youtube.com/vi/dQw4w9WgXcQ/0.jpg',
    };
  }
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
  return SharedPreferences.getInstance();
}

void main() {
  group('ShareIntentSheet', () {
    testWidgets('shows URL and gated Continue when engine is ready',
        (tester) async {
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
            home: Scaffold(body: ShareIntentSheet(url: _sharedUrl)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Shared link'), findsOneWidget);
      expect(find.textContaining('youtube.com'), findsOneWidget);
      final cta = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Choose quality & download'),
      );
      expect(cta.onPressed, isNotNull);
      expect(find.text('Not now'), findsOneWidget);
    });

    testWidgets('Continue opens FormatPickerScreen', (tester) async {
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
            home: Scaffold(body: ShareIntentSheet(url: _sharedUrl)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose quality & download'));
      await tester.pumpAndSettle();

      expect(find.byType(FormatPickerScreen), findsOneWidget);
      expect(find.text('Sample Video'), findsOneWidget);
    });

    testWidgets('disables Continue while engine is still setting up',
        (tester) async {
      final prefs = await _prefs();
      final mockEngine = MockEngineService();
      // Never-completing completer (no Timer scheduled) => AsyncLoading.
      final never = Completer<EngineStatus>();
      addTearDown(() {
        if (!never.isCompleted) never.completeError(StateError('disposed'));
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            // Never-completing future => AsyncLoading => "setting up" state.
            engineStatusProvider.overrideWith((ref) => never.future),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ShareIntentSheet(url: _sharedUrl)),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Setting up the engine'), findsOneWidget);
      final cta = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Choose quality & download'),
      );
      expect(cta.onPressed, isNull);
    });

    testWidgets('shows not-ready state on engine error', (tester) async {
      final prefs = await _prefs();
      final mockEngine = MockEngineService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            engineStatusProvider.overrideWith(
              (ref) => Future.value(
                const EngineStatus(ready: false, error: 'bootstrap failed'),
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: ShareIntentSheet(url: _sharedUrl)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('bootstrap failed'), findsOneWidget);
    });
  });

  group('FormatPicker metadata preview header', () {
    testWidgets('shows duration + stream counts + fallback art',
        (tester) async {
      final prefs = await _prefs();
      final mockEngine = MockEngineService();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: FormatPickerScreen(url: _sharedUrl, title: _sharedUrl),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 312 s from the mock => 05:12 via _formatDuration.
      expect(find.text('Duration 05:12'), findsOneWidget);
      // Mock returns 4 video + 2 audio, no muxed.
      expect(find.text('4 video · 2 audio streams'), findsOneWidget);
      // Null thumbnail => fallback placeholder icon.
      expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    });

    testWidgets('renders network thumbnail when engine provides one',
        (tester) async {
      final prefs = await _prefs();
      final mockEngine = _ThumbnailMockEngine();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: FormatPickerScreen(url: _sharedUrl, title: _sharedUrl),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Image widget is present even while the network fetch resolves/fails
      // (errorBuilder covers the failure path in tests without HTTP mocks).
      expect(find.byType(Image), findsWidgets);
      expect(find.text('Duration 05:12'), findsOneWidget);
    });
  });
}
