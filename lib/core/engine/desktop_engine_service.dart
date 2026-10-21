import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import '../utils/app_logger.dart';
import '../utils/crash_reports.dart';
import '../utils/trust_boundary.dart';
import 'engine_codec.dart';
import 'engine_contract.dart';
import 'engine_service.dart';
import 'engine_start_signal.dart';

const _uuid = Uuid();

/// Backoff before the next engine start after [consecutiveFailures]
/// abnormal exits: 1s, 2s, 4s, capped at 8s. Zero/negative → zero delay
/// so the normal first-start path is unaffected. Pure policy, unit-tested
/// without spawning processes.
@visibleForTesting
Duration desktopRestartBackoff(int consecutiveFailures) {
  if (consecutiveFailures <= 0) return Duration.zero;
  final shift = (consecutiveFailures - 1).clamp(0, 3);
  return Duration(seconds: 1 << shift);
}

/// Whether a stale last-exit timestamp should reset the crash counter.
/// Exits spaced further than [window] apart are independent incidents, not
/// a crash loop. Pure predicate, unit-tested.
@visibleForTesting
bool shouldResetCrashCounter({
  required DateTime? lastExitAt,
  required DateTime now,
  Duration window = const Duration(minutes: 5),
}) => lastExitAt == null || now.difference(lastExitAt) > window;

/// Per-method timeout budget. Slow network extractions
/// (formats/playlist/search) legitimately exceed the 30s fast budget; giving
/// them headroom stops false timeouts that desync Dart (pending dropped)
/// from the engine (still working). Cancel/queue-status stay tight so a
/// wedged extraction cannot mask a stuck cancel.
@visibleForTesting
Duration requestTimeoutForMethod(String method) {
  switch (method) {
    case EngineMethods.getFormats:
    case EngineMethods.playlistInfo:
    case EngineMethods.searchQuery:
      return const Duration(seconds: 90);
    default:
      // ignore: unnecessary_statements – single source is _requestTimeout
      return DesktopEngineService._requestTimeout;
  }
}

/// Fast lane. Cancel and queue-status bypass the serialized stdin
/// write queue so one slow formats/playlist extraction cannot hold them
/// hostage behind Dart's side of the pipe. Writes are synchronous
/// `IOSink.writeln` calls on Dart's single-threaded event loop, so bypassing
/// the queue cannot interleave bytes; responses correlate by id anyway.
@visibleForTesting
bool isFastLaneMethod(String method) =>
    method == EngineMethods.cancelDownload ||
    method == EngineMethods.queueStatus;

class DesktopEngineService implements EngineService {
  final String _pythonPath;
  final String? _workingDirectory;

  /// How long the engine may take to come up before a waiting request
  /// gives up. Far larger than any request budget: the first run may
  /// install yt-dlp (uv venv + uv pip install), which is minutes.
  static const Duration _startupBudget = Duration(minutes: 5);
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  String? _dataDir;

  final _pending = <String, Completer<Map<String, dynamic>>>{};

  /// Ids whose request already timed out. A late answer for one of these
  /// is expected; an answer for an id that is neither pending nor
  /// timed out is a protocol desync. Bounded so it cannot grow.
  final _timedOutIds = <String>{};

  void _rememberTimedOut(String id) {
    if (_timedOutIds.length > 64) _timedOutIds.clear();
    _timedOutIds.add(id);
  }
  final _progressController =
      StreamController<Map<String, dynamic>>.broadcast();

  bool _disposed = false;
  bool _running = false;
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 3;
  static const _requestTimeout = Duration(seconds: 30);

  /// Abnormal exits inside [_crashWindow] accumulate here. Unlike
  /// [_reconnectAttempts] (reset on every successful start), this is only
  /// reset by the time-window check in [_ensureRunning] — otherwise an
  /// engine that starts fine then dies instantly would loop forever.
  int _consecutiveAbnormalExits = 0;
  DateTime? _lastAbnormalExitAt;
  static const _crashWindow = Duration(minutes: 5);

  @visibleForTesting
  int get consecutiveAbnormalExits => _consecutiveAbnormalExits;

  DesktopEngineService({
    String pythonPath = 'python',
    String? workingDirectory,
    String? dataDir,
  }) : _pythonPath = pythonPath,
       _workingDirectory = workingDirectory,
       _dataDir = dataDir;

  @visibleForTesting
  void restart() => _restart();

