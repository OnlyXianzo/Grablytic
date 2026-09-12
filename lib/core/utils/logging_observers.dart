import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../engine/engine_service.dart';
import 'app_logger.dart';

/// Logs every navigation event (push/pop/replace) without holding
/// BuildContexts or routes — no memory leaks, O(1) per transition.
class LoggingNavigatorObserver extends NavigatorObserver {
  String _name(Route<dynamic>? route) =>
      route?.settings.name ?? route?.runtimeType.toString() ?? '<unknown>';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLogger.info(
      'NAV push ${_name(route)}${previousRoute != null ? ' from ${_name(previousRoute)}' : ''}',
      tag: 'navigation',
    );
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    AppLogger.info(
      'NAV pop ${_name(route)}${previousRoute != null ? ' → ${_name(previousRoute)}' : ''}',
      tag: 'navigation',
    );
    super.didPop(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    AppLogger.info(
      'NAV replace ${_name(oldRoute)} → ${_name(newRoute)}',
      tag: 'navigation',
    );
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }
}

/// Logs Riverpod provider failures state transitions at error level only —
/// normal rebuilds are NOT logged (avoids UI-lag log spam).
class LoggingProviderObserver extends ProviderObserver {
  @override
  void providerDidFail(
    ProviderBase<Object?> provider,
    Object error,
    StackTrace stackTrace,
    ProviderContainer container,
  ) {
    AppLogger.error(
      'Provider ${provider.name ?? provider.runtimeType} failed: $error',
      tag: 'riverpod',
      error: error,
      stackTrace: stackTrace,
    );
    super.providerDidFail(provider, error, stackTrace, container);
  }

  @override
  void didDisposeProvider(
    ProviderBase<Object?> provider,
    ProviderContainer container,
  ) {
    // Debug-level only; filtered from disk unless verbose.
    AppLogger.debug(
      'Provider disposed: ${provider.name ?? provider.runtimeType}',
      tag: 'riverpod',
    );
    super.didDisposeProvider(provider, container);
  }
}

/// Thin tracing decorator over any [EngineService] — injects logging hooks
/// into every API-layer branch (bootstrap, formats, download, playlist,
/// resume, update) with latency measurement, without touching call sites.
///
/// Errors are logged with full context then rethrown so UI behavior is
/// unchanged. No streams are duplicated; progress/log streams pass through.
class TracedEngineService implements EngineService {
  final EngineService _inner;
  const TracedEngineService(this._inner);

  Future<T> _traced<T>(String method, Future<T> Function() call) {
    return AppLogger.trace<T>(method, call, tag: 'engine-api');
  }

  @override
  Future<Map<String, dynamic>> bootstrap() =>
      _traced('engine/bootstrap', _inner.bootstrap);

  @override
  Future<void> setPaths(Map<String, dynamic> paths) => _traced(
        'paths/set',
        () => _inner.setPaths(_redactedPaths(paths)),
      );

  @override
  Future<Map<String, dynamic>> startDownload({
    required String url,
    required String downloadId,
    required Map<String, dynamic> config,
    required String networkType,
  }) {
    AppLogger.info(
      'Download requested: ${_redactUrl(url)} [$networkType]',
      tag: 'engine-api',
    );
    return _traced(
      'download/start',
      () => _inner.startDownload(
        url: url,
        downloadId: downloadId,
        config: config,
        networkType: networkType,
      ),
    );
  }

  @override
  Future<Map<String, dynamic>> cancelDownload(String downloadId) =>
      _traced('download/cancel', () => _inner.cancelDownload(downloadId));

  @override
  Stream<Map<String, dynamic>> get progressStream => _inner.progressStream;

  @override
  Future<Map<String, dynamic>> exportLogToDownloads({
    required String sourcePath,
    required String displayName,
  }) =>
      _traced(
        'log/export_to_downloads',
        () => _inner.exportLogToDownloads(
          sourcePath: sourcePath,
          displayName: displayName,
        ),
      );

  @override
  Future<Map<String, dynamic>> getFormats({
    required String url,
    required Map<String, dynamic> config,
  }) =>
      _traced('formats/get', () => _inner.getFormats(url: url, config: config));

  @override
  Future<Map<String, dynamic>> getPlaylistInfo({
    required String url,
    required Map<String, dynamic> config,
  }) => _traced(
        'playlist/info',
        () => _inner.getPlaylistInfo(url: url, config: config),
      );

  @override
  Future<String?> getSharedUrl() =>
      _traced('intent/get_shared', _inner.getSharedUrl);

  @override
  Stream<String> get sharedUrlStream =>
      _inner.sharedUrlStream.map((url) {
        AppLogger.info('Share intent received: ${_redactUrl(url)}',
            tag: 'share-intent');
        return url;
      });

  @override
  Future<Map<String, dynamic>> scanResumeCandidates(
          {required String cacheDir}) =>
      _traced('resume/scan',
          () => _inner.scanResumeCandidates(cacheDir: cacheDir));

  @override
  Future<Map<String, dynamic>> updateCheck() =>
      _traced('engine/update_check', _inner.updateCheck);

  @override
  Future<Map<String, dynamic>> setUpdateChannel(String channel) =>
      _traced('engine/set_update_channel',
          () => _inner.setUpdateChannel(channel));

  @override
  Stream<Map<String, dynamic>> get logStream => _inner.logStream;

  Map<String, dynamic> _redactedPaths(Map<String, dynamic> paths) {
    // Paths themselves are safe; cookies path value is redacted in AppLogger.
    return paths;
  }

  String _redactUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.queryParameters.isEmpty) {
        return uri.replace(path: uri.path.length > 60 ? '...${uri.path.substring(uri.path.length - 60)}' : uri.path).toString();
      }
      // Strip query tokens (sig, token, key) — keep param names for debugging.
      final redacted = uri.replace(
        queryParameters: uri.queryParameters.map((k, v) {
          final lk = k.toLowerCase();
          if (lk.contains('token') ||
              lk.contains('sig') ||
              lk.contains('key') ||
              lk.contains('auth')) {
            return MapEntry(k, '***');
          }
          return MapEntry(k, v.length > 40 ? '${v.substring(0, 40)}…' : v);
        }),
      );
      return redacted.toString();
    } catch (_) {
      return '<unparseable-url>';
    }
  }
}
