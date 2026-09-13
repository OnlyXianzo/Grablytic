import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';
import 'package:truestream/providers/download_provider.dart';

DownloadNotifier _notifier({DateTime Function()? clock}) =>
    DownloadNotifier(MockEngineService(), clock: clock);

void _seed(DownloadNotifier n) {
  n.addDownload(DownloadItem(
      id: 'dl-1', title: 't', url: 'https://x.test/v'));
}

void main() {
  group('DownloadNotifier event tracking', () {
    test('downloading stores speed, eta and clears stage', () {
      final n = _notifier();
      _seed(n);
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-1',
        'downloaded_bytes': 50,
        'total_bytes': 100,
        'speed': 1048576,
        'eta': 65,
      });
      final item = n.state.single;
      expect(item.status, 'downloading');
      expect(item.progress, closeTo(0.5, 0.001));
      // First sample seeds the EMA exactly (no prior history to average with).
      expect(item.speed, 1048576);
      // ETA is *derived* and suppressed until the grace window elapses — the
      // raw engine eta is never surfaced directly.
      expect(item.eta, -1);
      expect(item.speedHistory, [1048576]);
      expect(item.stage, isNull);
      expect(item.stageLabel, isNull);
    });

    test('downloading history ring buffer cap and sample floor', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final n = _notifier(clock: () => fakeNow);
      _seed(n);
      for (var i = 0; i < 65; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 1));
        n.handleProgressEvent({
          'type': 'event',
          'event': 'downloading',
          'download_id': 'dl-1',
          'downloaded_bytes': 1,
          'total_bytes': 100,
          'speed': (i + 1) * 1000,
        });
      }
      final item = n.state.single;
      // After 65 samples, capped to kSpeedHistoryCap (60).
      expect(item.speedHistory.length, 60);
      expect(item.speedHistory.length, kSpeedHistoryCap);
      expect(item.speedHistory.last, item.speed);
    });

    test('downloading speed history reset on retry', () {
      final n1 = _notifier();
      n1.addDownload(DownloadItem(id: 'dl-1', title: 't', url: 'u'));
      n1.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-1',
        'downloaded_bytes': 1,
        'total_bytes': 100,
        'speed': 1000,
      });
      expect(n1.state.single.speedHistory, [1000]);
      // Simulate user retry via overflow menu: copy the current state and clear history.
      final item = n1.state.single.copyWith(clearHistory: true);
      final n2 = _notifier();
      n2.addDownload(item);
      expect(n2.state.single.speedHistory, []);
    });

    test('downloading coalescing respects 1 Hz cadence', () {
      final n = _notifier();
      n.addDownload(DownloadItem(id: 'dl-1', title: 't', url: 'u'));
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-1',
        'downloaded_bytes': 10,
        'total_bytes': 100,
        'speed': 10000,
      });
      expect(n.state.single.speedHistory.length, 1);
      // Send a second event within the same <1s window; it should be
      // coalesced away, leaving history unchanged.
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-1',
        'downloaded_bytes': 20,
        'total_bytes': 100,
        'speed': 20000,
      });
      expect(n.state.single.speedHistory.length, 1);
      expect(n.state.single.speed, 10000);
      expect(n.state.single.eta, -1);
    });

    test('downloading zero-speed tick holds last speed and eta gracefully', () {
      var fakeNow = DateTime(2026, 1, 1, 12, 0, 0);
      final n = _notifier(clock: () => fakeNow);
      n.addDownload(DownloadItem(id: 'dl-1', title: 't', url: 'u'));
      // Feed 3 samples with speed > 0 and 1s gap to satisfy grace window (kEtaGraceSamples=3, kEtaGracePeriod=2s)
      for (var i = 0; i < 3; i++) {
        n.handleProgressEvent({
          'type': 'event',
          'event': 'downloading',
          'download_id': 'dl-1',
          'downloaded_bytes': (i + 1) * 10,
          'total_bytes': 100,
          'speed': 1000,
        });
        fakeNow = fakeNow.add(const Duration(seconds: 1));
      }
      expect(n.state.single.eta, isNot(-1));
      final lastEta = n.state.single.eta;
      final lastSpeed = n.state.single.speed;

      // Feed zero-speed ticks; they should drop the line to 0 in the
      // sparkline but preserve the last ETA and display speed gracefully.
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-1',
        'downloaded_bytes': 40,
        'total_bytes': 100,
        'speed': 0,
      });

      final item = n.state.single;
      expect(item.speedHistory, contains(0.0));
      expect(item.speed, lastSpeed);
      expect(item.eta, lastEta);
    });

    test('postprocessing sets stage without touching progress', () {
      final n = _notifier();
      _seed(n);
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-1',
        'downloaded_bytes': 99,
        'total_bytes': 100,
      });
      n.handleProgressEvent({
        'type': 'event',
        'event': 'postprocessing',
        'download_id': 'dl-1',
        'stage': 'merging',
        'stage_label': 'Merging streams...',
      });
      final item = n.state.single;
      expect(item.stage, 'merging');
      expect(item.stageLabel, 'Merging streams...');
      expect(item.status, 'downloading');
    });

    test('finished resets motion fields and completes', () {
      final n = _notifier();
      _seed(n);
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-1',
        'downloaded_bytes': 10,
        'total_bytes': 100,
        'speed': 5,
        'eta': 9,
      });
      n.handleProgressEvent({
        'type': 'event',
        'event': 'finished',
        'download_id': 'dl-1',
        'filesize_bytes': 100,
      });
      final item = n.state.single;
      expect(item.status, 'completed');
      expect(item.progress, 1.0);
      expect(item.speed, 0);
      expect(item.eta, -1);
      expect(item.stage, isNull);
    });

    test('type:log maps are ignored (single-owner ingestion)', () {
      final n = _notifier();
      _seed(n);
      n.handleProgressEvent({
        'type': 'log',
        'level': 'INFO',
        'message': 'noise',
      });
      expect(n.state.single.status, 'pending');
    });

    test('unknown ids are ignored', () {
      final n = _notifier();
      _seed(n);
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'downloaded_bytes': 1,
        'total_bytes': 2,
      });
      expect(n.state.single.progress, 0);
    });

    test('finished event captures file_path and updates state', () {
      final n = _notifier();
      _seed(n);
      n.handleProgressEvent({
        'type': 'event',
        'event': 'finished',
        'download_id': 'dl-1',
        'filesize_bytes': 10240,
        'file_path': '/storage/emulated/0/Download/TrueStream/video.mkv',
      });
      final item = n.state.single;
      expect(item.status, 'completed');
      expect(item.filePath, '/storage/emulated/0/Download/TrueStream/video.mkv');
      expect(item.downloadedBytes, 10240);
      expect(item.totalBytes, 10240);
    });
  });
}
