import 'package:grablytic/core/utils/pending_report.dart';

/// A [ReportStore] that lives in memory.
///
/// `testWidgets` runs its body inside a fake-async zone: a `dart:io`
/// future started there never completes, so a widget test driving the real
/// disk store does not fail — it hangs. Reporting code is exercised
/// through this instead, and [PendingReportStore] keeps its own file-level
/// tests in plain `test()` blocks.
class MemoryReportStore implements ReportStore {
  MemoryReportStore({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, PendingReport> _reports = {};

  /// Every report write that happened, in order. Assertions about
  /// "did anything touch the queue" read this instead of the filesystem.
  int writes = 0;

  List<PendingReport> get all => _sorted(_reports.values);

  @override
  Future<List<PendingReport>> list() async => _sorted(_reports.values);

  @override
  Future<PendingReport?> byId(String id) async => _reports[id];

  @override
  Future<PendingReport?> add(PendingReport report) async {
    writes++;
    PendingReport? existing;
    if (report.fingerprint.isNotEmpty) {
      for (final candidate in _reports.values) {
        if (candidate.fingerprint != report.fingerprint) continue;
        if (_clock().difference(candidate.createdAt) >=
            PendingReportStore.dedupWindow) {
          continue;
        }
        existing = candidate;
        break;
      }
    }
    if (existing != null) {
      final bumped = existing.copyWith(occurrences: existing.occurrences + 1);
      _reports[existing.id] = bumped;
      return bumped;
    }
    _reports[report.id] = report;
    if (_reports.length > PendingReportStore.maxReports) {
      final oldest = all.last;
      _reports.remove(oldest.id);
    }
    return report;
  }

  @override
  Future<void> remove(String id) async => _reports.remove(id);

  @override
  Future<void> markAttempt(String id) async {
    final report = _reports[id];
    if (report == null) return;
    _reports[id] = report.copyWith(attempts: report.attempts + 1);
  }

  @override
  Future<void> markPrompted(String id) async {
    final report = _reports[id];
    if (report == null) return;
    _reports[id] = report.copyWith(lastPromptAt: _clock());
  }

  static List<PendingReport> _sorted(Iterable<PendingReport> input) =>
      input.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}
