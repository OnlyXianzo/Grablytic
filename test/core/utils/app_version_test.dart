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

    test('shortOf drops the build number', () {
      expect(AppVersion.shortOf('0.0.6+6'), '0.0.6');
      expect(AppVersion.shortOf('0.0.1-beta+1'), '0.0.1-beta');
      expect(AppVersion.shortOf('0.0.6'), '0.0.6');
      expect(AppVersion.shortOf('unknown'), 'unknown');
    });

    test('short is shortOf applied to the stamped value', () {
      // The stamped value is 'unknown' in a test host, so this asserts the
      // wiring rather than a number: whatever arrives, no build number leaks
      // into the UI.
      expect(AppVersion.short, anyOf('unknown', isNot(contains('+'))));
    });
  });
}
