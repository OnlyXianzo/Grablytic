import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/extraction_cache.dart';

void main() {
  setUp(() {
    ExtractionCache.instance.clear();
  });

  group('ExtractionCache', () {
    test('put and get returns cached extraction data', () {
      final cache = ExtractionCache.instance;
      expect(cache.has('https://example.com/video'), isFalse);

      final data = {'success': true, 'title': 'Test Video', 'formats': []};
      cache.put('https://example.com/video', data);

      expect(cache.has('https://example.com/video'), isTrue);
      expect(cache.get('https://example.com/video')?['title'], 'Test Video');
    });

    test('getOrFetch only executes fetcher once for multiple calls', () async {
      final cache = ExtractionCache.instance;
      int fetchCount = 0;

      Future<Map<String, dynamic>> mockFetcher() async {
        fetchCount++;
        await Future.delayed(const Duration(milliseconds: 10));
        return {'success': true, 'title': 'Fetched $fetchCount'};
      }

      final results = await Future.wait([
        cache.getOrFetch('https://example.com/1', mockFetcher),
        cache.getOrFetch('https://example.com/1', mockFetcher),
        cache.getOrFetch('https://example.com/1', mockFetcher),
      ]);

      expect(fetchCount, 1);
      expect(results[0]['title'], 'Fetched 1');
      expect(results[1]['title'], 'Fetched 1');
      expect(results[2]['title'], 'Fetched 1');
    });

    test('remove and clear invalidate cached entries', () {
      final cache = ExtractionCache.instance;
      cache.put('https://example.com/1', {'success': true});
      cache.put('https://example.com/2', {'success': true});

      cache.remove('https://example.com/1');
      expect(cache.has('https://example.com/1'), isFalse);
      expect(cache.has('https://example.com/2'), isTrue);

      cache.clear();
      expect(cache.has('https://example.com/2'), isFalse);
    });

    test('expired entry is not returned', () async {
      final cache = ExtractionCache.instance;
      cache.put('https://example.com/expiring', {
        'success': true,
      }, const Duration(milliseconds: 5));

      expect(cache.has('https://example.com/expiring'), isTrue);
      await Future.delayed(const Duration(milliseconds: 10));
      expect(cache.has('https://example.com/expiring'), isFalse);
      expect(cache.get('https://example.com/expiring'), isNull);
    });
  });
}