  /// Crash reports filed for unexpected exits in this process.
  ///
  /// A crash-looping engine exits repeatedly, and the queue already
  /// collapses repeats by fingerprint — this cap is about not doing a log
  /// read and a file write on every restart of a hot loop.
  int _engineCrashReports = 0;
  static const int _maxEngineCrashReports = 3;

  @visibleForTesting
  Process? get process => _process;

  @visibleForTesting
  set processForTesting(Process? p) => _process = p;

  @visibleForTesting
  void attachProcessForTesting(Process p, {bool wireStreams = false}) {
    _process = p;
    _running = true;
    if (wireStreams) {
      _wireProcessStreams(p);
    }
    p.exitCode.then((code) {
      _running = false;
      if (_disposed || code == 0) return;
      // Capture even when the stream-close path already restarted: the
      // restart nulls `_process`, so a capture gated on that identity was
      // skipped exactly for the abnormal exits it exists for.
      _captureEngineExit(code);
      if (_process == p) _restart();
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      _stdoutSubscription?.cancel();
    } catch (_) {}
    try {
      _stderrSubscription?.cancel();
    } catch (_) {}
    _stdoutSubscription = null;
    _stderrSubscription = null;
    final oldProcess = _process;
    _process = null;
    _running = false;
    try {
      oldProcess?.kill();
    } catch (_) {}
    try {
      if (!_progressController.isClosed) _progressController.close();
    } catch (_) {}
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        // Complete with a failure RESULT, not an error: during provider
        // teardown the awaiting FutureProviders may already be gone, and an
        // unlistened error future fails widget tests and pollutes reports.
        // Every _sendRequest caller already handles success:false maps.
        try {
          completer.complete({
            'success': false,
            'error_type': 'ERROR_DISPOSED',
            'error_message': 'Engine disposed',
          });
        } catch (_) {}
      }
    }
    _pending.clear();
  }

  Future<String> _resolvePythonPath() async {
    String executable = _pythonPath;
    if (executable == 'python' || executable == 'python3') {
      // Only APP-OWNED roots. The old code probed
      // `Directory.current/engine/.venv/bin/python` — the process working
      // directory, which on Windows is the shortcut's "Start in" folder
      // and on Linux is whatever directory the launcher inherited. An
      // attacker who can drop a `python` binary into a folder the user
      // opens from (an extracted archive is the classic vector) got
      // code execution as the user, invisibly.
      final roots = <String>[
        File(Platform.resolvedExecutable).parent.path,
        ?_dataDir,
      ];
      final candidates = <String>[];
      for (final root in roots) {
        if (Platform.isWindows) {
          candidates
            ..add('$root\\engine\\.venv\\Scripts\\python.exe')
            ..add('$root\\.venv\\Scripts\\python.exe');
        } else {
          candidates
            ..add('$root/engine/.venv/bin/python')
            ..add('$root/.venv/bin/python');
        }
      }

      for (final path in candidates) {
        if (File(path).existsSync()) {
          return path;
        }
      }

      // Development only: an explicit environment variable, never the
      // working directory.
      if (kDebugMode) {
        final dev = Platform.environment['GRABLYTIC_PYTHON'];
        if (dev != null && dev.isNotEmpty && File(dev).existsSync()) {
          return dev;
        }
      }
    }

    if (executable == 'python' && (Platform.isLinux || Platform.isMacOS)) {
      try {
        final result = await Process.run('which', ['python3']);
        if (result.exitCode == 0 &&
            result.stdout.toString().trim().isNotEmpty) {
          return 'python3';
        }
      } catch (_) {
        return 'python3';
      }
    }

    return executable;
  }

  Future<void>? _startFuture;

  Future<void> _ensureRunning() async {
    if (_running && _process != null) return;
    if (_disposed) throw Exception('Engine disposed');
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      throw Exception(
        'Engine failed to start after $_maxReconnectAttempts attempts',
      );
    }
    // Crash-loop breaker: exits spaced wider than the window are
    // independent incidents; rapid ones accumulate and refuse to restart.
    if (shouldResetCrashCounter(
      lastExitAt: _lastAbnormalExitAt,
      now: DateTime.now(),
      window: _crashWindow,
    )) {
      _consecutiveAbnormalExits = 0;
    }
    if (_consecutiveAbnormalExits >= _maxReconnectAttempts) {
      throw Exception(
        'Engine crashed $_consecutiveAbnormalExits times in quick succession; refusing to restart',
      );
    }

    if (_startFuture != null) {
      await _startFuture;
      return;
    }

    _startFuture = _doEnsureRunning();
    try {
      await _startFuture;
    } finally {
      _startFuture = null;
    }
  }

  Future<void> _doEnsureRunning() async {
    _reconnectAttempts++;
    // Back off after abnormal exits so a crash-looping engine cannot
    // hot-spin process spawns. Zero crashes → zero delay (normal path).
    final backoff = desktopRestartBackoff(_consecutiveAbnormalExits);
    if (backoff > Duration.zero) await Future.delayed(backoff);

    final executable = await ensureDependencies(await _resolvePythonPath());

    // Set up PYTHONPATH environment variable to include the executable directory
    // and development paths so python can always find 'grablytic_engine'.
    final env = Map<String, String>.from(Platform.environment);
    final pythonPaths = <String>[];

    // Add directory containing the app executable (production bundle path)
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    pythonPaths.add(executableDir);

    // Add development directory paths
    final currentDir = Directory.current.path;
    pythonPaths.add('$currentDir/engine');
    pythonPaths.add('$currentDir/Project-Grablytic/engine');

    if (env.containsKey('PYTHONPATH')) {
      pythonPaths.add(env['PYTHONPATH']!);
    }

    env['PYTHONPATH'] = pythonPaths.join(Platform.isWindows ? ';' : ':');

    _process = await Process.start(
      executable,
      ['-m', 'grablytic_engine'],
      workingDirectory: _workingDirectory,
      environment: env,
      runInShell: false,
    );

    _wireProcessStreams(_process!);

    final currentProcess = _process!;
    currentProcess.exitCode.then((code) {
      _running = false;
      if (_disposed || code == 0) return;
      _captureEngineExit(code);
      if (_process == currentProcess) _restart();
    });

    _running = true;
    _reconnectAttempts = 0;
    // Desktop equivalent of the Android "paths applied" signal (#91): the
    // interpreter is up, so Home's resume scan and status banner may run.
    markEngineStarted();
  }

  void _wireProcessStreams(Process process) {
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Engine stdout error: $error',
              tag: 'engine',
              error: error,
              stackTrace: stackTrace,
            );
            _running = false;
            if (!_disposed && _process == process) {
              _restart();
            }
          },
          onDone: () {
            AppLogger.info('Engine stdout stream closed', tag: 'engine');
            _running = false;
            if (!_disposed && _process == process) {
              _restart();
            }
          },
          cancelOnError: true,
        );

    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            AppLogger.warn(line, tag: 'engine-stderr');
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.warn('Engine stderr error: $error', tag: 'engine-stderr');
          },
          cancelOnError: false,
        );
  }

  void _restart() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    final oldProcess = _process;
    _process = null;
    _running = false;
    oldProcess?.kill();
    // Count the abnormal exit for the crash-loop breaker in
    // [_ensureRunning]. Deliberately NOT reset on next successful start —
    // only the time-window check resets it (see _ensureRunning).
    _consecutiveAbnormalExits++;
    _lastAbnormalExitAt = DateTime.now();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Engine process exited'));
      }
    }
    _pending.clear();
  }

  /// Queues a report for an engine process that died with [exitCode].
  ///
  /// Fire-and-forget: `_restart` is the recovery path and a disk write must
  /// never delay bringing the engine back. The log tail carries the Python
  /// traceback, because engine stderr is forwarded to the app log.
  void _captureEngineExit(int exitCode) {
    if (_engineCrashReports >= _maxEngineCrashReports) return;
    final reports = CrashReports.instance;
    if (reports == null) return;
    _engineCrashReports++;
    unawaited(
      reports
          .capture(EngineExitError(exitCode), null)
          .catchError((Object _) => null),
    );
  }

  void _handleLine(String line) {
    try {
      final data = jsonDecode(line) as Map<String, dynamic>;

      if (data['type'] == 'event') {
        if (!_progressController.isClosed) {
          try {
            _progressController.add(data);
          } catch (_) {
            // StreamSink may be in bad state after engine restart
          }
        }
        return;
      }

      if (data['type'] == 'log') {
        if (!_progressController.isClosed) {
          try {
            _progressController.add(data);
          } catch (_) {
            // StreamSink may be in bad state after engine restart
          }
        }
        return;
      }

      final id = data['id'] as String?;
      if (id == null) {
        AppLogger.warn(
          'Engine response without an id: protocol desync',
          tag: 'engine',
        );
        return;
      }
      if (!_pending.containsKey(id)) {
        // A response for an id we are not waiting for. Either it is the
        // late answer to a request that already timed out (harmless) or
        // the engine answered with an id we never sent (a real desync).
        // The old code dropped both silently, so a desync was invisible
        // until a download mysteriously never started.
        if (_timedOutIds.remove(id)) {
          AppLogger.info(
            'Late engine response for the timed-out request $id',
            tag: 'engine',
          );
        } else {
          AppLogger.warn(
            'Unknown engine response id $id: protocol desync',
            tag: 'engine',
          );
        }
        return;
      }

      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;

      if (data.containsKey('error')) {
        final error = data['error'] as Map<String, dynamic>;
        completer.completeError(
          Exception(error['error_message'] ?? 'Unknown error'),
        );
      } else {
        final result = data['result'];
        if (result is Map) {
          completer.complete(Map<String, dynamic>.from(result));
        } else {
          // A malformed result used to become `{}`, which every caller
          // read as "no success, no reason". Report it as a protocol
          // error instead of a silent empty answer.
          AppLogger.warn(
            'Malformed engine result for request $id',
            tag: 'engine',
          );
          completer.complete(
            EngineEnvelope.error(
              errorType: 'ERROR_PROTOCOL',
              message: 'Malformed engine result',
            ),
          );
        }
      }
    } catch (e) {
      // Malformed engine stdout lines used to vanish. Protocol
      // violations are engine bugs — surface them (truncated) instead.
      final preview = line.length > 200 ? '${line.substring(0, 200)}…' : line;
      AppLogger.warn(
        'Engine protocol: unparseable stdout line: $preview',
        tag: 'engine',
      );
    }
  }

  Future<bool> _hasYtDlp(String pythonPath) async {
    try {
      final result = await Process.run(pythonPath, [
        '-m',
        'yt_dlp',
        '--version',
      ]).timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _findUv() async {
    if (_dataDir != null) {
      final uvCandidate = Platform.isWindows
          ? '$_dataDir\\bin\\uv.exe'
          : '$_dataDir/bin/uv';
      if (File(uvCandidate).existsSync()) return uvCandidate;
    }
    final uvName = Platform.isWindows ? 'uv.exe' : 'uv';
    final whichCmd = Platform.isWindows ? 'where' : 'which';
    final whichResult = await Process.run(whichCmd, [uvName]);
    if (whichResult.exitCode == 0) {
      return whichResult.stdout.toString().trim().split('\n').first.trim();
    }
    return null;
  }

  Future<String> _installYtDlpViaUv(String uvPath) async {
    final venvDir = _dataDir != null
        ? '$_dataDir/venv'
        : '${Directory.systemTemp.path}/grablytic-venv';
    final venvPython = Platform.isWindows
        ? '$venvDir\\Scripts\\python.exe'
        : '$venvDir/bin/python';

    AppLogger.info('Creating uv venv at $venvDir...', tag: 'engine-deps');
    var result = await Process.run(uvPath, [
      'venv',
      venvDir,
    ]).timeout(const Duration(seconds: 60));

    if (result.exitCode != 0) {
      AppLogger.warn('uv venv failed: ${result.stderr}', tag: 'engine-deps');
    }

    AppLogger.info(
      'Installing yt-dlp ${EngineContract.ytDlpVersion} into venv...',
      tag: 'engine-deps',
    );
    // Hash-locked, not just version-locked (#18). The requirement goes
    // through a temporary file because `--hash` is only accepted in a
    // requirements file, and `--require-hashes` makes uv refuse anything
    // whose digest is not listed. `--no-deps` keeps the lock consistent:
    // yt-dlp has no runtime dependency we would otherwise have to hash.
    final reqFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'grablytic-ytdlp-requirements.txt',
    );
    try {
      await reqFile.writeAsString(EngineContract.ytDlpHashedRequirement);
      result = await Process.run(uvPath, [
        'pip',
        'install',
        '--require-hashes',
        '--no-deps',
        '-r',
        reqFile.path,
      ], workingDirectory: venvDir).timeout(const Duration(seconds: 120));
    } finally {
      try {
        if (await reqFile.exists()) await reqFile.delete();
      } on FileSystemException {
        // A leftover temp file is not a reason to fail the install.
      }
    }

    if (result.exitCode != 0) {
      throw Exception('Failed to install yt-dlp: ${result.stderr}');
    }

    return venvPython;
  }

  /// Ensures yt-dlp is available. Returns the Python path to use (system
  /// or venv). If a venv was created, its Python is returned.
  Future<String> ensureDependencies(String pythonPath) async {
    if (await _hasYtDlp(pythonPath)) return pythonPath;

    // The version is PINNED. Installing "latest" from PyPI at runtime
    // means a breaking upstream release changes the engine's behaviour
    // with no review, and a compromised package would run with the
    // user's privileges. A pinned version is reproducible; the pinned
    // value is bumped deliberately, in a release.
    final uvPath = await _findUv();
    if (uvPath == null) {
      throw Exception(
        'yt-dlp ${EngineContract.ytDlpVersion} is required but uv was not found. '
        'Run the bootstrap process first.',
      );
    }

    AppLogger.info(
      'Installing yt-dlp ${EngineContract.ytDlpVersion} via uv...',
      tag: 'engine-deps',
    );
    final venvPython = await _installYtDlpViaUv(uvPath);

    if (!await _hasYtDlp(venvPython)) {
      throw Exception('yt-dlp installation completed but verification failed.');
    }

    AppLogger.info('yt-dlp ready via venv: $venvPython', tag: 'engine-deps');
    return venvPython;
  }

  Future<void>? _requestQueue;

  Future<Map<String, dynamic>> _sendRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    final id = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final request = EngineEnvelope.encodeRequest(
      id: id,
      method: method,
      params: {
        ...params,
        // Every request states which contract it speaks. The engine
        // refuses a mismatched MAJOR version instead of half-understanding
        // the request.
        'contract_version': EngineContract.version,
      },
    );

    // An error that completes the completer BEFORE the caller attaches
    // its listener would escape to the zone: main.dart logs an uncaught
    // zone error as FATAL, and the opt-in GitHub auto-report could fire
    // for an ordinary timeout. Mark the future as handled here; the
    // caller still gets the error through the chain returned below.
    completer.future.ignore();

    // The budget covers the exchange (the queue wait, the write and the
    // answer) but NOT the start-up. The first run may have to install
    // yt-dlp (uv venv + uv pip install), which takes minutes; arming
    // the request timer before that made every first-run request time
    // out even though the engine came up a moment later. The start-up
    // gets its own, much larger, watchdog below.
    final timeoutBudget = requestTimeoutForMethod(method);
    Timer? timeout;
    void armTimeout() {
      timeout ??= Timer(timeoutBudget, () {
        if (!completer.isCompleted) {
          _pending.remove(id);
          _rememberTimedOut(id);
          completer.completeError(Exception('Request $method timed out'));
        }
      });
    }

    // A start-up that never finishes (a wedged uv, a pipe that stays
    // open) must not leave the request pending for ever either. The
    // watchdog is deliberately far larger than the request budget: it
    // only fires when the engine never came up at all.
    final startupWatchdog = Timer(_startupBudget, () {
      if (!completer.isCompleted) {
        _pending.remove(id);
        completer.completeError(
          Exception(
            'Engine did not start within ${_startupBudget.inSeconds}s',
          ),
        );
      }
    });

    // The engine must be UP before the request budget starts.
    try {
      await _ensureRunning();
    } catch (e) {
      startupWatchdog.cancel();
      _pending.remove(id);
      if (!completer.isCompleted) completer.completeError(e);
      rethrow;
    }
    startupWatchdog.cancel();
    armTimeout();

    Future<void> writeRequest() async {
      final proc = _process;
      if (proc == null) throw StateError('engine process died before write');
      proc.stdin.writeln(request);
      proc.stdin.flush();
    }

    if (isFastLaneMethod(method)) {
      // Fast lane: never wait behind a queued slow extraction's write.
      try {
        await writeRequest();
      } catch (e) {
        // Do not leak the pending entry on a dead transport; the timer
        // would otherwise fire on a zombie id and desync by id.
        _pending.remove(id);
        timeout?.cancel();
        if (!completer.isCompleted) completer.completeError(e);
        rethrow;
      }
    } else {
      final previousQueue = _requestQueue;
      final currentTask = () async {
        if (previousQueue != null) {
          try {
            await previousQueue;
          } catch (_) {}
        }
        await writeRequest();
      }();
      _requestQueue = currentTask;

      try {
        await currentTask;
      } catch (e) {
        _pending.remove(id);
        timeout?.cancel();
        if (!completer.isCompleted) completer.completeError(e);
        rethrow;
      }
    }

    return completer.future
        .then((result) {
          timeout?.cancel();
          return result;
        })
        .catchError((error) {
          timeout?.cancel();
          throw error;
        });
  }

  @override
  Future<Map<String, dynamic>> bootstrap() async {
    final result = await _sendRequest(EngineMethods.bootstrap, {});
    EngineContract.assertCompatible(result);
    return result;
  }

  @override
  Future<void> setPaths(Map<String, dynamic> paths) async {
    _dataDir = paths['data_dir'] as String?;
    await _sendRequest(EngineMethods.setPaths, paths);
  }

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    return _sendRequest(EngineMethods.startDownload, {
      'url': url,
      'download_id': downloadId,
      'config': config,
      'network_type': networkType,
    });
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) async {
    return _sendRequest(EngineMethods.cancelDownload, {
      'download_id': downloadId,
    });
  }

  @override
  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  @override
  Stream<Map<String, dynamic>> get logStream =>
      _progressController.stream.where((data) => data['type'] == 'log');

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return _sendRequest(EngineMethods.getFormats, {
      'url': url,
      'config': config,
    });
  }

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return _sendRequest(EngineMethods.playlistInfo, {
      'url': url,
      'config': config,
    });
  }

  @override
  Future<Map<String, dynamic>> search({
    required String query,
    String site = 'youtube',
    int limit = 20,
    required Map<String, dynamic> config,
  }) async {
    return _sendRequest(EngineMethods.searchQuery, {
      'query': query,
      'site': site,
      'limit': limit,
      'config': config,
    });
  }

  @override
  Future<String?> getSharedUrl() => Future.value(null);

  @override
  Stream<String> get sharedUrlStream => const Stream.empty();

  @override
  Future<Map<String, dynamic>> scanResumeCandidates({
    required String cacheDir,
  }) async {
    return _sendRequest(EngineMethods.scanResume, {'cache_dir': cacheDir});
  }

  @override
  Future<Map<String, dynamic>> reportResumeAttempt({
    required String cacheDir,
    required String filepath,
    required bool success,
  }) async {
    try {
      return await _sendRequest(EngineMethods.resumeReport, {
        'cache_dir': cacheDir,
        'filepath': filepath,
        'success': success,
      });
    } catch (_) {
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Engine request failed',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> updateCheck() async {
    return _sendRequest(EngineMethods.updateCheck, {});
  }

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) async {
    return _sendRequest(EngineMethods.setUpdateChannel, {'channel': channel});
  }

  @override
  Future<Map<String, dynamic>> exportLogToDownloads({
    required String sourcePath,
    required String displayName,
  }) async {
    // Desktop has direct filesystem access: plain copy into
    // ~/Downloads/Grablytic-logs/. Never throws (contract).
    try {
      final src = File(sourcePath);
      if (!await src.exists()) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'Log file not found',
        );
      }
      Directory base;
      try {
        // path_provider is intentionally NOT imported here to keep the
        // engine layer free of plugin channels; resolve Downloads manually.
        final home =
            Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '.';
        base = Directory('$home/Downloads/Grablytic-logs');
      } catch (_) {
        return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT',
          message: 'Could not resolve Downloads folder',
        );
      }
      await base.create(recursive: true);
      final safeName = sanitizeExportFileName(displayName);
      var dest = File('${base.path}/$safeName');
      var n = 1;
      while (await dest.exists()) {
        n++;
        dest = File('${base.path}/$safeName-$n');
      }
      await src.copy(dest.path);
      return {'success': true, 'path': dest.path};
    } catch (_) {
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Engine request failed',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() async =>
      EngineEnvelope.error(
        errorType: 'ERROR_UNSUPPORTED',
        message: 'Not supported on this platform',
        extra: {'supported': false},
      );

  @override
  Future<Map<String, dynamic>> networkMeteredStatus() async {
    // No metered API via connectivity_plus: transport heuristic.
    // Fail closed (metered) on errors — prompt, don't silently spend.
    try {
      final results = await Connectivity().checkConnectivity();
      final unmetered =
          results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
      return {'success': true, 'supported': true, 'metered': !unmetered};
    } catch (_) {
      return {'success': true, 'supported': true, 'metered': true};
    }
  }

  @override
  Future<Map<String, dynamic>> requestBatteryExemption() async =>
      EngineEnvelope.error(
        errorType: 'ERROR_UNSUPPORTED',
        message: 'Not supported on this platform',
        extra: {'supported': false},
      );

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() async =>
      EngineEnvelope.error(
        errorType: 'ERROR_UNSUPPORTED',
        message: 'Not supported on this platform',
        extra: {'supported': false},
      );

  @override
  Future<Map<String, dynamic>> requestNotificationPermission() async =>
      EngineEnvelope.error(
        errorType: 'ERROR_UNSUPPORTED',
        message: 'Not supported on this platform',
        extra: {'supported': false},
      );

  @override
  Future<Map<String, dynamic>> queueStatus() async {
    try {
      return await _sendRequest(EngineMethods.queueStatus, {});
    } catch (_) {
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Engine request failed',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> setConcurrency(int maxConcurrent) async {
    try {
      return await _sendRequest(EngineMethods.setConcurrency, {
        'max_concurrent': maxConcurrent,
      });
    } catch (_) {
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Engine request failed',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> clearArchive() async {
    try {
      return await _sendRequest(EngineMethods.clearArchive, {});
    } catch (_) {
      return EngineEnvelope.error(
        errorType: 'ERROR_TRANSPORT',
        message: 'Engine request failed',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> openNotificationSettings() async =>
      EngineEnvelope.error(
        errorType: 'ERROR_UNSUPPORTED',
        message: 'Not supported on this platform',
        extra: {'supported': false},
      );

  @override
  Future<Map<String, dynamic>> openUrl(String url) async {
    // Only hand web links to the user's configured browser. Process arguments
    // are passed without a shell so issue text cannot become shell syntax.
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      return EngineEnvelope.error(
        errorType: 'ERROR_INVALID_ARGUMENT',
        message: 'Only GitHub HTTPS links can be opened',
      );
    }
    try {
      final os = Platform.operatingSystem;
      if (os == 'linux') {
        await Process.start('xdg-open', [uri.toString()], mode: ProcessStartMode.detached);
      } else if (os == 'macos') {
        await Process.start('open', [uri.toString()], mode: ProcessStartMode.detached);
      } else if (os == 'windows') {
        await Process.start('rundll32.exe', ['url.dll,FileProtocolHandler', uri.toString()], mode: ProcessStartMode.detached);
      } else {
        return EngineEnvelope.error(errorType: 'ERROR_UNSUPPORTED', message: 'Not supported on this platform');
      }
      return {'success': true};
    } on ProcessException catch (e) {
      AppLogger.warn('Could not open the browser: $e', tag: 'engine');
      return EngineEnvelope.error(errorType: 'ERROR_TRANSPORT', message: 'Could not open the browser');
    }
  }

  @override
  Future<Map<String, dynamic>> openFile(String path) async {
    // Desktop opens via the OS resolver; never throws — UI falls back to
    // showing the path when no handler exists.
    try {
      final os = Platform.operatingSystem;
      if (os == 'linux') {
        await Process.run('xdg-open', [path]);
      } else if (os == 'macos') {
        await Process.run('open', [path]);
      } else if (os == 'windows') {
        await Process.run('explorer', [path]);
      } else {
        return EngineEnvelope.error(
          errorType: 'ERROR_UNSUPPORTED',
          message: 'Not supported on this platform',
          extra: {'supported': false},
        );
      }
      return {'success': true};
    } catch (e) {
      return EngineEnvelope.error(
        errorType: 'ERROR_OPEN_FAILED',
        message: 'Could not open file: $e',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> syncSchedule({
    required bool enabled,
    int intervalMinutes = 60,
    bool wifiOnly = true,
    bool requiresCharging = false,
  }) async => {'success': true, 'supported': false};

  @override
  Future<Map<String, dynamic>> syncQueueReminder({
    required bool enabled,
    int intervalMinutes = 180,
  }) async => {'success': true, 'supported': false};

  @override
  Future<void> showErrorNotification({
    required String downloadId,
    required String title,
    required String error,
  }) async {}

  /// Completes without posting a notification; desktop support is unavailable.
  @override
  Future<void> showSuccessNotification({
    required String downloadId,
    required String title,
    required String message,
  }) async {}
}


