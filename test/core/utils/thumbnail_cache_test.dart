import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/thumbnail_cache.dart';

void main() {
  group('ThumbnailCache (T07 persistent home thumbnails)', () {
    test('file names are filesystem-safe and capped', () {
      expect(ThumbnailCache.fileNameFor('abc-123_X'), 'abc-123_X.jpg');
      expect(ThumbnailCache.fileNameFor('a/b\\c:d'), 'a_b_c_d.jpg');
      expect(ThumbnailCache.fileNameFor(''), 'thumb.jpg');
      expect(
        ThumbnailCache.fileNameFor('x' * 100).length,
        lessThanOrEqualTo(68),
      );
    });

    test('rejects empty and non-http URLs without network', () async {
      expect(
        await ThumbnailCache.fetchToCache(
          cacheDir: '/tmp/t07-nocache',
          id: 'a',
          url: '',
        ),
        isNull,
      );
      expect(
        await ThumbnailCache.fetchToCache(
          cacheDir: '/tmp/t07-nocache',
          id: 'b',
          url: 'ftp://example.com/x.jpg',
        ),
        isNull,
      );
      expect(
        await ThumbnailCache.fetchToCache(
          cacheDir: '/tmp/t07-nocache',
          id: 'c',
          url: 'not a url at all',
        ),
        isNull,
      );
    });
  });

  group('ThumbnailCache.prune', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('grablytic-thumbs-');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<File> _write(String name, int bytes) async {
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(List<int>.filled(bytes, 0x41));
      return file;
    }

    test('drops thumbnails whose download is gone', () async {
      await _write('keep.jpg', 4);
      await _write('gone.jpg', 4);
      await _write('also-gone.jpg', 4);

      final removed = await ThumbnailCache.prune(
        cacheDir: dir.path,
        liveIds: {'keep'},
      );

      expect(removed, 2);
      final names = await dir
          .list()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      expect(names, ['keep.jpg']);
    });

    test('enforces the byte budget oldest-first', () async {
      final old = await _write('old.jpg', 400);
      final mid = await _write('mid.jpg', 400);
      final fresh = await _write('fresh.jpg', 400);
      // Deterministic order: the sort reads FileStat.modified.
      old.setLastModifiedSync(DateTime(2020, 1, 1));
      mid.setLastModifiedSync(DateTime(2021, 1, 1));
      fresh.setLastModifiedSync(DateTime(2022, 1, 1));

      final removed = await ThumbnailCache.prune(
        cacheDir: dir.path,
        liveIds: {'old', 'mid', 'fresh'},
        maxTotalBytes: 800,
      );

      expect(removed, 1);
      expect(await File('${dir.path}/old.jpg').exists(), isFalse);
      expect(await File('${dir.path}/fresh.jpg').exists(), isTrue);
    });

    test('a missing directory is not an error', () async {
      expect(
        await ThumbnailCache.prune(
          cacheDir: '${dir.path}/does-not-exist',
          liveIds: const {},
        ),
        0,
      );
    });

    test('non-image leftovers are left alone', () async {
      final stray = await _write('notes.txt', 4);
      await ThumbnailCache.prune(cacheDir: dir.path, liveIds: const {});
      expect(await stray.exists(), isTrue);
    });
  });
}
