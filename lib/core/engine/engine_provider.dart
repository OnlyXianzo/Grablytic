import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/settings_provider.dart';
import 'engine_service.dart';
import 'platform_channel_engine_service.dart';
import 'desktop_engine_service.dart';
import 'mock_engine_service.dart';

final engineProvider = Provider<EngineService>((ref) {
  final engine = Platform.isAndroid
      ? PlatformChannelEngineService()
      : (Platform.isWindows || Platform.isLinux || Platform.isMacOS
          ? DesktopEngineService()
          : MockEngineService());

  final settings = ref.read(settingsProvider);
  final initialOutputDir = settings.downloadPath == '/Internal/Videos'
      ? '$_appDir/TrueStream'
      : settings.downloadPath;

  if (_appDir != null) {
    _setPathsFuture = engine.setPaths({
      'data_dir': _appDir,
      'cache_dir': _cacheDir,
      'output_dir': initialOutputDir,
      'ffmpeg_path': _ffmpegPath,
      'aria2c_path': _aria2cPath,
      'deno_path': _denoPath,
      'cookies_path': settings.cookiesPath,
    });
  }

  ref.listen<AppSettings>(settingsProvider, (previous, next) {
    if (previous?.downloadPath != next.downloadPath || previous?.cookiesPath != next.cookiesPath) {
      final outputDir = next.downloadPath == '/Internal/Videos'
          ? '$_appDir/TrueStream'
          : next.downloadPath;
      engine.setPaths({
        'data_dir': _appDir,
        'cache_dir': _cacheDir,
        'output_dir': outputDir,
        'ffmpeg_path': _ffmpegPath,
        'aria2c_path': _aria2cPath,
        'deno_path': _denoPath,
        'cookies_path': next.cookiesPath,
      });
    }
  });

  if (engine is MockEngineService) {
    ref.onDispose(() => engine.dispose());
  }
  return engine;
});

/// Future that completes when the initial setPaths call finishes.
/// Awaited by engineStatusProvider before calling bootstrap().
Future<void>? _setPathsFuture;
Future<void>? get engineSetPathsFuture => _setPathsFuture;

String? _appDir;
String? _cacheDir;
String? _ffmpegPath;
String? _aria2cPath;
String? _denoPath;

void setEngineDirs(
  String appDir,
  String cacheDir, {
  String? ffmpegPath,
  String? aria2cPath,
  String? denoPath,
}) {
  _appDir = appDir;
  _cacheDir = cacheDir;
  _ffmpegPath = ffmpegPath;
  _aria2cPath = aria2cPath;
  _denoPath = denoPath;
}
