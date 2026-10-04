import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/widgets/download_overflow_menu.dart';
import 'package:grablytic/providers/download_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

Future<void> _pumpMenu(
  WidgetTester tester,
  DownloadItem item,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final engine = MockEngineService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
        downloadProvider.overrideWith((ref) {
          final notifier = DownloadNotifier(engine);
          notifier.addDownload(item);
          return notifier;
        }),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 390,
              // Card-row geometry: title takes the space, actions sit at
              // the right edge so the popup anchors and flips leftward
              // exactly like production rows.
              child: Row(
                children: [
                  const Expanded(child: Text('Menu Item')),
                  DownloadOverflowButton(
                    item: item,
                    colorScheme: const ColorScheme.dark(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
}

DownloadItem _item(String status) => DownloadItem(
      id: 'm1',
      title: 'Menu Item',
      url: 'https://example.com/m1',
      status: status,
    );

void main() {
  // Phone-like viewport so the popup menu fits as on device (the default
  // 800px test surface pushes the right-anchored menu off-edge).
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('DownloadOverflowButton cancel action', () {
    testWidgets('active download offers working Cancel', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      await _pumpMenu(tester, _item('downloading'));
      expect(find.text('Cancel download'), findsOneWidget);
      await tester.tap(find.text('Cancel download'));
      await tester.pumpAndSettle();
      expect(find.text('Cancelling download'), findsOneWidget);
    });

    testWidgets('terminal download shows Cancel disabled', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      await _pumpMenu(tester, _item('completed'));
      final cancelTile = find.text('Cancel download');
      expect(cancelTile, findsOneWidget);
      await tester.tap(cancelTile);
      await tester.pumpAndSettle();
      // Disabled: no snackbar, menu still open.
      expect(find.text('Cancelling download'), findsNothing);
      expect(find.text('Cancel download'), findsOneWidget);
    });
  });
}
