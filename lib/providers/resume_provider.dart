import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../core/engine/engine_provider.dart';

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
      final infoFile = File(candidate.filepath.replaceAll('.part', '.info.json'));
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
      final infoFile = File(candidate.filepath.replaceAll('.part', '.info.json'));
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
  Future<String?> resumeDownload(ResumeCandidate candidate) async {
    final url = candidate.likelyUrl;
    if (url == null || url.isEmpty || candidate.expired) return null;
    removeCandidateFromList(candidate);
    return url;
  }
}

final resumeProvider = StateNotifierProvider<ResumeNotifier, AsyncValue<List<ResumeCandidate>>>((ref) {
  return ResumeNotifier(ref);
});
