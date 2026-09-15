import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../core/engine/engine_provider.dart';

/// Remove ONE trailing '.part' only (BRUTAL-6 info.json).
///
/// replaceAll mangles names like 'my.part.video.f137.part' into
/// 'my.info.json.video.f137.info.json', orphaning the real sibling
/// '.info.json' on dismiss/delete. Mirrors the engine's _strip_part_suffix
/// (TEARDOWN-3).
String stripPartSuffix(String path) =>
    path.endsWith('.part') ? path.substring(0, path.length - 5) : path;

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

  factory ResumeCandidate.fromJson(Map<String, dynamic> json) {
    return ResumeCandidate(
      filename: json['filename'] as String,
      filepath: json['filepath'] as String,
      sizeBytes: json['size_bytes'] as int? ?? 0,
      ageSeconds: json['age_seconds'] as int? ?? 0,
      likelyUrl: json['likely_url'] as String?,
      expired: json['expired'] as bool? ?? false,
    );
  }
}

class ResumeNotifier extends StateNotifier<AsyncValue<List<ResumeCandidate>>> {
  final Ref _ref;

  ResumeNotifier(this._ref) : super(const AsyncValue.loading()) {
    scan();
  }

  Future<void> scan() async {
    state = const AsyncValue.loading();
    try {
      final cacheDir = await getTemporaryDirectory();
      final engine = _ref.read(engineProvider);
      final result = await engine.scanResumeCandidates(cacheDir: cacheDir.path);
      if (result['success'] == true) {
        final candidatesList = (result['candidates'] as List? ?? [])
            .map((e) => ResumeCandidate.fromJson(Map<String, dynamic>.from(e)))
            .toList();
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

  Future<void> dismiss(ResumeCandidate candidate) async {
    final currentList = state.value ?? [];
    try {
      final file = File(candidate.filepath);
      if (await file.exists()) {
        await file.delete();
      }
      final infoFile = File('${stripPartSuffix(candidate.filepath)}.info.json');
      if (await infoFile.exists()) {
        await infoFile.delete();
      }
    } catch (_) {}

    state = AsyncValue.data(currentList.where((c) => c.filepath != candidate.filepath).toList());
  }

  Future<void> deleteFileOnly(ResumeCandidate candidate) async {
    try {
      final file = File(candidate.filepath);
      if (await file.exists()) {
        await file.delete();
      }
      final infoFile = File('${stripPartSuffix(candidate.filepath)}.info.json');
      if (await infoFile.exists()) {
        await infoFile.delete();
      }
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
      final dir = cacheDir ?? (await getTemporaryDirectory()).path;
      final engine = _ref.read(engineProvider);
      await engine.reportResumeAttempt(
          cacheDir: dir, filepath: filepath, success: success);
    } catch (_) {}
  }
}

final resumeProvider = StateNotifierProvider<ResumeNotifier, AsyncValue<List<ResumeCandidate>>>((ref) {
  return ResumeNotifier(ref);
});
