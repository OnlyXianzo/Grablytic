import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/engine_start_signal.dart';

/// #91: Home must never start the engine itself; it reacts to the start.
///
/// These pin the two properties the widgets rely on — one-shot, and
/// replayable to a late subscriber — because a missed event means the
/// interrupted-downloads card silently never scans.
void main() {
  tearDown(resetEngineStartSignal);

  test('nobody has started the engine at process start', () {
    expect(engineHasStarted, isFalse);
  });

  test('markEngineStarted flips the flag', () {
    markEngineStarted();
    expect(engineHasStarted, isTrue);
  });

  test('the first report reaches a listener', () async {
    final seen = <void>[];
    final sub = engineStarted.listen(seen.add);
    markEngineStarted();
    // Broadcast streams deliver on a microtask.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, hasLength(1));
  });

  test('later reports are ignored', () async {
    final seen = <void>[];
    markEngineStarted();
    final sub = engineStarted.listen(seen.add);
    markEngineStarted();
    markEngineStarted();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    // One replay for the late subscriber, not three.
    expect(seen, hasLength(1));
  });

  test('a subscriber that arrives after the start gets an event', () async {
    markEngineStarted();
    final future = engineStarted.first;
    await expectLater(future, completes);
  });

  test('resetEngineStartSignal forgets the start', () async {
    markEngineStarted();
    resetEngineStartSignal();
    expect(engineHasStarted, isFalse);

    var fired = false;
    final sub = engineStarted.listen((_) => fired = true);
    await Future<void>.delayed(Duration.zero);
    expect(fired, isFalse, reason: 'a fresh start must not replay an old one');

    markEngineStarted();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(fired, isTrue);
  });
}
