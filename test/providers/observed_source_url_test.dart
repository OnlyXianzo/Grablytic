import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:grablytic/providers/settings_provider.dart';

import '../support/fake_proxy_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('observed source URL validation (SEC-002)', () {
    test('accepts an absolute http(s) URL with a host', () {
      expect(validateObservedSourceUrl('https://www.youtube.com/@SomeChannel'), isNull);
      expect(validateObservedSourceUrl('http://example.com/playlist?list=PL1'), isNull);
      expect(validateObservedSourceUrl('  https://youtube.com/channel/UC123  '), isNull);
    });

    test('refuses anything a poll tier could not use', () {
      expect(validateObservedSourceUrl(''), isNotNull);
      expect(validateObservedSourceUrl('   '), isNotNull);
      expect(validateObservedSourceUrl('not a url'), isNotNull);
      expect(validateObservedSourceUrl('javascript:alert(1)'), isNotNull);
      expect(validateObservedSourceUrl('file:///data/local/tmp/x.txt'), isNotNull);
      expect(validateObservedSourceUrl('content://com.example/x'), isNotNull);
      expect(validateObservedSourceUrl('https:///no-host'), isNotNull);
      expect(validateObservedSourceUrl('//example.com/no-scheme'), isNotNull);
    });

    test('the stored source keeps the trimmed URL, not the raw text', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = SettingsNotifier(
        prefs,
        proxySecretStore: FakeProxySecretStore(),
      );

      final added = notifier.addObservedSource({
        'name': 'A channel',
        'url': '  https://www.youtube.com/channel/UC1234567890123456789012  ',
        'quality': 'best',
        'enabled': true,
      });

      expect(added, isTrue);
      expect(notifier.state.observedSources, hasLength(1));
      expect(
        notifier.state.observedSources.single['url'],
        'https://www.youtube.com/channel/UC1234567890123456789012',
      );
    });

    test('a rejected source is not stored', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final notifier = SettingsNotifier(
        prefs,
        proxySecretStore: FakeProxySecretStore(),
      );

      final added = notifier.addObservedSource({
        'name': 'Sneaky',
        'url': 'file:///data/local/tmp/feeds/videos.xml',
        'quality': 'best',
        'enabled': true,
      });

      expect(added, isFalse);
      expect(notifier.state.observedSources, isEmpty);
      expect(prefs.getString('observedSources'), isNull);
    });
  });
}
