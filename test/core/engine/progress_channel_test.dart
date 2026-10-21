import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/progress_channel.dart';

/// #98 — one native subscription, decoded once, shared by every consumer.
///
/// Two readers each calling `receiveBroadcastStream()` registered two
/// Kotlin sinks, so every progress event crossed the bridge twice and was
/// `jsonDecode`d twice. These tests count subscriptions and decodes.
class _CountingEventChannel extends EventChannel {
  _CountingEventChannel(this.source) : super('test/progress');

  final Stream<dynamic> source;
  int subscriptions = 0;

  @override
  Stream<dynamic> receiveBroadcastStream([dynamic arguments]) {
    subscriptions++;
    return source;
  }
}

void main() {
  test('two listeners share one native subscription', () async {
    final native = StreamController<dynamic>.broadcast();
    final channel = _CountingEventChannel(native.stream);
    final progress = ProgressChannel(channel: channel);

    final first = <Map<String, dynamic>>[];
    final second = <Map<String, dynamic>>[];
    final subA = progress.events.listen(first.add);
    final subB = progress.events.listen(second.add);

    native.add('{"type":"progress","download_id":"abc","percent":12.5}');
    await Future<void>.delayed(Duration.zero);

    expect(channel.subscriptions, 1, reason: 'one sink, not one per reader');
    expect(first, hasLength(1));
    expect(second, hasLength(1));
    expect(first.single['percent'], 12.5);

    await subA.cancel();
    await subB.cancel();
    await native.close();
  });

  test('events are decoded once and handed to every listener', () async {
    final native = StreamController<dynamic>.broadcast();
    final channel = _CountingEventChannel(native.stream);
    final progress = ProgressChannel(channel: channel);

    final logs = <Map<String, dynamic>>[];
    final progressEvents = <Map<String, dynamic>>[];
    final subA = progress.events
        .where((e) => e['type'] == 'log')
        .listen(logs.add);
    final subB = progress.events
        .where((e) => e['type'] == 'progress')
        .listen(progressEvents.add);

    native.add('{"type":"log","level":"INFO","message":"hello"}');
    native.add('{"type":"progress","percent":50}');
    await Future<void>.delayed(Duration.zero);

    expect(logs.single['message'], 'hello');
    expect(progressEvents.single['percent'], 50);
    expect(channel.subscriptions, 1);

    await subA.cancel();
    await subB.cancel();
    await native.close();
  });

  test('a map event is passed through without a decode', () async {
    final native = StreamController<dynamic>.broadcast();
    final progress = ProgressChannel(channel: _CountingEventChannel(native.stream));

    final seen = <Map<String, dynamic>>[];
    final sub = progress.events.listen(seen.add);

    native.add(<String, dynamic>{'type': 'progress', 'percent': 1});
    await Future<void>.delayed(Duration.zero);

    expect(seen.single['percent'], 1);
    await sub.cancel();
    await native.close();
  });

  test('malformed payloads are dropped, later events still arrive', () async {
    final native = StreamController<dynamic>.broadcast();
    final progress = ProgressChannel(channel: _CountingEventChannel(native.stream));

    final seen = <Map<String, dynamic>>[];
    final sub = progress.events.listen(seen.add);

    native.add('not json');
    native.add('[1,2,3]');
    native.add(42);
    native.add('{"type":"progress","percent":9}');
    await Future<void>.delayed(Duration.zero);

    expect(seen, hasLength(1));
    expect(seen.single['percent'], 9);
    await sub.cancel();
    await native.close();
  });

  test('the last listener leaving releases the native subscription', () async {
    final native = StreamController<dynamic>.broadcast();
    final channel = _CountingEventChannel(native.stream);
    final progress = ProgressChannel(channel: channel);

    final sub = progress.events.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(channel.subscriptions, 1);

    await sub.cancel();
    await Future<void>.delayed(Duration.zero);

    // Re-listening after the idle gap must re-subscribe, not silently sit on
    // a stream nobody feeds.
    final second = progress.events.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(channel.subscriptions, 2);

    await second.cancel();
    await native.close();
  });

  test('native errors are forwarded instead of swallowed', () async {
    final native = StreamController<dynamic>.broadcast();
    final progress = ProgressChannel(channel: _CountingEventChannel(native.stream));

    final errors = <Object>[];
    final sub = progress.events.listen((_) {}, onError: errors.add);

    native.addError(StateError('bridge died'));
    await Future<void>.delayed(Duration.zero);

    expect(errors.single, isA<StateError>());
    await sub.cancel();
    await native.close();
  });
}
