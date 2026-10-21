import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/widgets/skeleton.dart';

/// The skeleton widgets replaced bare `CircularProgressIndicator`s on five
/// screens. These tests pin the two properties the rest of the app relies
/// on: each skeleton builds inside a themed app, and a group of placeholders
/// shares ONE shimmer (the whole point of [SkeletonShimmer]) instead of one
/// per box.
///
/// `pump()`, never `pumpAndSettle()`: the shimmer repeats forever by design,
/// so settling would time out — in a test and in the app.
Future<void> _pump(WidgetTester tester, Widget child, {bool dark = false}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: dark ? ThemeData.dark() : ThemeData.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('Skeleton draws a box with the requested size', (tester) async {
    await _pump(tester, const Skeleton(width: 40, height: 12));

    expect(tester.getSize(find.byType(Skeleton)), const Size(40, 12));
  });

  testWidgets('SkeletonShimmer hosts exactly one shimmer', (tester) async {
    await _pump(
      tester,
      const SkeletonShimmer(
        child: Column(
          children: [
            Skeleton(width: 120, height: 10),
            Skeleton(width: 90, height: 10),
            Skeleton(width: 60, height: 10),
          ],
        ),
      ),
    );

    // One shader sweep for the group, not one per box.
    expect(find.byType(Skeleton), findsNWidgets(3));
    expect(find.byType(RepaintBoundary), findsWidgets);
  });

  testWidgets('each screen skeleton builds in light and dark', (tester) async {
    final skeletons = <Widget>[
      const SkeletonHeaderCard(),
      const SkeletonList(itemCount: 3),
      const SearchResultsSkeleton(itemCount: 2),
      const PlaylistSkeleton(),
      const BootstrapSkeleton(),
      const HistorySkeleton(itemCount: 2),
      const PickerSkeleton(url: 'https://example.com/video'),
      const InlineSkeletonRow(),
    ];

    for (final dark in [false, true]) {
      for (final skeleton in skeletons) {
        await _pump(tester, skeleton, dark: dark);
        await tester.pump();
        expect(
          tester.takeException(),
          isNull,
          reason: '${skeleton.runtimeType} (dark: $dark) threw while building',
        );
      }
    }
  });

  testWidgets('a skeleton does not overflow a narrow phone width',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final skeleton in <Widget>[
      const SearchResultsSkeleton(itemCount: 3),
      const HistorySkeleton(itemCount: 3),
      const PlaylistSkeleton(),
      const BootstrapSkeleton(),
    ]) {
      await _pump(tester, SingleChildScrollView(child: skeleton));
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: '${skeleton.runtimeType} overflowed at 320 dp',
      );
    }
  });
}
