import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/theme/app_theme.dart';

/// Locks in the bundled product face: every text style in both schemes
/// must resolve to the repo-bundled InstrumentSans family — never a
/// runtime-fetched webfont (privacy: no font-CDN beacon on launch).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('AppTheme product face', () {
    for (final entry in {'light': AppTheme.light(), 'dark': AppTheme.dark()}.entries) {
      test('${entry.key} uses bundled InstrumentSans everywhere', () {
        final styles = [
          entry.value.textTheme.displayLarge,
          entry.value.textTheme.headlineLarge,
          entry.value.textTheme.headlineMedium,
          entry.value.textTheme.titleLarge,
          entry.value.textTheme.titleMedium,
          entry.value.textTheme.bodyLarge,
          entry.value.textTheme.bodyMedium,
          entry.value.textTheme.bodySmall,
          entry.value.textTheme.labelLarge,
          entry.value.textTheme.labelSmall,
        ];
        expect(styles, isNotEmpty);
        for (final s in styles) {
          expect(s?.fontFamily, 'InstrumentSans',
              reason: '${entry.key} ${s.toString()} must use the bundled family');
        }
      });
    }
  });
}
