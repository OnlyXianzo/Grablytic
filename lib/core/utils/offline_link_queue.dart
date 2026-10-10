import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/home/screens/batch_download_screen.dart';
import 'notification_helper.dart';
import '../../providers/batch_provider.dart';
import '../../providers/preset_provider.dart';
import '../../providers/settings_provider.dart';
import '../engine/engine_service.dart';
import 'app_logger.dart';

/// SharedPreferences key for the persisted offline link queue.
const String offlineLinkQueueKey = 'grablytic_offline_link_queue';

/// SharedPreferences key for the cached offline link count.
const String offlineQueueCountKey = 'offlineQueueCount';

/// Interval presets in minutes for queue reminders (T20).
const List<int> queueReminderIntervalPresets = [60, 180, 360, 720, 1440];

/// Formats queue reminder interval for human-readable UI.
String formatQueueReminderInterval(int minutes) {
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  if (hours == 1) return '1 hour';
  if (hours == 3) return '3 hours (default)';
  if (hours < 24) return '$hours hours';
  final days = hours ~/ 24;
  return days == 1 ? '24 hours' : '$days days';
}

/// Requests POST_NOTIFICATIONS permission on Android 13+ only when
/// the user opts into queue reminders (T20).
Future<bool> requestQueueReminderPermission(EngineService engine) async {
  try {
    final status = await engine.notificationPermissionStatus();
    if (status['granted'] == true) {
      return true;
    }
    final req = await engine.requestNotificationPermission();
    return req['granted'] == true;
  } catch (_) {
    return true; // Fail-open on non-Android platforms
  }
}

/// Represents a URL queued while the device was offline (T19).
class QueuedLink {
  final String url;
  final String? title;
  final DateTime addedAt;
  final String source; // 'share', 'paste', 'clipboard'

  const QueuedLink({
    required this.url,
    this.title,
    required this.addedAt,
    this.source = 'paste',
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    if (title != null) 'title': title,
    'added_at': addedAt.toIso8601String(),
    'source': source,
  };

  factory QueuedLink.fromJson(Map<String, dynamic> json) {
    return QueuedLink(
      url: json['url'] as String,
      title: json['title'] as String?,
      addedAt:
          DateTime.tryParse(json['added_at'] as String? ?? '') ??
          DateTime.now(),
      source: json['source'] as String? ?? 'paste',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QueuedLink &&
          runtimeType == other.runtimeType &&
          url == other.url;

  @override
  int get hashCode => url.hashCode;
}

/// Normalizes and cleans a URL for deduplication in the offline queue.
String? normalizeQueueUrl(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  // URLs cannot contain whitespace
  if (s.contains(RegExp(r'\s'))) return null;
  final withScheme = s.startsWith('http://') || s.startsWith('https://')
      ? s
      : 'https://$s';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) return null;
  return uri.toString();
}

/// Helper to determine if the device is currently offline.
///
/// Fail-open: returns false (assumes online) if connectivity check throws
/// or wedges. A wedged platform connectivity service must never hang link
/// submit/share flows (or widget tests, where the channel never answers).
Future<bool> isDeviceOffline({Connectivity? connectivity}) async {
  try {
    final conn = connectivity ?? Connectivity();
    final results = await conn.checkConnectivity().timeout(
      const Duration(seconds: 3),
      onTimeout: () => <ConnectivityResult>[ConnectivityResult.wifi],
    );
    if (results.isEmpty) return true;
    return results.every((r) => r == ConnectivityResult.none);
  } on TimeoutException {
    return false;
  } catch (e) {
    AppLogger.warn(
      'Connectivity check error ($e); assuming online',
      tag: 'OfflineQueue',
    );
    return false;
  }
}

/// Repository for persisting the offline link queue in [SharedPreferences].
class OfflineQueueStore {
  final SharedPreferences _prefs;

  OfflineQueueStore(this._prefs);

  List<QueuedLink> load() {
    final rawList = _prefs.getStringList(offlineLinkQueueKey) ?? [];
    final links = <QueuedLink>[];
    for (final str in rawList) {
      try {
        final map = jsonDecode(str) as Map<String, dynamic>;
        links.add(QueuedLink.fromJson(map));
      } catch (e) {
        AppLogger.warn(
          'Corrupt queued link record skipped: $e',
          tag: 'OfflineQueue',
        );
      }
    }
    return links;
  }

  Future<void> save(List<QueuedLink> links) async {
    final encoded = links.map((l) => jsonEncode(l.toJson())).toList();
    await _prefs.setStringList(offlineLinkQueueKey, encoded);
    await _prefs.setInt(offlineQueueCountKey, links.length);
  }

  Future<bool> addLink(
    String rawUrl, {
    String? title,
    String source = 'paste',
  }) async {
    final normalized = normalizeQueueUrl(rawUrl);
    if (normalized == null) return false;

    final current = load();
    if (current.any((l) => l.url == normalized)) {
      AppLogger.info(
        'Link already in offline queue: $normalized',
        tag: 'OfflineQueue',
      );
      return false; // Deduped
    }

    current.add(
      QueuedLink(
        url: normalized,
        title: title,
        addedAt: DateTime.now(),
        source: source,
      ),
    );

    await save(current);
    AppLogger.info(
      'Queued offline link ($source): $normalized',
      tag: 'OfflineQueue',
    );
    return true;
  }

  Future<bool> removeLink(String rawUrl) async {
    final normalized = normalizeQueueUrl(rawUrl) ?? rawUrl.trim();
    final current = load();
    final before = current.length;
    current.removeWhere((l) => l.url == normalized);
    if (current.length != before) {
      await save(current);
      return true;
    }
    return false;
  }

  Future<void> clear() async {
    await _prefs.remove(offlineLinkQueueKey);
    await _prefs.setInt(offlineQueueCountKey, 0);
  }
}

/// State notifier managing the in-memory and persistent offline queue.
class OfflineQueueNotifier extends StateNotifier<List<QueuedLink>> {
  final OfflineQueueStore _store;
  final Connectivity _connectivity;

  OfflineQueueNotifier(this._store, [Connectivity? connectivity])
    : _connectivity = connectivity ?? Connectivity(),
      super(_store.load());

  /// Adds a link to the queue if offline, deduplicating existing entries.
  Future<bool> addLink(
    String rawUrl, {
    String? title,
    String source = 'paste',
  }) async {
    final added = await _store.addLink(rawUrl, title: title, source: source);
    if (added) {
      state = _store.load();
    }
    return added;
  }

  /// Removes a link by URL.
  Future<void> removeLink(String rawUrl) async {
    final removed = await _store.removeLink(rawUrl);
    if (removed) {
      state = _store.load();
    }
  }

  /// Clears all queued links.
  Future<void> clear() async {
    await _store.clear();
    state = const [];
  }

  /// Dispatches all queued links in one tap when connectivity is restored.
  ///
  /// Starts a batch using the active preset's quality ceiling, then clears the
  /// saved queue. Returns 0 for an empty queue, -1 while offline, or the number
  /// handed to the batch; this does not wait for downloads to complete.
  /// Queue persistence errors propagate after the batch has been started.
  Future<int> sendAll(BuildContext context, WidgetRef ref) async {
    if (state.isEmpty) return 0;

    final offline = await isDeviceOffline(connectivity: _connectivity);
    if (offline) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          styledSnackBar(context, 'Cannot start downloads: device is still offline.'),
        );
      }
      return -1;
    }

