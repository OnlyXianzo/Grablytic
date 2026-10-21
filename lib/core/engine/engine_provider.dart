import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/settings_provider.dart';
import '../utils/logging_observers.dart';
import '../utils/offline_link_queue.dart';
import 'engine_service.dart';
import 'platform_channel_engine_service.dart';
import 'desktop_engine_service.dart';
import 'mock_engine_service.dart';

/// The `paths/set` payload.
///
/// Built once for both call sites (first configuration and every settings
/// change). They used to be two hand-written maps, and neither carried
/// `log_level`, so the engine never learned about the detailed-logging
/// toggle (#100).
Map<String, dynamic> enginePathsPayload({
  required String appDir,
  required String cacheDir,
  required String outputDir,
  required bool verbose,
  String? ffmpegPath,
  String? aria2cPath,
  String? denoPath,
  String? cookiesPath,
}) =>
    <String, dynamic>{
      'data_dir': appDir,
      'cache_dir': cacheDir,
      'output_dir': outputDir,
      'ffmpeg_path': ffmpegPath,
      'aria2c_path': aria2cPath,
      'deno_path': denoPath,
      'cookies_path': cookiesPath,
      'log_level': engineLogLevel(verbose),
    };

/// The engine log level that matches Settings → "Detailed engine logging".
///
/// `paths/set` carries the name, not a number: the engine maps it in
/// `paths.py`, so the value stays readable in an IPC trace.
String engineLogLevel(bool verbose) => verbose ? 'debug' : 'info';

final engineProvider = Provider<EngineService>((ref) {
  final engine = Platform.isAndroid
      ? PlatformChannelEngineService()
      : (Platform.isWindows || Platform.isLinux || Platform.isMacOS
            ? DesktopEngineService()
            : MockEngineService());

  final settings = ref.read(settingsProvider);
  final initialOutputDir = settings.downloadPath == '/Internal/Videos'
      ? '$_appDir/Grablytic'
      : settings.downloadPath;
  // ytdlnis parity: cookies only reach yt-dlp when the master switch is
  // on (per-site toggles are merged into the file by the Cookies screen).
  String? effectiveCookiesPath({
    required bool useCookies,
    required String? cookiesPath,
  }) => useCookies ? cookiesPath : null;

  if (_appDir != null) {
    _setPathsFuture = engine.setPaths(enginePathsPayload(
      appDir: _appDir!,
      cacheDir: _cacheDir!,
      outputDir: initialOutputDir,
      verbose: settings.verbose,
      ffmpegPath: _ffmpegPath,
      aria2cPath: _aria2cPath,
      denoPath: _denoPath,
      cookiesPath: effectiveCookiesPath(
        useCookies: settings.useCookies,
        cookiesPath: settings.cookiesPath,
      ),
    ));
  }

  ref.listen<AppSettings>(settingsProvider, (previous, next) {
    if (previous?.downloadPath != next.downloadPath ||
        previous?.cookiesPath != next.cookiesPath ||
        previous?.useCookies != next.useCookies ||
        previous?.verbose != next.verbose) {
      final outputDir = next.downloadPath == '/Internal/Videos'
          ? '$_appDir/Grablytic'
          : next.downloadPath;
      engine.setPaths(enginePathsPayload(
        appDir: _appDir!,
        cacheDir: _cacheDir!,
        outputDir: outputDir,
        verbose: next.verbose,
        ffmpegPath: _ffmpegPath,
        aria2cPath: _aria2cPath,
        denoPath: _denoPath,
        cookiesPath: effectiveCookiesPath(
          useCookies: next.useCookies,
          cookiesPath: next.cookiesPath,
        ),
      ));
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

    // Sync offline queue reminder settings with the platform scheduler.
    if (previous?.queueReminderEnabled != next.queueReminderEnabled ||
        previous?.queueReminderIntervalMinutes !=
            next.queueReminderIntervalMinutes) {
      try {
        final queue = ref.read(offlineQueueProvider);
        if (!next.queueReminderEnabled || queue.isEmpty) {
          engine.syncQueueReminder(enabled: false);
        } else {
          engine.syncQueueReminder(
            enabled: true,
            intervalMinutes: next.queueReminderIntervalMinutes,
          );
        }
      } catch (_) {}
    }
  });

  // Watch offline queue transitions to cancel or schedule reminders.
  ref.listen(offlineQueueProvider, (previous, next) {
    final currentSettings = ref.read(settingsProvider);
    if (!currentSettings.queueReminderEnabled) return;
    try {
      if (next.isEmpty) {
        engine.syncQueueReminder(enabled: false);
      } else if (previous == null || previous.isEmpty) {
        engine.syncQueueReminder(
          enabled: true,
          intervalMinutes: currentSettings.queueReminderIntervalMinutes,
        );
      }
    } catch (_) {}
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

  // Publish the initial queue reminder setting to WorkManager.
  try {
    final initialQueue = ref.read(offlineQueueProvider);
    if (settings.queueReminderEnabled && initialQueue.isNotEmpty) {
      engine.syncQueueReminder(
        enabled: true,
        intervalMinutes: settings.queueReminderIntervalMinutes,
      );
    } else {
      engine.syncQueueReminder(enabled: false);
    }
  } catch (_) {}

  // Every transport owns closable resources (broadcast controllers,
  // native process handles, pending completers) — dispose all of them,
  // not just the mock. Previously hot-restart leaked the platform and
  // desktop transports (process + subscriptions + cached streams).
  ref.onDispose(() {
    try {
      engine.dispose();
    } catch (_) {}
  });

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
