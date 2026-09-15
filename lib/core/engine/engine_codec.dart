import 'dart:convert';

/// Single source of truth for the engine IPC contract (BRUTAL-1).
///
/// The same method ids are dispatched on by three other layers with plain
/// string literals — Kotlin `MainActivity` (`"download/start" ->` branches)
/// and Python `__main__.py` (`method == "download/start"` branches) — plus
/// both Dart transports in this directory. A typo in any one copy fails
/// silently at runtime (unknown-method / NOT_FOUND), so Dart call sites
/// must use these constants; the VALUES are frozen by the native/python
/// side and covered by `engine_codec_test.dart`.
///
/// Out of scope on purpose: Kotlin/Python keep their literals (their own
/// compilers and on-device/CI builds guard them; renaming across the
/// platform boundary cannot be proven from this tree alone).
abstract final class EngineMethods {
  static const String bootstrap = 'engine/bootstrap';
  static const String setPaths = 'paths/set';
  static const String startDownload = 'download/start';
  static const String cancelDownload = 'download/cancel';
  static const String queueStatus = 'download/queue_status';
  static const String setConcurrency = 'download/set_concurrency';
  static const String clearArchive = 'download/clear_archive';
  static const String getFormats = 'formats/get';
  static const String playlistInfo = 'playlist/info';
  static const String searchQuery = 'search/query';
  static const String getSharedUrl = 'intent/get_shared';
  static const String sharedUrlInbound = 'intent/shared_url';
  static const String openUrl = 'intent/open_url';
  static const String scanResume = 'resume/scan';
  static const String exportLog = 'log/export_to_downloads';
  static const String updateCheck = 'engine/update_check';
  static const String setUpdateChannel = 'engine/set_update_channel';
  static const String batteryStatus = 'system/battery_status';
  static const String batteryRequest = 'system/battery_request';
  static const String notificationStatus = 'system/notification_status';
  static const String notificationRequest = 'system/notification_request';
  static const String notificationSettings = 'system/notification_settings';
  static const String syncSchedule = 'schedule/sync';
}

/// Shared encode/decode for the engine envelope (BRUTAL-1).
///
/// Both Dart transports previously hand-rolled the same three shapes
/// (request `{id, method, params}`, nullable-JSON response, failure map)
/// with subtly divergent fallbacks. Centralized here; transports keep
/// their own delivery (stdio vs MethodChannel). Never throws.
abstract final class EngineEnvelope {
  /// `{id, method, params}` JSON for the desktop stdio transport.
  static String encodeRequest({
    required String id,
    required String method,
    required Map<String, dynamic> params,
  }) =>
      jsonEncode({'id': id, 'method': method, 'params': params});

  /// Nullable JSON response string → map. Null/garbage/non-object maps to
  /// `{}` (the historical platform-transport fallback), never throws.
  static Map<String, dynamic> decodeResponse(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return {};
  }

  /// Standard failure envelope: `{'success': false, 'error_type',
  /// 'error_message', ...extra}`. Use for every transport-level fallback
  /// so "unsupported" means the same shape on desktop, mobile, and mock.
  static Map<String, dynamic> error({
    required String errorType,
    required String message,
    Map<String, dynamic>? extra,
  }) =>
      {
        'success': false,
        'error_type': errorType,
        'error_message': message,
        ...?extra,
      };
}
