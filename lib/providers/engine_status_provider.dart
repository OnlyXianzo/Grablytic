import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/engine/engine_provider.dart';

/// One binary's installed-state record (engine `binaries[]` payload).
/// Source tells the user WHERE it came from: bundled (apk jniLibs),
/// downloaded (engine bin dir), system (PATH), runtime (language package),
/// unsupported (no distribution channel on this platform), missing, or
/// resolved/unknown (legacy fallback).
class BinaryStatus {
  final String name;
  final bool ok;
  final String source;
  final String? version;
  final String? detail;

  const BinaryStatus({
    required this.name,
    required this.ok,
    this.source = 'unknown',
    this.version,
    this.detail,
  });

  factory BinaryStatus.fromJson(Map<String, dynamic> json) {
    return BinaryStatus(
      name: json['name'] as String? ?? 'unknown',
      ok: json['ok'] as bool? ?? false,
      source: json['source'] as String? ?? 'unknown',
      version: json['version'] as String?,
      detail: json['detail'] as String?,
    );
  }

  /// Human label for the source chip.
  String get sourceLabel {
    switch (source) {
      case 'bundled':
        return 'Bundled';
      case 'downloaded':
        return 'Downloaded';
      case 'system':
        return 'System';
      case 'runtime':
        return 'Runtime';
      case 'unsupported':
        return 'Unavailable';
      case 'missing':
        return 'Missing';
      default:
        return 'Installed';
    }
  }

  /// True when re-running bootstrap could conceivably fix it.
  bool get isActionable => ok || (source != 'unsupported' && source != 'runtime');
}

class EngineStatus {
  final bool ready;
  final String? ytDlpVersion;
  final bool ytDlpOutdated;
  final bool ffmpegOk;
  final String? ffmpegVersion;
  final bool aria2cOk;
  final String? aria2cVersion;
  // Desktop-only: Deno
  final bool denoOk;
  final String? denoVersion;
  // Android-only: QuickJS
  final bool quickjsOk;
  // Common: detected JS runtime (quickjs | deno | none)
  final String? jsRuntime;
  final String? jsRuntimeVersion;
  final List<String> updateComponents;
  /// Per-binary records (additive engine payload; may be empty on old builds).
  final List<BinaryStatus> binaries;
  final String? bootstrapProgress;
  final String? error;

  const EngineStatus({
    required this.ready,
    this.ytDlpVersion,
    this.ytDlpOutdated = false,
    this.ffmpegOk = false,
    this.ffmpegVersion,
    this.aria2cOk = false,
    this.aria2cVersion,
    this.denoOk = false,
    this.denoVersion,
    this.quickjsOk = false,
    this.jsRuntime,
    this.jsRuntimeVersion,
    this.updateComponents = const [],
    this.binaries = const [],
    this.bootstrapProgress,
    this.error,
  });

  /// True if essential binaries (yt-dlp + ffmpeg) are ready.
  /// aria2c is optional; JS runtime is platform-specific.
  bool get allBinariesOk => ytDlpVersion != null && ffmpegOk;

  /// True if the JS runtime for this platform is available.
  bool get jsRuntimeOk {
    if (Platform.isAndroid) return quickjsOk;
    return denoOk;
  }

  String? get statusMessage {
    if (error != null) return error;
    if (updateComponents.contains('yt_dlp')) {
      return 'yt-dlp has a new version — download now';
    }
    if (updateComponents.contains('ffmpeg')) {
      return 'FFmpeg update available';
    }
    // Deno updates are desktop-only — never surface on Android
    if (!Platform.isAndroid && updateComponents.contains('deno')) {
      return 'Deno update available';
    }
    if (updateComponents.contains('aria2c')) {
      return 'aria2c update available';
    }
    return null;
  }
}

final engineStatusProvider = FutureProvider<EngineStatus>((ref) async {
  final engine = ref.watch(engineProvider);
  try {
    // Ensure setPaths completes before bootstrap — prevents
    // "paths/set not called before bootstrap" race condition.
    final pathsFuture = engineSetPathsFuture;
    if (pathsFuture != null) {
      await pathsFuture;
    }
    final result = await engine.bootstrap();
    if (result['success'] == true) {
      final components = (result['update_components'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      final jsRuntime = result['js_runtime'] as String?;
      final jsRuntimeVersion = result['js_runtime_version'] as String?;
      final quickjsOk = result['quickjs_ok'] as bool? ?? false;
      final ffmpegOk = result['ffmpeg_ok'] as bool? ?? false;
      final aria2cOk = result['aria2c_ok'] as bool? ?? false;
      // Additive payload (new engines): full provenance records.
      final rawBinaries = result['binaries'] as List?;
      final List<BinaryStatus> binaries;
      if (rawBinaries != null) {
        binaries = rawBinaries
            .whereType<Map>()
            .map((m) => BinaryStatus.fromJson(
                Map<String, dynamic>.from(m)))
            .toList();
      } else {
        // Legacy fallback: synthesize from scattered keys (source unknown).
        binaries = [
          BinaryStatus(
              name: 'yt-dlp',
              ok: result['yt_dlp_version'] != null,
              version: result['yt_dlp_version'] as String?),
          BinaryStatus(
              name: 'ffmpeg',
              ok: ffmpegOk,
              version: result['ffmpeg_version'] as String?),
          BinaryStatus(
              name: 'aria2c',
              ok: aria2cOk,
              version: result['aria2c_version'] as String?),
        ];
      }
      return EngineStatus(
        ready: true,
        ytDlpVersion: result['yt_dlp_version'] as String?,
        ytDlpOutdated: result['yt_dlp_outdated'] as bool? ?? false,
        ffmpegOk: ffmpegOk,
        ffmpegVersion: result['ffmpeg_version'] as String?,
        aria2cOk: aria2cOk,
        aria2cVersion: result['aria2c_version'] as String?,
        denoOk: jsRuntime == 'deno',
        denoVersion: jsRuntime == 'deno' ? jsRuntimeVersion : null,
        quickjsOk: quickjsOk,
        jsRuntime: jsRuntime,
        jsRuntimeVersion: jsRuntimeVersion,
        updateComponents: components,
        binaries: binaries,
      );
    }
    return EngineStatus(
      ready: false,
      error: result['error_message'] as String?,
    );
  } catch (e) {
    return EngineStatus(
      ready: false,
      error: e.toString(),
    );
  }
});
