import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native progress/log EventChannel, subscribed and decoded **once**.
///
/// Pass 3 fixed the eager engine start by having log ingestion open this
/// channel directly, but that left two independent readers of the same
/// stream: `PlatformChannelEngineService.progressStream` for downloads and
/// `logChannelProvider` for the log buffer. Both called
/// `receiveBroadcastStream()`, which registers a SECOND native sink (Kotlin
/// keeps a list), so every progress event crossed the bridge twice and was
/// `jsonDecode`d twice — once to be shown, once to be thrown away by the
/// `type == 'log'` filter.
///
/// This is the one reader. A single native subscription feeds a broadcast
/// controller, so every consumer (progress, logs, anything added later)
/// shares one decode pass and one native sink.
class ProgressChannel {
  ProgressChannel({
    EventChannel channel = const EventChannel(channelName),
  }) : _channel = channel {
    _controller = StreamController<Map<String, dynamic>>.broadcast(
      onListen: _subscribe,
      onCancel: _unsubscribeIfIdle,
    );
  }

  /// Name frozen by Kotlin (`MainActivity.PROGRESS_CHANNEL`).
  static const String channelName = 'com.theonly.grablytic/progress';

  /// Process-wide instance. Tests replace it with [resetInstance].
  static ProgressChannel instance = ProgressChannel();

  /// Drops the shared instance (and its subscription). Tests that install a
  /// mock stream handler use this so a previous test's sink cannot leak in.
  @visibleForTesting
  static void resetInstance() {
    final old = instance;
    instance = ProgressChannel();
    old._close();
  }

  final EventChannel _channel;
  late final StreamController<Map<String, dynamic>> _controller;
  StreamSubscription<dynamic>? _subscription;

  /// Decoded events, one copy each.
  Stream<Map<String, dynamic>> get events => _controller.stream;

  void _subscribe() {
    if (_subscription != null) return;
    _subscription = _channel.receiveBroadcastStream().listen(
      _onEvent,
      onError: _onError,
      cancelOnError: false,
    );
  }

  /// Called when a listener leaves. With no listeners left the native side
  /// is told to stop (`onCancel` on the Kotlin handler), so the next listen
  /// re-registers cleanly instead of leaving a sink attached to a dead
  /// controller.
  void _unsubscribeIfIdle() {
    if (_controller.hasListener) return;
    final subscription = _subscription;
    _subscription = null;
    subscription?.cancel();
  }

  void _onEvent(dynamic event) {
    final Map<String, dynamic>? decoded = _decode(event);
    if (decoded != null && !_controller.isClosed) _controller.add(decoded);
  }

  /// Forward errors instead of swallowing them: the download card used to
  /// sit at 0% on a dead bridge with nothing in the log to explain it.
  void _onError(Object error, StackTrace stackTrace) {
    if (!_controller.isClosed) _controller.addError(error, stackTrace);
  }

  static Map<String, dynamic>? _decode(dynamic event) {
    if (event is Map) return Map<String, dynamic>.from(event);
    if (event is! String) return null;
    try {
      final decoded = jsonDecode(event);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  void _close() {
    _subscription?.cancel();
    _subscription = null;
    if (!_controller.isClosed) _controller.close();
  }
}
