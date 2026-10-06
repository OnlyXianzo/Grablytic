import 'dart:io';
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

    final file = File(assetPath);
    Widget image = file.existsSync()
        ? Image.file(
            file,
            width: size,
            height: size,
            fit: fit,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          )
        : Image.asset(
            assetPath,
            width: size,
            height: size,
            fit: fit,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          );

    final effectiveRadius = borderRadius ?? BorderRadius.circular(size * 0.28);

    Widget result = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF26201B) : const Color(0xFFFAF7F2),
        borderRadius: effectiveRadius,
        border: Border.all(
          color: isDark ? const Color(0xFF3D332B) : const Color(0xFFE5DDD3),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1F1A16).withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 4,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size * 0.68, size * 0.68),
            painter: _GrablyticEmblemPainter(isDark: isDark),
          ),
          image,
        ],
      ),
    );

    if (borderRadius != null) {
      result = ClipRRect(
        borderRadius: borderRadius!,
        child: result,
      );
    }

    return result;
  }
}

class _GrablyticEmblemPainter extends CustomPainter {
  final bool isDark;

  const _GrablyticEmblemPainter({this.isDark = false});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final darkPaint = Paint()
      ..color = isDark ? const Color(0xFFFAF7F2) : const Color(0xFF232323)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final redPaint = Paint()
      ..color = const Color(0xFFE52E20)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Piece 1: Top-Left Dark Triangle/Polygon
    final path1 = Path()
      ..moveTo(w * 0.12, h * 0.16)
      ..lineTo(w * 0.44, h * 0.36)
      ..lineTo(w * 0.33, h * 0.47)
      ..lineTo(w * 0.12, h * 0.44)
      ..close();
    canvas.drawPath(path1, darkPaint);

    // Piece 2: Bottom-Left Dark Quadrilateral
    final path2 = Path()
      ..moveTo(w * 0.12, h * 0.54)
      ..lineTo(w * 0.38, h * 0.51)
      ..lineTo(w * 0.38, h * 0.84)
      ..lineTo(w * 0.12, h * 0.84)
      ..close();
    canvas.drawPath(path2, darkPaint);

    // Piece 3: Right Red Play Triangle
    final path3 = Path()
      ..moveTo(w * 0.48, h * 0.38)
      ..lineTo(w * 0.86, h * 0.50)
      ..lineTo(w * 0.48, h * 0.68)
      ..close();
    canvas.drawPath(path3, redPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
