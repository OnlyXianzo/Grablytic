import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/settings_provider.dart';
import '../engine/engine_service.dart';
import 'app_logger.dart';

/// Logs every navigation event (push/pop/replace) without holding
/// BuildContexts or routes — no memory leaks, O(1) per transition.
class LoggingNavigatorObserver extends NavigatorObserver {
  String _name(Route<dynamic>? route) =>
      route?.settings.name ?? route?.runtimeType.toString() ?? '<unknown>';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLogger.info(
      'NAV push ${_name(route)}${previousRoute != null ? ' from ${_name(previousRoute)}' : ''}',
      tag: 'navigation',
    );
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLogger.info(
      'NAV pop ${_name(route)}${previousRoute != null ? ' → ${_name(previousRoute)}' : ''}',
      tag: 'navigation',
    );
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLogger.info(
      'NAV replace ${_name(oldRoute)} → ${_name(newRoute)}',
      tag: 'navigation',
    );
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

/// Logs Riverpod provider failures state transitions at error level only —
/// normal rebuilds are NOT logged (avoids UI-lag log spam).
class LoggingProviderObserver extends ProviderObserver {
  @override
  void providerDidFail(
    ProviderBase<Object?> provider,
    Object error,
    StackTrace stackTrace,
    ProviderContainer container,
  ) {
    AppLogger.error(
      'Provider ${provider.name ?? provider.runtimeType} failed: $error',
      tag: 'riverpod',
      error: error,
      stackTrace: stackTrace,
    );
    super.providerDidFail(provider, error, stackTrace, container);
  }

  @override
  void didDisposeProvider(
    ProviderBase<Object?> provider,
    ProviderContainer container,
  ) {
    // Debug-level only; filtered from disk unless verbose.
    AppLogger.debug(
      'Provider disposed: ${provider.name ?? provider.runtimeType}',
      tag: 'riverpod',
    );
    super.didDisposeProvider(provider, container);
  }

