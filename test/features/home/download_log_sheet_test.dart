import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truestream/core/utils/log_buffer.dart';
import 'package:truestream/core/utils/log_entry.dart';
import 'package:truestream/features/home/widgets/download_log_sheet.dart';
import 'package:truestream/providers/log_provider.dart';

void main() {
  late LogBuffer buffer;

  setUp(() {
    buffer = LogBuffer();
  });

  Widget buildTestWidget({
    required String downloadId,
    required String title,
    String? status,
    String? url,
  }) {
    return ProviderScope(
      overrides: [
        logBufferProvider.overrideWithValue(buffer),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: DownloadLogSheet(
            downloadId: downloadId,
            title: title,
            status: status,
            url: url,
          ),
        ),
      ),
    );
  }

  testWidgets('renders title, status, and download ID', (tester) async {
    await tester.pumpWidget(
      buildTestWidget(
        downloadId: 'dl-test-1234567890',
        title: 'Rick Astley - Never Gonna Give You Up',
        status: 'downloading',
      ),
    );

    expect(find.text('Rick Astley - Never Gonna Give You Up'), findsOneWidget);
    expect(find.text('DOWNLOADING'), findsOneWidget);
    expect(find.textRange.ofSubstring('ID: dl-test-1234'), findsOneWidget);
  });

  testWidgets('renders empty state when no logs exist', (tester) async {
    await tester.pumpWidget(
      buildTestWidget(
        downloadId: 'dl-empty',
        title: 'Empty Download',
      ),
    );
    // Disk-fallback check is async (shows a spinner first); settle it.
    await tester.pump();
    await tester.pump();

    expect(find.text('No logs recorded for this download yet'), findsOneWidget);
  });

  testWidgets('renders scoped log entries for target downloadId', (tester) async {
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      logger: 'downloader',
      message: 'Download started for video',
      downloadId: 'dl-target',
    ));
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.warn,
      logger: 'hooks',
      message: 'Milestone reached 50%',
      downloadId: 'dl-target',
    ));
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      logger: 'other',
      message: 'Unrelated download log',
      downloadId: 'dl-other',
    ));

    await tester.pumpWidget(
      buildTestWidget(
        downloadId: 'dl-target',
        title: 'Target Item',
      ),
    );

    expect(find.textRange.ofSubstring('Download started for video'), findsOneWidget);
    expect(find.textRange.ofSubstring('Milestone reached 50%'), findsOneWidget);
    expect(find.textRange.ofSubstring('Unrelated download log'), findsNothing);
  });

  testWidgets('search query filters log lines in real-time', (tester) async {
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      logger: 'downloader',
      message: 'Connecting to server',
      downloadId: 'dl-search',
    ));
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.error,
      logger: 'ffmpeg',
      message: 'Conversion failed',
      downloadId: 'dl-search',
    ));

    await tester.pumpWidget(
      buildTestWidget(
        downloadId: 'dl-search',
        title: 'Search Item',
      ),
    );

    expect(find.textRange.ofSubstring('Connecting to server'), findsOneWidget);
    expect(find.textRange.ofSubstring('Conversion failed'), findsOneWidget);

    // Enter search filter
    await tester.enterText(find.byType(TextField), 'Conversion');
    await tester.pumpAndSettle();

    expect(find.textRange.ofSubstring('Connecting to server'), findsNothing);
    expect(find.textRange.ofSubstring('Conversion failed'), findsOneWidget);
  });

  testWidgets('live stream updates sheet automatically when new entry added', (tester) async {
    await tester.pumpWidget(
      buildTestWidget(
        downloadId: 'dl-live',
        title: 'Live Item',
      ),
    );

    // Disk-fallback check is async (shows a spinner first); settle it.
    await tester.pump();
    await tester.pump();

    expect(find.text('No logs recorded for this download yet'), findsOneWidget);

    // Emit live log
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      logger: 'live_test',
      message: 'Incoming live fragment downloaded',
      downloadId: 'dl-live',
    ));

    await tester.pump();
    await tester.pump();

    expect(find.textRange.ofSubstring('Incoming live fragment downloaded'), findsOneWidget);
    expect(find.text('No logs recorded for this download yet'), findsNothing);
  });

  testWidgets('completed download logs remain viewable after global buffer overflow', (tester) async {
    // Tiny global buffer: proves the sheet reads the per-download store,
    // not just the live global entries.
    buffer = LogBuffer(maxEntries: 3);
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      logger: 'downloader',
      message: 'Download started for finished video',
      downloadId: 'dl-done',
    ));
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.error,
      logger: 'downloader',
      message: 'Transient fragment retry',
      downloadId: 'dl-done',
    ));
    buffer.add(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      logger: 'downloader',
      message: 'Download completed',
      downloadId: 'dl-done',
    ));
    // Overflow the global buffer with unrelated entries.
    for (var i = 0; i < 10; i++) {
      buffer.add(LogEntry(
        timestamp: DateTime.now(),
        level: LogLevel.info,
        logger: 'other',
        message: 'noise-$i',
      ));
    }

    await tester.pumpWidget(
      buildTestWidget(
        downloadId: 'dl-done',
        title: 'Finished Item',
        status: 'completed',
      ),
    );

    expect(find.text('COMPLETED'), findsOneWidget);
    expect(find.textRange.ofSubstring('Download started for finished video'), findsOneWidget);
    expect(find.textRange.ofSubstring('Transient fragment retry'), findsOneWidget);
    expect(find.textRange.ofSubstring('Download completed'), findsOneWidget);
    expect(find.textRange.ofSubstring('noise-'), findsNothing);
  });
}
