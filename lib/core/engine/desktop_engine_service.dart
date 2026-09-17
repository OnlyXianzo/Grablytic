import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import '../utils/app_logger.dart';
import '../utils/trust_boundary.dart';
import 'engine_codec.dart';
import 'engine_service.dart';

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
}) =>
    lastExitAt == null || now.difference(lastExitAt) > window;

class DesktopEngineService implements EngineService {
  final String _pythonPath;
  final String? _workingDirectory;
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  String? _dataDir;

  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _progressController = StreamController<Map<String, dynamic>>.broadcast();

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
  })  : _pythonPath = pythonPath,
        _workingDirectory = workingDirectory,
        _dataDir = dataDir;

  @visibleForTesting
  void restart() => _restart();

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
      if (!_disposed && code != 0 && _process == p) {
        _restart();
      }
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
      final venvCandidates = Platform.isWindows
          ? [
              '${Directory.current.path}/engine/.venv/Scripts/python.exe',
              '${Directory.current.path}/.venv/Scripts/python.exe',
            ]
          : [
              '${Directory.current.path}/engine/.venv/bin/python',
              '${Directory.current.path}/.venv/bin/python',
            ];

      for (final path in venvCandidates) {
        if (File(path).existsSync()) {
          return path;
        }
      }
    }

    if (executable == 'python' && (Platform.isLinux || Platform.isMacOS)) {
      try {
        final result = await Process.run('which', ['python3']);
        if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
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
      throw Exception('Engine failed to start after $_maxReconnectAttempts attempts');
    }
    // Crash-loop breaker: exits spaced wider than the window are
    // independent incidents; rapid ones accumulate and refuse to restart.
    if (shouldResetCrashCounter(
        lastExitAt: _lastAbnormalExitAt, now: DateTime.now(), window: _crashWindow)) {
      _consecutiveAbnormalExits = 0;
    }
    if (_consecutiveAbnormalExits >= _maxReconnectAttempts) {
      throw Exception(
          'Engine crashed $_consecutiveAbnormalExits times in quick succession; refusing to restart');
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
      if (!_disposed && code != 0 && _process == currentProcess) {
        _restart();
      }
    });

    _running = true;
    _reconnectAttempts = 0;
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
      if (id == null || !_pending.containsKey(id)) return;

      final completer = _pending.remove(id);
      if (completer == null || completer.isCompleted) return;

      if (data.containsKey('error')) {
        final error = data['error'] as Map<String, dynamic>;
        completer.completeError(
          Exception(error['error_message'] ?? 'Unknown error'),
        );
      } else {
        completer.complete(data['result'] as Map<String, dynamic>? ?? {});
      }
    } catch (e) {
      // BRUTAL-6: malformed engine stdout lines used to vanish. Protocol
      // violations are engine bugs — surface them (truncated) instead.
      final preview = line.length > 200 ? '${line.substring(0, 200)}…' : line;
      AppLogger.warn('Engine protocol: unparseable stdout line: $preview',
          tag: 'engine');
    }
  }

  Future<bool> _hasYtDlp(String pythonPath) async {
    try {
      final result = await Process.run(
        pythonPath,
        ['-m', 'yt_dlp', '--version'],
      ).timeout(const Duration(seconds: 10));
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
    final venvDir = _dataDir != null ? '$_dataDir/venv' : '${Directory.systemTemp.path}/grablytic-venv';
    final venvPython = Platform.isWindows
        ? '$venvDir\\Scripts\\python.exe'
        : '$venvDir/bin/python';

    AppLogger.info('Creating uv venv at $venvDir...', tag: 'engine-deps');
    var result = await Process.run(
      uvPath,
      ['venv', venvDir],
    ).timeout(const Duration(seconds: 60));

    if (result.exitCode != 0) {
      AppLogger.warn('uv venv failed: ${result.stderr}', tag: 'engine-deps');
    }

    AppLogger.info('Installing yt-dlp into venv...', tag: 'engine-deps');
    result = await Process.run(
      uvPath,
      ['pip', 'install', 'yt-dlp'],
      workingDirectory: venvDir,
    ).timeout(const Duration(seconds: 120));

    if (result.exitCode != 0) {
      throw Exception('Failed to install yt-dlp: ${result.stderr}');
    }

    return venvPython;
  }

  /// Ensures yt-dlp is available. Returns the Python path to use (system
  /// or venv). If a venv was created, its Python is returned.
  Future<String> ensureDependencies(String pythonPath) async {
    if (await _hasYtDlp(pythonPath)) return pythonPath;

    final uvPath = await _findUv();
    if (uvPath == null) {
      AppLogger.warn('uv not found, attempting pip fallback...', tag: 'engine-deps');
      final pipCmd = Platform.isWindows ? 'pip' : 'pip3';
      final pipResult = await Process.run(pipCmd, ['install', '--user', 'yt-dlp']);
      if (pipResult.exitCode == 0 && await _hasYtDlp(pythonPath)) {
        return pythonPath;
      }
      throw Exception(
        'yt-dlp is required but uv not found and pip fallback failed. Run the bootstrap process first.',
      );
    }

    AppLogger.info('Installing yt-dlp via uv...', tag: 'engine-deps');
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
      params: params,
    );

    final previousQueue = _requestQueue;
    final currentTask = () async {
      if (previousQueue != null) {
        try {
          await previousQueue;
        } catch (_) {}
      }
      await _ensureRunning();
      _process!.stdin.writeln(request);
      _process!.stdin.flush();
    }();
    _requestQueue = currentTask;

    await currentTask;

    final timeout = Timer(_requestTimeout, () {
      if (!completer.isCompleted) {
        _pending.remove(id);
        completer.completeError(Exception('Request $method timed out'));
      }
    });

    return completer.future.then((result) {
      timeout.cancel();
      return result;
    }).catchError((error) {
      timeout.cancel();
      throw error;
    });
  }

  @override
  Future<Map<String, dynamic>> bootstrap() async {
    return _sendRequest(EngineMethods.bootstrap, {});
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
  Stream<Map<String, dynamic>> get logStream => _progressController.stream
      .where((data) => data['type'] == 'log');

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
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir}) async {
    return _sendRequest(EngineMethods.scanResume, {
      'cache_dir': cacheDir,
    });
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
          errorType: 'ERROR_TRANSPORT', message: 'Engine request failed');
    }
  }

  @override
  Future<Map<String, dynamic>> updateCheck() async {
    return _sendRequest(EngineMethods.updateCheck, {});
  }

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) async {
    return _sendRequest(EngineMethods.setUpdateChannel, {
      'channel': channel,
    });
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
            errorType: 'ERROR_TRANSPORT', message: 'Log file not found');
      }
      Directory base;
      try {
        // path_provider is intentionally NOT imported here to keep the
        // engine layer free of plugin channels; resolve Downloads manually.
        final home = Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '.';
        base = Directory('$home/Downloads/Grablytic-logs');
      } catch (_) {
        return EngineEnvelope.error(
            errorType: 'ERROR_TRANSPORT',
            message: 'Could not resolve Downloads folder');
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
          errorType: 'ERROR_TRANSPORT', message: 'Engine request failed');
    }
  }

  @override
  Future<Map<String, dynamic>> batteryExemptionStatus() async =>
      EngineEnvelope.error(
          errorType: 'ERROR_UNSUPPORTED',
          message: 'Not supported on this platform',
          extra: {'supported': false});

  @override
  Future<Map<String, dynamic>> networkMeteredStatus() async {
    // No metered API via connectivity_plus: transport heuristic.
    // Fail closed (metered) on errors — prompt, don't silently spend.
    try {
      final results = await Connectivity().checkConnectivity();
      final unmetered = results.contains(ConnectivityResult.wifi) ||
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
          extra: {'supported': false});

  @override
  Future<Map<String, dynamic>> notificationPermissionStatus() async =>
      EngineEnvelope.error(
          errorType: 'ERROR_UNSUPPORTED',
          message: 'Not supported on this platform',
          extra: {'supported': false});

  @override
  Future<Map<String, dynamic>> requestNotificationPermission() async =>
      EngineEnvelope.error(
          errorType: 'ERROR_UNSUPPORTED',
          message: 'Not supported on this platform',
          extra: {'supported': false});

  @override
  Future<Map<String, dynamic>> queueStatus() async {
    try {
      return await _sendRequest(EngineMethods.queueStatus, {});
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Engine request failed');
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
          errorType: 'ERROR_TRANSPORT', message: 'Engine request failed');
    }
  }

  @override
  Future<Map<String, dynamic>> clearArchive() async {
    try {
      return await _sendRequest(EngineMethods.clearArchive, {});
    } catch (_) {
      return EngineEnvelope.error(
          errorType: 'ERROR_TRANSPORT', message: 'Engine request failed');
    }
  }

  @override
  Future<Map<String, dynamic>> openNotificationSettings() async =>
      EngineEnvelope.error(
          errorType: 'ERROR_UNSUPPORTED',
          message: 'Not supported on this platform',
          extra: {'supported': false});

  @override
  Future<Map<String, dynamic>> openUrl(String url) async =>
      EngineEnvelope.error(
          errorType: 'ERROR_UNSUPPORTED',
          message: 'Not supported on this platform',
          extra: {'supported': false});

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
            extra: {'supported': false});
      }
      return {'success': true};
    } catch (e) {
      return EngineEnvelope.error(
          errorType: 'ERROR_OPEN_FAILED', message: 'Could not open file: $e');
    }
  }

  @override
  Future<Map<String, dynamic>> syncSchedule({
    required bool enabled,
    int intervalMinutes = 60,
    bool wifiOnly = true,
    bool requiresCharging = false,
  }) async =>
      {'success': true, 'supported': false};
}