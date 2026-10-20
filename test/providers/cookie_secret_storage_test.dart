import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/providers/settings_provider.dart';

import '../support/fake_cookie_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('cookie jars leave SharedPreferences', () {
    test('the jar content is never written to preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = FakeCookieSecretStore();
      final notifier = SettingsNotifier(prefs, cookieSecretStore: store);
      await notifier.cookieProfilesReady;

      notifier.upsertCookieProfile(
        url: 'https://youtube.com',
        description: 'YT',
        lines: const ['.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tabc123'],
      );
      // Give the unawaited store write a turn.
      await Future<void>.delayed(Duration.zero);

      final raw = prefs.getStringList('cookieProfiles') ?? [];
      expect(raw, isNotEmpty);
      for (final entry in raw) {
        expect(entry, isNot(contains('abc123')));
        expect(entry, isNot(contains('SID')));
      }
      // The jar itself is in the secret store.
      expect(store.stored.values.first.join('\n'), contains('abc123'));
    });

    test('a legacy plaintext jar is migrated out of preferences', () async {
      SharedPreferences.setMockInitialValues({
        'cookieProfiles': [
          jsonEncode({
            'id': 'legacy-1',
            'url': 'https://youtube.com',
            'description': 'legacy',
            'enabled': true,
            'content': ['.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tlegacysecret'],
          }),
        ],
      });
      final prefs = await SharedPreferences.getInstance();
      final store = FakeCookieSecretStore();
      final notifier = SettingsNotifier(prefs, cookieSecretStore: store);
      await notifier.cookieProfilesReady;

      final raw = prefs.getStringList('cookieProfiles') ?? [];
      for (final entry in raw) {
        expect(entry, isNot(contains('legacysecret')));
      }
      expect(store.stored['legacy-1']!.join('\n'), contains('legacysecret'));
      // The jar is still available in memory for the cookies screen.
      final profile = notifier.state.cookieProfiles.first;
      expect((profile['content'] as List).first, contains('legacysecret'));
    });

    test('deleting a profile removes the stored jar', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = FakeCookieSecretStore();
      final notifier = SettingsNotifier(prefs, cookieSecretStore: store);
      await notifier.cookieProfilesReady;

      notifier.upsertCookieProfile(
        url: 'https://a.test',
        description: 'A',
        lines: const ['line'],
      );
      await Future<void>.delayed(Duration.zero);
      final id = notifier.state.cookieProfiles.first['id'] as String;
      expect(store.stored.containsKey(id), isTrue);

      notifier.deleteCookieProfile(id);
      await Future<void>.delayed(Duration.zero);
      expect(store.stored.containsKey(id), isFalse);
    });
  });
}
