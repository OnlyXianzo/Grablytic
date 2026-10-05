import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/library/screens/library_screen.dart';
import 'package:grablytic/providers/download_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

Future<void> _pumpLibrary(
  WidgetTester tester,
  SharedPreferences prefs,
  MockEngineService engine,
  List<DownloadItem> items,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
        downloadProvider.overrideWith((ref) {
          final notifier = DownloadNotifier(engine);
          for (final item in items) {
            notifier.addDownload(item);
          }
          return notifier;
        }),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

DownloadItem _item(String id, String title, String status) => DownloadItem(
      id: id,
      title: title,
      url: 'https://example.com/$id',
      status: status,
    );

void main() {
  late SharedPreferences prefs;
  late MockEngineService engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    engine = MockEngineService();
  });

  group('Library P4-2 fidelity (segmented + search + chips)', () {
    testWidgets('segmented control switches to Playlists tab', (tester) async {
      await _pumpLibrary(tester, prefs, engine, []);
      expect(find.text('No downloads yet'), findsOneWidget);
      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      expect(find.text('No playlists yet'), findsOneWidget);
    });

    testWidgets('search narrows rows by title', (tester) async {
      await _pumpLibrary(tester, prefs, engine, [
        _item('a1', 'Alpha Video', 'completed'),
        _item('b1', 'Beta Clip', 'completed'),
      ]);
      expect(find.text('Alpha Video'), findsOneWidget);
      expect(find.text('Beta Clip'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextField, 'Search title or link'), 'alpha');
      await tester.pumpAndSettle();
      expect(find.text('Alpha Video'), findsOneWidget);
      expect(find.text('Beta Clip'), findsNothing);
    });

    testWidgets('failed chip isolates the Failed section', (tester) async {
      await _pumpLibrary(tester, prefs, engine, [
        _item('c1', 'Done One', 'completed'),
        _item('e1', 'Bad One', 'error'),
      ]);
      await tester.tap(find.widgetWithText(FilterChip, 'Failed'));
      await tester.pumpAndSettle();
      expect(find.text('Failed downloads'), findsOneWidget);
      expect(find.text('Bad One'), findsOneWidget);
      expect(find.text('Done One'), findsNothing);
      expect(find.text('Downloaded'), findsNothing);
    });

    testWidgets('in-row delete asks for confirm on terminal rows',
        (tester) async {
      await _pumpLibrary(tester, prefs, engine, [
        _item('d1', 'Deletable', 'completed'),
      ]);
      await tester.tap(find.byTooltip('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete file?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Deletable'), findsOneWidget);
    });
  });
}
