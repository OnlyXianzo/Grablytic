import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/github_reporter.dart';

void main() {
  group('GithubReporter.issueUrl budget (#106)', () {
    test('keeps the body when the encoded URL fits', () {
      final url = GithubReporter().issueUrl(title: 'Bug', body: 'short');
      expect(url.queryParameters.containsKey('body'), isTrue);
    });

    test('drops the body when the encoded URL would be refused', () {
      // A Devanagari description expands about ninefold once percent-encoded,
      // so a 6,000-character body is far past GitHub's 8,192-byte boundary.
      // Opening that URL yields a 414 page, not a prefilled form.
      final url = GithubReporter().issueUrl(title: 'Bug', body: 'é' * 6000);
      expect(url.queryParameters.containsKey('body'), isFalse);
      expect(url.toString().length, lessThan(7500));
    });
  });
}
