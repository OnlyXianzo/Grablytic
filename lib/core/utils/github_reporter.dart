import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_logger.dart';
import 'app_version.dart';

/// Automated GitHub Issue reporter (Flutter side, STEP 3C).
///
/// - Reads the local `app_logs.txt` tail (never the whole file).
/// - Checks for duplicate open issues via the GitHub Search API to avoid spam.
/// - POSTs a formatted bug issue with environment specs + redacted log tail.
///
/// Distributed clients never receive a GitHub write token. Automatic reports
/// are prepared locally; manual reports open a user-reviewed GitHub issue form.
class GithubReporter {
  /// Conservative report-only scrubber. Diagnostic text is public once a user
  /// submits the GitHub form, so URLs and local paths are omitted entirely;
  /// regex failure returns no diagnostic text rather than the original value.
  static String sanitizeForReport(String input, {int maxLength = 6000}) {
    try {
      var value = AppLogger.redact(input);
      // Authorization and other header-like credentials (including values
      // not anticipated by the general-purpose logger scrubber).
      // replaceAll() substitutes its replacement literally: `$1` there
      // reaches the issue body as the two characters "$1". Capture groups
      // need the Mapped form (AppLogger already did it this way).
      value = value.replaceAllMapped(
        RegExp(r'^\s*(authorization|proxy-authorization|cookie|set-cookie)\s*[:=].*$', multiLine: true, caseSensitive: false),
        (m) => '${m.group(1)}: ***REDACTED***',
      );
      // URLs may identify a private resource even after query parameters are
      // removed. Do not send them at all from reports.
      value = value.replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '[URL removed]');
      // File paths expose usernames, mounted volumes, and personal folders.
      value = value.replaceAll(RegExp(r'(?:(?:[A-Za-z]:\\|/)(?:[^\s\n\r:]+[\\/])+[^\s\n\r:]+)'), '[local path removed]');
      value = value.replaceAll(RegExp(r'\b(?:/home|/Users)/[^/\s]+', caseSensitive: false), '[user path removed]');
      if (value.length > maxLength) {
        value = '[earlier content omitted]\n${value.substring(value.length - maxLength)}';
      }
      return value;
    } catch (_) {
      return '[diagnostics omitted: safe redaction failed]';
    }
  }
  final String owner;
  final String repo;
  final String? _explicitToken;

  static const String _envRepo = String.fromEnvironment(
    'GITHUB_REPO',
    defaultValue: 'OnlyXianzo/Grablytic',
  );

  /// Flutter SDK version, stamped at build time:
  /// `flutter build apk --dart-define=GRABLYTIC_FLUTTER_VERSION=$(flutter --version | head -1)`
  /// (wired in .github/workflows/build.yml). `const` is required — AOT
  /// builds drop non-const environment lookups. Empty (dev runs) → 'unknown'.
  static const String _envFlutter = String.fromEnvironment(
    'GRABLYTIC_FLUTTER_VERSION',
    defaultValue: '',
  );

  /// Short git SHA stamped at build time (`--dart-define=GRABLYTIC_GIT_SHA`,
  /// wired in .github/workflows/build.yml). Lets any pasted log be pinned to
  /// the exact commit that produced it. Empty (dev runs) → 'unknown'.
  static const String _envGitSha = String.fromEnvironment(
    'GRABLYTIC_GIT_SHA',
    defaultValue: '',
  );

  GithubReporter({
    String? owner,
    String? repo,
    String? token,
  })  : owner = owner ?? _envRepo.split('/').first,
        repo = repo ?? (_envRepo.contains('/') ? _envRepo.split('/').last : 'Grablytic'),
        _explicitToken = token;

  String? get _token {
    // No token is compiled into client apps. Explicit injection remains only
    // for controlled tests/tools; the production UI uses the reviewed issue
    // page because a distributed client cannot safely hold a write credential.
    if (_explicitToken != null && _explicitToken.isNotEmpty) {
      return _explicitToken;
    }
    return null;
  }

  bool get canPost => _token != null && _token!.isNotEmpty;

  static String get buildIdentifier => _envGitSha.isEmpty ? 'unknown' : _envGitSha;

  /// Short stable fingerprint for dedup: error type + first stack frame.
  /// Simple FNV-1a hex — no crypto dependency needed.
  String fingerprint(String title, [String? stackFirstLine]) {
    final input = '$title\n${stackFirstLine ?? ''}';
    var hash = 0x811c9dc5;
    for (final code in input.codeUnits) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Searches open issues for the fingerprint marker. Returns the existing
  /// issue URL, or null when no duplicate exists / search unavailable.
  Future<String?> findDuplicate(String fp) async {
    final token = _token;
    if (token == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final q = Uri.encodeQueryComponent('repo:$owner/$repo "$fp" state:open');
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/search/issues?q=$q'),
      );
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        AppLogger.warn('GitHub dedup search failed: ${resp.statusCode}',
            tag: 'github-reporter');
        return null;
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final total = (data['total_count'] as num?)?.toInt() ?? 0;
      if (total <= 0) return null;
      final items = (data['items'] as List?) ?? [];
      if (items.isEmpty) return null;
      return (items.first as Map)['html_url'] as String?;
    } catch (e) {
      AppLogger.warn('GitHub dedup search error: $e', tag: 'github-reporter');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Creates the issue. Returns the issue URL on success.
  Future<String?> createIssue({
    required String title,
    required String body,
    List<String> labels = const ['bug'],
  }) async {
    final token = _token;
    if (token == null) {
      throw StateError(
          'No GitHub write credential is available in this client; open the user-reviewed issue form instead.');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(
        Uri.parse('https://api.github.com/repos/$owner/$repo/issues'),
      );
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('X-GitHub-Api-Version', '2022-11-28');
      req.headers.contentType = ContentType.json;
      // Redact at the network boundary as well as when the draft is built:
      // an issue is public, and a caller that hands over raw text must not
      // be able to publish a credential.
      req.write(jsonEncode({
        'title': sanitizeForReport(title, maxLength: 200),
        'body': sanitizeForReport(body, maxLength: 6000),
        'labels': labels,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final respBody = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 201) {
        final data = jsonDecode(respBody) as Map<String, dynamic>;
        return data['html_url'] as String?;
      }
      AppLogger.warn(
          'GitHub issue POST failed: ${resp.statusCode} ${respBody.length > 500 ? respBody.substring(0, 500) : respBody}',
          tag: 'github-reporter');
      return null;
    } catch (e) {
      AppLogger.warn('GitHub issue POST error: $e', tag: 'github-reporter');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Builds a crash report **without touching the network**.
  ///
  /// Split out of [reportCrash] so the fatal handler can capture a report
  /// and return: the old single method awaited a duplicate search and a
  /// POST from inside the crash handler, which meant a crash during
  /// shutdown could sit for twenty seconds before the process gave up.
  /// Capture writes the draft to disk; submission is a separate, later
  /// decision.
  Future<GithubReportDraft> draftCrash(
    Object error,
    StackTrace? stack, {
    Map<String, dynamic> context = const {},
    String? appVersion,
  }) async {
    final stackText = stack?.toString() ?? '';
    final stackLines = stackText.trim().split('\n');
    final firstFrame = sanitizeForReport(
        stackLines.isNotEmpty ? stackLines.first.trim() : '',
        maxLength: 300);
    final errStr = sanitizeForReport(error.toString(), maxLength: 500);
    final shortErr = errStr.length > 120 ? '${errStr.substring(0, 120)}…' : errStr;
    final fp = fingerprint(shortErr, firstFrame);
    final title = '[Auto-report $fp] $shortErr';
    final logTail = await AppLogger.readLogTail();
    final body = _buildBody(
      summary: 'Automated crash report (unhandled exception).',
      repro: '_Auto-captured — see stack trace and logs below._',
      expected: 'App should not crash.',
      actual: '```\n$errStr\n$firstFrame\n```',
      fp: fp,
      logTail: logTail,
      stack: stackText.length > 6000 ? stackText.substring(0, 6000) : stackText,
      context: context,
      appVersion: appVersion ?? AppVersion.value,
    );
    return GithubReportDraft(fingerprint: fp, title: title, body: body);
  }

  /// Sends a prepared draft.
  ///
  /// This is the only place a report becomes a GitHub issue, for both the
  /// automatic and the manual path: dedup search, then create, and a
  /// status that says exactly what happened. No token means no issue, and
  /// the caller gets `manualNeeded` so it can offer the prefilled page
  /// instead of pretending.
  Future<GithubReportResult> submitDraft(GithubReportDraft draft) async {
    if (!canPost) {
      AppLogger.info(
          'Report ${draft.fingerprint} prepared; no token — manual filing.',
          tag: 'github-reporter');
      return GithubReportResult(
        status: GithubReportStatus.manualNeeded,
        fingerprint: draft.fingerprint,
        body: draft.body,
        title: draft.title,
      );
    }
    final dup = await findDuplicate(draft.fingerprint);
    if (dup != null) {
      AppLogger.info(
          'Duplicate issue found (${draft.fingerprint}): $dup',
          tag: 'github-reporter');
      return GithubReportResult(
        status: GithubReportStatus.duplicate,
        fingerprint: draft.fingerprint,
        url: dup,
        body: draft.body,
        title: draft.title,
      );
    }
    final url = await createIssue(title: draft.title, body: draft.body);
    if (url != null) {
      AppLogger.info('Issue filed (${draft.fingerprint}): $url',
          tag: 'github-reporter');
      return GithubReportResult(
        status: GithubReportStatus.created,
        fingerprint: draft.fingerprint,
        url: url,
        body: draft.body,
        title: draft.title,
      );
    }
    return GithubReportResult(
      status: GithubReportStatus.failed,
      fingerprint: draft.fingerprint,
      body: draft.body,
      title: draft.title,
    );
  }

  /// Full auto-report pipeline for an unhandled exception: build, then
  /// submit. Kept for callers that want the whole thing in one call; the
  /// crash handler uses [draftCrash] alone.
  Future<GithubReportResult> reportCrash(
    Object error,
    StackTrace stack, {
    Map<String, dynamic> context = const {},
    String? appVersion,
  }) async {
    final draft = await draftCrash(
      error,
      stack,
      context: context,
      appVersion: appVersion ?? AppVersion.value,
    );
    return submitDraft(draft);
  }

  /// Manual flow for the LogViewer "Report to GitHub" button.
  ///
  /// [fullLog] attaches the full rolling log (capped) instead of the tail.
  /// The fingerprint mixes in the filing minute so unrelated manual reports
  /// never dedup-collapse into one issue (crash reports keep pure
  /// content-based fingerprints for grouping).
  Future<GithubReportResult> reportManual({
    required String userSummary,
    String userSteps = '',
    String? appVersion,
    bool fullLog = false,
    Map<String, dynamic> context = const {},
  }) async =>
      submitDraft(await draftManual(
        userSummary: userSummary,
        userSteps: userSteps,
        appVersion: appVersion ?? AppVersion.value,
        fullLog: fullLog,
        context: context,
      ));

  /// Builds the manual draft without sending it.
  Future<GithubReportDraft> draftManual({
    required String userSummary,
    String userSteps = '',
    String? appVersion,
    bool fullLog = false,
    Map<String, dynamic> context = const {},
  }) async {
    final logTail =
        fullLog ? await AppLogger.readFullLog() : await AppLogger.readLogTail();
    final minute =
        DateTime.now().toUtc().toIso8601String().substring(0, 16);
    final safeSummary = sanitizeForReport(userSummary, maxLength: 3000);
    final fp = fingerprint('$safeSummary\n$minute', null);
    final shortSummary =
        safeSummary.length > 100 ? '${safeSummary.substring(0, 100)}…' : safeSummary;
    final title =
        '[Manual $fp] ${shortSummary.isEmpty ? 'Problem report' : shortSummary}';
    final body = _buildBody(
      summary: userSummary,
      repro: userSteps.isEmpty ? '_Not provided._' : userSteps,
      expected: '_Not provided._',
      actual: 'Manually filed from Diagnostics & Logs screen.',
      fp: fp,
      logTail: logTail,
      stack: '',
      context: context,
      appVersion: appVersion ?? AppVersion.value,
      logLabel: fullLog ? 'full' : 'tail',
    );
    return GithubReportDraft(fingerprint: fp, title: title, body: body);
  }

  /// A prefilled GitHub "new issue" page.
  ///
  /// The submission path for a stock build: the user sees the exact issue
  /// text on GitHub before pressing Submit. No token, nothing to extract
  /// from the APK. GitHub accepts a long query string, but some browsers
  /// and share sheets truncate near 8 KB, so an over-long body is left out
  /// of the URL — the caller has the text and shows it to the user.
  Uri issueUrl({
    required String title,
    required String body,
    List<String> labels = const ['bug'],
  }) {
    final base = 'https://github.com/$owner/$repo/issues/new';
    final safeTitle = sanitizeForReport(title, maxLength: 200);
    final safeBody = sanitizeForReport(body, maxLength: 6000);
    final full = Uri.parse(base).replace(queryParameters: {
      'title': safeTitle,
      'body': safeBody,
      'labels': labels.join(','),
    });
    if (full.toString().length <= _maxIssueUrlChars) return full;
    return Uri.parse(base).replace(queryParameters: {
      'title': safeTitle,
      'labels': labels.join(','),
    });
  }

  /// Roughly what browsers and Android intents handle without truncation.
  static const int _maxIssueUrlChars = 7500;

  String _buildBody({
    required String summary,
    required String repro,
    required String expected,
    required String actual,
    required String fp,
    required String logTail,
    required String stack,
    required Map<String, dynamic> context,
    required String appVersion,
    String logLabel = 'tail',
  }) {
    final env = _envSpecs(appVersion);
    // Apply the stricter public-report scrubber at the final serialization
    // boundary too, so every caller (including automatic reports) is covered.
    summary = sanitizeForReport(summary, maxLength: 3000);
    repro = sanitizeForReport(repro, maxLength: 3000);
    expected = sanitizeForReport(expected, maxLength: 2000);
    actual = sanitizeForReport(actual, maxLength: 3000);
    stack = sanitizeForReport(stack, maxLength: 6000);
    logTail = sanitizeForReport(logTail, maxLength: 6000);
    final ctxStr = context.isEmpty
        ? '_None._'
        : context.entries
            .map((e) => '- `${sanitizeForReport(e.key, maxLength: 100)}`: `${sanitizeForReport(e.value.toString(), maxLength: 500)}`')
            .join('\n');
    return '''
### Summary
$summary

### Steps to reproduce
$repro

### Expected behavior
$expected

### Actual behavior
$actual

### Platform
- OS: ${sanitizeForReport(env['os'] ?? 'unknown', maxLength: 100)} (${sanitizeForReport(env['osVersion'] ?? 'unknown', maxLength: 200)})
- App version: $appVersion (build ${env['build']})
- Dart: ${env['dart']} · Flutter: ${env['flutter'] ?? 'n/a'}
- Debug build: ${env['debug']}

### Additional context
$ctxStr

### Stack trace
${stack.isEmpty ? '_None captured._' : '```\n$stack\n```'}

### Logs ($logLabel, redacted)
```text
$logTail
```

---
<!-- fingerprint: $fp · auto-report: flutter -->
''';
  }

  Map<String, String> _envSpecs(String appVersion) {
    return {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dart': Platform.version.split(' ').first,
      'flutter': _envFlutter.isEmpty ? 'unknown' : _envFlutter,
      'build': _envGitSha.isEmpty ? 'unknown' : _envGitSha,
      'debug': kDebugMode.toString(),
    };
  }
}

enum GithubReportStatus { created, duplicate, manualNeeded, failed }

/// A report that has been built and redacted, but not sent.
///
/// Separating "prepare" from "send" is what lets the crash handler finish
/// in milliseconds: everything expensive (log read is bounded, the network
/// is not) is either local or moved to submission time.
@immutable
class GithubReportDraft {
  const GithubReportDraft({
    required this.fingerprint,
    required this.title,
    required this.body,
  });

  final String fingerprint;
  final String title;
  final String body;
}

class GithubReportResult {
  final GithubReportStatus status;
  final String fingerprint;
  final String? url;
  final String body;
  final String title;
  const GithubReportResult({
    required this.status,
    required this.fingerprint,
    this.url,
    required this.body,
    required this.title,
  });
}
