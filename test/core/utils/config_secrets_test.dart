import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/config_secrets.dart';

void main() {
  test('recursively strips proxy fields from maps and lists', () {
    final input = jsonEncode({
      'format': 'best',
      'proxy': 'http://user:pw@proxy.example:8080',
      'nested': [{'proxy_password': 'pw', 'keep': true}],
    });
    expect(jsonDecode(stripProxyFieldsFromJson(input)!), {
      'format': 'best',
      'nested': [{'keep': true}],
    });
  });

  test('drops malformed persisted config rather than preserving secrets', () {
    expect(stripProxyFieldsFromJson('{"proxy":"unfinished'), isNull);
  });
}
