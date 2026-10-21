import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'github_reporter.dart';
import 'pending_report.dart';
import 'report_sanitizer.dart';

/// Where a report came from, for the issue body.
enum ReportSource { crash, manual }

/// A Python engine process that exited on its own.
///
/// Not a real exception, but it has to look like one: the report pipeline
/// is built around an error plus a stack, and an unexpected engine exit is
/// the most common desktop failure the user can actually hit. The recent
/// log tail (collected by [CrashReporter.recordCrash]) is where the Python
/// traceback lives, because engine stderr is forwarded to the app log.
class EngineExitError extends Error {
  EngineExitError(this.exitCode, {this.restarted = true});

  final int exitCode;

  /// Whether the service started the engine again. False means the user
  /// is now looking at an app with no engine behind it.
  final bool restarted;

  @override
  String toString() => 'The background engine exited with code $exitCode'
      '${restarted ? ' and was restarted' : ''}.';
}

/// What happened when a report was sent.
enum ReportSubmission {
  /// The issue exists. [ReportOutcome.url] points at it.
  created,

  /// An open issue for this exact failure already exists.
  duplicate,

  /// No token in this build, so the app cannot file the issue itself. The
  /// UI opens a prefilled GitHub page; the user presses Submit there. The
  /// app does **not** claim this was submitted.
  needsBrowser,

  /// The network call failed. The report stays queued.
  failed,
}

@immutable
class ReportOutcome {
  const ReportOutcome({
    required this.status,
    this.url,
    this.message,
    required this.report,
  });

  final ReportSubmission status;

  /// Set for [ReportSubmission.created], [ReportSubmission.duplicate] and
  /// [ReportSubmission.needsBrowser].
  final String? url;

  /// One short line of context for the UI. Already redacted.
  final String? message;

  final PendingReport report;
}

/// Builds, stores and submits crash and bug reports.
///
/// The design constraints this class exists to satisfy:
///
///  * **Capture survives the crash.** Nothing here does network I/O on the
///    fatal path. The handler writes one small sanitized file and returns;
///    the user decides on the next launch whether it is sent.
///  * **Nothing unredacted touches disk.** Every field is passed through
///    [ReportSanitizer] *before* the report is written, so a pending file
///    on disk is already safe to attach to an issue by hand.
///  * **No second pipeline.** Submission goes through the existing
///    [GithubReporter] (search-based dedup, token or browser fallback)
///    rather than a parallel implementation.
///  * **Never throws.** A crash reporter that throws inside the crash
///    handler turns one failure into two.
class CrashReporter {
  CrashReporter({
    required ReportStore? store,
    GithubReporter Function()? reporterFactory,
    DateTime Function()? clock,
    Future<SharedPrefsView> Function()? prefsLoader,
  })  : _store = store,
        _reporterFactory = reporterFactory ?? GithubReporter.new,
        _clock = clock ?? DateTime.now,
        _prefsLoader = prefsLoader,
        _sessionStartedAt = (clock ?? DateTime.now)();

  /// Process-wide instance, installed by `main()` once the app directory
  /// is known. Null before that (and in most tests), which every caller
  /// treats as "reporting unavailable" rather than an error.
  static CrashReporter? instance;

  final ReportStore? _store;
  final GithubReporter Function() _reporterFactory;
  final DateTime Function() _clock;
  final Future<SharedPrefsView> Function()? _prefsLoader;

  /// When this process started — a report older than this came from a
  /// previous session, which is what "the app restarted after the failure"
  /// means in the issue body.
  final DateTime _sessionStartedAt;

  bool get available => _store != null;

  /// Captured at crash time; captured length is bounded so a gigantic
  /// exception message cannot bloat the report.
  static const int _maxTitleChars = 110;
  static const int _maxStackChars = 6000;
  static const int _maxLogChars = 12000;

