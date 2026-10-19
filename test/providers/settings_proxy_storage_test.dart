import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/providers/settings_provider.dart';
import '../support/fake_proxy_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('proxy secure-storage migration', () {
    test('moves legacy SharedPreferences proxy into secure storage', () async {
      SharedPreferences.setMockInitialValues({
        'proxy': 'http://user:pw@proxy.example:8080',
      });
      final prefs = await SharedPreferences.getInstance();
      final secureStore = FakeProxySecretStore();
      final notifier = SettingsNotifier(prefs, proxySecretStore: secureStore);

      await notifier.proxyReady;

      expect(secureStore.value, 'http://user:pw@proxy.example:8080');
      expect(prefs.getString('proxy'), isNull);
      expect(notifier.state.proxy, secureStore.value);
      expect(await notifier.proxyForDownload(), secureStore.value);
    });

    test('secure value wins over and clears a stale plaintext copy', () async {
      SharedPreferences.setMockInitialValues({'proxy': 'http://old:8080'});
      final prefs = await SharedPreferences.getInstance();
      final secureStore = FakeProxySecretStore(value: 'http://new:8080');
      final notifier = SettingsNotifier(prefs, proxySecretStore: secureStore);

      await notifier.proxyReady;

      expect(notifier.state.proxy, 'http://new:8080');
      expect(prefs.getString('proxy'), isNull);
    });

    test(
      'saving and clearing never writes proxy into SharedPreferences',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final secureStore = FakeProxySecretStore();
        final notifier = SettingsNotifier(prefs, proxySecretStore: secureStore);
        await notifier.proxyReady;

        await notifier.setProxy(' http://user:pw@proxy.example:8080 ');
        expect(secureStore.value, 'http://user:pw@proxy.example:8080');
        expect(notifier.state.proxy, secureStore.value);
        expect(prefs.getString('proxy'), isNull);

        await notifier.setProxy(null);
        expect(secureStore.value, isNull);
        expect(notifier.state.proxy, isNull);
        expect(prefs.getString('proxy'), isNull);
      },
    );

    test('legacy custom templates are scrubbed of proxy credentials', () async {
      final legacyTemplate = jsonEncode({
        'name': 'Legacy',
        'args': '--write-subs --proxy http://user:pw@proxy.example:8080',
      });
      SharedPreferences.setMockInitialValues({
        'customTemplates': jsonEncode([legacyTemplate]),
      });
      final prefs = await SharedPreferences.getInstance();
      final notifier = SettingsNotifier(
        prefs,
        proxySecretStore: FakeProxySecretStore(),
      );
      await notifier.proxyReady;

      expect(notifier.state.customTemplates, [
        jsonEncode({'name': 'Legacy', 'args': '--write-subs'}),
      ]);
      expect(prefs.getString('customTemplates'), isNot(contains('proxy.example')));

      await notifier.setCustomTemplates([
        jsonEncode({
          'name': 'New',
          'args': '--proxy=http://user:pw@proxy.example:8080 --embed-subs',
        }),
      ]);
      expect(prefs.getString('customTemplates'), isNot(contains('proxy.example')));
    });

    test(
      'secure-store failure clears legacy plaintext and blocks use',
      () async {
        SharedPreferences.setMockInitialValues({
          'proxy': 'http://user:pw@p:8',
        });
        final prefs = await SharedPreferences.getInstance();
        final secureStore = FakeProxySecretStore()..failWrites = true;
        final notifier = SettingsNotifier(prefs, proxySecretStore: secureStore);

        await notifier.proxyReady;

        expect(prefs.getString('proxy'), isNull);
        expect(notifier.state.proxy, isNull);
        await expectLater(notifier.proxyForDownload(), throwsStateError);
      },
    );
  });
}
