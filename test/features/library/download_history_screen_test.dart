import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/database/download_history_db.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/features/library/screens/download_history_screen.dart';
import 'package:grablytic/providers/download_history_provider.dart';

class _RecordingEngine extends MockEngineService {
  final List<String> openedPaths = [];

  @override
  Future<Map<String, dynamic>> openFile(String path) async {
    openedPaths.add(path);
    return {'success': true};
  }
}

DownloadRecord _record(
  String id, {
  String? filePath,
  String? thumbnailPath,
  String status = 'completed',
}) =>
    DownloadRecord(
      id: id,
      url: 'https://instagram.com/p/$id/',
      title: 'reel $id',
      platform: 'instagram',
      status: status,
      filePath: filePath,
      thumbnailPath: thumbnailPath,
    );

Future<void> _pump(
  WidgetTester tester,
  _RecordingEngine engine,
  List<DownloadRecord> records, {
  bool grid = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadHistoryProvider.overrideWith((ref) async => records),
        engineProvider.overrideWithValue(engine),
      ],
      child: MaterialApp(
        home: Scaffold(body: DownloadHistoryScreen(useGridView: grid)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('history_thumb_test');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('DownloadHistoryScreen thumbnails + play', () {
    testWidgets('local thumbnail renders and play opens the file',
        (tester) async {
      final thumb = File('${tmp.path}/thumb.jpg')
        ..writeAsBytesSync([0, 1, 2, 3]);
      final video = File('${tmp.path}/reel.mkv')
        ..writeAsBytesSync([0, 1, 2, 3]);
      final engine = _RecordingEngine();
      await _pump(tester, engine,
          [_record('r1', filePath: video.path, thumbnailPath: thumb.path)]);

      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('history-play-r1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('history-play-r1')));
      await tester.pumpAndSettle();
      expect(engine.openedPaths, [video.path]);
    });

    testWidgets('missing thumbnail and file shows fallback, no play button',
        (tester) async {
      final engine = _RecordingEngine();
      await _pump(tester, engine, [_record('r2')]);

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.camera_alt), findsOneWidget);
      expect(find.byKey(const Key('history-play-r2')), findsNothing);
    });

    testWidgets('stale file path shows error, never calls openFile',
        (tester) async {
      final engine = _RecordingEngine();
      await _pump(tester, engine,
          [_record('r3', filePath: '${tmp.path}/gone.mkv')]);

      expect(find.byKey(const Key('history-play-r3')), findsOneWidget);
      await tester.tap(find.byKey(const Key('history-play-r3')));
      await tester.pumpAndSettle();

      expect(engine.openedPaths, isEmpty);
      expect(find.textContaining('File not found'), findsOneWidget);
    });

    testWidgets('grid cards render thumbnail and play', (tester) async {
      final thumb = File('${tmp.path}/g.jpg')..writeAsBytesSync([0, 1]);
      final video = File('${tmp.path}/g.mkv')..writeAsBytesSync([0, 1]);
      final engine = _RecordingEngine();
      await _pump(tester, engine,
          [_record('g1', filePath: video.path, thumbnailPath: thumb.path)],
          grid: true);

      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('history-play-g1')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('history-play-g1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('history-play-g1')));
      await tester.pumpAndSettle();
      expect(engine.openedPaths, [video.path]);
    });
  });
}
