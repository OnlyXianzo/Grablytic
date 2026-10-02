import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/utils/offline_link_queue.dart';

class _MockConnectivity implements Connectivity {
  final List<ConnectivityResult> results;
  _MockConnectivity(this.results);

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => results;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Stream.value(results);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('T19: normalizeQueueUrl', () {
    test('normalizes standard http/https URLs', () {
      expect(
        normalizeQueueUrl('https://youtube.com/watch?v=123'),
        'https://youtube.com/watch?v=123',
      );
      expect(
        normalizeQueueUrl('  http://example.com/video  '),
        'http://example.com/video',
      );
    });

    test('prepends https scheme if missing but host valid', () {
      expect(
        normalizeQueueUrl('youtube.com/watch?v=123'),
        'https://youtube.com/watch?v=123',
      );
    });

    test('rejects empty and malformed URLs', () {
      expect(normalizeQueueUrl(''), isNull);
      expect(normalizeQueueUrl('   '), isNull);
      expect(normalizeQueueUrl('not a url at all'), isNull);
    });
  });

  group('T19: isDeviceOffline', () {
    test('returns true when connectivity is none or empty', () async {
      final offlineConn = _MockConnectivity([ConnectivityResult.none]);
      expect(await isDeviceOffline(connectivity: offlineConn), isTrue);

      final emptyConn = _MockConnectivity([]);
      expect(await isDeviceOffline(connectivity: emptyConn), isTrue);
    });

    test('returns false when wifi or mobile connected', () async {
      final wifiConn = _MockConnectivity([ConnectivityResult.wifi]);
      expect(await isDeviceOffline(connectivity: wifiConn), isFalse);

      final mobileConn = _MockConnectivity([ConnectivityResult.mobile]);
      expect(await isDeviceOffline(connectivity: mobileConn), isFalse);
    });
  });

  group('T19: OfflineQueueStore persistence and deduplication', () {
    late SharedPreferences prefs;
    late OfflineQueueStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      store = OfflineQueueStore(prefs);
    });

    test('initial queue is empty', () {
      expect(store.load(), isEmpty);
    });

    test('adds valid links with source tag and timestamps', () async {
      final added1 = await store.addLink(
        'https://youtube.com/watch?v=test1',
        title: 'Video 1',
        source: 'share',
      );
      expect(added1, isTrue);

      final added2 = await store.addLink(
        'https://youtube.com/watch?v=test2',
        title: 'Video 2',
        source: 'paste',
      );
      expect(added2, isTrue);

      final links = store.load();
      expect(links.length, 2);
      expect(links[0].url, 'https://youtube.com/watch?v=test1');
      expect(links[0].source, 'share');
      expect(links[0].title, 'Video 1');
      expect(links[1].url, 'https://youtube.com/watch?v=test2');
      expect(links[1].source, 'paste');
    });

    test('deduplicates existing links in queue', () async {
      final first = await store.addLink('https://youtube.com/watch?v=same');
      expect(first, isTrue);

      // Attempt to re-add same URL
      final second = await store.addLink('https://youtube.com/watch?v=same');
      expect(second, isFalse);

      // Attempt to add with trailing slash or spaces
      final third = await store.addLink('  https://youtube.com/watch?v=same  ');
      expect(third, isFalse);

      final links = store.load();
      expect(links.length, 1);
    });

    test('removes link by URL', () async {
      await store.addLink('https://youtube.com/watch?v=item1');
      await store.addLink('https://youtube.com/watch?v=item2');

      final removed = await store.removeLink(
        'https://youtube.com/watch?v=item1',
      );
      expect(removed, isTrue);

      final links = store.load();
      expect(links.length, 1);
      expect(links.first.url, 'https://youtube.com/watch?v=item2');

      final removeNonExistent = await store.removeLink(
        'https://not-in-queue.com',
      );
      expect(removeNonExistent, isFalse);
    });

    test('clears entire queue', () async {
      await store.addLink('https://youtube.com/watch?v=1');
      await store.addLink('https://youtube.com/watch?v=2');
      expect(store.load().length, 2);

      await store.clear();
      expect(store.load(), isEmpty);
    });

    test('persists explicitly across store instances (restarts)', () async {
      await store.addLink(
        'https://youtube.com/watch?v=restart_test',
        title: 'Persisted Video',
        source: 'clipboard',
      );

      // Create new store instance from same SharedPreferences
      final reloadedStore = OfflineQueueStore(prefs);
      final links = reloadedStore.load();
      expect(links.length, 1);
      expect(links.first.url, 'https://youtube.com/watch?v=restart_test');
      expect(links.first.title, 'Persisted Video');
      expect(links.first.source, 'clipboard');
    });
  });
}
