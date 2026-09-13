abstract class EngineService {
  Future<Map<String, dynamic>> bootstrap();
  Future<void> setPaths(Map<String, dynamic> paths);
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  });
  Future<Map<String, dynamic>> cancelDownload(String downloadId);
  Stream<Map<String, dynamic>> get progressStream;
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  });
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  });
  Future<Map<String, dynamic>> search({
    required String query,
    String site = 'youtube',
    int limit = 20,
    required Map<String, dynamic> config,
  });
  Future<String?> getSharedUrl();
  Stream<String> get sharedUrlStream;
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir});
  Future<Map<String, dynamic>> updateCheck();
  Future<Map<String, dynamic>> setUpdateChannel(String channel);
  Stream<Map<String, dynamic>> get logStream;

  /// Copies an app-private log file to the public Downloads folder so the
  /// user can reach it without root/PC (scoped storage blocks browsing
  /// app-private dirs on Android 12+). Returns
  /// `{'success': true, 'path': <human-readable location>}` or
  /// `{'success': false, ...}` — never throws.
  Future<Map<String, dynamic>> exportLogToDownloads({
    required String sourcePath,
    required String displayName,
  });

  /// Background-execution permissions (Android only; other platforms
  /// return `{'success': false, 'supported': false}`).
  /// `batteryExemptionStatus` → `{'success', 'supported', 'exempt'}`.
  /// `requestBatteryExemption` opens the system exemption screen and
  /// returns `{'success': <launched>}` — never throws.
  Future<Map<String, dynamic>> batteryExemptionStatus();
  Future<Map<String, dynamic>> requestBatteryExemption();

  /// Notification permission (Android 13+; older Android is always
  /// granted, other platforms unsupported). `requestNotificationPermission`
  /// shows the system prompt once and completes with the verdict —
  /// never throws.
  Future<Map<String, dynamic>> notificationPermissionStatus();
  Future<Map<String, dynamic>> requestNotificationPermission();

  /// Download queue (engine backstop; Dart owns the queued UI state).
  /// `queueStatus` → `{'active': [...ids], 'queued': [...ids], 'max_concurrent': N}`.
  /// `setConcurrency` clamps 1–5, returns `{'success', 'max_concurrent'}`.
  /// Never throws — unsupported platforms return `{'success': false}`.
  Future<Map<String, dynamic>> queueStatus();
  Future<Map<String, dynamic>> setConcurrency(int maxConcurrent);

  /// Delete the engine download-archive file (recovery for archive-skipped
  /// re-downloads). Returns `{'success', 'removed', 'path'}` — never throws.
  Future<Map<String, dynamic>> clearArchive();

  /// Open the OS notification settings for this app (Android 13+ denial
  /// recovery). Returns `{'success', 'launched'}` — never throws.
  Future<Map<String, dynamic>> openNotificationSettings();
}
