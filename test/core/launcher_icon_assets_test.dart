import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Android Launcher Icon Assets Integrity Tests', () {
    const densities = [
      ('mipmap-mdpi', 48, 108),
      ('mipmap-hdpi', 72, 162),
      ('mipmap-xhdpi', 96, 216),
      ('mipmap-xxhdpi', 144, 324),
      ('mipmap-xxxhdpi', 192, 432),
    ];

    const resBase = 'android/app/src/main/res';
    const pngHeader = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    (int width, int height) parsePngDimensions(List<int> bytes) {
      // PNG IHDR chunk starts at byte 12 (4 bytes length, 4 bytes 'IHDR', 4 bytes width, 4 bytes height)
      expect(bytes.sublist(0, 8), pngHeader, reason: 'Must match PNG magic header');
      final width = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
      final height = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
      return (width, height);
    }

    test('colors.xml defines ic_launcher_background matching brand terracotta', () {
      final file = File('$resBase/values/colors.xml');
      expect(file.existsSync(), isTrue, reason: 'colors.xml must exist');
      final content = file.readAsStringSync();
      expect(content, contains('<color name="ic_launcher_background">#A33419</color>'));
    });

    test('mipmap-anydpi-v26 defines adaptive ic_launcher and ic_launcher_round', () {
      final launcherXml = File('$resBase/mipmap-anydpi-v26/ic_launcher.xml');
      final roundXml = File('$resBase/mipmap-anydpi-v26/ic_launcher_round.xml');

      expect(launcherXml.existsSync(), isTrue, reason: 'ic_launcher.xml must exist');
      expect(roundXml.existsSync(), isTrue, reason: 'ic_launcher_round.xml must exist');

      for (final f in [launcherXml, roundXml]) {
        final content = f.readAsStringSync();
        expect(content, contains('<adaptive-icon'));
        expect(content, contains('android:drawable="@color/ic_launcher_background"'));
        expect(content, contains('android:drawable="@mipmap/ic_launcher_foreground"'));
      }
    });

    test('AndroidManifest.xml declares both android:icon and android:roundIcon', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml');
      expect(manifest.existsSync(), isTrue);
      final content = manifest.readAsStringSync();
      expect(content, contains('android:icon="@mipmap/ic_launcher"'));
      expect(content, contains('android:roundIcon="@mipmap/ic_launcher_round"'));
    });

    for (final (density, legacyExpected, fgExpected) in densities) {
      test('Density $density has valid legacy, round, and adaptive foreground PNGs', () {
        final legacyFile = File('$resBase/$density/ic_launcher.png');
        final roundFile = File('$resBase/$density/ic_launcher_round.png');
        final fgFile = File('$resBase/$density/ic_launcher_foreground.png');

        expect(legacyFile.existsSync(), isTrue, reason: '$legacyFile must exist');
        expect(roundFile.existsSync(), isTrue, reason: '$roundFile must exist');
        expect(fgFile.existsSync(), isTrue, reason: '$fgFile must exist');

        final legacyBytes = legacyFile.readAsBytesSync();
        final roundBytes = roundFile.readAsBytesSync();
        final fgBytes = fgFile.readAsBytesSync();

        final (lw, lh) = parsePngDimensions(legacyBytes);
        expect(lw, legacyExpected, reason: '$legacyFile width');
        expect(lh, legacyExpected, reason: '$legacyFile height');

        final (rw, rh) = parsePngDimensions(roundBytes);
        expect(rw, legacyExpected, reason: '$roundFile width');
        expect(rh, legacyExpected, reason: '$roundFile height');

        final (fw, fh) = parsePngDimensions(fgBytes);
        expect(fw, fgExpected, reason: '$fgFile width');
        expect(fh, fgExpected, reason: '$fgFile height');
      });
    }
  });
}
