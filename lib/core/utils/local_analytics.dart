import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:shared_preferences/shared_preferences.dart';

/// Strictly local download analytics (T21).
///
/// No network, no SDK, no telemetry — events persist as JSON in
/// SharedPreferences on this device only. Sources: shared intents, pasted
/// links, per-domain buckets (YouTube/Instagram/other), successes, retries,
/// failures with a failed-job list, range filter, Clear. Jobs recorded with
/// `incognito: true` are never stored (no incognito source exists yet; the
/// guard is structural and unit-tested).
class LocalAnalytics {
  static const String _keyEvents = 'local_analytics_events_v1';
  static const int _maxEvents = 2000;

  /// Intake kinds.
  static const String kindShare = 'share';
  static const String kindPaste = 'paste';

  /// Outcome kinds.
  static const String outcomeSuccess = 'success';
  static const String outcomeRetry = 'retry';
  static const String outcomeFailure = 'failure';

  /// Domain buckets.
  static const String domainYoutube = 'youtube';
  static const String domainInstagram = 'instagram';
  static const String domainOther = 'other';

  /// Classify a URL into a domain bucket (pure, unit-tested).
  static String domainOf(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('youtu')) return domainYoutube;
    if (lower.contains('instagram')) return domainInstagram;
    return domainOther;
  }

  static Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  static Future<List<Map<String, dynamic>>> _read() async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_keyEvents);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<Map>().map(Map<String, dynamic>.from).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _write(List<Map<String, dynamic>> events) async {
    try {
      final prefs = await _prefs();
      final capped = events.length > _maxEvents
          ? events.sublist(events.length - _maxEvents)
          : events;
      await prefs.setString(_keyEvents, jsonEncode(capped));
    } catch (_) {}
  }

  static Future<void> _append(Map<String, dynamic> event) async {
    final events = await _read();
    events.add(event);
    await _write(events);
  }

  /// Record a share/paste intake. Incognito intakes are dropped silently.
  static Future<void> recordIntake(
    String kind,
    String url, {
    bool incognito = false,
  }) async {
    if (incognito) return;
    if (kind != kindShare && kind != kindPaste) return;
    await _append({
      'ts': DateTime.now().millisecondsSinceEpoch,
      'kind': kind,
      'domain': domainOf(url),
      'outcome': null,
    });
  }

  /// Record a job outcome. Incognito jobs are dropped silently.
  static Future<void> recordOutcome({
    required String jobId,
    required String outcome,
    String url = '',
    String title = '',
    String errorType = '',
    bool incognito = false,
  }) async {
    if (incognito) return;
    if (outcome != outcomeSuccess &&
        outcome != outcomeRetry &&
        outcome != outcomeFailure) {
      return;
    }
    await _append({
      'ts': DateTime.now().millisecondsSinceEpoch,
      'kind': null,
      'domain': domainOf(url),
      'outcome': outcome,
      'jobId': jobId,
      'title': title.length > 120 ? '${title.substring(0, 120)}…' : title,
      'errorType': errorType,
    });
  }

  /// Aggregated counts in [sinceMs, now]. Null [sinceMs] = all time.
  static Future<Map<String, int>> summary({int? sinceMs}) async {
    final events = await _read();
    final inRange = events.where(
      (e) => sinceMs == null || (e['ts'] as int? ?? 0) >= sinceMs,
    );
    var shares = 0, pastes = 0, success = 0, retries = 0, failures = 0;
    var yt = 0, ig = 0, other = 0;
    for (final e in inRange) {
      if (e['kind'] == kindShare) shares++;
      if (e['kind'] == kindPaste) pastes++;
      switch (e['domain']) {
        case domainYoutube:
          yt++;
          break;
        case domainInstagram:
          ig++;
          break;
        default:
          other++;
      }
      switch (e['outcome']) {
        case outcomeSuccess:
          success++;
          break;
        case outcomeRetry:
          retries++;
          break;
        case outcomeFailure:
          failures++;
          break;
      }
    }
    return {
      'shares': shares,
      'pastes': pastes,
      'success': success,
      'retries': retries,
      'failures': failures,
      'youtube': yt,
      'instagram': ig,
      'other': other,
      'total': inRange.length,
    };
  }

  /// Failed jobs newest-first in range (never includes raw URLs).
  static Future<List<Map<String, dynamic>>> failures({int? sinceMs}) async {
    final events = await _read();
    return events
        .where(
          (e) =>
              e['outcome'] == outcomeFailure &&
              (sinceMs == null || (e['ts'] as int? ?? 0) >= sinceMs),
        )
        .toList()
      ..sort((a, b) => (b['ts'] as int? ?? 0).compareTo(a['ts'] as int? ?? 0));
  }

  /// Delete all locally stored analytics.
  static Future<void> clear() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(_keyEvents);
    } catch (_) {}
  }
}
