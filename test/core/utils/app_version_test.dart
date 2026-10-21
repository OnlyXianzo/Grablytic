import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/app_version.dart';

void main() {
  group('AppVersion (#105)', () {
    test('a host without the stamp says unknown, not a stale version', () {
      // The define is supplied by the build (GRABLYTIC_APP_VERSION from
      // pubspec.yaml). A test process has none, and the old code answered
      // with a hardcoded literal instead.
      expect(AppVersion.value, anyOf('unknown', matches(r'^\d+\.\d+\.\d+')));
    });

    test('short drops the build number', () {
      expect('0.6.0+6'.split('+').first, '0.6.0');
      expect(AppVersion.short, AppVersion.value.split('+').first);
    });
  });
}
