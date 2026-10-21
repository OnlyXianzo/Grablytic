import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/engine/engine_provider.dart';
import '../core/engine/progress_channel.dart';
import '../core/utils/log_buffer.dart';
import '../core/utils/log_ingester.dart';

final logBufferProvider = Provider<LogBuffer>((ref) {
  final buffer = LogBuffer.forThisPlatform();
  ref.onDispose(() => buffer.dispose());
  return buffer;
});

/// The engine's log events, **without** creating the engine.
///
/// `logIngesterProvider` used to `ref.watch(engineProvider)`, and building
/// the engine calls `setPaths(...)` → Chaquopy `paths/set` →
/// `getModule("grablytic_engine")` → `import yt_dlp`. Measured: **40.5 MiB
/// RSS and ~480 modules** on the first frame of every launch, including a
/// first launch that never leaves onboarding.
///
/// On Android the source is [ProgressChannel] — the same single native
/// subscription the engine service reads, decoded once for both consumers
/// (#98). Off Android the transport is a local process and constructing it
/// is cheap, so it serves its own filtered view.
final logChannelProvider = Provider<Stream<Map<String, dynamic>>>((ref) {
  if (!Platform.isAndroid) {
    return ref.watch(engineProvider).logStream;
  }
  return ProgressChannel.instance.events.where(
    (event) => event['type'] == 'log',
  );
});

/// Starts the LogIngester on the engine's log stream.
///
/// No longer depends on [engineProvider] on Android — see
/// [logChannelProvider]. Engine logs therefore still land in the buffer
/// from the moment the app is up, but the Python VM is not started for
/// them.
final logIngesterProvider = Provider<LogIngester?>((ref) {
  final buffer = ref.watch(logBufferProvider);
  final ingester = LogIngester(buffer);
  ingester.start(ref.watch(logChannelProvider));
  ref.onDispose(() => ingester.stop());
  return ingester;
});
