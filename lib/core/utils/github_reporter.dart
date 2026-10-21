import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'app_logger.dart';
import 'report_sanitizer.dart';

/// Automated GitHub Issue reporter (Flutter side, STEP 3C).
///
/// - Reads the local `app_logs.txt` tail (never the whole file).
/// - Checks for duplicate open issues via the GitHub Search API to avoid spam.
/// - POSTs a formatted bug issue with environment specs + redacted log tail.
///
/// Token is NEVER hardcoded: pass explicitly (from secure storage / user
/// input) or compile with `--dart-define=GITHUB_TOKEN=ghp_...`.
///
/// A release build has no token, and that is the intended design — a token
/// shipped in an APK is a token anyone can extract. So the normal path is
/// [issueUrl]: a prefilled `github.com/.../issues/new` page the user
/// reviews and submits in their own browser, under their own account. The
/// app cannot observe that submission, and does not pretend to: the
/// resulting status is `needsBrowser`, never `created`.
///
/// Every free-text field goes through [ReportSanitizer] before it is put
/// in an issue, on both the direct-POST and the prefilled-URL path.
class GithubReporter {
  final String owner;
  final String repo;
  final String? _explicitToken;

  /// Compile-time token. CI / local builds inject via:
  /// `flutter run --dart-define=GITHUB_TOKEN=ghp_...`
  static const String _envToken = String.fromEnvironment(
    'GITHUB_TOKEN',
    defaultValue: '',
  );

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
    if (_explicitToken != null && _explicitToken.isNotEmpty) {
      return _explicitToken;
    }
    if (_envToken.isNotEmpty) return _envToken;
    // Never read from SharedPreferences here — caller passes a user-supplied
    // token explicitly so secrets stay out of prefs-backed logs.
    return null;
  }

  bool get canPost => _token != null && _token!.isNotEmpty;

  /// Short stable fingerprint for dedup: error type + first stack frame.
  /// Simple FNV-1a hex — no crypto dependency needed.
  String fingerprint(String title, [String? stackFirstLine]) =>
      reportFingerprint(title, stackFirstLine);

  /// A prefilled GitHub "new issue" URL.
  ///
  /// This is the submission path for a stock build: the user sees the exact
  /// issue text in their browser, on GitHub, before pressing Submit. No
  /// token, no backend, nothing that can be extracted from the APK.
  ///
  /// GitHub accepts a long query string but some browsers and share sheets
  /// truncate around 8 KB, so an over-long body is dropped from the URL and
  /// the caller is expected to have copied it to the clipboard first (the
  /// UI does). The bare new-issue page still opens, so the tap is never a
  /// dead end.
  Uri issueUrl({
    required String title,
    required String body,
    List<String> labels = const ['bug'],
  }) {
    final base = 'https://github.com/$owner/$repo/issues/new';
    final safeTitle = ReportSanitizer.sanitize(title);
    final safeBody = ReportSanitizer.sanitize(body);
    final uri = Uri.parse(base).replace(queryParameters: {
      'title': safeTitle,
      'body': safeBody,
      'labels': labels.join(','),
    });
    if (uri.toString().length <= _maxIssueUrlChars) return uri;
    return Uri.parse(base).replace(queryParameters: {
      'title': safeTitle,
      'labels': labels.join(','),
    });
  }

  /// Roughly what browsers and Android intents handle without truncation.
  static const int _maxIssueUrlChars = 7500;

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
    List<String> labels = const ['bug', 'auto-report'],
  }) async {
    final token = _token;
    if (token == null) {
      throw StateError(
          'GITHUB_TOKEN missing — pass --dart-define=GITHUB_TOKEN=... or supply a token.');
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
      // Redact at the boundary, not at every call site: an issue is public
      // and a caller that forgets is a credential on the internet.
      req.write(jsonEncode({
        'title': ReportSanitizer.sanitize(title),
        'body': ReportSanitizer.sanitize(body),
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

  /// Full auto-report pipeline for an unhandled exception.
  /// Returns [GithubReportResult] — either an issue URL, a duplicate URL,
  /// or the formatted body for manual filing when no token is configured.
  Future<GithubReportResult> reportCrash(
    Object error,
    StackTrace stack, {
    Map<String, dynamic> context = const {},
    String appVersion = '0.0.1-beta+1',
  }) async {
    final stackLines = stack.toString().trim().split('\n');
    final firstFrame = stackLines.isNotEmpty ? stackLines.first.trim() : '';
    final errStr = error.toString();
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
      stack: stack.toString().length > 6000
          ? stack.toString().substring(0, 6000)
          : stack.toString(),
      context: context,
      appVersion: appVersion,
    );

    if (!canPost) {
      AppLogger.info('Crash captured ($fp); no token — manual filing body ready.',
          tag: 'github-reporter');
      return GithubReportResult(
        status: GithubReportStatus.manualNeeded,
        fingerprint: fp,
        body: body,
        title: title,
      );
    }
    final dup = await findDuplicate(fp);
    if (dup != null) {
      AppLogger.info('Duplicate crash issue found ($fp): $dup',
          tag: 'github-reporter');
      return GithubReportResult(
        status: GithubReportStatus.duplicate,
        fingerprint: fp,
        url: dup,
        body: body,
        title: title,
      );
    }
    final url = await createIssue(title: title, body: body);
    if (url != null) {
      AppLogger.info('Crash issue filed ($fp): $url', tag: 'github-reporter');
      return GithubReportResult(
        status: GithubReportStatus.created,
        fingerprint: fp,
        url: url,
        body: body,
        title: title,
      );
    }
    return GithubReportResult(
      status: GithubReportStatus.failed,
      fingerprint: fp,
      body: body,
      title: title,
    );
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
    String appVersion = '0.0.1-beta+1',
    bool fullLog = false,
    Map<String, dynamic> context = const {},
  }) async {
    final logTail =
        fullLog ? await AppLogger.readFullLog() : await AppLogger.readLogTail();
    final minute =
        DateTime.now().toUtc().toIso8601String().substring(0, 16);
    final fp = fingerprint('$userSummary\n$minute', null);
    final title = '[Manual $fp] ${userSummary.length > 100 ? '${userSummary.substring(0, 100)}…' : userSummary}';
    final body = _buildBody(
      summary: userSummary,
      repro: userSteps.isEmpty ? '_Not provided._' : userSteps,
      expected: '_Not provided._',
      actual: 'Manually filed from Diagnostics & Logs screen.',
      fp: fp,
      logTail: logTail,
      stack: '',
      context: context,
      appVersion: appVersion,
      logLabel: fullLog ? 'full' : 'tail',
    );
    if (!canPost) {
      return GithubReportResult(
        status: GithubReportStatus.manualNeeded,
        fingerprint: fp,
        body: body,
        title: title,
      );
    }
    final dup = await findDuplicate(fp);
    if (dup != null) {
      return GithubReportResult(
        status: GithubReportStatus.duplicate,
        fingerprint: fp,
        url: dup,
        body: body,
        title: title,
      );
    }
    final url = await createIssue(title: title, body: body);
    return GithubReportResult(
      status: url != null ? GithubReportStatus.created : GithubReportStatus.failed,
      fingerprint: fp,
      url: url,
      body: body,
      title: title,
    );
  }

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
    final ctxStr = context.isEmpty
        ? '_None._'
        : ReportSanitizer.sanitizeMap(context)
            .entries
            .map((e) => '- `${e.key}`: `${e.value}`')
            .join('\n');
    // Sanitized here as well as at the network boundary: the body is also
    // returned to callers that copy it to the clipboard, and "redacted only
    // on the wire" left the clipboard copy — the one people paste into
    // gists and chat — in the clear.
    return ReportSanitizer.sanitize('''
### Summary
$summary

### Steps to reproduce
$repro

### Expected behavior
$expected

### Actual behavior
$actual

### Platform
- OS: ${env['os']} (${env['osVersion']})
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
''');
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

/// Short stable fingerprint for dedup: a label plus its first distinguishing
/// line. FNV-1a hex — no crypto dependency, stable across runs and
/// platforms, and short enough to live inside an issue body comment.
String reportFingerprint(String label, [String? detail]) {
  final input = '$label\n${detail ?? ''}';
  var hash = 0x811c9dc5;
  for (final code in input.codeUnits) {
    hash ^= code;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
