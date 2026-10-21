import 'dart:async';
import 'package:flutter/services.dart';
import '../utils/app_logger.dart';
import 'engine_codec.dart';
import 'engine_contract.dart';
import 'engine_service.dart';
import 'engine_start_signal.dart';
import 'progress_channel.dart';

class PlatformChannelEngineService implements EngineService {
  final MethodChannel _channel = const MethodChannel(
    'com.theonly.grablytic/engine',
  );
  final _intentController = StreamController<String>.broadcast();

  /// The shared native subscription (see [ProgressChannel]).
  ///
  /// One reader for the whole process: the engine's progress view and the
  /// log ingester both derive from it, so an event is decoded once and
  /// crosses the bridge once (#98).
  Stream<Map<String, dynamic>> get _events => ProgressChannel.instance.events;

  PlatformChannelEngineService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == EngineMethods.sharedUrlInbound) {
        final arguments = call.arguments;
        final map = arguments is Map
            ? Map<String, dynamic>.from(arguments)
            : null;
        final url = map?['url'] as String?;
        if (url != null && url.isNotEmpty) {
          _intentController.add(url);
        }
      }
      return null;
    });
  }

  @override
  Stream<String> get sharedUrlStream => _intentController.stream;


  /// Default budget for one native round trip.
  ///
  /// The platform channel had NO timeout at all: a native handler that
  /// never answered left the Dart future pending forever, so the UI
  /// waited on a spinner that could not end (and the download card kept
  /// a "starting" state for the rest of the session).
  static const Duration defaultCallTimeout = Duration(seconds: 120);

  /// Long-running extraction methods get a larger budget than the fast
  /// lane, mirroring the desktop transport's per-method budgets.
  static Duration timeoutForMethod(String method) {
    switch (method) {
      case EngineMethods.getFormats:
      case EngineMethods.playlistInfo:
      case EngineMethods.searchQuery:
        return const Duration(minutes: 5);
      case EngineMethods.startDownload:
        return const Duration(minutes: 2);
      default:
        return defaultCallTimeout;
    }
  }

  // ---------------------------------------------------------------------
  // Lazy engine start
  // ---------------------------------------------------------------------
  //
  // `setPaths` used to cross the bridge the moment the provider graph was
  // built. On Android that call is what starts the work: `paths/set` runs
  // `BinaryPackageManager.init()` and `getModule("grablytic_engine")`,
  // which imports `downloader` -> `yt_dlp` — 40.5 MiB RSS and ~480
  // modules on the first frame of every launch, including launches that
  // never download anything.
  //
  // So the paths are now HELD here and applied by the first call that
  // actually needs the engine. Everything the UI does before that (log
  // streaming, settings, history) never touches Python.
  Map<String, dynamic>? _pendingPaths;
  bool _pathsApplied = false;
  Future<void>? _startup;

  /// Bumped by every `setPaths`. #97: a settings change that landed while
  /// the FIRST `paths/set` was still in flight (it can take seconds — the
  /// handler runs `BinaryPackageManager.init()` and the engine import) used
  /// to be overwritten by that call's "clear the pending map" step, so the
  /// new download directory was silently ignored until the next change.
  int _pathsGeneration = 0;

  /// Calls that reach into Python, and so must wait for the engine.
  ///
  /// The rest of the bridge is pure Kotlin (notifications, intents, icon
  /// switching, the WorkManager schedule, the battery/metered probes).
  /// Making those wait for a 40 MiB interpreter would have been a
  /// regression in the opposite direction: a queue reminder is scheduled
  /// from a settings toggle without the user downloading anything.
  static const Set<String> _pythonMethods = {
    EngineMethods.bootstrap,
    EngineMethods.startDownload,
    EngineMethods.cancelDownload,
    EngineMethods.queueStatus,
    EngineMethods.setConcurrency,
    EngineMethods.clearArchive,
    EngineMethods.getFormats,
    EngineMethods.playlistInfo,
    EngineMethods.searchQuery,
    EngineMethods.scanResume,
    EngineMethods.resumeReport,
    EngineMethods.updateCheck,
    EngineMethods.setUpdateChannel,
  };

  /// Configuration call that can arrive before the engine is up.
  ///
  /// The settings listener fires on a preference change, which may happen
  /// on a screen the user opened without downloading anything. Handing it
  /// to native before `paths/set` answered `ERR_ENGINE_UNAVAILABLE` and the
  /// value was lost for the session. It is parked here instead and
  /// replayed once the paths are in.
  final Map<String, Object?> _deferredConfig = <String, Object?>{};

  /// Applies the held paths exactly once, then replays parked config.
  Future<void> _ensureStarted() {
    if (_pathsApplied) return Future<void>.value();
    final inFlight = _startup;
    if (inFlight != null) return inFlight;
    if (_pendingPaths == null) return Future<void>.value();
    final future = _applyPaths();
    _startup = future;
    return future;
  }

  Future<void> _applyPaths() async {
    try {
      await _applyLatestPaths();
    } finally {
      // Cleared in `finally`: a failed start must be retryable by the next
      // call rather than pinning every later call to a dead future.
      _startup = null;
    }
    if (_deferredConfig.isEmpty) return;
    final pending = Map<String, Object?>.of(_deferredConfig);
    _deferredConfig.clear();
    for (final entry in pending.entries) {
      await _invokeEnvelope(entry.key, entry.value);
    }
  }

  /// Sends the pending paths, and anything that arrived while sending.
  ///
  /// Bounded: a `setPaths` that keeps changing during the send is applied a
  /// few times at most, and a newer value simply wins on the next call (by
  /// then `_pathsApplied` is true and `setPaths` goes straight through).
  Future<void> _applyLatestPaths() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final paths = _pendingPaths;
      if (paths == null) return;
      final generation = _pathsGeneration;
      await _channel.invokeMethod(EngineMethods.setPaths, paths);
      _pathsApplied = true;
      // Native starts Chaquopy inside this call, so the interpreter is up
      // from here on (#91). Reported before the re-send loop so a Home that
      // is waiting to scan does not wait for a second round trip.
      markEngineStarted();
      if (generation != _pathsGeneration) continue; // a newer map arrived
      _pendingPaths = null;
      return;
    }
  }

  /// Invokes a native method and returns a well-formed envelope.
  ///
  /// Never throws: every failure mode becomes an envelope with
  /// `success: false` and a typed `error_type`, so callers keep working
  /// while the failure is still visible.
  ///
  /// The old code returned `{}` for a malformed payload. `{}` has no
  /// `success` key, so every caller read it as "not successful" — but
  /// with no error type and no message, the UI showed nothing and the
  /// log recorded nothing. A corrupted or truncated bridge payload is
  /// now reported as `ERROR_PROTOCOL`.
  Future<Map<String, dynamic>> _invokeEnvelope(
    String method, [
    Object? arguments,
  ]) async {
    if (_pythonMethods.contains(method)) {
      // Park the concurrency setting until the engine exists instead of
      // letting native answer "engine not up" and losing it.
      //
      // Only when paths are actually WAITING: with no paths at all there is
      // nothing to start the engine with, so the call goes through and
      // native's ERR_ENGINE_UNAVAILABLE is the honest answer.
      if (!_pathsApplied &&
          _pendingPaths != null &&
          method == EngineMethods.setConcurrency) {
        _deferredConfig[method] = arguments;
        final parked = <String, dynamic>{'success': true, 'deferred': true};
        if (arguments is Map && arguments['max_concurrent'] is int) {
          parked['max_concurrent'] = arguments['max_concurrent'];
        }
        return parked;
      }
      try {
        await _ensureStarted();
      } catch (e) {
        AppLogger.warn('Engine paths could not be applied: $e', tag: 'engine');
        return EngineEnvelope.error(
          errorType: 'ERROR_ENGINE_UNAVAILABLE',
          message: 'Engine paths could not be applied: $e',
        );
      }
    }
    final String? raw;
    try {
      raw = await _channel
          .invokeMethod<String>(method, arguments)
          .timeout(timeoutForMethod(method));
    } on TimeoutException {
      AppLogger.warn(
        'Native call $method timed out',
        tag: 'engine',
      );
      return EngineEnvelope.error(
        errorType: 'ERROR_TIMEOUT',
        message: 'Native call $method timed out',
      );
    } on PlatformException catch (e) {
      AppLogger.warn(
        'Native call $method failed: ${e.code}',
        tag: 'engine',
      );
      return EngineEnvelope.error(
        errorType: e.code.isEmpty ? 'ERROR_TRANSPORT' : e.code,
        message: e.message ?? 'Native call failed',
      );
    } catch (e) {
      AppLogger.warn(
        'Native call $method failed: $e',
        tag: 'engine',
      );
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }

    if (raw == null || raw.isEmpty) {
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'No response from native layer for $method',
      );
    }
    final decoded = EngineEnvelope.decodeResponse(raw);
    if (decoded.isEmpty) {
      AppLogger.warn(
        'Malformed native response for $method',
        tag: 'engine',
      );
      return EngineEnvelope.error(
        errorType: 'ERROR_PROTOCOL',
        message: 'Malformed response for $method',
      );
    }
    return decoded;
  }

  @override
  Future<Map<String, dynamic>> bootstrap() async {
    final decoded = await _invokeEnvelope(EngineMethods.bootstrap);
    if (decoded['success'] == true) EngineContract.assertCompatible(decoded);
    return decoded;
  }

  /// Holds the paths until the engine is first actually used.
  ///
  /// Deliberately does NOT cross the bridge: see the lazy-start block
  /// above. A later call replaces the held map, so the newest paths win —
  /// the same "last write is what the engine gets" semantics the eager
  /// version had, without paying for the import at first frame.
  @override
  Future<void> setPaths(Map<String, dynamic> paths) async {
    // Counted before the branch so an in-flight first start notices it.
    _pathsGeneration++;
    if (_pathsApplied) {
      await _channel.invokeMethod(EngineMethods.setPaths, paths);
      return;
    }
    _pendingPaths = paths;
    // A start may already be running and have taken its own copy: wake it.
    final inFlight = _startup;
    if (inFlight != null) await inFlight;
  }

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    return _invokeEnvelope(EngineMethods.startDownload, {
      'url': url,
      'download_id': downloadId,
      'config': config,
      'network_type': networkType,
    });
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) async {
    return _invokeEnvelope(
      EngineMethods.cancelDownload,
      {'download_id': downloadId},
    );
  }

  @override
  Stream<Map<String, dynamic>> get progressStream => _events;

  @override
  void dispose() {
    try {
      _pendingPaths = null;
      _pathsApplied = false;
      _startup = null;
      _deferredConfig.clear();
      if (!_intentController.isClosed) _intentController.close();
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return _invokeEnvelope(
      EngineMethods.getFormats,
      {'url': url, 'config': config},
    );
  }

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return _invokeEnvelope(
      EngineMethods.playlistInfo,
      {'url': url, 'config': config},
    );
  }

  @override
  Future<Map<String, dynamic>> search({
    required String query,
    String site = 'youtube',
    int limit = 20,
    required Map<String, dynamic> config,
  }) async {
    return _invokeEnvelope(
      EngineMethods.searchQuery,
      {'query': query, 'site': site, 'limit': limit, 'config': config},
    );
  }

  @override
  Future<String?> getSharedUrl() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.getSharedUrl,
      );
      return result?['url'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> scanResumeCandidates({
    required String cacheDir,
  }) async {
    return _invokeEnvelope(
      EngineMethods.scanResume,
      {'cache_dir': cacheDir},
    );
  }

  @override
  Future<Map<String, dynamic>> reportResumeAttempt({
    required String cacheDir,
    required String filepath,
    required bool success,
  }) async {
    try {
      final result = await _channel.invokeMethod<String>(
        EngineMethods.resumeReport,
        {'cache_dir': cacheDir, 'filepath': filepath, 'success': success},
      );
      return EngineEnvelope.decodeResponse(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> updateCheck() async {
    try {
      final result = await _channel.invokeMethod<String>(
        EngineMethods.updateCheck,
      );
      if (result == null) return {};
      return EngineEnvelope.decodeResponse(result);
    } catch (e) {
      return EngineEnvelope.error(
        errorType: 'ERROR_UNKNOWN',
        message: 'Not available on this platform: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) async {
    try {
      final result = await _channel.invokeMethod<String>(
        EngineMethods.setUpdateChannel,
        {'channel': channel},
      );
      if (result == null) return {};
      return EngineEnvelope.decodeResponse(result);
    } catch (e) {
      return EngineEnvelope.error(
        errorType: 'ERROR_UNKNOWN',
        message: 'Not available on this platform: $e',
      );
    }
  }

  /// Engine `type:log` maps ride the same EventChannel as progress events
  /// (Kotlin forwards every JSON blob). Filtered view — broadcast-safe, so
  /// downloadProvider (progress) and LogIngester (logs) coexist. Single
  /// ingestion point for logs is LogIngester; downloadProvider ignores
  /// `type:log` maps (they carry no top-level download_id).
  @override
  Stream<Map<String, dynamic>> get logStream =>
      progressStream.where((event) => event['type'] == 'log');

  @override
  Future<Map<String, dynamic>> exportLogToDownloads({
    required String sourcePath,
    required String displayName,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>(EngineMethods.exportLog, {
        'source_path': sourcePath,
        'display_name': displayName,
      });
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return Map<String, dynamic>.from(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> networkMeteredStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.networkMetered,
      );
      if (result == null) {
        return {'success': false, 'supported': true, 'metered': true};
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return {'success': false, 'supported': true, 'metered': true};
    }
  }

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.batteryStatus,
      );
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed',
        extra: {'supported': false},
      );
    }
  }

  @override
  Future<Map<String, dynamic>> requestBatteryExemption() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.batteryRequest,
      );
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return Map<String, dynamic>.from(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.notificationStatus,
      );
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed',
        extra: {'supported': false},
      );
    }
  }

  @override
  Future<Map<String, dynamic>> requestNotificationPermission() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.notificationRequest,
      );
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return Map<String, dynamic>.from(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> queueStatus() async {
    return _invokeEnvelope(EngineMethods.queueStatus, {});
  }

  @override
  Future<Map<String, dynamic>> setConcurrency(int maxConcurrent) async {
    return _invokeEnvelope(
      EngineMethods.setConcurrency,
      {'max_concurrent': maxConcurrent},
    );
  }

  @override
  Future<Map<String, dynamic>> clearArchive() async {
    try {
      final result = await _channel.invokeMethod<String>(
        EngineMethods.clearArchive,
        {},
      );
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return EngineEnvelope.decodeResponse(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> openNotificationSettings() async {
    try {
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.notificationSettings,
        {},
      );
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return Map<String, dynamic>.from(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> openUrl(String url) async {
    try {
      final result = await _channel.invokeMethod<Map>(EngineMethods.openUrl, {
        'url': url,
      });
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return Map<String, dynamic>.from(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> openFile(String path) async {
    try {
      final result = await _channel.invokeMethod<Map>(EngineMethods.openFile, {
        'path': path,
      });
      if (result == null) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'No response from native layer',
        );
      }
      return Map<String, dynamic>.from(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> syncSchedule({
    required bool enabled,
    int intervalMinutes = 60,
    bool wifiOnly = true,
    bool requiresCharging = false,
  }) async {
    try {
      final result = await _channel
          .invokeMethod<Map>(EngineMethods.syncSchedule, {
            'enabled': enabled,
            'interval_minutes': intervalMinutes,
            'wifi_only': wifiOnly,
            'requires_charging': requiresCharging,
          });
      if (result == null) return {'success': true};
      return Map<String, dynamic>.from(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> syncQueueReminder({
    required bool enabled,
    int intervalMinutes = 180,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.syncQueueReminder,
        {'enabled': enabled, 'interval_minutes': intervalMinutes},
      );
      if (result == null) return {'success': true};
      return Map<String, dynamic>.from(result);
    } catch (e) {
      // The reason travels with the failure. The old code answered a
      // generic "Native call failed", so a broken bridge, a missing
      // plugin and a rejected argument were indistinguishable in the
      // UI and in the log.
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Native call failed: $e',
      );
    }
  }

  @override
  Future<void> showErrorNotification({
    required String downloadId,
    required String title,
    required String error,
  }) async {
    try {
      await _channel.invokeMethod('notification/show_error', {
        'download_id': downloadId,
        'title': title,
        'error': error,
      });
    } catch (_) {}
  }

  /// Requests a native success notification, discarding the response and
  /// suppressing channel errors, including a missing native implementation.
  @override
  Future<void> showSuccessNotification({
    required String downloadId,
    required String title,
    required String message,
  }) async {
    try {
      await _channel.invokeMethod('notification/show_success', {
        'download_id': downloadId,
        'title': title,
        'message': message,
      });
    } catch (_) {}
  }
}
