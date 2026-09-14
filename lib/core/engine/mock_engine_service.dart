import 'dart:async';
import 'engine_service.dart';

class MockEngineService implements EngineService {
  final _progressController = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Future<Map<String, dynamic>> bootstrap() async {
    return {
      'success': true,
      'yt_dlp_version': '2025.06.06',
      'ffmpeg_ok': false,
      'ffmpeg_version': null,
      'js_runtime': 'none',
      'js_runtime_version': null,
      'aria2c_ok': false,
      'aria2c_version': null,
      'needs_update': false,
      'update_components': <String>[],
      'manifest_source': 'mock',
    };
  }

  @override
  Future<void> setPaths(Map<String, dynamic> paths) async {}

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    Future.delayed(const Duration(seconds: 2), () {
      if (!_progressController.isClosed) {
        _progressController.add({
          'type': 'event',
          'event': 'downloading',
          'download_id': downloadId,
          'downloaded_bytes': 5242880,
          'total_bytes': 52428800,
          'total_bytes_is_estimate': false,
          'speed': 2097152.0,
          'eta': 23,
          'filename': 'working_cache/${downloadId}_video.mp4',
          'fragment_index': null,
          'fragment_count': null,
          'stream': null,
        });
      }
    });

    Future.delayed(const Duration(seconds: 5), () {
      if (!_progressController.isClosed) {
        _progressController.add({
          'type': 'event',
          'event': 'finished',
          'download_id': downloadId,
          'filepath': '/storage/emulated/0/Download/TrueStream/Video.mp4',
          'filesize_bytes': 52428800,
          'duration_seconds': 312,
          'title': 'Sample Video',
          'uploader': 'Channel',
          'upload_date': '20250101',
          'thumbnail_path': null,
          'format_id': '137+140',
          'vcodec': 'avc1',
          'acodec': 'mp4a.40.2',
          'height': 1080,
          'fps': 30.0,
          'abr': 128.0,
          'ext': 'mp4',
        });
      }
    });

