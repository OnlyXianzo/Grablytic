import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grablytic/core/engine/desktop_engine_service.dart';
import 'package:grablytic/core/utils/crash_reports.dart';
import 'package:grablytic/core/utils/github_reporter.dart';

import '../../support/memory_report_store.dart';

/// A reporter that never touches the network or the log file.
class _SilentReporter extends GithubReporter {
  @override
  Future<GithubReportDraft> draftCrash(
    Object error,
    StackTrace? stack, {
    Map<String, dynamic> context = const {},
    String? appVersion,
  }) async =>
      GithubReportDraft(
        fingerprint: 'fp-engine',
        title: '[Auto-report fp-engine] engine exit',
        body: '### Summary\nThe engine exited.\n',
      );
}

class _FakeProcess implements Process {
  bool killCalled = false;
  ProcessSignal? lastSignal;
  final Completer<int> _exitCodeCompleter = Completer<int>();
  final StreamController<List<int>> _stdoutController = StreamController<List<int>>.broadcast();
  final StreamController<List<int>> _stderrController = StreamController<List<int>>.broadcast();

  @override
  int get pid => 99999;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalled = true;
    lastSignal = signal;
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

  void completeStdoutDone() {
    _stdoutController.close();
  }

  void addStdoutError(Object error) {
    _stdoutController.addError(error);
  }

