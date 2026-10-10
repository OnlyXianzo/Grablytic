import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/offline_link_queue.dart';
import 'package:grablytic/features/home/screens/batch_download_screen.dart';
import 'package:grablytic/features/home/screens/link_saver_screen.dart';
import 'package:grablytic/features/home/widgets/offline_queue_banner.dart';
import 'package:grablytic/providers/batch_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Connectivity implements Connectivity {
  final bool online;
  _Connectivity(this.online);
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    online ? ConnectivityResult.wifi : ConnectivityResult.none,
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Record the UI's dispatch contract without starting downloads or touching SQLite.
class _RecordingBatch extends BatchNotifier {
  _RecordingBatch(super.ref);
  int starts = 0;
  @override
  void startBatch(
    List<BatchItem> items, {
    String? playlistId,
    String? qualityCeiling,
    bool skipExisting = true,
  }) {
    starts++;
    state = BatchState(items: items, qualityCeiling: qualityCeiling);
  }
}

void main() {
  late OfflineQueueStore store;
  late ProviderContainer container;
  late _RecordingBatch batch;

  Future<void> pumpQueue(
    WidgetTester tester, {
    bool banner = false,
    bool online = true,
    bool empty = false,
  }) async {
    SharedPreferences.setMockInitialValues({'activePresetId': 'preset_720p'});
    final prefs = await SharedPreferences.getInstance();
    store = OfflineQueueStore(prefs);
    if (!empty) {
      await store.addLink(
        'https://example.com/one',
        title: 'First video',
        source: 'share',
      );
      await store.addLink('https://example.com/two', source: 'clipboard');
    }
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        offlineQueueStoreProvider.overrideWithValue(store),
        connectivityProvider.overrideWithValue(_Connectivity(online)),
        batchProvider.overrideWith((ref) => batch = _RecordingBatch(ref)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: banner
              ? Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: OfflineQueueBanner()),
                  ),
                )
              : const LinkSaverScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty Link Saver has no download actions', (tester) async {
    await pumpQueue(tester, empty: true);
    expect(find.text('No saved links'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets(
    'saved links show title fallback and source icons; delete persists',
    (tester) async {
      await pumpQueue(tester);
      expect(find.text('First video'), findsOneWidget);
      expect(find.text('https://example.com/two'), findsOneWidget);
      expect(find.byIcon(Icons.share_outlined), findsOneWidget);
      expect(find.byIcon(Icons.content_paste_outlined), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('link_saver_delete_https://example.com/one')),
      );
      await tester.pumpAndSettle();
      expect(store.load().map((link) => link.url), ['https://example.com/two']);
      expect(find.text('Download All (1)'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('link_saver_delete_https://example.com/two')),
      );
      await tester.pumpAndSettle();
      expect(store.load(), isEmpty);
      expect(find.text('No saved links'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    },
  );

  for (final banner in [false, true]) {
    testWidgets(
      '${banner ? 'banner' : 'Link Saver'} downloads only the selected link',
      (tester) async {
        await pumpQueue(tester, banner: banner);
        if (banner) {
          await tester.tap(find.byTooltip('Show links'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Download').first);
        } else {
          await tester.tap(find.text('Download').first);
        }
        await tester.pumpAndSettle();
        final state = container.read(batchProvider);
        expect(state.items.single.url, 'https://example.com/one');
        expect(state.items.single.title, 'First video');
        expect(state.qualityCeiling, '720p');
        expect(batch.starts, 1);
        expect(store.load().map((link) => link.url), [
          'https://example.com/two',
        ]);
      },
    );
  }

  testWidgets(
    'View Batch survives clearing the banner and uses the root navigator',
    (tester) async {
      await pumpQueue(tester, banner: true);
      final nestedNavigator = tester.state<NavigatorState>(
        find.byType(Navigator).last,
      );
      await tester.tap(find.byKey(const Key('offline_queue_send_all_button')));
      await tester.pumpAndSettle();
      expect(store.load(), isEmpty);
      expect(find.byKey(const Key('offline_queue_banner')), findsNothing);
      expect(container.read(batchProvider).items.map((item) => item.url), [
        'https://example.com/one',
        'https://example.com/two',
      ]);
      expect(
        tester.widget<SnackBar>(find.byType(SnackBar)).duration,
        const Duration(seconds: 5),
      );
      await tester.tap(find.text('View Batch'));
      await tester.pumpAndSettle();
      final screen = tester.widget<BatchDownloadScreen>(
        find.byType(BatchDownloadScreen),
      );
      expect(screen.skipQualityDialog, isTrue);
      expect(screen.items, hasLength(2));
      expect(nestedNavigator.canPop(), isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      // Viewing an existing batch must not dispatch it again.
      expect(batch.starts, 1);
    },
  );

  testWidgets('Link Saver Download All preserves saved links when offline', (
    tester,
  ) async {
    await pumpQueue(tester, online: false);
    await tester.tap(find.byKey(const Key('link_saver_download_all_fab')));
    await tester.pumpAndSettle();
    expect(store.load(), hasLength(2));
    expect(container.read(batchProvider).items, isEmpty);
    expect(
      find.text('Cannot start downloads: device is still offline.'),
      findsOneWidget,
    );
  });
}
