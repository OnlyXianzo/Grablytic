import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/features/home/widgets/batch_quality_dialog.dart';

void main() {
  group('batchQualityLabel', () {
    test('labels every offered option', () {
      expect(batchQualityLabel('480p'), contains('480p'));
      expect(batchQualityLabel('720p'), contains('720p'));
      expect(batchQualityLabel('1080p'), contains('1080p'));
      expect(batchQualityLabel('best'), isNotEmpty);
    });
  });

  group('normalizeBatchCeiling', () {
    test('keeps offered options, falls back to best otherwise', () {
      for (final o in batchQualityOptions) {
        expect(normalizeBatchCeiling(o), o);
      }
      expect(normalizeBatchCeiling('4k'), 'best');
      expect(normalizeBatchCeiling('2160p'), 'best');
      expect(normalizeBatchCeiling(null), 'best');
      expect(normalizeBatchCeiling(''), 'best');
    });
  });

  group('showBatchQualityDialog', () {
    testWidgets('Start returns the selected quality', (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showBatchQualityDialog(
                  context: context,
                  initialCeiling: '1080p',
                  itemCount: 100,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('100 items'), findsOneWidget);
      await tester.tap(find.byKey(const Key('batch-quality-720p')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('batch-quality-start')));
      await tester.pumpAndSettle();

      expect(result, '720p');
    });

    testWidgets('Cancel returns null', (tester) async {
      String? result = 'sentinel';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showBatchQualityDialog(
                  context: context,
                  initialCeiling: 'best',
                  itemCount: 7,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('batch-quality-cancel')));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });

    testWidgets('unknown initial falls back to Best selected', (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showBatchQualityDialog(
                  context: context,
                  initialCeiling: '4k',
                  itemCount: 3,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Accept the pre-selected fallback without touching any radio.
      await tester.tap(find.byKey(const Key('batch-quality-start')));
      await tester.pumpAndSettle();

      expect(result, 'best');
    });
  });
}
