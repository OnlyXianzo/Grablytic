import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;

/// What the user says went wrong, in the app's own vocabulary.
///
/// Kept short on purpose: five choices is a single glance on a phone, and
/// the result maps to a GitHub label the maintainer can triage by.
enum ReportCategory {
  crash('crash', 'Crash or freeze', 'A screen froze or the app closed'),
  download('download', 'Download failed', 'A video or audio download did not finish'),
  playback('playback', 'Playback or file', 'The file would not open or play correctly'),
  interface('ui', 'Something looks wrong', 'Layout, theme, or a control misbehaving'),
  other('other', 'Something else', 'None of the above');

  const ReportCategory(this.id, this.label, this.hint);

  /// Stable identifier used in prefs, JSON and GitHub labels.
  final String id;

  /// Button text in the report form.
  final String label;

  /// One line under the label, for the cases where the label is ambiguous.
  final String hint;

  static ReportCategory fromId(String? id) => values.firstWhere(
        (c) => c.id == id,
        orElse: () => ReportCategory.other,
      );
}

/// One report waiting to be sent.
///
/// Everything in here is already sanitized when it is written — the store
/// never holds raw user text or raw log lines. See [CrashReporter].
@immutable
class PendingReport {
  const PendingReport({
    required this.id,
    required this.fingerprint,
    required this.category,
    required this.title,
    required this.summary,
    required this.body,
    required this.createdAt,
    required this.source,
    this.occurrences = 1,
    this.attempts = 0,
    this.lastPromptAt,
    this.errorType,
  });

  /// Local identifier (uuid). Not the fingerprint: two reports for the same
  /// crash share a fingerprint but only one file exists (see the store).
  final String id;

  /// Content hash of the failure, used to collapse repeats.
  final String fingerprint;

  final ReportCategory category;

  /// The GitHub issue title (already redacted).
  final String title;

  /// The user's own description, or a generated one-liner for a crash.
  final String summary;

  /// Full Markdown body, already redacted.
  final String body;

  final DateTime createdAt;

  /// `auto` for a captured crash, `manual` for something the user typed.
  final String source;

  /// How many times this exact failure has been seen.
  final int occurrences;

  /// How many submission attempts have been made.
  final int attempts;

  /// When the recovery prompt last mentioned this report.
  final DateTime? lastPromptAt;

  /// Exception class for a captured crash (`_TypeError`, `SocketException`).
  final String? errorType;

  bool get isCrash => source == 'auto';

  /// A one-line description for the recovery banner.
  String get shortLabel {
    final text = summary.trim();
    if (text.isEmpty) return title;
    return text.length > 90 ? '${text.substring(0, 89)}…' : text;
  }

  PendingReport copyWith({
    int? occurrences,
    int? attempts,
    DateTime? lastPromptAt,
    String? title,
    String? summary,
    String? body,
    ReportCategory? category,
  }) {
    return PendingReport(
      id: id,
      fingerprint: fingerprint,
      category: category ?? this.category,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      body: body ?? this.body,
      createdAt: createdAt,
      source: source,
      occurrences: occurrences ?? this.occurrences,
      attempts: attempts ?? this.attempts,
      lastPromptAt: lastPromptAt ?? this.lastPromptAt,
      errorType: errorType,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fingerprint': fingerprint,
        'category': category.id,
        'title': title,
        'summary': summary,
        'body': body,
        'created_at': createdAt.toUtc().toIso8601String(),
        'source': source,
        'occurrences': occurrences,
        'attempts': attempts,
        'last_prompt_at': lastPromptAt?.toUtc().toIso8601String(),
        'error_type': errorType,
      };

  static PendingReport? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final body = json['body']?.toString();
    if (id == null || id.isEmpty || body == null) return null;
    final created = DateTime.tryParse(json['created_at']?.toString() ?? '');
    if (created == null) return null;
    return PendingReport(
      id: id,
      fingerprint: json['fingerprint']?.toString() ?? '',
      category: ReportCategory.fromId(json['category']?.toString()),
      title: json['title']?.toString() ?? 'Grablytic report',
      summary: json['summary']?.toString() ?? '',
      body: body,
      createdAt: created,
      source: json['source']?.toString() == 'auto' ? 'auto' : 'manual',
      occurrences: (json['occurrences'] as num?)?.toInt() ?? 1,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastPromptAt: DateTime.tryParse(json['last_prompt_at']?.toString() ?? ''),
      errorType: json['error_type']?.toString(),
    );
  }
}

