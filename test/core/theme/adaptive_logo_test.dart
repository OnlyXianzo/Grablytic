import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/theme/adaptive_logo.dart';

void main() {
  testWidgets('AdaptiveLogo renders light asset in light mode', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(
          body: AdaptiveLogo(size: 96),
        ),
      ),
    );

    final imageFinder = find.byType(Image);
    expect(imageFinder, findsOneWidget);

    final image = tester.widget<Image>(imageFinder);
    final assetImage = image.image as AssetImage;
    expect(assetImage.assetName, 'assets/brand/grablytic_logo_light.png');
    expect(image.width, 96);
    expect(image.height, 96);
  });

  testWidgets('AdaptiveLogo renders dark asset in dark mode', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: AdaptiveLogo(size: 96),
        ),
      ),
    );

    final imageFinder = find.byType(Image);
    expect(imageFinder, findsOneWidget);

    final image = tester.widget<Image>(imageFinder);
    final assetImage = image.image as AssetImage;
    expect(assetImage.assetName, 'assets/brand/grablytic_logo_dark.png');
  });

  testWidgets('AdaptiveLogo respects explicit variant overrides', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(
          body: Column(
            children: [
              AdaptiveLogo(variant: LogoVariant.light),
              AdaptiveLogo(variant: LogoVariant.legacy),
            ],
          ),
        ),
      ),
    );

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images.length, 2);

    expect((images[0].image as AssetImage).assetName, 'assets/brand/grablytic_logo_light.png');
    expect((images[1].image as AssetImage).assetName, 'assets/brand/grablytic_logo.png');
  });

  testWidgets('AdaptiveLogo clips with provided borderRadius', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(
          body: AdaptiveLogo(
            size: 96,
            borderRadius: BorderRadius.all(Radius.circular(24)),
          ),
        ),
      ),
    );

    final clipFinder = find.byType(ClipRRect);
    expect(clipFinder, findsOneWidget);

    final clip = tester.widget<ClipRRect>(clipFinder);
    expect(clip.borderRadius, const BorderRadius.all(Radius.circular(24)));
  });
}
