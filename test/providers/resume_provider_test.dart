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

Future<ResumeNotifier> _notifierWith(List<ResumeCandidate> seed) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    engineProvider.overrideWith((ref) => MockEngineService()),
    // NOTE: real ResumeNotifier.scan() runs in ctor (empty mock result);
    // seed state directly after it settles.
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
      final n = await _notifierWith([midPart(dir.path)]);
      await n.dismiss(midPart(dir.path));
      expect(File('${dir.path}/my.part.video.f137.part').existsSync(), isFalse);
      expect(File('${dir.path}/my.part.video.f137.info.json').existsSync(),
          isFalse);
      expect(n.state.value, isEmpty);
    });

    test('RED: deleteFileOnly deletes sibling info.json when .part appears mid-name',
        () async {
      final dir = await seedMidPartFiles();
      final n = await _notifierWith([midPart(dir.path)]);
      await n.deleteFileOnly(midPart(dir.path));
      expect(File('${dir.path}/my.part.video.f137.part').existsSync(), isFalse);
      expect(File('${dir.path}/my.part.video.f137.info.json').existsSync(),
          isFalse);
    });
  });
}
