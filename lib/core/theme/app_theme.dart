import 'package:flutter/material.dart';

class GrablyticColors {
  GrablyticColors._();

  // Light tokens — Earth & Ethos
  static const lightSurface = Color(0xFFfdf9f6);
  static const lightSurfaceDim = Color(0xFFddd9d6);
  static const lightSurfaceBright = Color(0xFFfdf9f6);
  static const lightSurfaceContainerLowest = Color(0xFFffffff);
  static const lightSurfaceContainerLow = Color(0xFFf7f3f0);
  static const lightSurfaceContainer = Color(0xFFf1edea);
  static const lightSurfaceContainerHigh = Color(0xFFebe7e4);
  static const lightSurfaceContainerHighest = Color(0xFFe5e2df);
  static const lightOnSurface = Color(0xFF1c1b1a);
  static const lightOnSurfaceVariant = Color(0xFF54433f);
  static const lightInverseSurface = Color(0xFF31302f);
  static const lightInverseOnSurface = Color(0xFFf4f0ed);
  static const lightOutline = Color(0xFF87736e);
  static const lightOutlineVariant = Color(0xFFd9c1bc);
  static const lightSurfaceTint = Color(0xFF934938);
  static const lightPrimary = Color(0xFF7d3929);
  static const lightOnPrimary = Color(0xFFffffff);
  static const lightPrimaryContainer = Color(0xFF9b503e);
  static const lightOnPrimaryContainer = Color(0xFFffdcd4);
  static const lightInversePrimary = Color(0xFFffb4a3);
  static const lightSecondary = Color(0xFF5d5e5f);
  static const lightOnSecondary = Color(0xFFffffff);
  static const lightSecondaryContainer = Color(0xFFe0dfdf);
  static const lightOnSecondaryContainer = Color(0xFF626363);
  static const lightTertiary = Color(0xFF00584a);
  static const lightOnTertiary = Color(0xFFffffff);
  static const lightTertiaryContainer = Color(0xFF007361);
  static const lightOnTertiaryContainer = Color(0xFF9bf5de);
  static const lightError = Color(0xFFba1a1a);
  static const lightOnError = Color(0xFFffffff);
  static const lightErrorContainer = Color(0xFFffdad6);
  static const lightOnErrorContainer = Color(0xFF93000a);
  static const lightPrimaryFixed = Color(0xFFffdad2);
  static const lightPrimaryFixedDim = Color(0xFFffb4a3);
  static const lightOnPrimaryFixed = Color(0xFF3c0801);
  static const lightOnPrimaryFixedVariant = Color(0xFF753323);
  static const lightSecondaryFixed = Color(0xFFe3e2e2);
  static const lightSecondaryFixedDim = Color(0xFFc6c6c6);
  static const lightOnSecondaryFixed = Color(0xFF1a1c1c);
  static const lightOnSecondaryFixedVariant = Color(0xFF464747);
  static const lightTertiaryFixed = Color(0xFF9af3dc);
  static const lightTertiaryFixedDim = Color(0xFF7ed7c1);
  static const lightOnTertiaryFixed = Color(0xFF00201a);
  static const lightOnTertiaryFixedVariant = Color(0xFF005143);
  static const lightBackground = Color(0xFFfdf9f6);
  static const lightOnBackground = Color(0xFF1c1b1a);
  static const lightSurfaceVariant = Color(0xFFe5e2df);

