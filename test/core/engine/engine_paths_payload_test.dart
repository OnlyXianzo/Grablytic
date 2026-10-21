import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_provider.dart';

void main() {
  group('enginePathsPayload (#100)', () {
    test('carries the log level for the detailed-logging toggle', () {
      expect(engineLogLevel(false), 'info');
      expect(engineLogLevel(true), 'debug');

      final quiet = enginePathsPayload(
        appDir: '/data/app',
        cacheDir: '/data/cache',
        outputDir: '/storage/emulated/0/Download',
        verbose: false,
      );
      final loud = enginePathsPayload(
        appDir: '/data/app',
        cacheDir: '/data/cache',
        outputDir: '/storage/emulated/0/Download',
        verbose: true,
      );

      expect(quiet['log_level'], 'info');
      expect(loud['log_level'], 'debug');
      // The engine reads these names positionally in Kotlin and by keyword
      // in Python; a rename here would silently drop the level.
      expect(quiet.keys, containsAll(<String>[
        'data_dir',
        'cache_dir',
        'output_dir',
        'ffmpeg_path',
        'aria2c_path',
        'deno_path',
        'cookies_path',
        'log_level',
      ]));
    });
  });
}
