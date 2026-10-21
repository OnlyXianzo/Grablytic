import 'app_logger.dart';
import 'github_reporter.dart';
import 'pending_report.dart';

/// A Python engine process that exited on its own.
///
/// Not a real exception, but it has to look like one: the report pipeline
/// is built around an error plus a stack, and an unexpected engine exit is
/// the most common desktop failure a user can actually hit. The recent log
/// tail is where the Python traceback lives, because engine stderr is
/// forwarded to the app log.
class EngineExitError extends Error {
  EngineExitError(this.exitCode, {this.restarted = true});

  final int exitCode;

  /// Whether the service started the engine again. False means the user is
  /// looking at an app with no engine behind it.
  final bool restarted;

  @override
  String toString() => 'The background engine exited with code $exitCode'
      '${restarted ? ' and was restarted' : ''}.';
}

/// Captures crashes locally and decides, later, whether GitHub sees them.
///
/// The rules this class exists to enforce:
///
///  * **Capture always, send by choice.** A crash is written to disk even
///    with automatic reporting off — otherwise the next launch has nothing
///    to offer, which made the "we ran into a problem last time" prompt
///    reachable only for people who had already opted in.
///  * **No network on the fatal path.** [capture] builds a draft and
///    writes one small file. Submission happens on the next launch or when
///    the user taps Send.
///  * **One pipeline.** Submission goes through [GithubReporter]
///    ([GithubReporter.submitDraft]), so dedup, tokens and the manual
///    fallback behave the same everywhere.
///  * **Never throws.** A reporter that throws inside the crash handler
///    turns one failure into two.
class CrashReports {
  CrashReports({
    required ReportStore? store,
    GithubReporter Function()? reporterFactory,
    DateTime Function()? clock,
    Future<bool> Function()? autoSendLoader,
    String appVersion = '0.0.1-beta+1',
  })  : _store = store,
        _reporterFactory = reporterFactory ?? GithubReporter.new,
        _clock = clock ?? DateTime.now,
        _autoSendLoader = autoSendLoader,
        _appVersion = appVersion,
        _sessionStartedAt = (clock ?? DateTime.now)();

  /// Process-wide instance, installed by `main()` once the app directory is
  /// known. Null before that and in most tests; every caller treats null as
  /// "reporting unavailable" rather than an error.
  static CrashReports? instance;

  final ReportStore? _store;
  final GithubReporter Function() _reporterFactory;
  final DateTime Function() _clock;
  final Future<bool> Function()? _autoSendLoader;
  final String _appVersion;

  /// When this process started. A report older than this came from a
  /// previous session, which is exactly what "the app restarted after the
  /// failure" means to the person reading the banner.
  final DateTime _sessionStartedAt;

  bool get available => _store != null;

  /// Records an unhandled failure. Local only — safe to call from an error
  /// handler. Returns the stored report, or null if capture was impossible.
  Future<PendingReport?> capture(
    Object error,
    StackTrace? stack, {
    Map<String, dynamic> context = const {},
  }) async {
    final store = _store;
    if (store == null) return null;
    try {
      final draft = await _reporterFactory().draftCrash(
        error,
        stack,
        context: context,
        appVersion: _appVersion,
      );
      return await store.add(PendingReport(
        id: _newId(draft.fingerprint),
        fingerprint: draft.fingerprint,
        category: ReportCategory.crash,
        title: draft.title,
        summary: _summaryOf(error),
        body: draft.body,
        createdAt: _clock(),
        source: 'auto',
      ));
    } on Exception catch (e) {
      // Capture is best-effort: a full disk or an unreadable log must not
      // replace the original failure with a confusing second one.
      AppLogger.warn('Crash report not saved: $e', tag: 'reporting');
      return null;
    }
  }

  Future<List<PendingReport>> pending() async => await _store?.list() ?? [];

  Future<PendingReport?> byId(String id) async => await _store?.byId(id);

  Future<void> dismiss(String id) async => _store?.remove(id);

  /// The crash the recovery banner should mention, if any.
  ///
  /// Only crashes, only from an earlier session, and never more often than
  /// [PendingReportStore.promptCooldown]: a banner that appears on every
  /// launch is one the user learns to dismiss without reading.
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

  /// Whether a queued crash may be filed without asking.
  ///
  /// Default false. This is deliberately *not* the switch that decides
  /// whether a crash is remembered — see the class doc.
  Future<bool> autoSendEnabled() async {
    final loader = _autoSendLoader;
    if (loader == null) return false;
    try {
      return await loader();
    } on Exception catch (e) {
      // Unreadable preferences fail to the private default: do not send.
      AppLogger.warn('Could not read the auto-report setting: $e',
          tag: 'reporting');
      return false;
    }
  }

  /// Files queued crashes when the user opted in AND the build can post.
  ///
  /// A stock build has no token, so this is a no-op there — the queue is
  /// for the user to send, not for the app to retry forever. Stops at the
  /// first failure so a dead network does not burn every attempt count.
  Future<void> submitQueuedIfOptedIn() async {
    if (!await autoSendEnabled()) return;
    final store = _store;
    if (store == null) return;
    final reporter = _reporterFactory();
    if (!reporter.canPost) {
      // Opted in, but this build has no token: nothing can be filed without
      // the user. Say so once per launch instead of silently doing nothing.
      AppLogger.info(
        'Automatic reporting is on but this build cannot post; '
        'queued crashes stay for the user to send.',
        tag: 'reporting',
      );
      return;
    }
    for (final report in await store.list()) {
      if (!report.isCrash) continue;
      final result = await reporter.submitDraft(
        GithubReportDraft(
          fingerprint: report.fingerprint,
          title: report.title,
          body: report.body,
        ),
      );
      switch (result.status) {
        case GithubReportStatus.created:
        case GithubReportStatus.duplicate:
          await store.remove(report.id);
        case GithubReportStatus.manualNeeded:
          // Nothing will change without a token; stop asking.
          return;
        case GithubReportStatus.failed:
          await store.markAttempt(report.id);
          return;
      }
    }
  }

  /// A one-line summary for the banner.
  ///
  /// Built from the error rather than from the draft body so the banner can
  /// say "the app stopped" in one line; the body is what the form shows.
  static String _summaryOf(Object error) {
    // Redacted before it is stored, not only before it is sent: this value
    // is written to <app>/reports/<id>.json, and those files outlive the
    // process and can be attached to an issue by hand.
    final safe = GithubReporter.sanitizeForReport(
      error.toString(),
      maxLength: 500,
    );
    final oneLine = safe.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.isEmpty) return 'The app stopped unexpectedly.';
    return oneLine.length > 160 ? '${oneLine.substring(0, 159)}…' : oneLine;
  }

  static String _newId(String fingerprint) {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$stamp-${fingerprint.isEmpty ? 'anon' : fingerprint}';
  }

  /// Where reports live for this install, e.g. `<app>/reports`.
  static Future<PendingReportStore?> openStore(String? appDirPath) =>
      PendingReportStore.open(appDirPath);
}
