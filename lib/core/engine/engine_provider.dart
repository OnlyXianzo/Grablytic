import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/settings_provider.dart';
import '../utils/logging_observers.dart';
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
  // ytdlnis parity: cookies only reach yt-dlp when the master switch is
  // on (per-site toggles are merged into the file by the Cookies screen).
  String? effectiveCookiesPath(
      {required bool useCookies, required String? cookiesPath}) =>
      useCookies ? cookiesPath : null;

  if (_appDir != null) {
    _setPathsFuture = engine.setPaths({
      'data_dir': _appDir,
      'cache_dir': _cacheDir,
      'output_dir': initialOutputDir,
      'ffmpeg_path': _ffmpegPath,
      'aria2c_path': _aria2cPath,
      'deno_path': _denoPath,
      'cookies_path': effectiveCookiesPath(
          useCookies: settings.useCookies, cookiesPath: settings.cookiesPath),
    });
  }

  ref.listen<AppSettings>(settingsProvider, (previous, next) {
    if (previous?.downloadPath != next.downloadPath ||
        previous?.cookiesPath != next.cookiesPath ||
        previous?.useCookies != next.useCookies) {      final outputDir = next.downloadPath == '/Internal/Videos'
          ? '$_appDir/TrueStream'
          : next.downloadPath;
      engine.setPaths({
        'data_dir': _appDir,
        'cache_dir': _cacheDir,
        'output_dir': outputDir,
        'ffmpeg_path': _ffmpegPath,
        'aria2c_path': _aria2cPath,
        'deno_path': _denoPath,
        'cookies_path': effectiveCookiesPath(
            useCookies: next.useCookies, cookiesPath: next.cookiesPath),
      });
    }
    // Queue gate: push the persisted preference whenever it changes (the
    // Settings slider also calls setConcurrency directly for immediacy;
    // this listener covers every other path that mutates the setting).
    // Never throws — EngineService.setConcurrency is fail-safe.
    if (previous?.maxConcurrentDownloads != next.maxConcurrentDownloads) {
      try {
        engine.setConcurrency(next.maxConcurrentDownloads);
      } catch (_) {}
    }

    // Schedule background periodic sync: push updated parameters whenever changed.
    if (previous?.scheduleEnabled != next.scheduleEnabled ||
        previous?.scheduleIntervalMinutes != next.scheduleIntervalMinutes ||
        previous?.scheduleWifiOnly != next.scheduleWifiOnly ||
        previous?.scheduleRequiresCharging != next.scheduleRequiresCharging) {
      try {
        engine.syncSchedule(
          enabled: next.scheduleEnabled,
          intervalMinutes: next.scheduleIntervalMinutes,
          wifiOnly: next.scheduleWifiOnly,
          requiresCharging: next.scheduleRequiresCharging,
        );
      } catch (_) {}
    }
  });

  // Initial sync: the engine backstop defaults to 2, so push the persisted
  // preference at startup (fire-and-forget; the module global exists as
  // soon as Chaquopy/the subprocess can serve calls).
  try {
    engine.setConcurrency(settings.maxConcurrentDownloads);
  } catch (_) {}

  // Initial schedule sync to platform WorkManager.
  try {
    engine.syncSchedule(
      enabled: settings.scheduleEnabled,
      intervalMinutes: settings.scheduleIntervalMinutes,
      wifiOnly: settings.scheduleWifiOnly,
      requiresCharging: settings.scheduleRequiresCharging,
    );
  } catch (_) {}

  if (engine is MockEngineService) {
    ref.onDispose(() => engine.dispose());
  }
  // Inject API-layer logging hooks (latency + error tracing) on every branch.
  return TracedEngineService(engine);
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