/// Disk-backed queue of reports that have not been submitted yet.
///
/// Why a queue at all: the old crash path built a report body inside the
/// fatal handler and threw it away when there was no GitHub token — which
/// is every release build. The user saw nothing, and the next launch did
/// not know a crash had happened. A file per report fixes both.
///
/// Bounds are deliberate: [maxReports] files, each capped by the caller's
/// body size, and a fingerprint seen twice becomes one file with a count
/// instead of a second issue.
class PendingReportStore {
  PendingReportStore(this.directory, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Directory directory;
  final DateTime Function() _clock;

  /// Hard cap on retained reports. A crash loop must not fill the disk.
  static const int maxReports = 3;

  /// A repeated fingerprint inside this window collapses into one report.
  static const Duration dedupWindow = Duration(days: 7);

  /// How often the recovery prompt may mention the same report.
  static const Duration promptCooldown = Duration(days: 3);

  /// Largest body the store will accept, in UTF-16 code units.
  static const int maxBodyChars = 64000;

  static const String _suffix = '.json';

  /// Opens the store under `<appDir>/reports`, or returns null when the
  /// app directory is not known yet (tests, or a crash before init).
  static Future<PendingReportStore?> open(String? appDirPath) async {
    if (appDirPath == null || appDirPath.isEmpty) return null;
    final dir = Directory('$appDirPath/reports');
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } on FileSystemException {
      // Read-only storage, no permission, or a file where the directory
      // should be: reporting degrades to unavailable rather than failing
      // startup.
      return null;
    }
    return PendingReportStore(dir);
  }

  /// Newest first. Corrupt or unreadable files are skipped, never fatal.
  Future<List<PendingReport>> list() async {
    final reports = <PendingReport>[];
    try {
      if (!await directory.exists()) return reports;
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith(_suffix)) continue;
        final report = await _read(entity);
        if (report != null) reports.add(report);
      }
    } on FileSystemException {
      // The directory vanished mid-listing (uninstall, cleanup); return
      // whatever was read before that.
      return reports;
    }
    reports.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return reports;
  }

  Future<PendingReport?> byId(String id) async {
    for (final report in await list()) {
      if (report.id == id) return report;
    }
    return null;
  }

  /// Adds [report], collapsing a repeat of the same fingerprint.
  ///
  /// Returns the stored report — which may be an *existing* one with a
  /// bumped [PendingReport.occurrences] when the failure was seen before.
  Future<PendingReport?> add(PendingReport report) async {
    final safe = _bounded(report);
    try {
      final existing = await _findByFingerprint(safe.fingerprint);
      if (existing != null &&
          _clock().difference(existing.createdAt) < dedupWindow) {
        final bumped = existing.copyWith(
          occurrences: existing.occurrences + 1,
        );
        await _write(bumped);
        return bumped;
      }
      await _write(safe);
      await _enforceCap(keepId: safe.id);
      return safe;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> remove(String id) async {
    try {
      final file = File('${directory.path}/$id$_suffix');
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A report that cannot be deleted is retried on the next launch.
    }
  }

  /// Records that a submission was attempted, so the UI can say "tried".
  Future<void> markAttempt(String id) async {
    final report = await byId(id);
    if (report == null) return;
    await _write(report.copyWith(attempts: report.attempts + 1));
  }

  /// Records that the recovery prompt showed this report.
  Future<void> markPrompted(String id) async {
    final report = await byId(id);
    if (report == null) return;
    await _write(report.copyWith(lastPromptAt: _clock()));
  }

  Future<PendingReport?> _findByFingerprint(String fingerprint) async {
    if (fingerprint.isEmpty) return null;
    for (final report in await list()) {
      if (report.fingerprint == fingerprint) return report;
    }
    return null;
  }

  PendingReport _bounded(PendingReport report) {
    if (report.body.length <= maxBodyChars) return report;
    return report.copyWith(
      body: '${report.body.substring(0, maxBodyChars)}\n\n[... truncated ...]',
    );
  }

  /// Drops the oldest reports once the cap is exceeded.
  Future<void> _enforceCap({required String keepId}) async {
    final reports = await list();
    if (reports.length <= maxReports) return;
    final removable = reports
        .where((r) => r.id != keepId)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    var excess = reports.length - maxReports;
    for (final report in removable) {
      if (excess <= 0) break;
      await remove(report.id);
      excess--;
    }
  }

  Future<PendingReport?> _read(File file) async {
    try {
      final raw = await file.readAsString();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PendingReport.fromJson(Map<String, dynamic>.from(decoded));
    } on Exception {
      // Unreadable or not JSON at all (a truncated write from an older
      // build): skip the file, never fail the listing.
      return null;
    } on TypeError {
      // Valid JSON with the wrong shape (`[1,2,3]`, a string where the
      // map belongs).
      return null;
    }
  }

  /// Atomic write: a half-written `tmp` is never read back as a report.
  Future<void> _write(PendingReport report) async {
    final target = File('${directory.path}/${report.id}$_suffix');
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(report.toJson()), flush: true);
    await tmp.rename(target.path);
  }

  @visibleForTesting
  File fileFor(String id) => File('${directory.path}/$id$_suffix');
}
