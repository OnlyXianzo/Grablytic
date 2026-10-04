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

  group('logoVariant pref', () {
    test('defaults to system', () {
      expect(n.state.logoVariant, 'system');
    });

    test('setLogoVariant persists valid values', () {
      n.setLogoVariant('dark');
      expect(n.state.logoVariant, 'dark');
      n.setLogoVariant('legacy');
      expect(n.state.logoVariant, 'legacy');
    });

    test('invalid values clamp to system', () {
      n.setLogoVariant('nope');
      expect(n.state.logoVariant, 'system');
      n.setLogoVariant('');
      expect(n.state.logoVariant, 'system');
    });

    test('reload keeps stored value, drops invalid stored value', () async {
      SharedPreferences.setMockInitialValues({'logoVariant': 'light'});
      final prefs = await SharedPreferences.getInstance();
      final n2 = SettingsNotifier(prefs);
      await Future<void>.delayed(Duration.zero);
      expect(n2.state.logoVariant, 'light');

      SharedPreferences.setMockInitialValues({'logoVariant': 'junk'});
      final prefsBad = await SharedPreferences.getInstance();
      final n3 = SettingsNotifier(prefsBad);
      await Future<void>.delayed(Duration.zero);
      expect(n3.state.logoVariant, 'system');
    });
  });
}
