import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/utils/log_buffer.dart';
import '../core/utils/log_ingester.dart';
import '../core/engine/engine_provider.dart';

final logBufferProvider = Provider<LogBuffer>((ref) {
  final buffer = LogBuffer.forThisPlatform();
  ref.onDispose(() => buffer.dispose());
  return buffer;
});

/// The engine's event channel, decoded, **without** creating the engine.
///
/// `logIngesterProvider` used to `ref.watch(engineProvider)`, and building
/// the engine calls `setPaths(...)` → Chaquopy `paths/set` →
/// `getModule("grablytic_engine")` → `import yt_dlp`. Measured: **40.5 MiB
/// RSS and ~480 modules** on the first frame of every launch, including a
/// first launch that never leaves onboarding.
///
/// So the log channel is opened directly. It is the same
/// `com.theonly.grablytic/progress` EventChannel the engine service reads,
/// and Kotlin keeps a **list** of sinks (`MainActivity.registerEventSink`),
/// so a second listener does not displace the first: progress events and
/// log events each reach every subscriber.
///
/// Off Android the channel does not exist; the transport there is a local
/// process and constructing it is cheap, so it serves the stream.
final logChannelProvider = Provider<Stream<Map<String, dynamic>>>((ref) {
  if (!Platform.isAndroid) {
    return ref.watch(engineProvider).logStream;
  }
  return _decodeEventChannel(
    const EventChannel('com.theonly.grablytic/progress'),
  ).where((event) => event['type'] == 'log');
});

/// Decodes the EventChannel's string/map payloads into maps.
///
/// Kept here rather than reusing [PlatformChannelEngineService.progressStream]
/// because that one lives on the engine instance — and touching the engine
/// instance is the thing this provider exists to avoid.
Stream<Map<String, dynamic>> _decodeEventChannel(EventChannel channel) {
  return channel
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
            } on FormatException {
              // A malformed payload is not a reason to kill the stream.
            }
          },
          handleError: (error, stackTrace, sink) {
            sink.addError(error, stackTrace);
          },
        ),
      );
}

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
