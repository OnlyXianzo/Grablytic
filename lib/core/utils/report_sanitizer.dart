import 'package:flutter/foundation.dart' show visibleForTesting;

/// Redaction for anything that leaves the device as a bug report.
///
/// This is deliberately **stricter** than [AppLogger]'s log-line scrubber:
/// a log line stays on the user's disk, but a report is posted to a public
/// GitHub issue. The extra classes here are the ones yt-dlp actually puts
/// into exception text — `Authorization: Basic …`, `Cookie: …`,
/// `?key=…` — plus the home-directory component of a file path.
///
/// The engine already has this parity (`persistent.scrub_text`, used by
/// `github_notifier`); the Dart side only knew about query tokens, so a
/// crash whose message embedded an auth header leaked on the Flutter path
/// and not the Python one.
///
/// **Fails closed.** If the scrubber itself throws (a pathological input
/// blowing a regex), [sanitize] returns a placeholder instead of the
/// original text. A report with no diagnostic value is a better outcome
/// than a report with a credential in it.
class ReportSanitizer {
  ReportSanitizer._();

  static const String redacted = '***REDACTED***';

  /// Returned when redaction could not be completed.
  static const String withheld = '[content withheld — redaction failed]';

  /// Header-shaped values: everything to end of line.
  ///
  /// Split out from the `=` patterns because a `Cookie:` header holds
  /// semicolons, and the assignment pattern stops at the first one —
  /// which would leave every cookie after the first in the clear.
  static final List<RegExp> _headerPatterns = [
    RegExp(
      r'((?:^|[\s\[{"])?(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token)\s*[:=]\s*)([^\r\n]+)',
      caseSensitive: false,
      multiLine: true,
    ),
  ];

  /// `key=value` / `key: value` / `"key": "value"` secrets.
  ///
  /// The key name survives so the report stays debuggable; the value
  /// never does.
  static final RegExp _assignmentPattern = RegExp(
    r'''(\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|token|api[_-]?key|apikey|api-key|secret|password|passwd|pwd|auth|authorization|sig|lsig|signature|session[_-]?id|sessionid|session|credential|credentials|jwt|bearer|po[_-]?token|proxy|private[_-]?key|client[_-]?secret|key)\b\s*[:=]\s*["']?)([^"'\s&,;}]+)''',
    caseSensitive: false,
  );

  /// A bare `Bearer <token>` / `Basic <base64>` outside a header line.
  static final RegExp _bearerPattern = RegExp(
    r'\b(bearer|basic)\s+([A-Za-z0-9._~+/=-]{12,})',
    caseSensitive: false,
  );

  /// `scheme://user:password@host` — proxy credentials.
  static final RegExp _userInfoPattern = RegExp(
    r'([a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@]+:)([^@\s/]+)(@)',
  );

  /// `/home/<name>/…` and `C:\Users\<name>\…`.
  ///
  /// The account name is personal data and adds nothing to a bug report;
  /// the rest of the path is diagnostic and stays.
  static final List<RegExp> _homePatterns = [
    RegExp(r'(/home/)([^/\s]+)(/)'),
    RegExp(r'(/Users/)([^/\s]+)(/)'),
    RegExp(r'([A-Za-z]:\\Users\\)([^\\\s]+)(\\)', caseSensitive: false),
  ];

  /// Redacts [input]. Never throws; returns [withheld] if it would have.
  static String sanitize(String? input) {
    if (input == null || input.isEmpty) return '';
    try {
      var out = input;
      for (final pattern in _headerPatterns) {
        out = out.replaceAllMapped(
          pattern,
          (m) => '${m.group(1)}$redacted',
        );
      }
      out = out.replaceAllMapped(
        _assignmentPattern,
        (m) => '${m.group(1)}$redacted',
      );
      out = out.replaceAllMapped(_bearerPattern, (m) => '${m.group(1)} $redacted');
      out = out.replaceAllMapped(
        _userInfoPattern,
        (m) => '${m.group(1)}$redacted${m.group(3)}',
      );
      for (final pattern in _homePatterns) {
        out = out.replaceAllMapped(pattern, (m) => '${m.group(1)}<user>${m.group(3)}');
      }
      return out;
    } catch (_) {
      return withheld;
    }
  }

  /// Redacts every value, and drops keys whose *name* marks them sensitive.
  ///
  /// Name matching is only a fast path — every value is scrubbed too, so
  /// a secret stored under an innocuous key is still caught.
  static Map<String, String> sanitizeMap(Map<String, Object?> input) {
    final out = <String, String>{};
    for (final entry in input.entries) {
      final key = sanitize(entry.key);
      if (_sensitiveKey(entry.key)) {
        out[key] = redacted;
        continue;
      }
      final value = entry.value;
      out[key] = sanitize(value is String ? value : '$value');
    }
    return out;
  }

  static bool _sensitiveKey(String key) {
    final lower = key.toLowerCase();
    const markers = [
      'cookie',
      'token',
      'password',
      'passwd',
      'secret',
      'auth',
      'proxy',
      'api_key',
      'apikey',
      'session',
      'credential',
    ];
    return markers.any(lower.contains);
  }

  /// Trims [text] to the last [maxChars] characters, cutting at a line
  /// boundary when there is one.
  ///
  /// A tail, not a head: the interesting part of a log is what happened
  /// last, and a report with 12 KB of startup noise instead of the crash
  /// is worse than no log at all.
  static String excerpt(String? text, {int maxChars = 12000}) {
    if (text == null || text.isEmpty) return '';
    if (text.length <= maxChars) return text;
    final tail = text.substring(text.length - maxChars);
    final newline = tail.indexOf('\n');
    final trimmed = newline >= 0 && newline < tail.length - 1
        ? tail.substring(newline + 1)
        : tail;
    return '[... truncated ...]\n$trimmed';
  }

  /// Exposed for tests: the patterns, in the order [sanitize] applies them.
  @visibleForTesting
  static List<String> get patternSources => [
        for (final p in _headerPatterns) p.pattern,
        _assignmentPattern.pattern,
        _bearerPattern.pattern,
        _userInfoPattern.pattern,
        for (final p in _homePatterns) p.pattern,
      ];
}
