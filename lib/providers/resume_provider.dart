import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/engine/engine_provider.dart';
import '../core/utils/app_logger.dart';
import '../core/utils/trust_boundary.dart';
import 'settings_provider.dart';

/// Remove ONE trailing '.part' only (BRUTAL-6 info.json).
///
/// replaceAll mangles names like 'my.part.video.f137.part' into
/// 'my.info.json.video.f137.info.json', orphaning the real sibling
/// '.info.json' on dismiss/delete. Mirrors the engine's _strip_part_suffix
/// (TEARDOWN-3).
String stripPartSuffix(String path) =>
    path.endsWith('.part') ? path.substring(0, path.length - 5) : path;

bool _isPathInAllowedDirs(String path, List<String> allowedDirs) {
  for (final dir in allowedDirs) {
    if (dir.isNotEmpty && isPathWithinDir(path, dir)) {
      return true;
    }
  }
  return false;
}

class ResumeCandidate {
  final String filename;
  final String filepath;
  final int sizeBytes;
  final int ageSeconds;
  final String? likelyUrl;
  final bool expired;

  ResumeCandidate({
    required this.filename,
    required this.filepath,
    required this.sizeBytes,
    required this.ageSeconds,
    this.likelyUrl,
    required this.expired,
  });

  /// Defensive JSON parser enforcing the trust boundary.
  ///
  /// Returns null if the JSON is malformed, missing required fields, or if
  /// the path fails validation (relative, path traversal, missing '.part', or
  /// outside [allowedDirs] if specified).
  static ResumeCandidate? fromJson(
    Map<String, dynamic> json, {
    List<String>? allowedDirs,
  }) {
    try {
      final rawPath = json['filepath'];
      if (rawPath is! String || rawPath.trim().isEmpty) return null;

      final cleanPath = sanitizeEngineFilePath(rawPath);
      if (cleanPath == null) return null;
      if (!cleanPath.endsWith('.part')) return null;

      if (allowedDirs != null && allowedDirs.isNotEmpty) {
        if (!_isPathInAllowedDirs(cleanPath, allowedDirs)) {
          return null;
        }
      }

      final rawName = json['filename'];
      final filename = (rawName is String && rawName.trim().isNotEmpty)
          ? sanitizeExportFileName(rawName, fallback: p.basename(cleanPath))
          : p.basename(cleanPath);

      final sizeBytes = json['size_bytes'];
      final ageSeconds = json['age_seconds'];
      final likelyUrl = json['likely_url'];
      final expired = json['expired'];

      return ResumeCandidate(
        filename: filename,
        filepath: cleanPath,
        sizeBytes: sizeBytes is num ? sizeBytes.toInt() : 0,
        ageSeconds: ageSeconds is num ? ageSeconds.toInt() : 0,
        likelyUrl: likelyUrl is String && likelyUrl.isNotEmpty ? likelyUrl : null,
        expired: expired is bool ? expired : false,
      );
    } catch (_) {
      return null;
    }
  }
}

class ResumeNotifier extends StateNotifier<AsyncValue<List<ResumeCandidate>>> {
  final Ref _ref;
  final Future<String> Function()? resolveCacheDir;
  final Future<String?> Function()? resolveDownloadDir;

  ResumeNotifier(
    this._ref, {
    this.resolveCacheDir,
    this.resolveDownloadDir,
  }) : super(const AsyncValue.loading()) {
    scan();
  }

  Future<List<String>> _allowedDirectories() async {
    final dirs = <String>[];
    try {
      if (resolveCacheDir != null) {
        final d = await resolveCacheDir!();
        if (d.isNotEmpty) dirs.add(d);
      } else {
        final d = (await getTemporaryDirectory()).path;
        if (d.isNotEmpty) dirs.add(d);
      }
    } catch (_) {}

    try {
      final dl = resolveDownloadDir != null
          ? await resolveDownloadDir!()
          : _ref.read(settingsProvider).downloadPath;
      if (dl != null && dl.isNotEmpty) dirs.add(dl);
    } catch (_) {}

    final canonical = <String>[];
    for (final d in dirs) {
      final norm = p.normalize(p.absolute(d));
      canonical.add(norm);
      try {
        final dirObj = Directory(norm);
        if (dirObj.existsSync()) {
          canonical.add(p.normalize(dirObj.resolveSymbolicLinksSync()));
        }
      } catch (_) {}
    }
    return canonical.toSet().toList();
  }

