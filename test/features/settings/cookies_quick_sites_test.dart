import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/features/settings/screens/cookies_screen.dart';

void main() {
  group('kQuickCookieSites', () {
    test('covers the requested sites with valid https URLs', () {
      final names = kQuickCookieSites.map((s) => s['name']).toSet();
      expect(names, containsAll({'YouTube', 'Instagram', 'X'}));
      expect(kQuickCookieSites.length, greaterThanOrEqualTo(6));
      for (final site in kQuickCookieSites) {
        final uri = Uri.parse(site['url']!);
        expect(uri.scheme, 'https', reason: site['name']);
        expect(uri.host.isNotEmpty, isTrue, reason: site['name']);
        expect(site['name']!.isNotEmpty, isTrue);
      }
      // No duplicate destinations.
      final urls = kQuickCookieSites.map((s) => s['url']!.toLowerCase()).toList();
      expect(urls.toSet(), hasLength(urls.length));
    });
  });
}
