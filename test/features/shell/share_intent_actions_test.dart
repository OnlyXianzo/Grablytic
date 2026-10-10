import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/extraction_cache.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/home/widgets/share_intent_sheet.dart';
import 'package:grablytic/providers/download_provider.dart';
import 'package:grablytic/providers/engine_status_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _url = 'https://example.com/video';

class _ShareEngine extends MockEngineService {
  final formatUrls = <String>[];
  final starts = <Map<String, dynamic>>[];
  Map<String, dynamic> preview = {'success': true};
  Map<String, dynamic> response = {'success': false, 'error_message': 'Denied'};
  Completer<Map<String, dynamic>>? pendingPreview;
  Completer<Map<String, dynamic>>? pendingStart;
  bool failPreview = false;
  bool failStart = false;

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    formatUrls.add(url);
    if (failPreview) throw StateError('extract failed');
    return pendingPreview == null ? preview : await pendingPreview!.future;
  }

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    starts.add({
      'url': url,
      'id': downloadId,
      'config': Map.of(config),
      'network': networkType,
    });
    if (failStart) throw StateError('start failed');
    return pendingStart == null ? response : await pendingStart!.future;
  }
}

void main() {
  late _ShareEngine engine;
  late ProviderContainer container;
  final direct = find.widgetWithText(ElevatedButton, 'Direct download');

  setUp(() {
    engine = _ShareEngine();
    ExtractionCache.instance.clear();
  });
  tearDown(() {
    engine.dispose();
    ExtractionCache.instance.clear();
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    String url = _url,
    bool ready = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      'activePresetId': 'preset_opus',
      'saveDescription': true,
    });
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(engine),
        engineStatusProvider.overrideWith(
          (ref) async => EngineStatus(ready: ready),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showShareIntentSheet(context, url),
                child: const Text('Share'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'cold sheet paints without extracting; Play triggers extraction once',
    (tester) async {
      await pumpSheet(tester);
      expect(engine.formatUrls, isEmpty);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();
      expect(engine.formatUrls, [_url]);
      expect(find.text('Preview unavailable'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(direct).onPressed, isNotNull);
    },
  );

  testWidgets('cached unavailable preview is displayed without re-extraction', (
    tester,
  ) async {
    ExtractionCache.instance.put(_url, {'success': true});
    await pumpSheet(tester);
    expect(find.text('Preview unavailable'), findsOneWidget);
    expect(engine.formatUrls, isEmpty);
  });

  testWidgets('failed extraction leaves download actions usable', (
    tester,
  ) async {
    engine.failPreview = true;
    await pumpSheet(tester);
    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pumpAndSettle();
    expect(find.text('Preview unavailable'), findsOneWidget);
    expect(tester.widget<ElevatedButton>(direct).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'not-ready engine disables direct download and prevents preview extraction',
    (tester) async {
      await pumpSheet(tester, ready: false);
      expect(tester.widget<ElevatedButton>(direct).onPressed, isNull);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();
      expect(engine.formatUrls, isEmpty);
      expect(find.text('Preview unavailable'), findsOneWidget);
    },
  );

  testWidgets(
    'playlist sheet does not offer video playback or extract formats',
    (tester) async {
      await pumpSheet(
        tester,
        url: 'https://www.youtube.com/playlist?list=PLtest',
      );
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      expect(engine.formatUrls, isEmpty);
    },
  );

  testWidgets(
    'dismissing while extraction is pending ignores the late response',
    (tester) async {
      engine.pendingPreview = Completer<Map<String, dynamic>>();
      await pumpSheet(tester);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      engine.pendingPreview!.complete({'success': true});
      await tester.pumpAndSettle();
      expect(find.byType(ShareIntentSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final queued in [false, true]) {
    testWidgets(
      'direct download registers ${queued ? 'queued' : 'active'} item with preset config',
      (tester) async {
        engine.response = {'success': true, 'queued': queued};
        await pumpSheet(tester);
        await tester.tap(direct);
        await tester.pumpAndSettle();
        final start = engine.starts.single;
        expect(start['url'], _url);
        expect(start['network'], 'wifi');
        expect(start['config'], containsPair('audio_only', true));
        expect(start['config'], containsPair('container', 'opus'));
        expect(start['config'], containsPair('write_description', true));
        final item = container.read(downloadProvider).single;
        expect(item.id, start['id']);
        expect(item.url, _url);
        expect(item.status, queued ? 'queued' : 'downloading');
        expect(find.byType(ShareIntentSheet), findsNothing);
        expect(engine.successNotifications.single['download_id'], item.id);
        expect(engine.errorNotifications, isEmpty);
        expect(engine.formatUrls, isEmpty);
      },
    );
  }

  testWidgets(
    'failed response keeps sheet open, reports error, and allows retry',
    (tester) async {
      await pumpSheet(tester);
      await tester.tap(direct);
      await tester.pumpAndSettle();
      expect(container.read(downloadProvider), isEmpty);
      expect(find.byType(ShareIntentSheet), findsOneWidget);
      expect(engine.errorNotifications.single['error'], 'Denied');
      expect(engine.successNotifications, isEmpty);
      expect(tester.widget<ElevatedButton>(direct).onPressed, isNotNull);
      await tester.tap(direct);
      await tester.pumpAndSettle();
      expect(engine.starts, hasLength(2));
    },
  );

  testWidgets('duplicate taps cannot submit a pending download twice', (
    tester,
  ) async {
    engine.pendingStart = Completer<Map<String, dynamic>>();
    await pumpSheet(tester);
    await tester.tap(direct);
    await tester.pump();
    expect(tester.widget<ElevatedButton>(direct).onPressed, isNull);
    await tester.tap(direct);
    expect(engine.starts, hasLength(1));
    engine.pendingStart!.complete({'success': false});
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(direct).onPressed, isNotNull);
  });

  testWidgets('transport exception restores the direct download action', (
    tester,
  ) async {
    engine.failStart = true;
    await pumpSheet(tester);
    await tester.tap(direct);
    await tester.pumpAndSettle();
    expect(tester.widget<ElevatedButton>(direct).onPressed, isNotNull);
    expect(container.read(downloadProvider), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
