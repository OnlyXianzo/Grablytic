import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truestream/core/engine/engine_provider.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';
import 'package:truestream/features/home/screens/playlist_selection_screen.dart';
import 'package:truestream/providers/download_provider.dart';
import 'package:truestream/providers/settings_provider.dart';

const _playlistUrl = 'https://www.youtube.com/playlist?list=PLtest123';

/// Realistic flat-extraction mix: 3 downloadable + deleted + private,
/// matching the shapes `get_playlist_info` reports (index/title/
/// duration_seconds/is_available).
List<Map<String, dynamic>> _mockEntries() => [
      {
        'index': 1,
        'title': 'Song 1',
        'url': 'https://www.youtube.com/watch?v=aaa111aaa11',
        'duration_seconds': 180,
        'thumbnail_url': null,
        'uploader': 'Channel',
        'is_available': true,
      },
      {
        'index': 2,
        'title': '[Deleted video]',
        'url': 'https://www.youtube.com/watch?v=bbb222bbb22',
        'duration_seconds': null,
        'thumbnail_url': null,
        'uploader': null,
        'is_available': false,
      },
      {
        'index': 3,
        'title': 'Song 3',
        'url': 'https://www.youtube.com/watch?v=ccc333ccc33',
        'duration_seconds': 240,
        'thumbnail_url': null,
        'uploader': 'Channel',
        'is_available': true,
      },
      {
        'index': 4,
        'title': '[Private video]',
        'url': 'https://www.youtube.com/watch?v=ddd444ddd44',
        'duration_seconds': null,
        'thumbnail_url': null,
        'uploader': null,
        'is_available': false,
      },
      {
        'index': 5,
        'title': 'Song 5',
        'url': 'https://www.youtube.com/watch?v=eee555eee55',
        'duration_seconds': 200,
        'thumbnail_url': null,
        'uploader': 'Channel',
        'is_available': true,
      },
    ];

class _PlaylistFakeEngine extends MockEngineService {
  String? lastStartUrl;
  Map<String, dynamic>? lastStartConfig;
  int startCalls = 0;

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return {
      'success': true,
      'title': 'Test Playlist',
      'uploader': 'Channel',
      'count': 5,
      'estimated_total_bytes': null,
      'entries': _mockEntries(),
    };
  }

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    startCalls++;
    lastStartUrl = url;
    lastStartConfig = Map<String, dynamic>.from(config);
    return {'success': true, 'download_id': downloadId, 'queued': false};
  }
}

Future<SharedPreferences> _prefs() async {
  SharedPreferences.setMockInitialValues({'onboardingCompleted': true});
  return SharedPreferences.getInstance();
}

Future<_PlaylistFakeEngine> _pump(
    WidgetTester tester, _PlaylistFakeEngine engine) async {
  final prefs = await _prefs();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
      ],
      child: const MaterialApp(
        home: PlaylistSelectionScreen(url: _playlistUrl),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return engine;
}

void main() {
  group('PlaylistSelectionScreen', () {
    testWidgets('preselects available entries, unavailable greyed out',
        (tester) async {
      await _pump(tester, _PlaylistFakeEngine());

      expect(find.text('Test Playlist'), findsOneWidget);
      // 3 downloadable preselected out of 5 total.
      expect(find.text('Download 3 selected'), findsOneWidget);
      // Unavailable entries are visible (not hidden) with a marker —
      // the lazy list disposes off-screen tiles, so verify each by
      // scrolling to it.
      await tester.scrollUntilVisible(
        find.byKey(const Key('playlist-entry-2')),
        300,
      );
      await tester.pumpAndSettle();
      expect(
          find.text('Video 2 · Unavailable (deleted/private)'),
          findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('playlist-entry-4')),
        300,
      );
      await tester.pumpAndSettle();
      expect(
          find.text('Video 4 · Unavailable (deleted/private)'),
          findsOneWidget);
      // Unavailable tiles' checkboxes are disabled (greyed, not hidden).
      Checkbox boxIn(String key) => tester.widget<Checkbox>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(Checkbox),
            ),
          );
      expect(boxIn('playlist-entry-4').onChanged, isNull);
      await tester.scrollUntilVisible(
        find.byKey(const Key('playlist-entry-2')),
        -300,
      );
      await tester.pumpAndSettle();
      expect(boxIn('playlist-entry-2').onChanged, isNull);
      // ...while an available tile stays interactive.
      await tester.scrollUntilVisible(
        find.byKey(const Key('playlist-entry-1')),
        -300,
      );
      await tester.pumpAndSettle();
      expect(boxIn('playlist-entry-1').onChanged, isNotNull);
    });

    testWidgets('tapping unavailable entry does not select it',
        (tester) async {
      await _pump(tester, _PlaylistFakeEngine());

      await tester.tap(find.byKey(const Key('playlist-entry-2')));
      await tester.pumpAndSettle();
      expect(find.text('Download 3 selected'), findsOneWidget);
    });

    testWidgets('subset selection + reverse reaches startDownload',
        (tester) async {
      final engine = _PlaylistFakeEngine();
      late ProviderContainer container;
      final prefs = await _prefs();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            engineProvider.overrideWithValue(engine),
          ],
          child: const MaterialApp(
            home: PlaylistSelectionScreen(url: _playlistUrl),
          ),
        ),
      );
      await tester.pumpAndSettle();
      container = ProviderScope.containerOf(
          tester.element(find.byType(PlaylistSelectionScreen)));

      // Deselect entry 3 → subset {1, 5}.
      await tester.tap(find.byKey(const Key('playlist-entry-3')));
      await tester.pumpAndSettle();
      expect(find.text('Download 2 selected'), findsOneWidget);

      // Reverse toggle on.
      await tester.tap(find.byKey(const Key('playlist-reverse')));
      await tester.pumpAndSettle();

      await tester
          .tap(find.byKey(const Key('playlist-download-cta')));
      await tester.pumpAndSettle();

      expect(engine.startCalls, 1);
      expect(engine.lastStartUrl, _playlistUrl);
      // Ascending indices; reverse travels as the engine flag (yt-dlp
      // selects by index, then reverses the selected set).
      expect(engine.lastStartConfig?['playlist_items'], '1,5');
      expect(engine.lastStartConfig?['playlist_rev'], isTrue);
      expect(engine.lastStartConfig?.containsKey('playlist_rand'), isFalse);
      // Flows through the normal download path (queue-admitted).
      expect(container.read(downloadProvider), hasLength(1));
      expect(container.read(downloadProvider).single.status, 'downloading');
      expect(container.read(downloadProvider).single.config?['playlist_items'],
          '1,5');
    });

    testWidgets('select-all / deselect-all toggles CTA', (tester) async {
      await _pump(tester, _PlaylistFakeEngine());

      await tester
          .tap(find.byKey(const Key('playlist-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Download 0 selected'), findsOneWidget);
      final cta = tester.widget<ElevatedButton>(
        find.byKey(const Key('playlist-download-cta')),
      );
      expect(cta.onPressed, isNull);

      await tester
          .tap(find.byKey(const Key('playlist-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('Download 3 selected'), findsOneWidget);
    });

    testWidgets('shuffle is mutually exclusive with reverse',
        (tester) async {
      final engine = await _pump(tester, _PlaylistFakeEngine());

      await tester.tap(find.byKey(const Key('playlist-reverse')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playlist-shuffle')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('playlist-download-cta')));
      await tester.pumpAndSettle();

      expect(engine.lastStartConfig?['playlist_rand'], isTrue);
      expect(engine.lastStartConfig?.containsKey('playlist_rev'), isFalse);
    });
  });
}
