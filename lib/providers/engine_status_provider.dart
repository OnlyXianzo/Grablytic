import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/engine/engine_provider.dart';

class EngineStatus {
  final bool ready;
  final String? ytDlpVersion;
  final bool ffmpegOk;
  final String? ffmpegVersion;
  final bool aria2cOk;
  final String? aria2cVersion;
  final bool denoOk;
  final String? denoVersion;
  final String? jsRuntime;
  final String? jsRuntimeVersion;
  final List<String> updateComponents;
  final String? bootstrapProgress;
  final String? error;

  const EngineStatus({
    required this.ready,
    this.ytDlpVersion,
    this.ffmpegOk = false,
    this.ffmpegVersion,
    this.aria2cOk = false,
    this.aria2cVersion,
    this.denoOk = false,
    this.denoVersion,
    this.jsRuntime,
    this.jsRuntimeVersion,
    this.updateComponents = const [],
    this.bootstrapProgress,
    this.error,
  });

  bool get allBinariesOk =>
      ytDlpVersion != null && ffmpegOk && aria2cOk;

  String? get statusMessage {
    if (error != null) return error;
    if (updateComponents.contains('yt_dlp')) {
      return 'yt-dlp has a new version — download now';
    }
    if (updateComponents.contains('ffmpeg')) {
      return 'FFmpeg update available';
    }
    if (updateComponents.contains('deno')) {
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
    final result = await engine.bootstrap();
    if (result['success'] == true) {
      final components = (result['update_components'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      final jsRuntime = result['js_runtime'] as String?;
      final jsRuntimeVersion = result['js_runtime_version'] as String?;
      return EngineStatus(
        ready: true,
        ytDlpVersion: result['yt_dlp_version'] as String?,
        ffmpegOk: result['ffmpeg_ok'] as bool? ?? false,
        ffmpegVersion: result['ffmpeg_version'] as String?,
        aria2cOk: result['aria2c_ok'] as bool? ?? false,
        aria2cVersion: result['aria2c_version'] as String?,
        denoOk: jsRuntime == 'deno',
        denoVersion: jsRuntime == 'deno' ? jsRuntimeVersion : null,
        jsRuntime: jsRuntime,
        jsRuntimeVersion: jsRuntimeVersion,
        updateComponents: components,
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
