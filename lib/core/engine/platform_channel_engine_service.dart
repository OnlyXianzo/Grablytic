import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'engine_service.dart';

class PlatformChannelEngineService implements EngineService {
  final MethodChannel _channel = const MethodChannel('com.theonly.truestream/engine');
  final EventChannel _eventChannel = const EventChannel('com.theonly.truestream/progress');
  final _intentController = StreamController<String>.broadcast();

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
      _eventChannel.receiveBroadcastStream().map((event) {
        if (event is String) {
          return Map<String, dynamic>.from(jsonDecode(event));
        }
        return Map<String, dynamic>.from(event);
      });

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

  @override
  Stream<Map<String, dynamic>> get logStream => const Stream.empty();
}