  Future<void> scan() async {
    state = const AsyncValue.loading();
    try {
      final cacheDir = resolveCacheDir != null
          ? await resolveCacheDir!()
          : (await getTemporaryDirectory()).path;
      final engine = _ref.read(engineProvider);
      final result = await engine.scanResumeCandidates(cacheDir: cacheDir);
      if (result['success'] == true) {
        final rawList = result['candidates'] as List? ?? [];
        final allowedDirs = await _allowedDirectories();
        final List<ResumeCandidate> candidatesList = [];

        for (final item in rawList) {
          if (item is! Map) continue;
          final candidate = ResumeCandidate.fromJson(
            Map<String, dynamic>.from(item),
            allowedDirs: allowedDirs,
          );
          if (candidate == null) {
            AppLogger.warn(
              'Dropping resume candidate outside trust boundary: ${item['filepath']}',
              tag: 'resume',
            );
            continue;
          }
          candidatesList.add(candidate);
        }
        state = AsyncValue.data(candidatesList);
      } else {
        state = AsyncValue.error(
            result['error_message'] ?? 'Failed to scan resume candidates',
            StackTrace.current);
      }
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  Future<void> _deleteCandidateFiles(ResumeCandidate candidate) async {
    final cleanPath = sanitizeEngineFilePath(candidate.filepath);
    if (cleanPath == null || !cleanPath.endsWith('.part')) {
      AppLogger.warn('Delete refused: invalid path: ${candidate.filepath}', tag: 'resume');
      return;
    }

    final allowedDirs = await _allowedDirectories();
    if (!_isPathInAllowedDirs(cleanPath, allowedDirs)) {
      AppLogger.warn('Delete refused: path outside allowed dirs: $cleanPath', tag: 'resume');
      return;
    }

    // 1. Delete .part file (with symlink realpath gate)
    final file = File(cleanPath);
    if (await file.exists()) {
      try {
        final realPath = await file.resolveSymbolicLinks();
        if (_isPathInAllowedDirs(realPath, allowedDirs)) {
          await file.delete();
        } else {
          AppLogger.warn('Delete refused: realpath outside allowed dirs: $realPath', tag: 'resume');
        }
      } catch (_) {}
    }

    // 2. Delete .info.json sidecar
    final base = stripPartSuffix(cleanPath);
    final sidecarPath = sanitizeEngineFilePath('$base.info.json');
    if (sidecarPath != null && _isPathInAllowedDirs(sidecarPath, allowedDirs)) {
      final infoFile = File(sidecarPath);
      if (await infoFile.exists()) {
        try {
          final realSidecar = await infoFile.resolveSymbolicLinks();
          if (_isPathInAllowedDirs(realSidecar, allowedDirs)) {
            await infoFile.delete();
          } else {
            AppLogger.warn('Sidecar realpath outside allowed dirs: $realSidecar', tag: 'resume');
          }
        } catch (_) {}
      }
    }
  }

  Future<void> dismiss(ResumeCandidate candidate) async {
    final currentList = state.value ?? [];
    try {
      await _deleteCandidateFiles(candidate);
    } catch (_) {}

    state = AsyncValue.data(currentList.where((c) => c.filepath != candidate.filepath).toList());
  }

  Future<void> deleteFileOnly(ResumeCandidate candidate) async {
    try {
      await _deleteCandidateFiles(candidate);
    } catch (_) {}
    final currentList = state.value ?? [];
    state = AsyncValue.data(currentList.where((c) => c.filepath != candidate.filepath).toList());
  }

  void removeCandidateFromList(ResumeCandidate candidate) {
    final currentList = state.value ?? [];
    state = AsyncValue.data(currentList.where((c) => c.filepath != candidate.filepath).toList());
  }

  /// Claim a resume candidate for restart (P2).
  ///
  /// Returns the [ResumeCandidate.likelyUrl] to re-open in the format flow
  /// and drops the candidate from the list, or null when there is nothing
  /// resumable (missing URL or expired stream URLs). Keeping the
  /// engine restart in the format flow preserves yt-dlp `continuedl`
  /// resume-by-filename without inventing Range logic here.
  ///
  /// Stashes url -> filepath so [reportAttempt] can strike-count the outcome
  /// (BRUTAL-5); the stash is one-shot per resume tap.
  final Map<String, String> _resumeOrigins = {};

  Future<String?> resumeDownload(ResumeCandidate candidate) async {
    final url = candidate.likelyUrl;
    if (url == null || url.isEmpty || candidate.expired) return null;
    _resumeOrigins[url] = candidate.filepath;
    removeCandidateFromList(candidate);
    return url;
  }

  /// Records one resume outcome for a previously stashed [url].
  /// Unknown urls (normal downloads) are a silent no-op. Never throws.
  /// [cacheDir] overrides directory resolution (tests; production passes
  /// nothing and the temp dir is resolved like [scan] does).
  Future<void> reportAttempt(
      {required String url, required bool success, String? cacheDir}) async {
    final filepath = _resumeOrigins.remove(url);
    if (filepath == null) return;
    try {
      final dir = cacheDir ??
          (resolveCacheDir != null
              ? await resolveCacheDir!()
              : (await getTemporaryDirectory()).path);
      final engine = _ref.read(engineProvider);
      await engine.reportResumeAttempt(
          cacheDir: dir, filepath: filepath, success: success);
    } catch (_) {}
  }
}

final resumeProvider = StateNotifierProvider<ResumeNotifier, AsyncValue<List<ResumeCandidate>>>((ref) {
  return ResumeNotifier(
    ref,
    resolveDownloadDir: () async => ref.read(settingsProvider).downloadPath,
  );
});
