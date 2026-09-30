import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/features/settings/widgets/storage_meter_card.dart';

Future<Directory> _dirWithFiles(Map<String, int> files) async {
  final dir = await Directory.systemTemp.createTemp('storage_meter');
  for (final entry in files.entries) {
    final file = File('${dir.path}/${entry.key}');
    await file.writeAsBytes(List.filled(entry.value, 0x61));
  }
  return dir;
}

void main() {
  group('formatBytes', () {
    test('formats boundary values', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-5), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes((2.5 * 1024 * 1024 * 1024).toInt()), '2.5 GB');
    });
  });

  group('scanMediaStorage', () {
    late List<Directory> dirs;
    setUp(() => dirs = []);
    tearDown(() async {
      for (final d in dirs) {
        try {
          await d.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('sums sizes, counts files, orders largest first', () async {
      final dir = await _dirWithFiles({
        'small.mp4': 100,
        'big.mkv': 3000,
        'mid.m4a': 500,
      });
      dirs.add(dir);
      final scan = await scanMediaStorage(dir);
      expect(scan.exists, isTrue);
      expect(scan.totalBytes, 3600);
      expect(scan.fileCount, 3);
      expect(
        scan.largest.map((e) => e.name),
        ['big.mkv', 'mid.m4a', 'small.mp4'],
      );
    });

    test('missing dir yields StorageScan.missing', () async {
      final scan = await scanMediaStorage(
        Directory('/definitely/not/here/grablytic_test'),
      );
      expect(scan.exists, isFalse);
      expect(scan.totalBytes, 0);
      expect(scan.fileCount, 0);
      expect(scan.largest, isEmpty);
    });

    test('respects topN', () async {
      final dir = await _dirWithFiles({
        for (var i = 0; i < 15; i++) 'f$i.mp4': 10 * (i + 1),
      });
      dirs.add(dir);
      final scan = await scanMediaStorage(dir, topN: 10);
      expect(scan.largest, hasLength(10));
      expect(scan.largest.first.name, 'f14.mp4');
    });
  });

  group('deleteMediaFile', () {
    late Directory base;
    setUp(() async {
      base = await Directory.systemTemp.createTemp('storage_meter_del');
    });
    tearDown(() async {
      try {
        await base.delete(recursive: true);
      } catch (_) {}
    });

    test('deletes inside base, refuses escape', () async {
      final inner = File('${base.path}/a.mp4');
      await inner.writeAsString('x');
      expect(await deleteMediaFile(inner.path, base.path), isTrue);
      expect(await inner.exists(), isFalse);

      final outside =
          await File('${base.parent.path}/grablytic_outside.tmp')
              .writeAsString('x');
      try {
        expect(
          await deleteMediaFile(outside.path, base.path),
          isFalse,
        );
        expect(await outside.exists(), isTrue);
      } finally {
        try {
          await outside.delete();
        } catch (_) {}
      }
      expect(
        await deleteMediaFile('${base.path}/nope.mp4', base.path),
        isFalse,
      );
    });
  });

  group('StorageMeterCard widget', () {
    // Widget tests run in a FakeAsync zone where real disk I/O never
    // resolves, so the widget's scan/delete seams carry scripted results
    // (official Flutter guidance: inject async work, never depend on
    // timing). The real scanMediaStorage/deleteMediaFile stay covered by
    // the plain unit tests above.
    StorageScan scanOf(Map<String, int> files) {
      var total = 0;
      final entries = files.entries
          .map((e) {
            total += e.value;
            return StorageFileEntry(path: '/dl/${e.key}', sizeBytes: e.value);
          })
          .toList()
        ..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
      return StorageScan(
        exists: true,
        totalBytes: total,
        fileCount: entries.length,
        largest: entries,
      );
    }

    testWidgets('shows usage summary, path, and largest files',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StorageMeterCard(
              downloadPath: '/dl',
              scanForTesting: (_) async =>
                  scanOf({'alpha.mkv': 2048, 'beta.mp4': 512}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Media storage'), findsOneWidget);
      expect(find.text('2.5 KB in 2 files'), findsOneWidget);
      expect(find.text('/dl'), findsOneWidget);
      expect(find.text('Largest files'), findsOneWidget);
      expect(find.text('alpha.mkv'), findsOneWidget);
      expect(find.text('beta.mp4'), findsOneWidget);
    });

    testWidgets('delete flow asks to confirm then removes the file',
        (tester) async {
      final deleted = <String>[];
      var calls = 0;
      Future<StorageScan> scan(Directory dir) async {
        calls++;
        // Pre-delete scan shows both files; post-delete rescan shows one.
        return calls <= 1
            ? scanOf({'alpha.mkv': 2048, 'beta.mp4': 512})
            : scanOf({'beta.mp4': 512});
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StorageMeterCard(
              downloadPath: '/dl',
              scanForTesting: scan,
              deleteForTesting: (path, base) async {
                deleted.add(path);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete file').first);
      await tester.pumpAndSettle();
      expect(find.text('Delete file?'), findsOneWidget);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(deleted, ['/dl/alpha.mkv']);
      expect(find.text('512 B in 1 files'), findsOneWidget);
      expect(find.text('alpha.mkv'), findsNothing);
    });

    testWidgets('missing folder degrades to unavailable line', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StorageMeterCard(
              downloadPath: '/definitely/not/here/grablytic_test',
              scanForTesting: (_) async => const StorageScan.missing(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Media storage'), findsOneWidget);
      expect(find.text('Folder unavailable'), findsOneWidget);
    });
  });
}
