import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:truestream/core/engine/engine_provider.dart';
import 'package:truestream/core/engine/mock_engine_service.dart';
import 'package:truestream/providers/resume_provider.dart';
import 'package:truestream/providers/settings_provider.dart';

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
}
