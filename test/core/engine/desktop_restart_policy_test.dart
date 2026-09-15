import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/desktop_engine_service.dart';

class _FakeProcess implements Process {
  final Completer<int> _exitCodeCompleter = Completer<int>();

  @override
  int get pid => 99998;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(-15);
    }
    return true;
  }

  void completeExit(int code) {
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(code);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('desktopRestartBackoff policy [TEARDOWN-2]', () {
    test('zero failures means zero delay (normal start unaffected)', () {
      expect(desktopRestartBackoff(0), Duration.zero);
    });

    test('exponential backoff 1s/2s/4s then capped at 8s', () {
      expect(desktopRestartBackoff(1), const Duration(seconds: 1));
      expect(desktopRestartBackoff(2), const Duration(seconds: 2));
      expect(desktopRestartBackoff(3), const Duration(seconds: 4));
      expect(desktopRestartBackoff(4), const Duration(seconds: 8));
      expect(desktopRestartBackoff(99), const Duration(seconds: 8));
    });

    test('negative input is treated as no backoff', () {
      expect(desktopRestartBackoff(-1), Duration.zero);
    });
  });

  group('shouldResetCrashCounter window [TEARDOWN-2]', () {
    final now = DateTime(2026, 9, 15, 12, 0, 0);

    test('no prior exit resets the counter', () {
      expect(shouldResetCrashCounter(lastExitAt: null, now: now), isTrue);
    });

    test('recent exit inside the window keeps the counter', () {
      expect(
        shouldResetCrashCounter(
            lastExitAt: now.subtract(const Duration(minutes: 4, seconds: 59)),
            now: now),
        isFalse,
      );
    });

    test('stale exit beyond the window resets the counter', () {
      expect(
        shouldResetCrashCounter(
            lastExitAt: now.subtract(const Duration(minutes: 5, seconds: 1)),
            now: now),
        isTrue,
      );
    });
  });

  group('abnormal-exit counting through the real watcher [TEARDOWN-2]', () {
    test('three rapid crashes accumulate to the cap', () async {
      final service = DesktopEngineService();
      expect(service.consecutiveAbnormalExits, 0);

      for (var i = 0; i < 3; i++) {
        final proc = _FakeProcess();
        service.attachProcessForTesting(proc);
        proc.completeExit(1);
        await pumpEventQueue();
      }

      expect(service.consecutiveAbnormalExits, 3);
      service.dispose();
    });

    test('clean exits never increment the counter', () async {
      final service = DesktopEngineService();
      final proc = _FakeProcess();
      service.attachProcessForTesting(proc);
      proc.completeExit(0);
      await pumpEventQueue();

      expect(service.consecutiveAbnormalExits, 0);
      service.dispose();
    });
  });
}
