import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/utils/log_buffer.dart';
import '../core/utils/log_entry.dart';
import '../core/utils/log_ingester.dart';
import '../core/engine/engine_provider.dart';

final logBufferProvider = Provider<LogBuffer>((ref) {
  final buffer = LogBuffer(maxEntries: 5000);
  ref.onDispose(() => buffer.dispose());
  return buffer;
});

final logEntriesProvider = Provider.autoDispose<List<LogEntry>>((ref) {
  final buffer = ref.watch(logBufferProvider);
  return buffer.entries;
});

/// Provider that starts the LogIngester when the engine is available.
/// Engine log events are ingested into the shared LogBuffer.
final logIngesterProvider = Provider<LogIngester?>((ref) {
  final buffer = ref.watch(logBufferProvider);
  final engine = ref.watch(engineProvider);
  final ingester = LogIngester(buffer);
  ingester.start(engine.logStream);
  ref.onDispose(() => ingester.stop());
  return ingester;
});