    final linksToDownload = List<QueuedLink>.from(state);
    final count = linksToDownload.length;

    // Convert to batch items and start batch
    final items = linksToDownload
        .map((l) => BatchItem(url: l.url, title: l.title ?? l.url))
        .toList(growable: false);

    final activePreset = ref.read(presetsProvider).activePreset;
    ref
        .read(batchProvider.notifier)
        .startBatch(items, qualityCeiling: activePreset.qualityCeiling);

    // Clear queue upon successful dispatch
    await clear();

    if (context.mounted) {
      // View Batch now uses rootNavigator and longer duration so the
      // action survives the queue-banner rebuild that follows clear().
      ScaffoldMessenger.of(context).showSnackBar(
        styledSnackBar(
          context,
          count == 1 ? 'Queued link sent to downloads' : 'All $count queued links sent to downloads',
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'View Batch',
            onPressed: () {
              // Use root navigator — the banner lives inside a nested
              // Scaffold/PageView where a plain Navigator.of may resolve
              // to the wrong scope and silently no-op.
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(
                  builder: (_) => BatchDownloadScreen(
                    items: items,
                    skipQualityDialog: true,
                  ),
                ),
              );
            },
          ),
        ),
      );
    }

    return count;
  }
}

/// Riverpod provider for Connectivity client (overridable in tests).
final connectivityProvider = Provider<Connectivity>((ref) => Connectivity());

/// Riverpod provider for the offline queue store.
final offlineQueueStoreProvider = Provider<OfflineQueueStore>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return OfflineQueueStore(prefs);
});

/// Riverpod provider for the reactive offline queue state.
final offlineQueueProvider =
    StateNotifierProvider<OfflineQueueNotifier, List<QueuedLink>>((ref) {
      final store = ref.watch(offlineQueueStoreProvider);
      final connectivity = ref.watch(connectivityProvider);
      return OfflineQueueNotifier(store, connectivity);
    });
