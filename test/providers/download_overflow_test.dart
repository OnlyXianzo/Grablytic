import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/download_provider.dart';

DownloadNotifier _notifier() => DownloadNotifier(MockEngineService());

void main() {
  group('Overflow actions (Milestones 4)', () {
    test('redownload blocked while active', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'o-1',
          title: 't',
          url: 'https://x.test/1',
          status: 'queued'));
      n.redownload('o-1', fresh: true);
      expect(n.state.single.status, 'queued');
    });

    test('redownload fresh merges overwrite+archive bypass into config', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'o-2',
          title: 't',
          url: 'https://x.test/2',
          status: 'completed',
          config: {'container': 'mp4'}));
      n.redownload('o-2', fresh: true);
      final item = n.state.single;
      expect(item.status, 'downloading');
      expect(item.config?['force_overwrite'], isTrue);
      expect(item.config?['ignore_archive'], isTrue);
      expect(item.config?['container'], 'mp4');
    });

    test('failed retry keeps resume-capable defaults (no force flags)', () {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'o-3',
          title: 't',
          url: 'https://x.test/3',
          status: 'error',
          config: {'container': 'mkv'}));
      n.redownload('o-3');
      final item = n.state.single;
      expect(item.status, 'downloading');
      expect(item.config?.containsKey('force_overwrite'), isFalse);
      expect(item.config?.containsKey('ignore_archive'), isFalse);
    });

    test('downloadAudioFromSource enqueues new audio item', () async {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'o-4',
          title: 'Video',
          url: 'https://x.test/4',
          status: 'completed',
          config: {'container': 'mp4'}));
      final newId = await n.downloadAudioFromSource('o-4');
      expect(newId, isNotNull);
      expect(n.state.length, 2);
      final audio = n.state.firstWhere((d) => d.id == newId);
      expect(audio.config?['audio_only'], isTrue);
      expect(audio.title, contains('(audio)'));
    });

    test('downloadAudioFromSource unknown id returns null', () async {
      final n = _notifier();
      expect(await n.downloadAudioFromSource('missing'), isNull);
    });

    test('removeFromHistory drops the row', () async {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'o-5', title: 't', url: 'https://x.test/5'));
      await n.removeFromHistory('o-5');
      expect(n.state, isEmpty);
    });

    test('deleteFileAndHistory refused while active', () async {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'o-6',
          title: 't',
          url: 'https://x.test/6',
          status: 'downloading'));
      expect(await n.deleteFileAndHistory('o-6'), isFalse);
      expect(n.state.length, 1);
    });

    test('deleteFileAndHistory removes terminal row without file', () async {
      final n = _notifier();
      n.addDownload(DownloadItem(
          id: 'o-7',
          title: 't',
          url: 'https://x.test/7',
          status: 'completed'));
      expect(await n.deleteFileAndHistory('o-7'), isTrue);
      expect(n.state, isEmpty);
    });

    test('clearArchive never throws', () async {
      final n = _notifier();
      final res = await n.clearArchive();
      expect(res['success'], isTrue);
    });
  });
}
