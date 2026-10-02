import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/utils/offline_link_queue.dart';
import 'package:grablytic/features/home/widgets/offline_queue_banner.dart';
import 'package:grablytic/providers/batch_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

class _MockConnectivity implements Connectivity {
  final List<ConnectivityResult> results;
  _MockConnectivity(this.results);

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => results;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Stream.value(results);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
  return SharedPreferences.getInstance();
}

void main() {
  group('T19: OfflineQueueBanner Widget Tests', () {
    testWidgets('banner is hidden when offline queue is empty', (tester) async {
      final prefs = await _prefs();
      final store = OfflineQueueStore(prefs);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            offlineQueueStoreProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(home: Scaffold(body: OfflineQueueBanner())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('offline_queue_banner')), findsNothing);
    });

    testWidgets('banner renders count, expands list, and clears queue', (
      tester,
    ) async {
      final prefs = await _prefs();
      final store = OfflineQueueStore(prefs);
      await store.addLink(
        'https://youtube.com/watch?v=1',
        title: 'Video 1',
        source: 'share',
      );
      await store.addLink(
        'https://youtube.com/watch?v=2',
        title: 'Video 2',
        source: 'paste',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            offlineQueueStoreProvider.overrideWithValue(store),
          ],
          child: const MaterialApp(home: Scaffold(body: OfflineQueueBanner())),
        ),
      );
      await tester.pumpAndSettle();

      // Banner should be visible with count 2
      expect(find.byKey(const Key('offline_queue_banner')), findsOneWidget);
      expect(find.text('Offline Link Queue'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      // Expand the list
      final expandBtn = find.byTooltip('Show links');
      expect(expandBtn, findsOneWidget);
      await tester.tap(expandBtn);
      await tester.pumpAndSettle();

      expect(find.text('Video 1'), findsOneWidget);
      expect(find.text('Video 2'), findsOneWidget);

      // Clear all
      final clearBtn = find.byKey(const Key('offline_queue_clear_button'));
      expect(clearBtn, findsOneWidget);
      await tester.tap(clearBtn);
      await tester.pumpAndSettle();

      // Queue is now empty, banner hides
      expect(find.byKey(const Key('offline_queue_banner')), findsNothing);
      expect(store.load(), isEmpty);
    });

    testWidgets(
      'one-tap Download All starts batch and clears offline queue when online',
      (tester) async {
        final prefs = await _prefs();
        final store = OfflineQueueStore(prefs);
        await store.addLink(
          'https://youtube.com/watch?v=send1',
          title: 'Link 1',
        );
        await store.addLink(
          'https://youtube.com/watch?v=send2',
          title: 'Link 2',
        );

        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            offlineQueueStoreProvider.overrideWithValue(store),
            connectivityProvider.overrideWithValue(
              _MockConnectivity([ConnectivityResult.wifi]),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(
              home: Scaffold(body: OfflineQueueBanner()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final downloadAllBtn = find.byKey(
          const Key('offline_queue_send_all_button'),
        );
        expect(downloadAllBtn, findsOneWidget);

        await tester.tap(downloadAllBtn);
        await tester.pumpAndSettle();

        // Batch state should now contain the 2 items
        final batch = container.read(batchProvider);
        expect(batch.items.length, 2);
        expect(
          batch.items.map((i) => i.url),
          containsAll([
            'https://youtube.com/watch?v=send1',
            'https://youtube.com/watch?v=send2',
          ]),
        );

        // Queue should now be empty in store and UI
        expect(store.load(), isEmpty);
        expect(find.byKey(const Key('offline_queue_banner')), findsNothing);

        // Drain SnackBar auto-dismiss timer
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('Download All when offline preserves queue and warns user', (
      tester,
    ) async {
      final prefs = await _prefs();
      final store = OfflineQueueStore(prefs);
      await store.addLink('https://youtube.com/watch?v=keep1', title: 'Keep 1');

      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          offlineQueueStoreProvider.overrideWithValue(store),
          connectivityProvider.overrideWithValue(
            _MockConnectivity([ConnectivityResult.none]),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: OfflineQueueBanner())),
        ),
      );
      await tester.pumpAndSettle();

      final downloadAllBtn = find.byKey(
        const Key('offline_queue_send_all_button'),
      );
      await tester.tap(downloadAllBtn);
      await tester.pumpAndSettle();

      // Batch state should be empty and queue should still hold the item
      final batch = container.read(batchProvider);
      expect(batch.items, isEmpty);
      expect(store.load().length, 1);
      expect(
        find.text('Cannot start downloads: device is still offline.'),
        findsOneWidget,
      );

      // Drain SnackBar auto-dismiss timer
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
