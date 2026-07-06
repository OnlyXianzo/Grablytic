import 'dart:async';
import 'log_entry.dart';
import 'log_buffer.dart';

class LogIngester {
  final LogBuffer _buffer;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  LogIngester(this._buffer);

  void start(Stream<Map<String, dynamic>> engineLogStream) {
    _subscription = engineLogStream.listen(_handleLogEvent);
  }

  void _handleLogEvent(Map<String, dynamic> data) {
    if (data['type'] != 'log') return;
    try {
      final entry = LogEntry.fromEngineJson(data);
      _buffer.add(entry);
    } catch (_) {
      // ignore malformed log entries
    }
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }
}
