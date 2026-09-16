import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import '../utils/app_logger.dart';
import 'engine_codec.dart';
import 'engine_service.dart';

class PlatformChannelEngineService implements EngineService {
  final MethodChannel _channel = const MethodChannel('com.theonly.grablytic/engine');
  final EventChannel _eventChannel = const EventChannel('com.theonly.grablytic/progress');
  final _intentController = StreamController<String>.broadcast();

  /// SINGLE native subscription, shared by progressStream + logStream.
  /// (Each receiveBroadcastStream() call re-triggers native onListen and
  /// would orphan the previous sink — so both views derive from this one
  /// cached broadcast stream. .map/.where preserve broadcast semantics.)
  Stream<Map<String, dynamic>>? _progressCache;

  PlatformChannelEngineService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == EngineMethods.sharedUrlInbound) {
        final arguments = call.arguments;
        final map = arguments is Map ? Map<String, dynamic>.from(arguments) : null;
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

  @override
  Future<Map<String, dynamic>> bootstrap() async {
    final result = await _channel.invokeMethod<String>(EngineMethods.bootstrap);
    if (result == null) return {};
    return EngineEnvelope.decodeResponse(result);
  }

  @override
  Future<void> setPaths(Map<String, dynamic> paths) async {
    await _channel.invokeMethod(EngineMethods.setPaths, paths);
  }

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    final result = await _channel.invokeMethod<String>(EngineMethods.startDownload, {
      'url': url,
      'download_id': downloadId,
      'config': config,
      'network_type': networkType,
    });
    if (result == null) return {};
    return EngineEnvelope.decodeResponse(result);
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) async {
    final result = await _channel.invokeMethod<String>(EngineMethods.cancelDownload, {
      'download_id': downloadId,
    });
    if (result == null) return {};
    return EngineEnvelope.decodeResponse(result);
  }

  @override
  Stream<Map<String, dynamic>> get progressStream =>
      _progressCache ??= _eventChannel
          .receiveBroadcastStream()
          .transform<Map<String, dynamic>>(
            StreamTransformer.fromHandlers(
              handleData: (event, sink) {
                try {
                  if (event is String) {
                    final decoded = jsonDecode(event);
                    if (decoded is Map) {
                      sink.add(Map<String, dynamic>.from(decoded));
                    }
                  } else if (event is Map) {
                    sink.add(Map<String, dynamic>.from(event));
                  }
                } catch (_) {
                  // Malformed payload ignored safely
                }
              },
              handleError: (error, stackTrace, sink) {
                // Formerly swallowed: downstream saw a stalled 0% card
                // indistinguishable from a dead bridge. Forward so
                // downloadProvider's onError logs and the UI can react.
                try {
                  AppLogger.warn('Progress channel error: $error',
                      tag: 'engine');
                } catch (_) {}
                sink.addError(error, stackTrace);
              },
            ),
          );

  @override
  void dispose() {
    try {
      _progressCache = null;
      if (!_intentController.isClosed) _intentController.close();
    } catch (_) {}
  }

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    final result = await _channel.invokeMethod<String>(EngineMethods.getFormats, {
      'url': url,
      'config': config,
    });
    if (result == null) return {};
    return EngineEnvelope.decodeResponse(result);
  }

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    final result = await _channel.invokeMethod<String>(EngineMethods.playlistInfo, {
      'url': url,
      'config': config,
    });
    if (result == null) return {};
    return EngineEnvelope.decodeResponse(result);
  }

  @override
  Future<Map<String, dynamic>> search({
    required String query,
    String site = 'youtube',
    int limit = 20,
    required Map<String, dynamic> config,
  }) async {
    final result = await _channel.invokeMethod<String>(EngineMethods.searchQuery, {
      'query': query,
      'site': site,
      'limit': limit,
      'config': config,
    });
    if (result == null) return {};
    return EngineEnvelope.decodeResponse(result);
  }

  @override
  Future<String?> getSharedUrl() async {
    try {
      final result = await _channel.invokeMethod<Map>(EngineMethods.getSharedUrl);
      return result?['url'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir}) async {
    final result = await _channel.invokeMethod<String>(EngineMethods.scanResume, {
      'cache_dir': cacheDir,
    });
    if (result == null) return {};
    return EngineEnvelope.decodeResponse(result);
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
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }

  @override
  Future<Map<String, dynamic>> updateCheck() async {
    try {
      final result = await _channel.invokeMethod<String>(EngineMethods.updateCheck);
      if (result == null) return {};
      return EngineEnvelope.decodeResponse(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_UNKNOWN',
          message: 'Not available on this platform');
    }
  }

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) async {
    try {
      final result = await _channel.invokeMethod<String>(EngineMethods.setUpdateChannel, {
        'channel': channel,
      });
      if (result == null) return {};
      return EngineEnvelope.decodeResponse(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_UNKNOWN',
          message: 'Not available on this platform');
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
      final result = await _channel.invokeMethod<Map>(
        EngineMethods.exportLog,
        {'source_path': sourcePath, 'display_name': displayName},
      );
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>(EngineMethods.batteryStatus);
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'Native call failed',
          extra: {'supported': false});
    }
  }

  @override
  Future<Map<String, dynamic>> requestBatteryExemption() async {
    try {
      final result = await _channel.invokeMethod<Map>(EngineMethods.batteryRequest);
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>(EngineMethods.notificationStatus);
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'Native call failed',
          extra: {'supported': false});
    }
  }

  @override
  Future<Map<String, dynamic>> requestNotificationPermission() async {
    try {
      final result = await _channel.invokeMethod<Map>(EngineMethods.notificationRequest);
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }

  @override
  Future<Map<String, dynamic>> queueStatus() async {
    try {
      final result =
          await _channel.invokeMethod<String>(EngineMethods.queueStatus, {});
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return EngineEnvelope.decodeResponse(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }

  @override
  Future<Map<String, dynamic>> setConcurrency(int maxConcurrent) async {
    try {
      final result =
          await _channel.invokeMethod<String>(EngineMethods.setConcurrency, {
        'max_concurrent': maxConcurrent,
      });
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return EngineEnvelope.decodeResponse(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }

  @override
  Future<Map<String, dynamic>> clearArchive() async {
    try {
      final result =
          await _channel.invokeMethod<String>(EngineMethods.clearArchive, {});
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return EngineEnvelope.decodeResponse(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }

  @override
  Future<Map<String, dynamic>> openNotificationSettings() async {
    try {
      final result = await _channel
          .invokeMethod<Map>(EngineMethods.notificationSettings, {});
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }

  @override
  Future<Map<String, dynamic>> openUrl(String url) async {
    try {
      final result = await _channel
          .invokeMethod<Map>(EngineMethods.openUrl, {'url': url});
      if (result == null) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'No response from native layer');
      }
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
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
      final result = await _channel.invokeMethod<Map>(EngineMethods.syncSchedule, {
        'enabled': enabled,
        'interval_minutes': intervalMinutes,
        'wifi_only': wifiOnly,
        'requires_charging': requiresCharging,
      });
      if (result == null) return {'success': true};
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Native call failed');
    }
  }
}

