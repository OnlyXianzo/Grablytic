import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/utils/logging_observers.dart';
import 'package:grablytic/providers/settings_provider.dart';

void main() {
  group('diffAppSettings', () {
    const base = AppSettings();

    test('empty for identical settings', () {
      expect(diffAppSettings(base, base), isEmpty);
    });

    test('reports changed scalars', () {
      final next = base.copyWith(qualityCeiling: '720p', aria2cChunks: 9);
      final changes = diffAppSettings(base, next);
      expect(changes, contains('qualityCeiling: 4k → 720p'));
      expect(changes, contains('aria2cChunks: 5 → 9'));
    });

    test('summarizes lists by count', () {
      final next = base.copyWith(sponsorBlockCats: ['sponsor', 'intro']);
      final changes = diffAppSettings(base, next);
      expect(
        changes.any((c) => c.startsWith('sponsorBlockCats:')),
        isTrue,
      );
      expect(changes.join(), isNot(contains('intro')));
    });

    test('masks proxy credentials', () {
      final next = base.copyWith(proxy: 'http://user:pass@proxy:8080');
      final changes = diffAppSettings(base, next);
      expect(changes.length, 1);
      expect(changes.single, isNot(contains('user:pass')));
      expect(changes.single, contains('@proxy:8080'));
    });

    test('null-safe on cleared values', () {
      final prev = base.copyWith(proxy: 'http://proxy:8080');
      final changes = diffAppSettings(prev, base);
      expect(changes.length, 1);
    });
  });
}
