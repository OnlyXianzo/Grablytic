import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/providers/settings_provider.dart';

void main() {
  late SettingsNotifier n;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    n = SettingsNotifier(prefs);
    await Future<void>.delayed(Duration.zero);
  });

  group('Cookie profiles (ytdlnis-style)', () {
    test('useCookies defaults off and toggles', () {
      expect(n.state.useCookies, isFalse);
      n.setUseCookies(true);
      expect(n.state.useCookies, isTrue);
    });

    test('upsert adds then replaces same-url profile, keeps enabled', () {
      n.upsertCookieProfile(url: 'https://youtube.com', description: 'YT', lines: const ['l1']);
      expect(n.state.cookieProfiles, hasLength(1));
      n.toggleCookieProfile(n.state.cookieProfiles.first['id'] as String);
      expect(n.state.cookieProfiles.first['enabled'], isFalse);
      n.upsertCookieProfile(
          url: 'https://YOUTUBE.com', description: 'YT2', lines: const ['l2']);
      expect(n.state.cookieProfiles, hasLength(1));
      final p = n.state.cookieProfiles.first;
      expect(p['description'], 'YT2');
      expect(p['content'], ['l2']);
      expect(p['enabled'], isFalse); // preserved across re-capture
    });

    test('delete and clear', () {
      n.upsertCookieProfile(url: 'https://a.test', description: 'A', lines: const ['l1']);
      final id = n.state.cookieProfiles.first['id'] as String;
      n.deleteCookieProfile(id);
      expect(n.state.cookieProfiles, isEmpty);
      n.upsertCookieProfile(url: 'https://a.test', description: 'A', lines: const ['l1']);
      n.clearCookieProfiles();
      expect(n.state.cookieProfiles, isEmpty);
    });

    test('copyWith keeps cookie fields', () {
      n.setUseCookies(true);
      n.upsertCookieProfile(url: 'https://a.test', description: 'A', lines: const ['l1']);
      final next = n.state.copyWith();
      expect(next.useCookies, isTrue);
      expect(next.cookieProfiles, hasLength(1));
    });
  });
}
