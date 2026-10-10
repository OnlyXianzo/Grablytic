import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/cookie_store.dart';

String _line(String domain) =>
    '$domain\tTRUE\t/\tTRUE\t1893456000\tSID\ttest-value';

List<NetscapeCookie> _parse(
  Object export, {
  String site = 'https://example.com',
}) => parsePastedCookies(
  jsonEncode(export),
  site,
).map(NetscapeCookie.fromLine).toList();

void main() {
  group('cookie format detection', () {
    final cases = <String, CookieParseFormat>{
      '': CookieParseFormat.unknown,
      '  not cookies  ': CookieParseFormat.unknown,
      '[broken json]': CookieParseFormat.unknown,
      '[]': CookieParseFormat.unknown,
      '# HTTP Cookie File': CookieParseFormat.netscape,
      '# Netscape HTTP Cookie File': CookieParseFormat.netscape,
      _line('.example.com'): CookieParseFormat.netscape,
      '#HttpOnly_${_line('.example.com')}': CookieParseFormat.netscape,
      '[{"name":"SID","value":"test-value"}]': CookieParseFormat.json,
      '{"cookies":[]}': CookieParseFormat.json,
      'SID=test-value': CookieParseFormat.header,
      'Cookie: SID=test-value; OTHER=second': CookieParseFormat.header,
    };
    for (final entry in cases.entries) {
      test('detects ${entry.key}', () {
        expect(detectCookieFormat(entry.key), entry.value);
      });
    }
  });

  group('JSON cookie imports', () {
    test('preserves Netscape attributes from browser exports', () {
      final cookies = _parse([
        {
          'domain': '.example.com',
          'name': 'SID',
          'value': 'test-value',
          'path': '/account',
          'secure': true,
          'httpOnly': true,
          'expirationDate': 1893456000.75,
        },
      ]);
      expect(
        cookies.single.toLine(),
        '#HttpOnly_.example.com\tTRUE\t/account\tTRUE\t1893456000\tSID\ttest-value',
      );
    });

    test('accepts wrapped exports and alternate field names', () {
      final cookie = _parse({
        'cookies': [
          {
            'host': 'login.example.com',
            'key': 'token',
            'value': 'value=with=equals',
            'hostOnly': true,
            'secure': 'TRUE',
            'httponly': true,
            'expires': '1893456000',
          },
        ],
      }).single;
      expect(
        cookie.toLine(),
        '#HttpOnly_.login.example.com\tFALSE\t/\tTRUE\t1893456000\ttoken\tvalue=with=equals',
      );
    });

    for (final key in ['expirationDate', 'expires', 'expiry', 'expiration']) {
      test('accepts $key including session expiration zero', () {
        expect(
          _parse([
            {'name': 'SID', 'value': 'x', key: 0},
          ]).single.expiration,
          '0',
        );
      });
    }

    test('skips invalid entries without discarding neighboring cookies', () {
      final cookies = _parse([
        null,
        'garbage',
        42,
        {},
        {'name': '   ', 'value': 'x'},
        {'name': 'SID', 'value': 'first'},
      ]);
      expect(cookies.map((c) => c.name), ['SID']);
      expect(cookies.first.domain, '.example.com');
      expect(cookies.first.path, '/');
      expect(cookies.first.secure, 'FALSE');
    });

    test('preserves an empty-valued browser cookie during JSON conversion', () {
      // Regression: trimming the serialized line removes the seventh field.
      final cookies = _parse([
        {'name': 'EMPTY', 'value': ''},
      ]);
      expect(cookies, hasLength(1));
      expect(cookies.single.name, 'EMPTY');
      expect(cookies.single.value, '');
    });

    test('simple maps derive the site domain and omit blank names/values', () {
      final cookies = _parse({
        ' SID ': ' value ',
        '': 'x',
        'empty': ' ',
      }, site: 'https://LOGIN.Example.com/account');
      expect(cookies.single.domain, '.login.example.com');
      expect(cookies.single.name, 'SID');
      expect(cookies.single.value, 'value');
      expect(cookies.single.includeSubdomains, 'TRUE');
      expect(cookies.single.secure, 'TRUE');
    });

    test('default expiration is approximately ten years in the future', () {
      const tenYears = 10 * 365 * 24 * 60 * 60;
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final expiry = int.parse(
        _parse([
          {'name': 'SID', 'value': 'x'},
        ]).single.expiration,
      );
      final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(expiry, inInclusiveRange(before + tenYears, after + tenYears));
    });

    for (final input in ['[]', '{broken', '[null, 1, {}]', '{"SID":"x"}']) {
      test('rejects unusable export with no site: $input', () {
        expect(parsePastedCookies(input, ''), isEmpty);
      });
    }
  });

  group('encoded imports', () {
    final sources = [
      _line('.example.com'),
      '[{"domain":".example.com","name":"SID","value":"test-value","expires":1893456000}]',
      'Cookie: SID=test-value; OTHER=second',
    ];
    for (final source in sources) {
      test('detects and imports wrapped ${source.substring(0, 12)}', () {
        final encoded = base64Encode(utf8.encode(source));
        final wrapped =
            ' \n${encoded.substring(0, 12)}\n${encoded.substring(12)}\t';
        expect(detectCookieFormat(wrapped), CookieParseFormat.base64);
        final cookies = parsePastedCookies(
          wrapped,
          'https://example.com',
        ).map(NetscapeCookie.fromLine).toList();
        expect(cookies.first.name, 'SID');
        expect(cookies.first.value, 'test-value');
        expect(cookies.first.domain, '.example.com');
        expect(cookies, hasLength(source.startsWith('Cookie:') ? 2 : 1));
      });
    }
    test('invalid UTF-8 and unrecognized decoded text do not throw', () {
      for (final input in [
        base64Encode(List.filled(24, 255)),
        base64Encode(utf8.encode('this is not a cookie export')),
      ]) {
        expect(detectCookieFormat(input), CookieParseFormat.unknown);
        expect(parsePastedCookies(input, ''), isEmpty);
      }
    });
  });

  group('domain validation and unrelated-domain warnings', () {
    for (final domain in [
      'localhost',
      '.com',
      '.bad..example.com',
      '.bad_name.com',
      '.-example.com',
      '.example.com-',
      '.example.com/path',
    ]) {
      test('filters invalid domain $domain from Netscape and JSON', () {
        expect(
          parsePastedCookies(
            '${_line(domain)}\n${_line('.example.com')}',
            'example.com',
          ),
          [_line('.example.com')],
        );
        final cookies = _parse([
          {'domain': domain, 'name': 'BAD', 'value': 'x'},
          {'domain': '.example.com', 'name': 'GOOD', 'value': 'x'},
        ]);
        expect(cookies.map((c) => c.name), ['GOOD']);
      });
    }

    test('keeps HttpOnly cookies and legitimate YouTube companion domains', () {
      final domains = [
        '.youtube.com',
        '.accounts.google.com',
        '.googleapis.com',
        '.gstatic.com',
        '.ggpht.com',
        '.ytimg.com',
        '.doubleclick.net',
      ];
      final lines = domains.map((d) => '#HttpOnly_${_line(d)}').toList();
      expect(
        parsePastedCookies(
          lines.join('\n'),
          'https://www.youtube.com/watch?v=test',
        ),
        lines,
      );
      expect(lastCookieUnrelatedCount, 0);
    });

    test('counts unrelated cookies without deleting multi-site exports', () {
      final lines = [
        '.example.com',
        '.login.example.com',
        '.notexample.com',
        '.example.com.attacker.test',
      ].map(_line).toList();
      expect(parsePastedCookies(lines.join('\n'), 'example.com'), lines);
      expect(lastCookieUnrelatedCount, 2);
      parsePastedCookies(_line('.example.com'), 'login.example.com');
      expect(lastCookieUnrelatedCount, 0);
    });

    test(
      'an export without a selected site has no unrelated-domain warning',
      () {
        final lines = [_line('.example.com'), _line('.other.test')];
        expect(parsePastedCookies(lines.join('\n'), ''), lines);
        expect(lastCookieUnrelatedCount, 0);
      },
    );
  });
}