    return {
      'success': true,
      'download_id': downloadId,
      'thread_started': true,
    };
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) async {
    return {
      'success': true,
      'download_id': downloadId,
      'cancelled': true,
    };
  }

  @override
  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return {
      'success': true,
      'title': 'Sample Video',
      'duration_seconds': 312,
      'thumbnail_url': null,
      'is_live': false,
      'is_playlist': false,
      'formats': [
        {
          'format_id': '401',
          'ext': 'mp4',
          'vcodec': 'av01',
          'acodec': 'none',
          'height': 2160,
          'width': 3840,
          'fps': 60.0,
          'tbr': 14000.0,
          'filesize': 2254857830,
          'filesize_is_estimate': false,
          'is_hdr': false,
          'dynamic_range': 'SDR',
          'stream_type': 'video',
        },
        {
          'format_id': '337',
          'ext': 'mp4',
          'vcodec': 'vp9',
          'acodec': 'none',
          'height': 2160,
          'width': 3840,
          'fps': 60.0,
          'tbr': 18000.0,
          'filesize': 3650722201,
          'filesize_is_estimate': false,
          'is_hdr': false,
          'dynamic_range': 'SDR',
          'stream_type': 'video',
        },
        {
          'format_id': '248',
          'ext': 'webm',
          'vcodec': 'vp9',
          'acodec': 'none',
          'height': 1080,
          'width': 1920,
          'fps': 30.0,
          'tbr': 8000.0,
          'filesize': 854857830,
          'filesize_is_estimate': false,
          'is_hdr': false,
          'dynamic_range': 'SDR',
          'stream_type': 'video',
        },
        {
          'format_id': '137',
          'ext': 'mp4',
          'vcodec': 'avc1',
          'acodec': 'none',
          'height': 1080,
          'width': 1920,
          'fps': 30.0,
          'tbr': 5000.0,
          'filesize': 624857830,
          'filesize_is_estimate': false,
          'is_hdr': false,
          'dynamic_range': 'SDR',
          'stream_type': 'video',
        },
        {
          'format_id': '251',
          'ext': 'webm',
          'vcodec': 'none',
          'acodec': 'opus',
          'abr': 160.0,
          'filesize': 3456789,
          'filesize_is_estimate': false,
          'stream_type': 'audio',
        },
        {
          'format_id': '140',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'abr': 128.0,
          'filesize': 2890123,
          'filesize_is_estimate': false,
          'stream_type': 'audio',
        },
      ],
      'recommended_video_format_id': '401',
      'recommended_audio_format_id': '251',
    };
  }

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return {
      'success': true,
      'title': 'Sample Playlist',
      'uploader': 'Channel',
      'count': 0,
      'estimated_total_bytes': null,
      'entries': <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, dynamic>> search({
    required String query,
    String site = 'youtube',
    int limit = 20,
    required Map<String, dynamic> config,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return {
        'success': false,
        'error_type': 'ERROR_INVALID_PARAM',
        'error_message': 'Search query cannot be empty',
      };
    }
    if (trimmed == '__trigger_error__') {
      return {
        'success': false,
        'error_type': 'ERROR_FORBIDDEN',
        'error_message': "Sign in to confirm you're not a bot",
      };
    }
    if (trimmed == '__empty__') {
      return {
        'success': true,
        'query': trimmed,
        'site': site,
        'count': 0,
        'entries': <Map<String, dynamic>>[],
      };
    }
    return {
      'success': true,
      'query': trimmed,
      'site': site,
      'count': 2,
      'entries': [
        {
          'index': 1,
          'title': '$trimmed - Official Video',
          'url': 'https://www.youtube.com/watch?v=mockVideo111',
          'duration_seconds': 212,
          'thumbnail_url': 'https://img.youtube.com/vi/mockVideo111/0.jpg',
          'uploader': 'Test Artist',
          'is_available': true,
        },
        {
          'index': 2,
          'title': '$trimmed - Live Performance',
          'url': 'https://www.youtube.com/watch?v=mockVideo222',
          'duration_seconds': 345,
          'thumbnail_url': 'https://img.youtube.com/vi/mockVideo222/0.jpg',
          'uploader': 'Music Channel',
          'is_available': true,
        },
      ],
    };
  }

  @override
  Future<String?> getSharedUrl() => Future.value(null);

  @override
  Stream<String> get sharedUrlStream => const Stream.empty();

  @override
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir}) async {
    return {
      'success': true,
      'candidates': <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, dynamic>> updateCheck() async {
    return {
      'success': true,
      'checked_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'yt_dlp_current': '2025.06.06',
      'yt_dlp_latest': '2025.06.06',
      'yt_dlp_update_available': false,
      'binaries': <Map<String, dynamic>>[
        {
          'name': 'ffmpeg',
          'current_sha256': 'abc123mock',
          'manifest_sha256': 'abc123mock',
          'update_available': false,
        },
        {
          'name': 'aria2c',
          'current_sha256': 'def456mock',
          'manifest_sha256': 'def456mock',
          'update_available': false,
        }
      ],
      'updates_queued': <String>[],
    };
  }

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) async {
    return {'success': true};
  }

  @override
  Stream<Map<String, dynamic>> get logStream => const Stream.empty();

  @override
  Future<Map<String, dynamic>> exportLogToDownloads({
    required String sourcePath,
    required String displayName,
  }) async {
    return {'success': true, 'path': 'mock/Downloads/$displayName'};
  }

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() async =>
      {'success': false, 'supported': false};

  @override
  Future<Map<String, dynamic>> requestBatteryExemption() async =>
      {'success': false, 'supported': false};

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() async =>
      {'success': false, 'supported': false};

  @override
  Future<Map<String, dynamic>> requestNotificationPermission() async =>
      {'success': false, 'supported': false};

  @override
  Future<Map<String, dynamic>> queueStatus() async => {
        'success': true,
        'active': <String>[],
        'queued': <String>[],
        'max_concurrent': 2,
      };

  @override
  Future<Map<String, dynamic>> setConcurrency(int maxConcurrent) async => {
        'success': true,
        'max_concurrent': maxConcurrent.clamp(1, 5),
      };

  @override
  Future<Map<String, dynamic>> clearArchive() async =>
      {'success': true, 'removed': false, 'path': null};

  @override
  Future<Map<String, dynamic>> openNotificationSettings() async =>
      {'success': false, 'supported': false};

  @override
  Future<Map<String, dynamic>> openUrl(String url) async =>
      {'success': false, 'supported': false};

  @override
  Future<Map<String, dynamic>> syncSchedule({
    required bool enabled,
    int intervalMinutes = 60,
    bool wifiOnly = true,
    bool requiresCharging = false,
  }) async =>
      {'success': true};

  void dispose() {
    _progressController.close();
  }
}
