import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/report_sanitizer.dart';

/// Redaction is the only thing standing between a crash message and a
/// public GitHub issue. These cases are the shapes yt-dlp and Flutter
/// actually produce, not invented ones.
void main() {
  group('secrets in query strings', () {
    test('masks signed-URL parameters but keeps the names', () {
      const url =
          'https://rr3.googlevideo.com/videoplayback?sig=ABC123&lsig=DEF456&token=ghi';
      final out = ReportSanitizer.sanitize(url);

      expect(out, contains('sig='));
      expect(out, isNot(contains('ABC123')));
      expect(out, isNot(contains('DEF456')));
      expect(out, isNot(contains('ghi')));
      expect(out, contains('videoplayback'));
    });

    test('masks key= even without a token-looking name around it', () {
      final out = ReportSanitizer.sanitize('?key=super-secret&quality=hd');
      expect(out, isNot(contains('super-secret')));
      expect(out, contains('quality=hd'));
    });

    test('does not mangle a word that merely ends in key', () {
      final out = ReportSanitizer.sanitize('monkey=banana');
      expect(out, contains('banana'), reason: 'no word boundary before key');
    });
  });

  group('headers', () {
    test('masks an Authorization header including its scheme', () {
      final out = ReportSanitizer.sanitize(
        'HTTP error 403\nAuthorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig\n',
      );
      expect(out, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(out, contains('Authorization:'));
    });

    test('masks a Cookie header all the way to end of line', () {
      final out = ReportSanitizer.sanitize(
        'Cookie: SID=abc; HSID=def; SSID=ghi\nnext line stays',
      );
      expect(out, isNot(contains('SID=abc')));
      expect(out, isNot(contains('HSID=def')));
      expect(out, contains('next line stays'));
    });

    test('masks Basic credentials', () {
      final out = ReportSanitizer.sanitize('Authorization: Basic dXNlcjpwYXNz');
      expect(out, isNot(contains('dXNlcjpwYXNz')));
    });
  });

  group('credentials in URLs', () {
    test('keeps the user, masks the password', () {
      final out =
          ReportSanitizer.sanitize('http://alice:hunter2@proxy.local:8080');
      expect(out, isNot(contains('hunter2')));
      expect(out, contains('alice'));
      expect(out, contains('proxy.local:8080'));
    });
  });

  group('personal data', () {
    test('masks the account name in POSIX home paths', () {
      final out = ReportSanitizer.sanitize(
        'FileNotFoundError: /home/ada/.config/grablytic/config.json',
      );
      expect(out, isNot(contains('/home/ada')));
      expect(out, contains('config.json'));
    });

    test('masks the account name in Windows user paths', () {
      final out = ReportSanitizer.sanitize(
        r'C:\Users\ada\AppData\Local\Grablytic\logs.txt',
      );
      expect(out, isNot(contains('ada')));
      expect(out, contains('logs.txt'));
    });

    test('leaves a normal file path alone', () {
      const path = '/storage/emulated/0/Download/Grablytic/video.mp4';
      expect(ReportSanitizer.sanitize(path), path);
    });
  });

  group('context maps', () {
    test('masks sensitive keys and scrubs the rest by value', () {
      final out = ReportSanitizer.sanitizeMap({
        'cookie_jar': 'SID=abc',
        'method': 'download/start?sig=leak',
        'count': 3,
      });

      expect(out['cookie_jar'], ReportSanitizer.redacted);
      expect(out['method'], isNot(contains('leak')));
      expect(out['count'], '3');
    });

    test('a secret under an innocent key is still caught by value', () {
      final out = ReportSanitizer.sanitizeMap({'note': 'token=abc123'});
      expect(out['note'], isNot(contains('abc123')));
    });
  });

  group('excerpt', () {
    test('keeps the tail and the newest lines', () {
      final text = List.generate(200, (i) => 'line $i').join('\n');
      final out = ReportSanitizer.excerpt(text, maxChars: 120);

      expect(out.length, lessThan(200));
      expect(out, contains('line 199'));
      expect(out, isNot(contains('line 0')));
      expect(out, startsWith('[... truncated ...]'));
    });

    test('short text is untouched', () {
      expect(ReportSanitizer.excerpt('hello', maxChars: 120), 'hello');
    });

    test('empty and null are empty', () {
      expect(ReportSanitizer.excerpt(null), '');
      expect(ReportSanitizer.excerpt(''), '');
    });
  });

  group('robustness', () {
    test('null and empty input are safe', () {
      expect(ReportSanitizer.sanitize(null), '');
      expect(ReportSanitizer.sanitize(''), '');
    });

    test('a mixed payload has no secret left anywhere', () {
      const payload = '''
SocketException: failed to fetch https://user:pw@host/v?token=AAA&sig=BBB
Authorization: Bearer CCC
Cookie: DDD=EEE
home: /home/frank/x.log
''';
      final out = ReportSanitizer.sanitize(payload);

      for (final secret in ['pw', 'AAA', 'BBB', 'CCC', 'DDD', 'EEE', 'frank']) {
        expect(out, isNot(contains(secret)), reason: '$secret leaked');
      }
    });

    test('pattern sources are declared in one place', () {
      expect(ReportSanitizer.patternSources, isNotEmpty);
      expect(ReportSanitizer.patternSources.length, greaterThan(4));
    });
  });
}
