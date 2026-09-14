import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/screens/home_screen.dart';
import 'package:grablytic/features/home/screens/search_results_screen.dart';
import 'package:grablytic/features/home/screens/format_picker_screen.dart';
import 'package:grablytic/features/home/widgets/error_recovery_card.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/providers/search_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _NoopResumeNotifier extends ResumeNotifier {
  _NoopResumeNotifier(super.ref);

  @override
  Future<void> scan() async {
    state = const AsyncValue.data([]);
  }
}

void main() {
  group('Search Flow Integration', () {
    late SharedPreferences prefs;
    late MockEngineService mockEngine;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'onboardingCompleted': true,
      });
      prefs = await SharedPreferences.getInstance();
      mockEngine = MockEngineService();
    });

    testWidgets('Submitting URL in HomeScreen opens FormatPickerScreen directly',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final inputFinder = find.byType(TextField);
      expect(inputFinder, findsOneWidget);

      await tester.enterText(
        inputFinder,
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      await tester.pump();

      // Submit via button or onSubmitted
      final submitButton = find.bySemanticsLabel('Submit URL');
      expect(submitButton, findsOneWidget);
      await tester.tap(submitButton);
      await tester.pumpAndSettle();

      // Verify FormatPickerScreen is opened
      expect(find.byType(FormatPickerScreen), findsOneWidget);
      expect(find.text('Sample Video'), findsOneWidget);
    });

    testWidgets('Submitting keywords in HomeScreen opens SearchResultsScreen',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            resumeProvider.overrideWith((ref) => _NoopResumeNotifier(ref)),
          ],
          child: const MaterialApp(
            home: HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final inputFinder = find.byType(TextField);
      expect(inputFinder, findsOneWidget);

      await tester.enterText(inputFinder, 'rick astley');
      await tester.pump();

      // Submit button dynamically reflects search mode
      final searchButton = find.bySemanticsLabel('Search videos');
      expect(searchButton, findsOneWidget);
      await tester.tap(searchButton);
      await tester.pumpAndSettle();

      // Verify SearchResultsScreen is opened
      expect(find.byType(SearchResultsScreen), findsOneWidget);
      expect(find.text('2 results for "rick astley"'), findsOneWidget);
      expect(find.text('rick astley - Official Video'), findsOneWidget);
      expect(find.text('rick astley - Live Performance'), findsOneWidget);
    });

    testWidgets('Tapping search result in SearchResultsScreen opens FormatPickerScreen',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: SearchResultsScreen(
              initialQuery: 'ambient music',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2 results for "ambient music"'), findsOneWidget);
      final firstResult = find.text('ambient music - Official Video');
      expect(firstResult, findsOneWidget);

      await tester.tap(firstResult);
      await tester.pumpAndSettle();

      // FormatPickerScreen should be opened for that specific result URL
      expect(find.byType(FormatPickerScreen), findsOneWidget);
    });

    testWidgets('Switching site chip to SoundCloud triggers search for that site',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: SearchResultsScreen(
              initialQuery: 'synthwave',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final soundCloudChip = find.text('SoundCloud');
      expect(soundCloudChip, findsOneWidget);

      await tester.tap(soundCloudChip);
      await tester.pumpAndSettle();

      final searchState = ProviderScope.containerOf(tester.element(find.byType(SearchResultsScreen)))
          .read(searchProvider);
      expect(searchState.site, equals('soundcloud'));
    });

    testWidgets('Search error displays ErrorRecoveryCard with retry',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: SearchResultsScreen(
              initialQuery: '__trigger_error__',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ErrorRecoveryCard), findsOneWidget);
      expect(find.textContaining("Sign in to confirm you're not a bot"), findsOneWidget);
    });

    testWidgets('Empty search results renders empty state message',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
          ],
          child: const MaterialApp(
            home: SearchResultsScreen(
              initialQuery: '__empty__',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No results found'), findsOneWidget);
      expect(
        find.text('Try different keywords or check your network connection.'),
        findsOneWidget,
      );
    });
  });
}
