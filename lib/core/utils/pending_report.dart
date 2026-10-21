import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;

/// The five categories the report form offers, as stored in a queued
/// report and as the GitHub label that follows from it.
///
/// Plain strings rather than an enum because the form itself is
/// data-driven: `ReportProblemScreen` renders a list of labels, and a
/// queued crash has to reopen with the same label selected.
abstract final class ReportCategory {
  static const String crash = 'Crash';
  static const String download = 'Download failure';
  static const String playback = 'Playback or file issue';
  static const String ui = 'UI problem';
  static const String other = 'Other';

  static const List<String> all = [crash, download, playback, ui, other];

  /// Falls back to [other] for anything unrecognised — a report written by
  /// a newer build must not be dropped because its category is unknown.
  static String fromThing(Object? value) {
    final text = value?.toString();
    return all.contains(text) ? text! : other;
  }

  /// The GitHub label for a category.
  static String label(String category) => switch (category) {
        crash => 'crash',
        download => 'download',
        playback => 'playback',
        ui => 'ui',
        _ => 'user-report',
      };
}

/// One report waiting to be sent.
///
/// Every field is already sanitized when the report is written: the queue
/// never holds raw exception text or an unredacted log tail. That matters
/// because these files outlive the process and a user may well attach one
/// to an issue by hand.
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
  });

  /// Local identifier. Not the fingerprint: two reports for the same crash
  /// share a fingerprint, but the store keeps only one file for them.
  final String id;

  /// Content hash of the failure, used to collapse repeats.
  final String fingerprint;

  final String category;

  /// The issue title (already redacted).
  final String title;

  /// The user's own words, or a generated one-liner for a crash.
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
    String? category,
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
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fingerprint': fingerprint,
        'category': category,
        'title': title,
        'summary': summary,
        'body': body,
        'created_at': createdAt.toUtc().toIso8601String(),
        'source': source,
        'occurrences': occurrences,
        'attempts': attempts,
        'last_prompt_at': lastPromptAt?.toUtc().toIso8601String(),
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
      category: ReportCategory.fromThing(json['category']),
      title: json['title']?.toString() ?? 'Grablytic report',
      summary: json['summary']?.toString() ?? '',
      body: body,
      createdAt: created,
      source: json['source']?.toString() == 'auto' ? 'auto' : 'manual',
      occurrences: (json['occurrences'] as num?)?.toInt() ?? 1,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      lastPromptAt: DateTime.tryParse(json['last_prompt_at']?.toString() ?? ''),
    );
  }
}

/// The operations a report queue has to provide.
///
/// An interface rather than a concrete class so a widget test can use an
/// in-memory queue: `testWidgets` runs in a fake-async zone where a
/// `dart:io` future never completes, and a test that hangs is worse than
/// no test. [PendingReportStore] is the disk implementation.
abstract class ReportStore {
  Future<List<PendingReport>> list();
  Future<PendingReport?> byId(String id);
  Future<PendingReport?> add(PendingReport report);
  Future<void> remove(String id);
  Future<void> markAttempt(String id);
  Future<void> markPrompted(String id);
}

/// Disk-backed queue of reports that have not been given to GitHub yet.
///
/// Why files and not the preferences blob: a crash has to survive the
/// process, and the preferences blob is a single key that the settings
/// screen rewrites. A file per report also means the "only one pending
/// crash" limit can be lifted without corrupting anything.
///
/// Bounds are deliberate: [maxReports] files, each body capped at
/// [maxBodyChars], and a fingerprint seen twice inside [dedupWindow]
/// collapses into one file with an occurrence count instead of a second
/// issue.
class PendingReportStore implements ReportStore {
  PendingReportStore(this.directory, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Directory directory;
  final DateTime Function() _clock;

  /// Hard cap on retained reports. A crash loop must not fill the disk.
  static const int maxReports = 3;

  /// A repeated fingerprint inside this window collapses into one report.
  static const Duration dedupWindow = Duration(days: 7);

  /// How often the recovery banner may mention the same report.
  static const Duration promptCooldown = Duration(days: 3);

  /// Largest body the store will accept, in UTF-16 code units.
  static const int maxBodyChars = 64000;

  static const String _suffix = '.json';

  /// Opens the store under `<appDir>/reports`, or returns null when the app
  /// directory is not known (tests, or a crash before init).
  static Future<PendingReportStore?> open(String? appDirPath) async {
    if (appDirPath == null || appDirPath.isEmpty) return null;
    final dir = Directory('$appDirPath/reports');
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } on FileSystemException {
      // Read-only storage or a file where the directory should be:
      // reporting degrades to unavailable instead of failing startup.
      return null;
    }
    return PendingReportStore(dir);
  }

  /// Newest first. Corrupt or unreadable files are skipped, never fatal.
  @override
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
      // The directory vanished mid-listing; keep what was already read.
      return reports;
    }
    reports.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return reports;
  }

  @override
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
  @override
  Future<PendingReport?> add(PendingReport report) async {
    final safe = _bounded(report);
    try {
      final existing = await _findByFingerprint(safe.fingerprint);
      if (existing != null &&
          _clock().difference(existing.createdAt) < dedupWindow) {
        final bumped =
            existing.copyWith(occurrences: existing.occurrences + 1);
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

  @override
  Future<void> remove(String id) async {
    try {
      final file = File('${directory.path}/$id$_suffix');
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A report that cannot be deleted is retried on the next launch.
    }
  }

  /// Records that a submission was attempted, so the UI can say "tried".
  @override
  Future<void> markAttempt(String id) async {
    final report = await byId(id);
    if (report == null) return;
    await _write(report.copyWith(attempts: report.attempts + 1));
  }

  /// Records that the recovery banner showed this report.
  @override
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
    final removable = reports.where((r) => r.id != keepId).toList()
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
    } on FileSystemException {
      return null;
    } on FormatException {
      // A truncated write from a killed process: skip the file.
      return null;
    } on TypeError {
      // Valid JSON, wrong shape.
      return null;
    }
  }

  /// Atomic write: a half-written `.tmp` is never read back as a report.
  Future<void> _write(PendingReport report) async {
    final target = File('${directory.path}/${report.id}$_suffix');
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(report.toJson()), flush: true);
    await tmp.rename(target.path);
  }

  @visibleForTesting
  File fileFor(String id) => File('${directory.path}/$id$_suffix');
}
