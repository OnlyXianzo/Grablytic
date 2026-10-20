import 'dart:io' show File;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

/// Decode width for a thumbnail rendered at [logicalWidth] pixels.
///
/// Flutter's `ImageCache` stores the **decoded** bitmap, and `cacheWidth`
/// is the only thing that tells the codec to downscale. Without it a
/// 1280×720 cover becomes `1280 × 720 × 4 B = 3.52 MiB` of RGBA for a
/// widget that is 112 px wide — 128× more memory than the 27.6 KiB the
/// same image costs at `cacheWidth: 112`. Enough of those and the default
/// 100 MiB image cache is full, at which point every scroll re-decodes
/// from disk.
///
/// The device pixel ratio is applied but capped at 2: a 3× screen gains
/// nothing visible from a 3× bitmap and pays for it 9× in pixels.
int thumbCacheWidth(BuildContext context, double logicalWidth) {
  // maybeOf, not devicePixelRatioOf: a widget pumped outside a MediaQuery
  // (a bare test) would throw, and a decode size is not worth an exception.
  final ratio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
  return _decodeWidth(logicalWidth, ratio);
}

/// Same, for helper methods that are not handed a [BuildContext].
///
/// Reads the ratio from the platform dispatcher instead of MediaQuery, so
/// a `_buildThumbnailWidget(ColorScheme)` helper does not have to grow a
/// context parameter just to size a decode.
int thumbCacheWidthFor(double logicalWidth) {
  // PlatformDispatcher, not WidgetsBinding.instance: the latter throws when
  // no binding exists yet, and this is called from build helpers that must
  // not care whether the binding is up.
  final views = PlatformDispatcher.instance.views;
  final ratio = views.isEmpty ? 1.0 : views.first.devicePixelRatio;
  return _decodeWidth(logicalWidth, ratio);
}

int _decodeWidth(double logicalWidth, double ratio) {
  final clamped = ratio.clamp(1.0, 2.0);
  final pixels = (logicalWidth * clamped).round();
  return pixels <= 0 ? 1 : pixels;
}

/// Decode width for an image that fills the screen width.
int fullWidthCacheWidth(BuildContext context) {
  final width = MediaQuery.maybeOf(context)?.size.width ?? 0;
  return thumbCacheWidth(context, width <= 0 ? 360 : width);
}

/// One thumbnail widget, so no screen can forget `cacheWidth` again.
///
/// Named `CachedThumb`, not `Thumb`: Material exports a `Thumb` of its own
/// (the slider thumb shape), and importing both makes every call site an
/// ambiguous-import error.
///
/// Prefers the app-private cached file (offline, no tracking pixel) and
/// falls back to the network URL, then [fallback]. Sized by the caller;
/// the decode size is derived, never guessed at the call site.
class CachedThumb extends StatelessWidget {
  const CachedThumb({
    super.key,
    required this.width,
    this.height,
    this.filePath,
    this.url,
    this.fallback,
    this.borderRadius,
  });

  /// Rendered logical width. Also the basis for the decode width.
  final double width;

  /// Rendered logical height. Defaults to a 16:9 box for [width].
  final double? height;

  /// App-private thumbnail sidecar, preferred when present.
  final String? filePath;

  /// Remote cover, used when there is no cached file.
  final String? url;

  /// Shown when neither source produces an image.
  final Widget? fallback;

  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final resolvedHeight = height ?? width * 9 / 16;
    final cacheWidth = thumbCacheWidth(context, width);

    Widget image(ImageProvider provider) => Image(
      image: ResizeImage(provider, width: cacheWidth),
      width: width,
      height: resolvedHeight,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => fallback ?? const SizedBox.shrink(),
    );

    Widget resolved() {
      final path = filePath ?? '';
      if (path.isNotEmpty) {
        return image(FileImage(File(path)));
      }
      final remote = url ?? '';
      if (remote.isNotEmpty) {
        return image(NetworkImage(remote));
      }
      return fallback ?? const SizedBox.shrink();
    }

    final child = resolved();
    final radius = borderRadius;
    if (radius == null) return child;
    return ClipRRect(borderRadius: radius, child: child);
  }
}
