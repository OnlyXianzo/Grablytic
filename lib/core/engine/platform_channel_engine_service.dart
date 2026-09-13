import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'engine_service.dart';

class PlatformChannelEngineService implements EngineService {
  final MethodChannel _channel = const MethodChannel('com.theonly.truestream/engine');
  final EventChannel _eventChannel = const EventChannel('com.theonly.truestream/progress');
  final _intentController = StreamController<String>.broadcast();

  /// SINGLE native subscription, shared by progressStream + logStream.
  /// (Each receiveBroadcastStream() call re-triggers native onListen and
  /// would orphan the previous sink — so both views derive from this one
  /// cached broadcast stream. .map/.where preserve broadcast semantics.)
  Stream<Map<String, dynamic>>? _progressCache;

  PlatformChannelEngineService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'intent/shared_url') {
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
    final result = await _channel.invokeMethod<String>('engine/bootstrap');
    if (result == null) return {};
    return Map<String, dynamic>.from(jsonDecode(result) as Map);
  }

  @override
  Future<void> setPaths(Map<String, dynamic> paths) async {
    await _channel.invokeMethod('paths/set', paths);
  }

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    final result = await _channel.invokeMethod<String>('download/start', {
      'url': url,
      'download_id': downloadId,
      'config': config,
      'network_type': networkType,
    });
    if (result == null) return {};
    return Map<String, dynamic>.from(jsonDecode(result) as Map);
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) async {
    final result = await _channel.invokeMethod<String>('download/cancel', {
      'download_id': downloadId,
    });
    if (result == null) return {};
    return Map<String, dynamic>.from(jsonDecode(result) as Map);
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
                // Keep stream alive on transient platform errors
              },
            ),
          );

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    final result = await _channel.invokeMethod<String>('formats/get', {
      'url': url,
      'config': config,
    });
    if (result == null) return {};
    return Map<String, dynamic>.from(jsonDecode(result) as Map);
  }

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    final result = await _channel.invokeMethod<String>('playlist/info', {
      'url': url,
      'config': config,
    });
    if (result == null) return {};
    return Map<String, dynamic>.from(jsonDecode(result) as Map);
  }

  @override
  Future<Map<String, dynamic>> search({
    required String query,
    String site = 'youtube',
    int limit = 20,
    required Map<String, dynamic> config,
  }) async {
    final result = await _channel.invokeMethod<String>('search/query', {
      'query': query,
      'site': site,
      'limit': limit,
      'config': config,
    });
    if (result == null) return {};
    return Map<String, dynamic>.from(jsonDecode(result) as Map);
  }

  @override
  Future<String?> getSharedUrl() async {
    try {
      final result = await _channel.invokeMethod<Map>('intent/get_shared');
      return result?['url'] as String?;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir}) async {
    final result = await _channel.invokeMethod<String>('resume/scan', {
      'cache_dir': cacheDir,
    });
    if (result == null) return {};
    return Map<String, dynamic>.from(jsonDecode(result) as Map);
  }

  @override
  Future<Map<String, dynamic>> updateCheck() async {
    try {
      final result = await _channel.invokeMethod<String>('engine/update_check');
      if (result == null) return {};
      return Map<String, dynamic>.from(jsonDecode(result) as Map);
    } catch (_) {
      return {'success': false, 'error_type': 'ERROR_UNKNOWN', 'error_message': 'Not available on this platform'};
    }
  }

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) async {
    try {
      final result = await _channel.invokeMethod<String>('engine/set_update_channel', {
        'channel': channel,
      });
      if (result == null) return {};
      return Map<String, dynamic>.from(jsonDecode(result) as Map);
    } catch (_) {
      return {'success': false, 'error_type': 'ERROR_UNKNOWN', 'error_message': 'Not available on this platform'};
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
        'log/export_to_downloads',
        {'source_path': sourcePath, 'display_name': displayName},
      );
      if (result == null) return {'success': false};
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return {'success': false};
    }
  }

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>('system/battery_status');
      if (result == null) return {'success': false};
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return {'success': false, 'supported': false};
    }
  }

  @override
  Future<Map<String, dynamic>> requestBatteryExemption() async {
    try {
      final result = await _channel.invokeMethod<Map>('system/battery_request');
      if (result == null) return {'success': false};
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return {'success': false};
    }
  }

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>('system/notification_status');
      if (result == null) return {'success': false};
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return {'success': false, 'supported': false};
    }
  }

  @override
  Future<Map<String, dynamic>> requestNotificationPermission() async {
    try {
      final result = await _channel.invokeMethod<Map>('system/notification_request');
      if (result == null) return {'success': false};
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return {'success': false};
    }
  }
}

