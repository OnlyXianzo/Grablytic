import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/core/engine/engine_provider.dart';
import 'package:grablytic/core/engine/mock_engine_service.dart';
import 'package:grablytic/providers/resume_provider.dart';
import 'package:grablytic/providers/settings_provider.dart';

ResumeCandidate _c({String? url = 'https://x.test/v', bool expired = false}) =>
    ResumeCandidate(
      filename: 'video.f308.webm.part',
      filepath: '/tmp/video.f308.webm.part',
      sizeBytes: 1024,
      ageSeconds: 60,
      likelyUrl: url,
      expired: expired,
    );

Future<ResumeNotifier> _notifierWith(
  List<ResumeCandidate> seed, {
  Future<String> Function()? resolveCacheDir,
  Future<String?> Function()? resolveDownloadDir,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    engineProvider.overrideWith((ref) => MockEngineService()),
    resumeProvider.overrideWith((ref) => ResumeNotifier(
          ref,
          resolveCacheDir: resolveCacheDir,
          resolveDownloadDir: resolveDownloadDir,
        )),
  ]);
  addTearDown(container.dispose);
  final n = container.read(resumeProvider.notifier);
  await Future<void>.delayed(Duration.zero);
  n.state = AsyncValue.data(seed);
  return n;
}

void main() {
  group('ResumeNotifier.resumeDownload (P2)', () {
    test('RED: valid candidate returns likelyUrl and drops it from list', () async {
      final n = await _notifierWith([_c()]);
      final url = await n.resumeDownload(_c());
      expect(url, 'https://x.test/v');
      expect(n.state.value, isEmpty);
    });

    test('RED: null likelyUrl returns null and keeps list', () async {
      final n = await _notifierWith([_c(url: null)]);
      final url = await n.resumeDownload(_c(url: null));
      expect(url, isNull);
      expect(n.state.value, hasLength(1));
    });

    test('RED: expired candidate returns null and keeps list', () async {
      final n = await _notifierWith([_c(expired: true)]);
      final url = await n.resumeDownload(_c(expired: true));
      expect(url, isNull);
      expect(n.state.value, hasLength(1));
    });
  });

  group('ResumeNotifier dismiss/deleteFileOnly (BRUTAL-6 info.json)', () {
    Future<Directory> seedMidPartFiles() async {
      final dir = await Directory.systemTemp.createTemp('resume-info');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      await File('${dir.path}/my.part.video.f137.part').writeAsString('x');
      await File('${dir.path}/my.part.video.f137.info.json').writeAsString('{}');
      return dir;
    }

    ResumeCandidate midPart(String dirPath) => ResumeCandidate(
          filename: 'my.part.video.f137.part',
          filepath: '$dirPath/my.part.video.f137.part',
          sizeBytes: 1,
          ageSeconds: 60,
          likelyUrl: 'https://x.test/v',
          expired: false,
        );

    test('RED: dismiss deletes sibling info.json when .part appears mid-name',
        () async {
      final dir = await seedMidPartFiles();
      final n = await _notifierWith([midPart(dir.path)],
          resolveCacheDir: () async => dir.path);
      await n.dismiss(midPart(dir.path));
      expect(File('${dir.path}/my.part.video.f137.part').existsSync(), isFalse);
      expect(File('${dir.path}/my.part.video.f137.info.json').existsSync(),
          isFalse);
      expect(n.state.value, isEmpty);
    });

    test('RED: deleteFileOnly deletes sibling info.json when .part appears mid-name',
        () async {
      final dir = await seedMidPartFiles();
      final n = await _notifierWith([midPart(dir.path)],
          resolveCacheDir: () async => dir.path);
      await n.deleteFileOnly(midPart(dir.path));
      expect(File('${dir.path}/my.part.video.f137.part').existsSync(), isFalse);
      expect(File('${dir.path}/my.part.video.f137.info.json').existsSync(),
          isFalse);
    });
  });

  group('ResumeCandidate.fromJson trust boundary sanitization', () {
    test('RED: rejects path traversal (../../evil.part)', () {
      final res = ResumeCandidate.fromJson({
        'filename': 'evil.part',
        'filepath': '../../evil.part',
      });
      expect(res, isNull);
    });

    test('RED: rejects relative paths', () {
      final res = ResumeCandidate.fromJson({
        'filename': 'evil.part',
        'filepath': 'relative/evil.part',
      });
      expect(res, isNull);
    });

    test('RED: rejects files without .part suffix', () {
      final res = ResumeCandidate.fromJson({
        'filename': 'grablytic.db',
        'filepath': '/tmp/grablytic.db',
      });
      expect(res, isNull);
    });

    test('RED: handles malformed json gracefully without throwing', () {
      expect(ResumeCandidate.fromJson({}), isNull);
      expect(ResumeCandidate.fromJson({'filepath': null}), isNull);
      expect(ResumeCandidate.fromJson({'filepath': 12345}), isNull);
    });

    test('RED: enforces allowedDirs when provided', () {
      final allowed = ['/data/user/0/cache'];
      final rejected = ResumeCandidate.fromJson({
        'filename': 'v.part',
        'filepath': '/data/user/0/databases/app.db.part',
      }, allowedDirs: allowed);
      expect(rejected, isNull);

      final accepted = ResumeCandidate.fromJson({
        'filename': 'v.part',
        'filepath': '/data/user/0/cache/v.part',
      }, allowedDirs: allowed);
      expect(accepted, isNotNull);
      expect(accepted!.filepath, '/data/user/0/cache/v.part');
    });
  });

  group('ResumeNotifier dismissal security & boundary protection', () {
    test('RED: dismiss refused for file outside allowed directories', () async {
      final outsideDir = await Directory.systemTemp.createTemp('outside-dir');
      final sensitiveFile = File('${outsideDir.path}/sensitive.part');
      await sensitiveFile.writeAsString('CRITICAL DATA');
      addTearDown(() => outsideDir.delete(recursive: true));

      final mockCacheDir = await Directory.systemTemp.createTemp('mock-cache');
      addTearDown(() => mockCacheDir.delete(recursive: true));

      final n = await _notifierWith(
        [],
        resolveCacheDir: () async => mockCacheDir.path,
        resolveDownloadDir: () async => mockCacheDir.path,
      );
      final cand = ResumeCandidate(
        filename: 'sensitive.part',
        filepath: sensitiveFile.path,
        sizeBytes: 13,
        ageSeconds: 10,
        likelyUrl: 'https://x.test/v',
        expired: false,
      );

      await n.dismiss(cand);
      expect(sensitiveFile.existsSync(), isTrue);
    });

    test('RED: sidecar traversal does not delete outside allowed directory', () async {
      final mockCache = await Directory.systemTemp.createTemp('cache-sidecar');
      addTearDown(() => mockCache.delete(recursive: true));

      final outsideDir = await Directory.systemTemp.createTemp('outside-sidecar');
      final victim = File('${outsideDir.path}/victim.info.json');
      await victim.writeAsString('VICTIM');
      addTearDown(() => outsideDir.delete(recursive: true));

      final n = await _notifierWith(
        [],
        resolveCacheDir: () async => mockCache.path,
        resolveDownloadDir: () async => mockCache.path,
      );
      final cand = ResumeCandidate(
        filename: 'test.part',
        filepath: '${outsideDir.path}/victim.part',
        sizeBytes: 10,
        ageSeconds: 5,
        likelyUrl: 'https://x.test/v',
        expired: false,
      );

      await n.dismiss(cand);
      expect(victim.existsSync(), isTrue);
    });
  });

  group('ResumeNotifier.reportAttempt (BRUTAL-5 strike loop)', () {
    test('RED: report without a prior resumeDownload is a silent no-op',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mock = MockEngineService();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWith((ref) => mock),
      ]);
      addTearDown(container.dispose);
      final n = container.read(resumeProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      await n.reportAttempt(url: 'https://x.test/never', success: false);
      expect(mock.reportedAttempts, isEmpty);
    });

    test('RED: resumeDownload stashes origin; reportAttempt forwards once',
        () async {
      final dir = await Directory.systemTemp.createTemp('resume-rep');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final partPath = '${dir.path}/v.part';
      await File(partPath).writeAsString('x');
      final cand = ResumeCandidate(
        filename: 'v.part',
        filepath: partPath,
        sizeBytes: 1,
        ageSeconds: 60,
        likelyUrl: 'https://x.test/v',
        expired: false,
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final mock = MockEngineService();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        engineProvider.overrideWith((ref) => mock),
      ]);
      addTearDown(container.dispose);
      final n = container.read(resumeProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      n.state = const AsyncValue.data([]);
      final url = await n.resumeDownload(cand);
      expect(url, 'https://x.test/v');
      await n.reportAttempt(url: url!, success: false, cacheDir: dir.path);
      expect(mock.reportedAttempts, hasLength(1));
      expect(mock.reportedAttempts.single['filepath'], partPath);
      expect(mock.reportedAttempts.single['success'], isFalse);
      // One-shot: second report for the same url is a no-op.
      await n.reportAttempt(url: url, success: false);
      expect(mock.reportedAttempts, hasLength(1));
    });
  });
}
