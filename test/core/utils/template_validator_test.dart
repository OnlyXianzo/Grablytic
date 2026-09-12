import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/providers/settings_provider.dart';

void main() {
  group('validateTemplateArgs (SEC-04)', () {
    test('allows ordinary download flags', () {
      expect(validateTemplateArgs('--write-sub --sub-lang en'), isNull);
      expect(validateTemplateArgs('-x --audio-format mp3'), isNull);
      expect(
          validateTemplateArgs('-o "%(title)s.%(ext)s"'), isNull);
    });

    test('blocks absolute output paths', () {
      expect(validateTemplateArgs('-o /etc/cron.d/x'), isNotNull);
      expect(
          validateTemplateArgs('--output=C:\\Windows\\x'), isNotNull);
      expect(
          validateTemplateArgs('--paths=/tmp/evil'), isNotNull);
    });

    test('blocks parent traversal', () {
      expect(validateTemplateArgs('-o ../../x'), isNotNull);
      expect(validateTemplateArgs('--output=a/b/../../c'), isNotNull);
    });

    test('blocks NUL and oversize input', () {
      expect(validateTemplateArgs('a\x00b'), isNotNull);
      expect(validateTemplateArgs('x' * 2001), isNotNull);
    });
  });

  group('templateWantsExec (SEC-04)', () {
    test('detects exec flags', () {
      expect(templateWantsExec('--exec echo hi'), isTrue);
      expect(
          templateWantsExec('--write-sub --exec-after-move echo hi'), isTrue);
    });

    test('ignores non-exec flags', () {
      expect(templateWantsExec('--write-sub --sub-lang en'), isFalse);
      expect(templateWantsExec('--executable-x'), isFalse);
    });
  });
}
