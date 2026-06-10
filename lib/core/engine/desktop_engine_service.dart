import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'engine_service.dart';

const _uuid = Uuid();

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

  DesktopEngineService({
    String pythonPath = 'python',
    String? workingDirectory,
    String? dataDir,
  })  : _pythonPath = pythonPath,
        _workingDirectory = workingDirectory,
        _dataDir = dataDir;

  void dispose() {
    _disposed = true;
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _process?.kill();
    _progressController.close();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Engine disposed'));
      }
    }
    _pending.clear();
  }

  Future<void> _ensureRunning() async {
    if (_running && _process != null) return;
    if (_disposed) throw Exception('Engine disposed');
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      throw Exception('Engine failed to start after $_maxReconnectAttempts attempts');
    }

    _reconnectAttempts++;

    // Resolve python executable path dynamically, checking local virtual environments first in development
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
          executable = path;
          break;
        }
      }
    }

    // Fall back to system python3 on Unix platforms if system python is requested and no local venv was resolved
    if (executable == 'python' && (Platform.isLinux || Platform.isMacOS)) {
      try {
        final result = await Process.run('which', ['python3']);
        if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
          executable = 'python3';
        }
      } catch (_) {
        executable = 'python3';
      }
    }

    // Set up PYTHONPATH environment variable to include the executable directory
    // and development paths so python can always find 'truestream_engine'.
    final env = Map<String, String>.from(Platform.environment);
    final pythonPaths = <String>[];

    // Add directory containing the app executable (production bundle path)
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    pythonPaths.add(executableDir);

    // Add development directory paths
    final currentDir = Directory.current.path;
    pythonPaths.add('$currentDir/engine');
    pythonPaths.add('$currentDir/Project-TrueStream/engine');

    if (env.containsKey('PYTHONPATH')) {
      pythonPaths.add(env['PYTHONPATH']!);
    }

    env['PYTHONPATH'] = pythonPaths.join(Platform.isWindows ? ';' : ':');

    await ensureDependencies(executable);

    _process = await Process.start(
      executable,
      ['-m', 'truestream_engine'],
      workingDirectory: _workingDirectory,
      environment: env,
      runInShell: true,
    );

    _stdoutSubscription = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);

    _stderrSubscription = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderr.writeln('[truestream-engine] $line');
    });

    _process!.exitCode.then((code) {
      _running = false;
      if (!_disposed && code != 0) {
        _restart();
      }
    });

    _running = true;
    _reconnectAttempts = 0;
  }

  void _restart() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _process = null;
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

      if (data['type'] == 'event' && !_progressController.isClosed) {
        _progressController.add(data);
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
    } catch (_) {}
  }

  Future<bool> _hasYtDlp(String pythonPath) async {
    try {
      final result = await Process.run(
        pythonPath,
        ['-c', 'import yt_dlp; print(yt_dlp.__version__)'],
      ).timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _installYtDlpViaUv(String uvPath) async {
    final result = await Process.run(
      uvPath,
      ['pip', 'install', 'yt-dlp'],
    ).timeout(const Duration(seconds: 120));
    if (result.exitCode != 0) {
      throw Exception('Failed to install yt-dlp via uv: ${result.stderr}');
    }
  }

  Future<void> ensureDependencies(String pythonPath) async {
    if (await _hasYtDlp(pythonPath)) return;

    String? uvPath;
    if (_dataDir != null) {
      final uvCandidate = Platform.isWindows
          ? '$_dataDir\\bin\\uv.exe'
          : '$_dataDir/bin/uv';
      if (File(uvCandidate).existsSync()) {
        uvPath = uvCandidate;
      }
    }
    if (uvPath == null) {
      final uvName = Platform.isWindows ? 'uv.exe' : 'uv';
      final whichCmd = Platform.isWindows ? 'where' : 'which';
      final whichResult = await Process.run(whichCmd, [uvName]);
      if (whichResult.exitCode == 0) {
        uvPath = whichResult.stdout.toString().trim().split('\n').first.trim();
      }
    }

    if (uvPath == null) {
      throw Exception(
        'yt-dlp is required but not installed. Run the bootstrap process first.',
      );
    }

    stderr.writeln('[truestream-engine] Installing yt-dlp...');
    await _installYtDlpViaUv(uvPath);

    if (!await _hasYtDlp(pythonPath)) {
      throw Exception(
        'yt-dlp installation via uv completed but verification failed.',
      );
    }
  }

  Future<Map<String, dynamic>> _sendRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    await _ensureRunning();

    final id = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    final request = jsonEncode({
      'id': id,
      'method': method,
      'params': params,
    });

    _process!.stdin.writeln(request);
    _process!.stdin.flush();

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
    return _sendRequest('engine/bootstrap', {});
  }

  @override
  Future<void> setPaths(Map<String, dynamic> paths) async {
    _dataDir = paths['data_dir'] as String?;
    await _sendRequest('paths/set', paths);
  }

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) async {
    return _sendRequest('download/start', {
      'url': url,
      'download_id': downloadId,
      'config': config,
      'network_type': networkType,
    });
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) async {
    return _sendRequest('download/cancel', {
      'download_id': downloadId,
    });
  }

  @override
  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return _sendRequest('formats/get', {
      'url': url,
      'config': config,
    });
  }

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) async {
    return _sendRequest('playlist/info', {
      'url': url,
      'config': config,
    });
  }

  @override
  Future<String?> getSharedUrl() => Future.value(null);

  @override
  Stream<String> get sharedUrlStream => const Stream.empty();

  @override
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir}) async {
    return _sendRequest('resume/scan', {
      'cache_dir': cacheDir,
    });
  }

  @override
  Future<Map<String, dynamic>> updateCheck() async {
    return _sendRequest('engine/update_check', {});
  }

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) async {
    return _sendRequest('engine/set_update_channel', {
      'channel': channel,
    });
  }
}