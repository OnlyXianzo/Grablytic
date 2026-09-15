import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/download_provider.dart';

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
        'file_path': '/storage/emulated/0/Download/Grablytic/video.mkv',
      });
      final item = n.state.single;
      expect(item.status, 'completed');
      expect(item.filePath, '/storage/emulated/0/Download/Grablytic/video.mkv');
      expect(item.downloadedBytes, 10240);
      expect(item.totalBytes, 10240);
    });

    test('interrupted item can be resumed via resumeInterrupted', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
        id: 'dl-int',
        title: 'Interrupted Download',
        url: 'https://test.com/v',
        status: 'interrupted',
        downloadedBytes: 500,
        totalBytes: 1000,
        attempts: 1,
      ));
      expect(n.state.single.status, 'interrupted');
      n.resumeInterrupted('dl-int');
      expect(n.state.single.status, 'downloading');
    });
  });

  group('T1-3 honest cancelling state', () {
    DownloadNotifier downloading() {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'dl-c', title: 't', url: 'https://x.test/v'));
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-c',
        'downloaded_bytes': 10,
        'total_bytes': 100,
        'speed': 1000,
      });
      expect(n.state.single.status, 'downloading');
      return n;
    }

    test('cancel marks cancelling, not cancelled', () {
      final n = downloading();
      n.cancelDownload('dl-c');
      final item = n.state.single;
      expect(item.status, 'cancelling');
      expect(item.speed, 0);
      // No premature terminal claims: error fields untouched until the
      // terminal event arrives.
      expect(item.errorType, isNull);
    });

    test('terminal cancelled event finalizes a cancelling item', () {
      final n = downloading();
      n.cancelDownload('dl-c');
      n.handleProgressEvent({
        'type': 'event',
        'event': 'cancelled',
        'download_id': 'dl-c',
      });
      final item = n.state.single;
      expect(item.status, 'cancelled');
      expect(item.errorType, 'ERROR_CANCELLED');
    });

    test('cancelling counts as active (no retry/delete races)', () {
      final n = downloading();
      n.cancelDownload('dl-c');
      expect(n.isActive('https://x.test/v'), isTrue);
      expect(n.isActiveId('dl-c'), isTrue);
    });
  });

  group('smoother eviction (no per-download leak)', () {
    DownloadNotifier downloadingSeeded(String id) {
      final n = _notifier();
      n.addDownload(DownloadItem(id: id, title: 't', url: 'https://x.test/$id'));
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': id,
        'downloaded_bytes': 10,
        'total_bytes': 100,
        'speed': 1000,
      });
      expect(n.smootherCount, 1);
      return n;
    }

    test('finished evicts the smoother', () {
      final n = downloadingSeeded('dl-1');
      n.handleProgressEvent({
        'type': 'event',
        'event': 'finished',
        'download_id': 'dl-1',
        'filesize_bytes': 100,
      });
      expect(n.state.single.status, 'completed');
      expect(n.smootherCount, 0);
    });

    test('error evicts the smoother', () {
      final n = downloadingSeeded('dl-1');
      n.handleProgressEvent({
        'type': 'event',
        'event': 'error',
        'download_id': 'dl-1',
        'error_type': 'ERROR_NETWORK',
        'error_message': 'boom',
      });
      expect(n.state.single.status, 'error');
      expect(n.smootherCount, 0);
    });

    test('cancelled evicts the smoother', () {
      final n = downloadingSeeded('dl-1');
      n.handleProgressEvent({
        'type': 'event',
        'event': 'cancelled',
        'download_id': 'dl-1',
      });
      expect(n.state.single.status, 'cancelled');
      expect(n.smootherCount, 0);
    });

    test('removeFromHistory evicts the smoother', () async {
      final n = downloadingSeeded('dl-1');
      await n.removeFromHistory('dl-1');
      expect(n.state, isEmpty);
      expect(n.smootherCount, 0);
    });

    test('100 completed downloads retain zero smoothers', () {
      final n = _notifier();
      for (var i = 0; i < 100; i++) {
        final id = 'dl-$i';
        n.addDownload(DownloadItem(id: id, title: 't', url: 'https://x.test/$id'));
        n.handleProgressEvent({
          'type': 'event',
          'event': 'downloading',
          'download_id': id,
          'downloaded_bytes': 10,
          'total_bytes': 100,
          'speed': 1000,
        });
        n.handleProgressEvent({
          'type': 'event',
          'event': 'finished',
          'download_id': id,
          'filesize_bytes': 100,
        });
      }
      expect(n.state, hasLength(100));
      expect(n.smootherCount, 0);
    });
  });

  group('num-tolerant byte parsing (field crash regression)', () {
    // Field logs showed 233x FATAL: `type 'double' is not a subtype of
    // type 'int?'` at handleProgressEvent when engine JSON decoded bytes as
    // double (HLS `~ 19.32KiB` estimates, Kotlin number coercion). Each throw
    // emitted another log line — crash-loop amplifying the 10+ hang.
    test('downloading accepts double bytes without throwing', () {
      final n = _notifier();
      _seed(n);
      n.handleProgressEvent({
        'type': 'event',
        'event': 'downloading',
        'download_id': 'dl-1',
        'downloaded_bytes': 952.43,
        'total_bytes': 19781.0,
        'speed': 952.43,
      });
      final item = n.state.single;
      expect(item.status, 'downloading');
      expect(item.downloadedBytes, 952);
      expect(item.totalBytes, 19781);
    });

    test('stream_finished and finished accept double filesize', () {
      final n = _notifier();
      _seed(n);
      n.handleProgressEvent({
        'type': 'event',
        'event': 'stream_finished',
        'download_id': 'dl-1',
        'filesize_bytes': 1234.56,
      });
      expect(n.state.single.downloadedBytes, 1234);
      n.handleProgressEvent({
        'type': 'event',
        'event': 'finished',
        'download_id': 'dl-1',
        'filesize_bytes': 5678.9,
      });
      expect(n.state.single.status, 'completed');
      expect(n.state.single.downloadedBytes, 5678);
    });
  });
}
