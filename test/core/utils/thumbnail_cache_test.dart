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
}
