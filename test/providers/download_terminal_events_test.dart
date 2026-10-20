import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/download_provider.dart';

DownloadNotifier _notifier() => DownloadNotifier(MockEngineService());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('terminal events for an unknown id', () {
    test('do not mutate the last known download', () async {
      final n = _notifier();
      n.addDownload(DownloadItem(
        id: 'keep-me',
        title: 'Keep',
        url: 'https://x.test/keep',
        status: 'downloading',
        progress: 0.4,
      ));

      // A terminal event for an id the app does not know about. The old
      // code fell back to `state.last`, so the KEEP item was marked
      // completed and persisted as if it had finished.
      n.handleProgressEvent({
        'type': 'event',
        'event': 'finished',
        'download_id': 'ghost',
        'filesize_bytes': 999,
      });

      expect(n.state.length, 1);
      expect(n.state.single.id, 'keep-me');
      expect(n.state.single.status, 'downloading');
      expect(n.state.single.progress, 0.4);
    });

    test('do not mutate anything when the list is empty', () {
      final n = _notifier();
      n.handleProgressEvent({
        'type': 'event',
        'event': 'error',
        'download_id': 'ghost',
        'error_type': 'ERROR_DOWNLOAD',
      });
      expect(n.state, isEmpty);
    });
  });

  group('redownload reconciles with the engine verdict', () {
    test('a rejected start becomes a local error, not a stuck download',
        () async {
      final n = DownloadNotifier(_RejectingEngine());
      n.addDownload(DownloadItem(
        id: 'r-1',
        title: 'T',
        url: 'https://x.test/r1',
        status: 'error',
      ));

      await n.redownload('r-1');

      expect(n.state.single.status, 'error');
      expect(n.state.single.errorType, 'ERROR_QUEUE_FULL');
    });

    test('an accepted start shows the running state', () async {
      final n = _notifier();
      n.addDownload(DownloadItem(
        id: 'r-2',
        title: 'T',
        url: 'https://x.test/r2',
        status: 'error',
      ));

      await n.redownload('r-2');

      expect(n.state.single.status, 'downloading');
    });
  });

  group('cancel reconciles with the engine verdict', () {
    test('a refused cancel closes the row locally', () async {
      final n = DownloadNotifier(_RejectingCancelEngine());
      n.addDownload(DownloadItem(
        id: 'c-1',
        title: 'T',
        url: 'https://x.test/c1',
        status: 'downloading',
      ));

      n.cancelDownload('c-1');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(n.state.single.status, 'cancelled');
      expect(n.state.single.errorType, 'ERROR_CANCELLED');
    });
  });
}

class _RejectingEngine extends MockEngineService {
  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    return {
      'success': false,
      'error_type': 'ERROR_QUEUE_FULL',
      'error_message': 'Queue is full',
    };
  }
}

class _RejectingCancelEngine extends MockEngineService {
  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) async {
    return {
      'success': false,
      'error_type': 'ERROR_DOWNLOAD_NOT_FOUND',
      'error_message': 'No such download',
    };
  }
}