  /// Records an unhandled failure. Never throws, never blocks on network.
  ///
  /// Returns the stored report, or null when capture itself was impossible
  /// (no app directory, disk full, malformed input).
  Future<PendingReport?> recordCrash(
    Object error,
    StackTrace? stack, {
    ReportSource source = ReportSource.crash,
  }) async {
    final store = _store;
    if (store == null) return null;
    try {
      final errorType = _errorType(error);
      final firstFrame = _firstFrame(stack);
      final fingerprint = reportFingerprint(errorType, firstFrame);
      final message = error.toString();
      final short = ReportSanitizer.sanitize(message);
      final summary = _shorten(short, 160);

      final report = PendingReport(
        id: _newId(fingerprint),
        fingerprint: fingerprint,
        category: ReportCategory.crash,
        title: _crashTitle(errorType, summary),
        summary: summary.isEmpty ? 'The app stopped unexpectedly.' : summary,
        body: _buildBody(
          summary: summary.isEmpty ? 'The app stopped unexpectedly.' : summary,
          category: ReportCategory.crash,
          errorType: errorType,
          errorDetail: message,
          stack: _shorten(stack?.toString() ?? '', _maxStackChars),
          logTail: await _readLogTail(),
          recovered: false,
          capturedInPreviousSession: false,
          fingerprint: fingerprint,
        ),
        createdAt: _clock(),
        source: source == ReportSource.crash ? 'auto' : 'manual',
        errorType: errorType,
      );
      return await store.add(report);
    } catch (_) {
      return null;
    }
  }

  /// Builds a report from the form. Returns null when the summary is empty
  /// or the store is unavailable.
  Future<PendingReport?> buildManual({
    required String summary,
    required ReportCategory category,
    Map<String, Object?> context = const {},
    bool includeLog = true,
  }) async {
    final store = _store;
    final text = summary.trim();
    if (store == null || text.isEmpty) return null;
    try {
      final safeSummary = ReportSanitizer.sanitize(text);
      final fingerprint = reportFingerprint('manual:${category.id}', safeSummary);
      final report = PendingReport(
        id: _newId(fingerprint),
        fingerprint: fingerprint,
        category: category,
        title: _manualTitle(category, safeSummary),
        summary: safeSummary,
        body: _buildBody(
          summary: safeSummary,
          category: category,
          errorType: null,
          errorDetail: null,
          stack: '',
          logTail: includeLog ? await _readLogTail() : '',
          context: context,
          recovered: false,
          capturedInPreviousSession: false,
          fingerprint: fingerprint,
        ),
        createdAt: _clock(),
        source: 'manual',
      );
      return await store.add(report);
    } on Exception {
      // Every step above is either pure or already fail-soft (the store
      // swallows its own I/O errors); this only guards an unexpected
      // platform failure while assembling the text.
      return null;
    }
  }

  /// The exact text that would be filed, for the review step.
  ///
  /// Built from the same code path as the real submission so what the user
  /// reads is what gets sent — a preview rendered by a second formatter
  /// eventually diverges from the real one.
  String preview(PendingReport report) => '${report.title}\n\n${report.body}';

  /// Sends [report].
  ///
  /// On success the report leaves the queue. On failure it stays, with its
  /// attempt count bumped, so "try again later" keeps the user's words.
  Future<ReportOutcome> submit(PendingReport report) async {
    final store = _store;
    if (store == null) {
      return ReportOutcome(
        status: ReportSubmission.failed,
        report: report,
        message: 'Reporting is not set up in this build.',
      );
    }

    // Re-sanitize on the way out. The stored copy is already clean; this
    // catches the case where a report file was edited by hand or written
    // by an older build, and costs microseconds.
    final title = ReportSanitizer.sanitize(report.title);
    final body = ReportSanitizer.sanitize(report.body);

    final reporter = _reporterFactory();
    if (!reporter.canPost) {
      return ReportOutcome(
        status: ReportSubmission.needsBrowser,
        url: reporter
            .issueUrl(title: title, body: body, labels: _labelsFor(report))
            .toString(),
        report: report,
        message: 'No GitHub token in this build — submit on the prefilled page.',
      );
    }

    try {
      final dup = await reporter.findDuplicate(report.fingerprint);
      if (dup != null) {
        await store.remove(report.id);
        return ReportOutcome(
          status: ReportSubmission.duplicate,
          url: dup,
          report: report,
          message: 'This was already reported.',
        );
      }
      final url = await reporter.createIssue(
        title: title,
        body: body,
        labels: _labelsFor(report),
      );
      if (url != null) {
        await store.remove(report.id);
        return ReportOutcome(
          status: ReportSubmission.created,
          url: url,
          report: report,
        );
      }
      await store.markAttempt(report.id);
      return ReportOutcome(
        status: ReportSubmission.failed,
        report: report,
        message: 'GitHub did not accept the report.',
      );
    } catch (e) {
      await store.markAttempt(report.id);
      return ReportOutcome(
        status: ReportSubmission.failed,
        report: report,
        message: ReportSanitizer.sanitize('$e'),
      );
    }
  }

