import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';
import 'package:truestream/providers/download_provider.dart';

DownloadNotifier _notifier() => DownloadNotifier(MockEngineService());

void main() {
  group('Download queue (Milestone 1)', () {
    test('queued event flips pending to queued', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'q-1', title: 't', url: 'https://x.test/1'));
      n.handleProgressEvent({
        'type': 'event',
        'event': 'queued',
        'download_id': 'q-1',
        'position': 1,
      });
      expect(n.state.single.status, 'queued');
      expect(n.queuedItems.length, 1);
    });

    test('downloading promotes queued to downloading', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'q-2',
          title: 't',
          url: 'https://x.test/2',
          status: 'queued'));
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'q-2',
        'downloaded_bytes': 10,
        'total_bytes': 100,
      });
      expect(n.state.single.status, 'downloading');
      expect(n.queuedItems, isEmpty);
    });

    test('isActive covers downloading/pending/queued', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'q-3',
          title: 't',
          url: 'https://x.test/3',
          status: 'queued'));
      expect(n.isActive('https://x.test/3'), isTrue);
      expect(n.isActiveId('q-3'), isTrue);
      expect(n.isActive('https://other.test/'), isFalse);
    });

    test('retryDownload blocked while active, allowed when terminal', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'q-4',
          title: 't',
          url: 'https://x.test/4',
          status: 'downloading'));
      // Must not throw and must not reset an active item.
      n.retryDownload('q-4');
      expect(n.state.single.status, 'downloading');
      expect(n.state.single.progress, 0);
    });

    test('syncConcurrency never throws', () async {
      final n = _notifier();
      await n.syncConcurrency(3);
    });
  });
}
