import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/log_buffer.dart';
import 'package:grablytic/core/utils/log_entry.dart';
import 'package:grablytic/features/home/widgets/download_log_overlay.dart';
import 'package:grablytic/providers/log_provider.dart';

LogEntry _engineLine(String id, String message) {
  return LogEntry(
    timestamp: DateTime(2026, 9, 12, 12, 0, 0),
    level: LogLevel.info,
    logger: 'grablytic_engine.downloader',
    message: message,
    context: {'download_id': id},
    source: 'engine',
  );
}

Widget _harness(LogBuffer buffer, {bool visible = true}) {
  return ProviderScope(
    overrides: [logBufferProvider.overrideWithValue(buffer)],
    child: MaterialApp(
      home: Scaffold(
        body: DownloadLogOverlay(downloadId: 'dl-1', visible: visible),
      ),
    ),
  );
}

void main() {
  group('DownloadLogOverlay', () {
    testWidgets('shows own download lines, hides others', (tester) async {
      final buffer = LogBuffer()
        ..add(_engineLine('dl-1', 'Fetching formats'))
        ..add(_engineLine('dl-2', 'other download chatter'))
        ..add(LogEntry(
          timestamp: DateTime(2026, 9, 12),
          level: LogLevel.info,
          logger: 'app',
          message: 'UI line, not engine',
          source: 'ui',
        ));
      addTearDown(buffer.dispose);

      await tester.pumpWidget(_harness(buffer));
      await tester.pump();

      expect(find.textContaining('Fetching formats'), findsOneWidget);
      expect(find.textContaining('other download chatter'), findsNothing);
      expect(find.textContaining('UI line, not engine'), findsNothing);
    });

    testWidgets('renders nothing when invisible or empty', (tester) async {
      final buffer = LogBuffer();
      addTearDown(buffer.dispose);

      await tester.pumpWidget(ProviderScope(
        overrides: [logBufferProvider.overrideWithValue(buffer)],
        child: const MaterialApp(
          home: Scaffold(
            body: DownloadLogOverlay(downloadId: 'dl-1', visible: false),
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(DownloadLogOverlay), findsOneWidget);
      expect(find.textContaining('LIVE'), findsNothing);

      await tester.pumpWidget(_harness(buffer));
      await tester.pump();
      expect(find.textContaining('LIVE'), findsNothing);
    });

    testWidgets('tap expands to older lines', (tester) async {
      final buffer = LogBuffer();
      for (var i = 0; i < 12; i++) {
        buffer.add(_engineLine('dl-1', 'line $i'));
      }
      addTearDown(buffer.dispose);

      await tester.pumpWidget(_harness(buffer));
      await tester.pump();

      // Collapsed: last 8 only.
      expect(find.textContaining('line 11'), findsOneWidget);
      expect(find.textContaining('line 0'), findsNothing);

      await tester.tap(find.byType(DownloadLogOverlay));
      await tester.pump();

      expect(find.textContaining('line 0'), findsOneWidget);
    });
  });
}
