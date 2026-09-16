import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/download_provider.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

import 'package:path/path.dart' as p;

class _MultiDirMockEngine extends MockEngineService {
  final Map<String, List<Map<String, dynamic>>> dirCandidates = {};

  @override
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir}) async {
    for (final entry in dirCandidates.entries) {
      if (p.canonicalize(entry.key) == p.canonicalize(cacheDir)) {
        return {
          'success': true,
          'candidates': entry.value,
        };
      }
    }
    return {
      'success': true,
      'candidates': dirCandidates[cacheDir] ?? [],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ResumeNotifier Multi-Directory & Active Filter Tests', () {
    late Directory tempCache;
    late Directory tempDownload;

    setUp(() async {
      tempCache = await Directory.systemTemp.createTemp('cache_test');
      tempDownload = await Directory.systemTemp.createTemp('dl_test');
    });

    tearDown(() async {
      try {
        await tempCache.delete(recursive: true);
      } catch (_) {}
      try {
        await tempDownload.delete(recursive: true);
      } catch (_) {}
    });

    test('scan discovers candidates in both cacheDir and downloadDir', () async {
      final mockEngine = _MultiDirMockEngine();
      final cacheFile = '${tempCache.path}/cache_video.part';
      final dlFile = '${tempDownload.path}/dl_video.part';

      mockEngine.dirCandidates[tempCache.path] = [
        {
          'filename': 'cache_video.part',
          'filepath': cacheFile,
          'size_bytes': 100,
          'age_seconds': 10,
          'likely_url': 'https://x.test/c',
          'expired': false,
        }
      ];
      mockEngine.dirCandidates[tempDownload.path] = [
        {
          'filename': 'dl_video.part',
          'filepath': dlFile,
          'size_bytes': 200,
          'age_seconds': 20,
          'likely_url': 'https://x.test/d',
          'expired': false,
        }
      ];

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      late ResumeNotifier notifier;
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(mockEngine),
        downloadProvider.overrideWith((ref) => DownloadNotifier(mockEngine)),
        resumeProvider.overrideWith((ref) => ResumeNotifier(
              ref,
              resolveCacheDir: () async => tempCache.path,
              resolveDownloadDir: () async => tempDownload.path,
            )),
      ]);
      addTearDown(container.dispose);

      notifier = container.read(resumeProvider.notifier);

      await notifier.scan();
      final candidates = notifier.state.value ?? [];

      expect(candidates, hasLength(2));
      final paths = candidates.map((c) => c.filepath).toSet();
      expect(paths.contains(cacheFile), isTrue);
      expect(paths.contains(dlFile), isTrue);
    });

    test('scan filters out active in-progress downloads', () async {
      final mockEngine = _MultiDirMockEngine();
      final activeFile = '${tempDownload.path}/active.mp4.part';
      final idleFile = '${tempDownload.path}/idle.mp4.part';

      mockEngine.dirCandidates[tempDownload.path] = [
        {
          'filename': 'active.mp4.part',
          'filepath': activeFile,
          'size_bytes': 500,
          'age_seconds': 5,
          'likely_url': 'https://x.test/active',
          'expired': false,
        },
        {
          'filename': 'idle.mp4.part',
          'filepath': idleFile,
          'size_bytes': 300,
          'age_seconds': 50,
          'likely_url': 'https://x.test/idle',
          'expired': false,
        }
      ];

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWithValue(mockEngine),
        downloadProvider.overrideWith((ref) => DownloadNotifier(mockEngine)),
        resumeProvider.overrideWith((ref) => ResumeNotifier(
              ref,
              resolveCacheDir: () async => tempCache.path,
              resolveDownloadDir: () async => tempDownload.path,
            )),
      ]);
      addTearDown(container.dispose);

      // Add active download to downloadProvider
      container.read(downloadProvider.notifier).addDownload(
            DownloadItem(
              id: 'd1',
              title: 'Active Download',
              url: 'https://x.test/active',
              status: 'downloading',
              filePath: '${tempDownload.path}/active.mp4',
            ),
          );

      final notifier = container.read(resumeProvider.notifier);

      await notifier.scan();
      final candidates = notifier.state.value ?? [];

      // Active download must be filtered out
      expect(candidates, hasLength(1));
      expect(candidates.single.filepath, idleFile);
    });
  });
}