  /// Queues a report for the next launch without sending it.
  Future<void> keepForLater(PendingReport report) async {
    await _store?.markAttempt(report.id);
  }

  Future<void> dismiss(String id) async {
    await _store?.remove(id);
  }

  Future<List<PendingReport>> pending() async => await _store?.list() ?? [];

  /// The crash the recovery prompt should mention, if any.
  ///
  /// Only crashes, only from an earlier session, and never more often than
  /// [PendingReportStore.promptCooldown] — a prompt that shows up on every
  /// launch is a prompt the user learns to dismiss without reading.
  Future<PendingReport?> promptCandidate() async {
    final store = _store;
    if (store == null) return null;
    for (final report in await store.list()) {
      if (!report.isCrash) continue;
      if (!report.createdAt.isBefore(_sessionStartedAt)) continue;
      final prompted = report.lastPromptAt;
      if (prompted != null &&
          _clock().difference(prompted) < PendingReportStore.promptCooldown) {
        continue;
      }
      return report;
    }
    return null;
  }

  Future<void> markPrompted(String id) async => _store?.markPrompted(id);

  /// Reads the automatic-reporting preference. Default false: a stock
  /// install never contacts GitHub.
  Future<bool> autoReportingEnabled() async {
    final loader = _prefsLoader;
    if (loader == null) return false;
    try {
      final prefs = await loader();
      return prefs.autoCrashReporting;
    } on Exception {
      // Preferences are not readable (first run, migration, plugin error).
      // Fail to the private default: do not send.
      return false;
    }
  }

  /// Sends every queued crash when the user opted in. Called once per
  /// launch, off the first frame. Stops at the first failure so a dead
  /// network does not burn the whole queue's attempt counts.
  Future<void> submitQueuedIfOptedIn() async {
    if (!await autoReportingEnabled()) return;
    final store = _store;
    if (store == null) return;
    for (final report in await store.list()) {
      if (!report.isCrash) continue;
      final outcome = await submit(report);
      if (outcome.status == ReportSubmission.failed) return;
    }
  }

  Future<String> _readLogTail() async {
    if (!AppLogger.isEnabled) return '';
    try {
      final tail = await AppLogger.readLogTail(maxBytes: 24 * 1024);
      // readLogTail already wrote through the logger's scrubber; sanitize
      // again because a line written before a pattern was added would
      // otherwise ride straight through.
      return ReportSanitizer.excerpt(
        ReportSanitizer.sanitize(tail),
        maxChars: _maxLogChars,
      );
    } on Exception {
      // No log tail is a valid report; a report that throws is not.
      return '';
    }
  }