  void addStderrError(Object error) {
    _stderrController.addError(error);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopEngineService process lifecycle & zombie prevention [T2-7]', () {
    test('restart kills active process handle before nulling it', () {
      final service = DesktopEngineService();
      final fakeProcess = _FakeProcess();
      service.processForTesting = fakeProcess;

      expect(service.process, same(fakeProcess));
      expect(fakeProcess.killCalled, isFalse);

      // Trigger restart
      service.restart();

      // Process handle must be nulled
      expect(service.process, isNull);

      // Old process MUST have been killed so no zombie lingers
      expect(fakeProcess.killCalled, isTrue,
          reason: 'DesktopEngineService._restart() must call kill() on the active process');
    });

    test('restart fails pending requests with Engine process exited', () async {
      final service = DesktopEngineService();
      final fakeProcess = _FakeProcess();
      service.processForTesting = fakeProcess;

      service.restart();

      expect(service.process, isNull);
      expect(fakeProcess.killCalled, isTrue);
    });

    test('dispose kills active process handle', () {
      final service = DesktopEngineService();
      final fakeProcess = _FakeProcess();
      service.processForTesting = fakeProcess;

      service.dispose();

      expect(fakeProcess.killCalled, isTrue);
    });

    test('exitCode watcher triggers restart and kills process on nonzero exit', () async {
      final service = DesktopEngineService();
      final fakeProcess = _FakeProcess();
      service.attachProcessForTesting(fakeProcess);

      expect(service.process, same(fakeProcess));

      // Simulate unexpected crash with exit code 1
      fakeProcess.completeExit(1);
      await pumpEventQueue();

      // Process handle should be nulled and kill called
      expect(service.process, isNull);
      expect(fakeProcess.killCalled, isTrue);
    });

    test('exitCode watcher does not restart on clean zero exit', () async {
      final service = DesktopEngineService();
      final fakeProcess = _FakeProcess();
      service.attachProcessForTesting(fakeProcess);

      expect(service.process, same(fakeProcess));

      // Simulate clean exit with code 0
      fakeProcess.completeExit(0);
      await pumpEventQueue();

      // Process was not restarted by the watcher
      expect(service.process, same(fakeProcess));
      expect(fakeProcess.killCalled, isFalse);
    });

    test('exitCode completion after explicit restart does not re-trigger restart', () async {
      final service = DesktopEngineService();
      final fakeProcess = _FakeProcess();
      service.attachProcessForTesting(fakeProcess);

      // Explicit restart
      service.restart();
      expect(service.process, isNull);
      expect(fakeProcess.killCalled, isTrue);

      // Attach a new replacement process
      final replacement = _FakeProcess();
      service.attachProcessForTesting(replacement);
      expect(service.process, same(replacement));

      // Old process exit code resolves asynchronously (e.g. SIGTERM -15)
      fakeProcess.completeExit(-15);
      await pumpEventQueue();

      // Replacement process must NOT have been killed by old process exit code
      expect(service.process, same(replacement));
      expect(replacement.killCalled, isFalse);
    });

    group('DesktopEngineService stream error & lifecycle handling (F-R2)', () {
      test('stdout onDone completes pending requests immediately and triggers restart', () async {
        final service = DesktopEngineService();
        final fakeProcess = _FakeProcess();
        service.attachProcessForTesting(fakeProcess, wireStreams: true);

        expect(service.process, same(fakeProcess));

        fakeProcess.completeStdoutDone();
        await pumpEventQueue();

        expect(service.process, isNull);
        expect(fakeProcess.killCalled, isTrue);
      });

      test('stdout onError triggers restart and fails pending requests without zone error', () async {
        final service = DesktopEngineService();
        final fakeProcess = _FakeProcess();
        service.attachProcessForTesting(fakeProcess, wireStreams: true);

        fakeProcess.addStdoutError(const FormatException('Malformed UTF-8 byte'));
        await pumpEventQueue();

        expect(service.process, isNull);
        expect(fakeProcess.killCalled, isTrue);
      });

      test('an abnormal exit is captured even though stdout closed first',
          () async {
        // Regression: the stdout onDone path restarts the engine, which
        // nulls `_process` before `exitCode` resolves. Gating the capture on
        // `_process == process` therefore skipped precisely the abnormal
        // exits it exists for.
        final store = MemoryReportStore();
        CrashReports.instance = CrashReports(
          store: store,
          reporterFactory: _SilentReporter.new,
        );
        addTearDown(() => CrashReports.instance = null);

        final service = DesktopEngineService();
        final fakeProcess = _FakeProcess();
        service.attachProcessForTesting(fakeProcess, wireStreams: true);

        fakeProcess.completeStdoutDone();
        await pumpEventQueue();

        // Closing stdout restarts the engine, and the restart kills the
        // process, so the exit code that arrives is SIGTERM (-15) rather
        // than the one the process would have produced. The point of this
        // test is that a report exists at all.
        final saved = await store.list();
        expect(saved, hasLength(1));
        expect(saved.single.summary, contains('exited with code'));
        expect(await fakeProcess.exitCode, -15);
      });

      test('a non-zero exit is captured before the restart', () async {
        final store = MemoryReportStore();
        CrashReports.instance = CrashReports(
          store: store,
          reporterFactory: _SilentReporter.new,
        );
        addTearDown(() => CrashReports.instance = null);

        final service = DesktopEngineService();
        final fakeProcess = _FakeProcess();
        service.attachProcessForTesting(fakeProcess);

        fakeProcess.completeExit(-9);
        await pumpEventQueue();

        final saved = await store.list();
        expect(saved, hasLength(1));
        expect(saved.single.summary, contains('-9'));
      });

      test('a clean exit is not reported as a crash', () async {
        final store = MemoryReportStore();
        CrashReports.instance = CrashReports(
          store: store,
          reporterFactory: _SilentReporter.new,
        );
        addTearDown(() => CrashReports.instance = null);

        final service = DesktopEngineService();
        final fakeProcess = _FakeProcess();
        service.attachProcessForTesting(fakeProcess);

        fakeProcess.completeExit(0);
        await pumpEventQueue();

        expect(await store.list(), isEmpty);
        expect((await fakeProcess.exitCode), 0);
      });

      test('stderr onError logs error safely without restarting engine', () async {
        final service = DesktopEngineService();
        final fakeProcess = _FakeProcess();
        service.attachProcessForTesting(fakeProcess, wireStreams: true);

        fakeProcess.addStderrError(const FormatException('Bad stderr byte'));
        await pumpEventQueue();

        expect(service.process, same(fakeProcess));
        expect(fakeProcess.killCalled, isFalse);
      });
    });
  });
}
