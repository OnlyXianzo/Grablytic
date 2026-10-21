import 'package:grablytic/core/utils/pending_report.dart';

/// A [ReportStore] that lives in memory.
///
/// `testWidgets` runs its body inside a fake-async zone, where a `dart:io`
/// future started there never completes — a widget test driving the real
/// disk store hangs instead of failing. Reporting widgets are tested
/// through this; [PendingReportStore] keeps its own file-level tests in
/// plain `test()` blocks.
class MemoryReportStore implements ReportStore {
  MemoryReportStore({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, PendingReport> _reports = {};

  /// Number of report writes, so a test can assert "nothing touched the
  /// queue" without reaching for the filesystem.
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
      _reports.remove(all.last.id);
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
