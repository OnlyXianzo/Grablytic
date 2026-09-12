import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';
import 'package:truestream/providers/download_provider.dart';

DownloadNotifier _notifier() => DownloadNotifier(MockEngineService());

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
      expect(item.speed, 1048576);
      expect(item.eta, 65);
      expect(item.stage, isNull);
      expect(item.stageLabel, isNull);
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
