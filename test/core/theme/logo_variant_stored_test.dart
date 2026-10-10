import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/theme/adaptive_logo.dart';

void main() {
  group('LogoVariant.fromStored', () {
    test('maps known pref values', () {
      expect(LogoVariant.fromStored('dark'), LogoVariant.dark);
      expect(LogoVariant.fromStored('light'), LogoVariant.light);
      expect(LogoVariant.fromStored('legacy'), LogoVariant.legacy);
    });

    test('system, null and unknown fall back to auto', () {
      expect(LogoVariant.fromStored('system'), LogoVariant.auto);
      expect(LogoVariant.fromStored(null), LogoVariant.auto);
      expect(LogoVariant.fromStored('nope'), LogoVariant.auto);
      expect(LogoVariant.fromStored(''), LogoVariant.auto);
    });
  });
}