  // Dark tokens — Earth & Ethos Dark
  static const darkSurface = Color(0xFF131313);
  static const darkSurfaceDim = Color(0xFF131313);
  static const darkSurfaceBright = Color(0xFF393939);
  static const darkSurfaceContainerLowest = Color(0xFF0e0e0e);
  static const darkSurfaceContainerLow = Color(0xFF1c1b1b);
  static const darkSurfaceContainer = Color(0xFF201f1f);
  static const darkSurfaceContainerHigh = Color(0xFF2a2a2a);
  static const darkSurfaceContainerHighest = Color(0xFF353534);
  static const darkOnSurface = Color(0xFFe5e2e1);
  static const darkOnSurfaceVariant = Color(0xFFd9c1bc);
  static const darkInverseSurface = Color(0xFFe5e2e1);
  static const darkInverseOnSurface = Color(0xFF313030);
  static const darkOutline = Color(0xFFa28c87);
  static const darkOutlineVariant = Color(0xFF54433f);
  static const darkSurfaceTint = Color(0xFFffb4a3);
  static const darkPrimary = Color(0xFFffb4a3);
  static const darkOnPrimary = Color(0xFF581d0f);
  static const darkPrimaryContainer = Color(0xFF9b503e);
  static const darkOnPrimaryContainer = Color(0xFFffdcd4);
  static const darkInversePrimary = Color(0xFF934938);
  static const darkSecondary = Color(0xFFd7c3b0);
  static const darkOnSecondary = Color(0xFF3a2e21);
  static const darkSecondaryContainer = Color(0xFF544738);
  static const darkOnSecondaryContainer = Color(0xFFc8b5a3);
  static const darkTertiary = Color(0xFFb7ccb9);
  static const darkOnTertiary = Color(0xFF233427);
  static const darkTertiaryContainer = Color(0xFF576a5b);
  static const darkOnTertiaryContainer = Color(0xFFd4e9d6);
  static const darkError = Color(0xFFffb4ab);
  static const darkOnError = Color(0xFF690005);
  static const darkErrorContainer = Color(0xFF93000a);
  static const darkOnErrorContainer = Color(0xFFffdad6);
  static const darkPrimaryFixed = Color(0xFFffdad2);
  static const darkPrimaryFixedDim = Color(0xFFffb4a3);
  static const darkOnPrimaryFixed = Color(0xFF3c0801);
  static const darkOnPrimaryFixedVariant = Color(0xFF753323);
  static const darkSecondaryFixed = Color(0xFFf4dfcb);
  static const darkSecondaryFixedDim = Color(0xFFd7c3b0);
  static const darkOnSecondaryFixed = Color(0xFF241a0e);
  static const darkOnSecondaryFixedVariant = Color(0xFF524436);
  static const darkTertiaryFixed = Color(0xFFd3e8d5);
  static const darkTertiaryFixedDim = Color(0xFFb7ccb9);
  static const darkOnTertiaryFixed = Color(0xFF0e1f13);
  static const darkOnTertiaryFixedVariant = Color(0xFF394b3d);
  static const darkBackground = Color(0xFF131313);
  static const darkOnBackground = Color(0xFFe5e2e1);
  static const darkSurfaceVariant = Color(0xFF353534);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final colorScheme = ColorScheme(
      brightness: Brightness.light,
      primary: GrablyticColors.lightPrimary,
      onPrimary: GrablyticColors.lightOnPrimary,
      primaryContainer: GrablyticColors.lightPrimaryContainer,
      onPrimaryContainer: GrablyticColors.lightOnPrimaryContainer,
      secondary: GrablyticColors.lightSecondary,
      onSecondary: GrablyticColors.lightOnSecondary,
      secondaryContainer: GrablyticColors.lightSecondaryContainer,
      onSecondaryContainer: GrablyticColors.lightOnSecondaryContainer,
      tertiary: GrablyticColors.lightTertiary,
      onTertiary: GrablyticColors.lightOnTertiary,
      tertiaryContainer: GrablyticColors.lightTertiaryContainer,
      onTertiaryContainer: GrablyticColors.lightOnTertiaryContainer,
      error: GrablyticColors.lightError,
      onError: GrablyticColors.lightOnError,
      errorContainer: GrablyticColors.lightErrorContainer,
      onErrorContainer: GrablyticColors.lightOnErrorContainer,
      surface: GrablyticColors.lightSurface,
      onSurface: GrablyticColors.lightOnSurface,
      onSurfaceVariant: GrablyticColors.lightOnSurfaceVariant,
      outline: GrablyticColors.lightOutline,
      outlineVariant: GrablyticColors.lightOutlineVariant,
      inverseSurface: GrablyticColors.lightInverseSurface,
      inversePrimary: GrablyticColors.lightInversePrimary,
      surfaceTint: GrablyticColors.lightSurfaceTint,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: GrablyticColors.lightSurface,
      textTheme: _buildTextTheme(colorScheme),
    );
  }

  static ThemeData dark() {
    final colorScheme = ColorScheme(
      brightness: Brightness.dark,
      primary: GrablyticColors.darkPrimary,
      onPrimary: GrablyticColors.darkOnPrimary,
      primaryContainer: GrablyticColors.darkPrimaryContainer,
      onPrimaryContainer: GrablyticColors.darkOnPrimaryContainer,
      secondary: GrablyticColors.darkSecondary,
      onSecondary: GrablyticColors.darkOnSecondary,
      secondaryContainer: GrablyticColors.darkSecondaryContainer,
      onSecondaryContainer: GrablyticColors.darkOnSecondaryContainer,
      tertiary: GrablyticColors.darkTertiary,
      onTertiary: GrablyticColors.darkOnTertiary,
      tertiaryContainer: GrablyticColors.darkTertiaryContainer,
      onTertiaryContainer: GrablyticColors.darkOnTertiaryContainer,
      error: GrablyticColors.darkError,
      onError: GrablyticColors.darkOnError,
      errorContainer: GrablyticColors.darkErrorContainer,
      onErrorContainer: GrablyticColors.darkOnErrorContainer,
      surface: GrablyticColors.darkSurface,
      onSurface: GrablyticColors.darkOnSurface,
      onSurfaceVariant: GrablyticColors.darkOnSurfaceVariant,
      outline: GrablyticColors.darkOutline,
      outlineVariant: GrablyticColors.darkOutlineVariant,
      inverseSurface: GrablyticColors.darkInverseSurface,
      inversePrimary: GrablyticColors.darkInversePrimary,
      surfaceTint: GrablyticColors.darkSurfaceTint,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: GrablyticColors.darkSurface,
      textTheme: _buildTextTheme(colorScheme),
    );
  }

  static TextTheme _buildTextTheme(ColorScheme colorScheme) {
    final base = TextTheme(
      displayLarge: TextStyle(
        fontSize: 48,
        fontWeight: FontWeight.w300,
        letterSpacing: -0.02,
      ),
      headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w400),
      headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w400),
      titleLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w500),
      titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.5,
      ),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      labelSmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
      bodySmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
    );

    // Bundled product face (assets/fonts/InstrumentSans-*.ttf, OFL).
    // Pure-Dart apply: no runtime font fetch, no network beacon, and the
    // theme constructs in plain unit tests. Previously GoogleFonts, which
    // fetched from fonts.gstatic.com on first build.
    return base.apply(fontFamily: 'InstrumentSans');
  }
}
