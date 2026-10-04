import 'package:flutter/material.dart';

/// Available variants for the Grablytic brand logo.
enum LogoVariant {
  /// Follows the active theme's brightness (light mode -> light logo, dark mode -> dark logo).
  auto,

  /// Explicitly uses the light logo (dark emblem on light background).
  light,

  /// Explicitly uses the dark logo (rounded-square with light emblem).
  dark,

  /// Explicitly uses the transparent emblem mark.
  mark,

  /// Explicitly uses the legacy original logo.
  legacy;

  /// Maps a stored `logoVariant` pref value ('system' | 'dark' | 'light' |
  /// 'legacy', anything else falls back to [LogoVariant.auto]) to a variant.
  static LogoVariant fromStored(String? stored) {
    switch (stored) {
      case 'dark':
        return LogoVariant.dark;
      case 'light':
        return LogoVariant.light;
      case 'legacy':
        return LogoVariant.legacy;
      default:
        return LogoVariant.auto;
    }
  }
}

/// An adaptive logo widget that renders the appropriate Grablytic logo asset
/// based on the active theme or an explicit [LogoVariant].
class AdaptiveLogo extends StatelessWidget {
  const AdaptiveLogo({
    super.key,
    this.size = 96,
    this.borderRadius,
    this.variant = LogoVariant.auto,
    this.fit = BoxFit.contain,
  });

  /// The width and height of the rendered logo.
  final double size;

  /// Optional border radius to clip the logo image.
  final BorderRadius? borderRadius;

  /// The logo variant to display. Defaults to [LogoVariant.auto].
  final LogoVariant variant;

  /// How to inscribe the logo into the space allocated during layout.
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final String assetPath;
    switch (variant) {
      case LogoVariant.auto:
        assetPath = isDark
            ? 'assets/brand/grablytic_logo_dark.png'
            : 'assets/brand/grablytic_logo_light.png';
        break;
      case LogoVariant.light:
        assetPath = 'assets/brand/grablytic_logo_light.png';
        break;
      case LogoVariant.dark:
        assetPath = 'assets/brand/grablytic_logo_dark.png';
        break;
      case LogoVariant.mark:
        assetPath = 'assets/brand/grablytic_logo_mark.png';
        break;
      case LogoVariant.legacy:
        assetPath = 'assets/brand/grablytic_logo.png';
        break;
    }

    Widget image = Image.asset(
      assetPath,
      width: size,
      height: size,
      fit: fit,
    );

    if (borderRadius != null) {
      image = ClipRRect(
        borderRadius: borderRadius!,
        child: image,
      );
    }

    return image;
  }
}
