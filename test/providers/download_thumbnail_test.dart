import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/database/download_history_db.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/library/screens/library_screen.dart';
import 'package:grablytic/providers/download_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

DownloadNotifier _notifier() => DownloadNotifier(MockEngineService());

void main() {
  group('Task 03: local thumbnail path propagation', () {
    test('finished event captures thumbnail_path into item state', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'dl-thumb', title: 't', url: 'https://x.test/v'));
      n.handleProgressEvent({
        'type': 'event',
        'event': 'finished',
        'download_id': 'dl-thumb',
        'filesize_bytes': 100,
        'file_path': '/tmp/video.mkv',
        'thumbnail_path': '/tmp/video.jpg',
      });
      final item = n.state.single;
      expect(item.status, 'completed');
      expect(item.filePath, '/tmp/video.mkv');
      expect(item.thumbnailPath, '/tmp/video.jpg');
    });

    test('finished without thumbnail_path preserves pre-existing path', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
        id: 'dl-keep',
        title: 't',
        url: 'https://x.test/v',
        thumbnailUrl: 'https://x.test/thumb.jpg',
      ));
      // First finish reports a sidecar …
      n.handleProgressEvent({
        'type': 'event',
        'event': 'finished',
        'download_id': 'dl-keep',
        'filesize_bytes': 100,
        'thumbnail_path': '/tmp/video.jpg',
      });
      expect(n.state.single.thumbnailPath, '/tmp/video.jpg');
      // … a later finish without the key (old engine) must not wipe it.
      n.handleProgressEvent({
        'type': 'event',
        'event': 'finished',
        'download_id': 'dl-keep',
        'filesize_bytes': 100,
      });
      expect(n.state.single.thumbnailPath, '/tmp/video.jpg');
      expect(n.state.single.thumbnailUrl, 'https://x.test/thumb.jpg');
    });

    test('DownloadRecord round-trips thumbnailPath', () {
      final record = DownloadRecord(
        id: 'r1',
        url: 'https://x.test/v',
        title: 't',
        thumbnailUrl: 'https://x.test/thumb.jpg',
        thumbnailPath: '/tmp/video.jpg',
      );
      final back = DownloadRecord.fromMap(record.toMap());
      expect(back.thumbnailPath, '/tmp/video.jpg');
      expect(back.thumbnailUrl, 'https://x.test/thumb.jpg');
    });

    test('DownloadRecord.fromMap tolerates pre-v2 rows without the key', () {
      final back = DownloadRecord.fromMap({
        'id': 'r0',
        'url': 'https://x.test/v',
        'title': 't',
      });
      expect(back.thumbnailPath, isNull);
      expect(back.thumbnailUrl, isNull);
    });
  });

  group('Task 03: Library local-thumbnail fallback', () {
    late SharedPreferences prefs;
    late MockEngineService mockEngine;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      mockEngine = MockEngineService();
    });

    testWidgets(
        'missing local sidecar renders placeholder, not a broken image',
        (WidgetTester tester) async {
      final item = DownloadItem(
        id: 'dl-local-thumb',
        title: 'Local Thumb Video',
        url: 'https://example.com/video',
        status: 'completed',
        filePath: '/tmp/definitely_missing_video.mkv',
        // Sidecar path that does not exist on disk: _ThumbnailImage must
        // fall back to the placeholder icon instead of throwing.
        thumbnailPath: '/tmp/definitely_missing_thumb.jpg',
        thumbnailUrl: '',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(mockEngine),
            downloadProvider.overrideWith((ref) {
              final notifier = DownloadNotifier(mockEngine);
              notifier.addDownload(item);
              return notifier;
            }),
          ],
          child: const MaterialApp(home: LibraryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Local Thumb Video'), findsOneWidget);
      // List-view completed fallback icon (no network image attempted).
      expect(find.byIcon(Icons.image_outlined), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