  @override
  void didUpdateProvider(
    ProviderBase<Object?> provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    // Settings transitions are the highest-value UI logs: every download
    // bug report starts with "what changed". Diffed centrally here so the
    // 30+ setters stay untouched.
    if (previousValue is AppSettings && newValue is AppSettings) {
      final changes = diffAppSettings(previousValue, newValue);
      for (final c in changes) {
        AppLogger.debug('Setting changed: $c', tag: 'settings');
      }
    }
    super.didUpdateProvider(provider, previousValue, newValue, container);
  }
}

/// Field-by-field AppSettings diff for [LoggingProviderObserver].
/// Secrets never hit the log: proxy credentials collapse to the host part.
List<String> diffAppSettings(AppSettings previous, AppSettings next) {
  final changes = <String>[];
  void field(String name, Object? a, Object? b, {bool sensitive = false}) {
    final sa = sensitive && a is String ? _maskSecret(a) : '$a';
    final sb = sensitive && b is String ? _maskSecret(b) : '$b';
    if ('$a' != '$b') changes.add('$name: $sa → $sb');
  }

  bool listEq(List a, List b) =>
      a.length == b.length &&
      Iterable.generate(a.length).every((i) => '${a[i]}' == '${b[i]}');

  void listField(String name, List a, List b) {
    if (!listEq(a, b)) changes.add('$name: ${a.length} → ${b.length} items');
  }

  field('wifiOnly', previous.wifiOnly, next.wifiOnly);
  field('turboMode', previous.turboMode, next.turboMode);
  field('completionAlerts', previous.completionAlerts, next.completionAlerts);
  field('downloadPath', previous.downloadPath, next.downloadPath);
  field('themeMode', previous.themeMode, next.themeMode);
  field('onboardingCompleted', previous.onboardingCompleted,
      next.onboardingCompleted);
  field('hasSeenBatteryPrompt', previous.hasSeenBatteryPrompt,
      next.hasSeenBatteryPrompt);
  field('qualityCeiling', previous.qualityCeiling, next.qualityCeiling);
  field('audioOnly', previous.audioOnly, next.audioOnly);
  field('proxy', previous.proxy, next.proxy, sensitive: true);
  field('verbose', previous.verbose, next.verbose);
  field('autoStartDownloadOnShare', previous.autoStartDownloadOnShare,
      next.autoStartDownloadOnShare);
  field('cookiesPath', previous.cookiesPath, next.cookiesPath);
  field('youtubeLoggedIn', previous.youtubeLoggedIn, next.youtubeLoggedIn);
  field('instagramLoggedIn', previous.instagramLoggedIn,
      next.instagramLoggedIn);
  field('twitterLoggedIn', previous.twitterLoggedIn, next.twitterLoggedIn);
  field('bilibiliLoggedIn', previous.bilibiliLoggedIn,
      next.bilibiliLoggedIn);
  field('twitchLoggedIn', previous.twitchLoggedIn, next.twitchLoggedIn);
  field('splitChapters', previous.splitChapters, next.splitChapters);
  field('updateChannel', previous.updateChannel, next.updateChannel);
  field('downloadSubtitles', previous.downloadSubtitles,
      next.downloadSubtitles);
  listField('subtitleLanguages', previous.subtitleLanguages,
      next.subtitleLanguages);
  field('downloadAutoSubtitles', previous.downloadAutoSubtitles,
      next.downloadAutoSubtitles);
  field('embedSubtitles', previous.embedSubtitles, next.embedSubtitles);
  field('aria2cEnabled', previous.aria2cEnabled, next.aria2cEnabled);
  field('aria2cChunks', previous.aria2cChunks, next.aria2cChunks);
  field('aria2cMaxSpeed', previous.aria2cMaxSpeed, next.aria2cMaxSpeed);
  field('useGridView', previous.useGridView, next.useGridView);
  listField('customTemplates', previous.customTemplates,
      next.customTemplates);
  listField('observedSources', previous.observedSources,
      next.observedSources);
  field('scheduleEnabled', previous.scheduleEnabled, next.scheduleEnabled);
  field('scheduleTime', previous.scheduleTime, next.scheduleTime);
  listField('scheduleDays', previous.scheduleDays, next.scheduleDays);
  field('scheduleIntervalMinutes', previous.scheduleIntervalMinutes,
      next.scheduleIntervalMinutes);
  field('scheduleWifiOnly', previous.scheduleWifiOnly, next.scheduleWifiOnly);
  field('scheduleRequiresCharging', previous.scheduleRequiresCharging,
      next.scheduleRequiresCharging);
  listField('sponsorBlockCats', previous.sponsorBlockCats,
      next.sponsorBlockCats);
  field('downloadArchive', previous.downloadArchive, next.downloadArchive);
  field('archiveByFolder', previous.archiveByFolder, next.archiveByFolder);
  field('maxConcurrentDownloads', previous.maxConcurrentDownloads,
      next.maxConcurrentDownloads);
  return changes;
}

String _maskSecret(String? value) {
  if (value == null || value.isEmpty) return '$value';
  final at = value.lastIndexOf('@');
  if (at >= 0) return '***${value.substring(at)}';
  return value.length <= 4 ? '***' : '***${value.substring(value.length - 4)}';
}

/// Thin tracing decorator over any [EngineService] — injects logging hooks
/// into every API-layer branch (bootstrap, formats, download, playlist,
/// resume, update) with latency measurement, without touching call sites.
///
/// Errors are logged with full context then rethrown so UI behavior is
/// unchanged. No streams are duplicated; progress/log streams pass through.
class TracedEngineService implements EngineService {
  final EngineService _inner;
  const TracedEngineService(this._inner);

  /// Calls slower than [_slowCallThreshold] get an extra WARN so hangs
  /// stand out in reports without reading latency math.
  static const Duration _slowCallThreshold = Duration(seconds: 10);

