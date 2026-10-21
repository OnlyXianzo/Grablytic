import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/theme/adaptive_logo.dart';

/// The asset name behind an [Image]'s provider.
///
/// `Image.asset(..., cacheWidth: ...)` wraps the `AssetImage` in a
/// `ResizeImage` (#96), so the provider is no longer the AssetImage itself.
String _assetName(Image image) {
  final provider = image.image;
  if (provider is ResizeImage) {
    return (provider.imageProvider as AssetImage).assetName;
  }
  return (provider as AssetImage).assetName;
}

/// Pins the ratio the tests reason about.
///
/// `flutter_test` reports a 3.0 DPR by default, which would push a 96 px logo
/// to the 192 px variant and make every expectation depend on the harness.
/// 1.0 keeps the mapping (96 → `96x96`) readable; [AdaptiveLogo] caps the
/// ratio at 2 anyway, and a separate test covers that cap.
void _pinDevicePixelRatio(WidgetTester tester, double ratio) {
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('AdaptiveLogo renders light asset in light mode', (tester) async {
    _pinDevicePixelRatio(tester, 1.0);
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
    expect(
      _assetName(image),
      'assets/brand/variants/grablytic_logo_light_96x96.png',
    );
    expect(image.width, 96);
    expect(image.height, 96);
  });

  testWidgets('AdaptiveLogo renders dark asset in dark mode', (tester) async {
    _pinDevicePixelRatio(tester, 1.0);
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
    expect(
      _assetName(image),
      'assets/brand/variants/grablytic_logo_dark_96x96.png',
    );
  });

  testWidgets('AdaptiveLogo respects explicit variant overrides', (tester) async {
    _pinDevicePixelRatio(tester, 1.0);
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

    expect(
      _assetName(images[0]),
      'assets/brand/variants/grablytic_logo_light_96x96.png',
    );
    // Legacy keeps the original master: it is the one variant with no
    // pre-scaled set.
    expect(_assetName(images[1]), 'assets/brand/grablytic_logo.png');
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

  testWidgets('a 28 dp badge picks a variant, not the 1024 master',
      (tester) async {
    _pinDevicePixelRatio(tester, 1.0);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(body: AdaptiveLogo(size: 28)),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    // A logical size is not a decode size: 28 px asks for the 32 px asset.
    expect(
      _assetName(image),
      'assets/brand/variants/grablytic_logo_light_32x32.png',
    );
  });

  testWidgets('the decode ratio is capped at 2x', (tester) async {
    _pinDevicePixelRatio(tester, 3.0);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: const Scaffold(body: AdaptiveLogo(size: 96)),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image as ResizeImage;
    // 96 × min(3.0, 2.0) = 192, not 288: a 3x screen does not get a 3x
    // decode for a chrome-sized badge.
    expect(provider.width, 192);
    expect(
      _assetName(image),
      'assets/brand/variants/grablytic_logo_light_192x192.png',
    );
  });
}