  String _buildBody({
    required String summary,
    required ReportCategory category,
    required String? errorType,
    required String? errorDetail,
    required String stack,
    required String logTail,
    required bool recovered,
    required bool capturedInPreviousSession,
    required String fingerprint,
    Map<String, Object?> context = const {},
  }) {
    final env = _environment();
    final safeContext = context.isEmpty
        ? const <String, String>{}
        : ReportSanitizer.sanitizeMap(context);
    final contextLines = safeContext.entries
        .map((e) => '- `${e.key}`: `${e.value}`')
        .join('\n');
    final errorBlock = errorType == null
        ? '_No exception — reported from the app._'
        : '```\n${ReportSanitizer.sanitize(errorType)}'
            '${errorDetail == null || errorDetail.isEmpty ? '' : ': ${ReportSanitizer.sanitize(errorDetail)}'}\n'
            '${ReportSanitizer.sanitize(_firstFrameFromString(stack))}\n```';
    final stackBlock = stack.isEmpty
        ? '_None captured._'
        : '```\n${ReportSanitizer.sanitize(stack)}\n```';
    final logBlock = logTail.isEmpty
        ? '_Not included._'
        : '```text\n$logTail\n```';
    final session = capturedInPreviousSession
        ? 'Previous session — the app closed unexpectedly.'
        : (recovered ? 'Recovered without a restart.' : 'Current session.');

    return '''### What happened
${ReportSanitizer.sanitize(summary)}

### Category
${category.label}

### Environment
- App: ${env['app']}
- Platform: ${env['platform']}
- Flutter: ${env['flutter']}
- Debug build: ${env['debug']}
- Session: $session
- Reported: ${_clock().toUtc().toIso8601String()}
${contextLines.isEmpty ? '' : '\n### Context\n$contextLines\n'}
### Error
$errorBlock

### Stack trace
$stackBlock

### Recent app activity (redacted)
$logBlock

---
<sub>Filed from Grablytic. Tokens, cookies, auth headers and account names
are removed automatically before the report leaves the device.</sub>
<!-- fingerprint: $fingerprint · category: ${category.id} -->
''';
  }

  Map<String, String> _environment() {
    final platform =
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    const sha = String.fromEnvironment('GRABLYTIC_GIT_SHA', defaultValue: '');
    const flutter = String.fromEnvironment(
      'GRABLYTIC_FLUTTER_VERSION',
      defaultValue: '',
    );
    return {
      'app': sha.isEmpty ? '0.0.1-beta (dev build)' : '0.0.1-beta+$sha',
      'platform': platform,
      'flutter': flutter.isEmpty ? 'unknown' : flutter,
      'debug': kDebugMode.toString(),
    };
  }

  List<String> _labelsFor(PendingReport report) =>
      ['bug', 'user-report', report.category.id == 'crash' ? 'crash' : report.category.id];

  static String _errorType(Object error) {
    final text = error.runtimeType.toString();
    return text.isEmpty ? 'Exception' : text;
  }

  static String? _firstFrame(StackTrace? stack) {
    if (stack == null) return null;
    for (final line in stack.toString().split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#')) return trimmed;
    }
    return null;
  }

  static String _firstFrameFromString(String stack) {
    for (final line in stack.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.startsWith('#')) return trimmed;
    }
    return '';
  }

  static String _crashTitle(String errorType, String detail) {
    final head = detail.isEmpty ? 'The app stopped unexpectedly' : detail;
    return _shorten('[Crash] $errorType: $head', _maxTitleChars);
  }

  static String _manualTitle(ReportCategory category, String summary) =>
      _shorten('[${category.label}] $summary', _maxTitleChars);

  static String _shorten(String text, int max) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= max) return oneLine;
    return '${oneLine.substring(0, max - 1)}…';
  }

  static String _newId(String fingerprint) {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = fingerprint.isEmpty ? 'anon' : fingerprint;
    return '$stamp-$salt';
  }

  /// Test/DI seam: only the preference this class reads.
  static Future<SharedPrefsView> Function() viewFromPrefs(
    Future<bool> Function() read,
  ) =>
      () async => SharedPrefsView(autoCrashReporting: await read());
}

/// The single preference the reporter needs, so this file does not depend
/// on the settings provider (which would drag Riverpod into `main`).
@immutable
class SharedPrefsView {
  const SharedPrefsView({required this.autoCrashReporting});
  final bool autoCrashReporting;
}
