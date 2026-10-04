import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/theme/app_theme.dart';

/// Locks in the bundled product typography:
/// - Headings and display styles resolve to bundled BricolageGrotesque.
/// - Body, labels, and metadata resolve to bundled Figtree.
/// Never a runtime-fetched webfont (privacy: no font-CDN beacon on launch).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('AppTheme product face', () {
    for (final entry in {'light': AppTheme.light(), 'dark': AppTheme.dark()}.entries) {
      test('${entry.key} uses bundled BricolageGrotesque for headings', () {
        final headingStyles = [
          entry.value.textTheme.displayLarge,
          entry.value.textTheme.headlineLarge,
          entry.value.textTheme.headlineMedium,
          entry.value.textTheme.titleLarge,
        ];
        expect(headingStyles, isNotEmpty);
        for (final s in headingStyles) {
          expect(s?.fontFamily, 'BricolageGrotesque',
              reason: '${entry.key} ${s.toString()} must use BricolageGrotesque');
        }
      });

      test('${entry.key} uses bundled Figtree for body and labels', () {
        final bodyStyles = [
          entry.value.textTheme.titleMedium,
          entry.value.textTheme.titleSmall,
          entry.value.textTheme.bodyLarge,
          entry.value.textTheme.bodyMedium,
          entry.value.textTheme.bodySmall,
          entry.value.textTheme.labelLarge,
          entry.value.textTheme.labelMedium,
          entry.value.textTheme.labelSmall,
        ];
        expect(bodyStyles, isNotEmpty);
        for (final s in bodyStyles) {
          expect(s?.fontFamily, 'Figtree',
              reason: '${entry.key} ${s.toString()} must use Figtree');
        }
      });
    }
  });
}