  Future<T> _traced<T>(String method, Future<T> Function() call) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await AppLogger.trace<T>(method, call, tag: 'engine-api');
      stopwatch.stop();
      if (stopwatch.elapsed >= _slowCallThreshold) {
        AppLogger.warn(
          'Slow engine call: $method took ${stopwatch.elapsed.inMilliseconds}ms',
          tag: 'engine-api',
        );
      }
      return result;
    } catch (e) {
      stopwatch.stop();
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> bootstrap() =>
      _traced('engine/bootstrap', _inner.bootstrap);

  @override
  Future<void> setPaths(Map<String, dynamic> paths) => _traced(
        'paths/set',
        () => _inner.setPaths(_redactedPaths(paths)),
      );

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) {
    AppLogger.info(
      'Download requested: ${_redactUrl(url)} [$networkType]',
      tag: 'engine-api',
    );
    return _traced(
      'download/start',
      () => _inner.startDownload(
        url: url,
        downloadId: downloadId,
        config: config,
        networkType: networkType,
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) =>
      _traced('download/cancel', () => _inner.cancelDownload(downloadId));

  @override
  Stream<Map<String, dynamic>> get progressStream => _inner.progressStream;

  @override
  Future<Map<String, dynamic>> exportLogToDownloads({
    required String sourcePath,
    required String displayName,
  }) =>
      _traced(
        'log/export_to_downloads',
        () => _inner.exportLogToDownloads(
          sourcePath: sourcePath,
          displayName: displayName,
        ),
      );

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() =>
      _traced('system/battery_status', () => _inner.batteryExemptionStatus());

  @override
  Future<Map<String, dynamic>> requestBatteryExemption() =>
      _traced('system/battery_request', () => _inner.requestBatteryExemption());

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() =>
      _traced('system/notification_status', () => _inner.notificationPermissionStatus());

  @override
  Future<Map<String, dynamic>> requestNotificationPermission() =>
      _traced('system/notification_request', () => _inner.requestNotificationPermission());

  @override
  Future<Map<String, dynamic>> queueStatus() =>
      _traced('download/queue_status', () => _inner.queueStatus());

  @override
  Future<Map<String, dynamic>> setConcurrency(int maxConcurrent) =>
      _traced('download/set_concurrency', () => _inner.setConcurrency(maxConcurrent));

  @override
  Future<Map<String, dynamic>> clearArchive() =>
      _traced('download/clear_archive', () => _inner.clearArchive());

  @override
  Future<Map<String, dynamic>> openNotificationSettings() => _traced(
      'system/notification_settings', () => _inner.openNotificationSettings());

  @override
  Future<Map<String, dynamic>> openUrl(String url) =>
      _traced('intent/open_url', () => _inner.openUrl(url));

  @override
  Future<Map<String, dynamic>> syncSchedule({
    required bool enabled,
    int intervalMinutes = 60,
    bool wifiOnly = true,
    bool requiresCharging = false,
  }) =>
      _traced(
        'schedule/sync',
        () => _inner.syncSchedule(
          enabled: enabled,
          intervalMinutes: intervalMinutes,
          wifiOnly: wifiOnly,
          requiresCharging: requiresCharging,
        ),
      );

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) =>
      _traced('formats/get', () => _inner.getFormats(url: url, config: config));

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) => _traced(
        'playlist/info',
        () => _inner.getPlaylistInfo(url: url, config: config),
      );

  @override
  Future<Map<String, dynamic>> search({
    required String query,
    String site = 'youtube',
    int limit = 20,
    required Map<String, dynamic> config,
  }) => _traced(
        'search/query',
        () => _inner.search(query: query, site: site, limit: limit, config: config),
      );

  @override
  Future<String?> getSharedUrl() =>
      _traced('intent/get_shared', _inner.getSharedUrl);

  @override
  Stream<String> get sharedUrlStream =>
      _inner.sharedUrlStream.map((url) {
        AppLogger.info('Share intent received: ${_redactUrl(url)}',
            tag: 'share-intent');
        return url;
      });

  @override
  Future<Map<String, dynamic>> scanResumeCandidates(
          {required String cacheDir}) =>
      _traced('resume/scan',
          () => _inner.scanResumeCandidates(cacheDir: cacheDir));

  @override
  Future<Map<String, dynamic>> reportResumeAttempt(
          {required String cacheDir,
          required String filepath,
          required bool success}) =>
      _traced(
          'resume/report',
          () => _inner.reportResumeAttempt(
              cacheDir: cacheDir, filepath: filepath, success: success));

  @override
  Future<Map<String, dynamic>> updateCheck() =>
      _traced('engine/update_check', _inner.updateCheck);

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) =>
      _traced('engine/set_update_channel',
          () => _inner.setUpdateChannel(channel));

  @override
  Stream<Map<String, dynamic>> get logStream => _inner.logStream;

  Map<String, dynamic> _redactedPaths(Map<String, dynamic> paths) {
    // Paths themselves are safe; cookies path value is redacted in AppLogger.
    return paths;
  }

  String _redactUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.queryParameters.isEmpty) {
        return uri.replace(path: uri.path.length > 60 ? '...${uri.path.substring(uri.path.length - 60)}' : uri.path).toString();
      }
      // Strip query tokens (sig, token, key) — keep param names for debugging.
      final redacted = uri.replace(
        queryParameters: uri.queryParameters.map((k, v) {
          final lk = k.toLowerCase();
          if (lk.contains('token') ||
              lk.contains('sig') ||
              lk.contains('key') ||
              lk.contains('auth')) {
            return MapEntry(k, '***');
          }
          return MapEntry(k, v.length > 40 ? '${v.substring(0, 40)}…' : v);
        }),
      );
      return redacted.toString();
    } catch (_) {
      return '<unparseable-url>';
    }
  }
}
