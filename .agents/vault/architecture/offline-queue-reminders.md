---
title: Offline Queue and Queue Reminders
date: 2026-10-08
tags: [grablytic, architecture, offline, queue, reminders, background]
status: complete
---

# Offline Queue and Queue Reminders

Opt-in capture of links while the device is offline, plus an optional WorkManager reminder that fires only while links are pending. Repo paths: `lib/core/utils/offline_link_queue.dart`, `lib/features/home/widgets/offline_queue_banner.dart`, `lib/core/engine/engine_service.dart`, `lib/core/engine/engine_codec.dart`, `android/app/src/main/kotlin/com/theonly/grablytic/QueueReminderWorker.kt`, `android/app/src/main/kotlin/com/theonly/grablytic/MainActivity.kt`.

> Two coupled features from the 2026-10-02 wave: T19 (persistent offline link saver + one-tap batch dispatch) and T20 (opt-in inexact offline queue reminders). Both share the same queue store. **Not on `main`.**

## Storage — SharedPreferences, not SQLite

`lib/core/utils/offline_link_queue.dart`:

```dart
const String offlineLinkQueueKey  = 'grablytic_offline_link_queue';   // :16
const String offlineQueueCountKey = 'offlineQueueCount';              // :19
```

- `OfflineQueueStore.load()` `:138-153` — `getStringList` + per-record `jsonDecode`, **corrupt records skipped**.
- `OfflineQueueStore.save()` `:155-159` — `setStringList` + `setInt(offlineQueueCountKey, links.length)`. The count is mirrored into an int purely so Kotlin can read it cheaply (see Reminder section).
- `OfflineQueueStore.clear()` `:207-210` — `remove` + count 0.

`class QueuedLink` `:51-91` — `url`, `title`, `addedAt`, `source` (`'share' | 'paste' | 'clipboard'`), `toJson`/`fromJson`, and `==`/`hashCode` **on URL only**.

## Offline detection

`isDeviceOffline({Connectivity?})` `:112-130`: 3 s timeout; `results.isEmpty` → `true`; offline only when `results.every((r) => r == ConnectivityResult.none)`. **Fails open** — returns `false` on `TimeoutException` or any throw (`:127-129`).

Uses `connectivity_plus: ^7.1.1` (`pubspec.yaml`).

## Normalization and dedupe

`normalizeQueueUrl` `:94-105` — rejects empty/whitespace-containing; prepends `https://` when no scheme; requires a host containing `.`. `addLink` refuses exact duplicates `:169-176`.

## Providers

Declared in the util file, **not** in `lib/providers/` (which remains 11 files — see [[dart-providers|dart-providers]]):

| Provider | Line |
|---|---|
| `connectivityProvider` | `offline_link_queue.dart:310` |
| `offlineQueueStoreProvider` | `:313-316` |
| `offlineQueueProvider` = `StateNotifierProvider<OfflineQueueNotifier, List<QueuedLink>>` | `:319-324`, seeded from `_store.load()` in the notifier ctor `:220` |

## One-tap batch dispatch

`OfflineQueueNotifier.sendAll(BuildContext, WidgetRef)` `:252-306`:

1. Empty queue → return `0`.
2. Still offline → return `-1` + snackbar `'Cannot start downloads: device is still offline.'` (`:258-262`).
3. Else map every `QueuedLink` → `BatchItem(url:, title: title ?? url)` (`:271-273`), call `ref.read(batchProvider.notifier).startBatch(items, qualityCeiling: activePreset.qualityCeiling)` (`:275-278`).
4. `await clear()` (`:281`).
5. Snackbar with a **"View Batch"** action pushing `BatchDownloadScreen(items: items)` (`:283-303`).

Note the batch inherits the **active preset's** quality ceiling here — unlike [[batch-system|batch-system]]'s own quality dialog, which snapshots an explicit choice.

## Banner UI

`lib/features/home/widgets/offline_queue_banner.dart`, mounted on Home at `home_screen.dart:65`. Self-hides when empty (`:25`).

| Key | Line | Meaning |
|---|---|---|
| `offline_queue_banner` | `:32` | banner root |
| `offline_queue_reminder_button` | `:169` | bell icon → reminder opt-in |
| `offline_queue_clear_button` | `:220` | clear all |
| `offline_queue_send_all_button` | `:230-239` | **"Download All"** |

Expandable per-link list with per-item remove (`:113-164`).

## Capture points (all gate on `isDeviceOffline()`)

| Path | Location | `source` |
|---|---|---|
| Share intent, in-app | `lib/features/shell/screens/app_shell.dart:228-246` | `'share'` |
| Share intent, overlay | `lib/features/home/screens/share_overlay_screen.dart:141-154` — snackbar `'Offline: Shared link saved to queue'`, then `_finish()` after 600 ms | `'share'` |
| URL paste / submit | `home_screen.dart:438-456` | `'paste'` |
| Clipboard on foreground | `app_shell.dart:81-114` `_checkClipboardOnForeground` in `didChangeAppLifecycleState(resumed)`, guarded by `_lastInspectedClipboardText` | `'clipboard'` |

## T20 — queue reminders

### Dart contract

```dart
/// Synchronizes offline queue reminder parameters with native WorkManager (T20).
Future<Map<String, dynamic>> syncQueueReminder({
  required bool enabled, int intervalMinutes = 180});     // engine_service.dart:111-116
```

- Method id `EngineMethods.syncQueueReminder = 'queue_reminder/sync'` (`lib/core/engine/engine_codec.dart:44`).
- Android invoke `platform_channel_engine_service.dart:528-546`; `null` → `{'success': true}`; throw → `ERROR_TRANSPORT`.
- Desktop is a **no-op**: `{'success': true, 'supported': false}` (`desktop_engine_service.dart:876-880`).
- Traced via `logging_observers.dart:356-366`; mock records `lastQueueReminderSync` (`mock_engine_service.dart:433-445`).

### Three sync call sites — all in `lib/core/engine/engine_provider.dart`

1. `:89-104` settings-change listener — syncs when `queueReminderEnabled` or `queueReminderIntervalMinutes` changes; sends `enabled: false` when disabled **or queue empty**.
2. `:107-121` queue-transition listener — early-returns unless enabled; `false` on empty, `true` on empty→non-empty.
3. `:140-151` startup — `enabled: true` only if `queueReminderEnabled && initialQueue.isNotEmpty`.

All wrapped in `try/catch (_) {}`.

### Settings

`queueReminderEnabled` (default `false`) and `queueReminderIntervalMinutes` (default `180`) — `lib/providers/settings_provider.dart:129-130,185-186`, read `:400-403`, setters `:752-760`.

Presets `const List<int> queueReminderIntervalPresets = [60, 180, 360, 720, 1440]` (`offline_link_queue.dart:22`); `formatQueueReminderInterval` `:25-33` (180 → `'3 hours (default)'`).

`requestQueueReminderPermission(EngineService)` `:37-48` — checks then requests notification permission; **fails open** (`return true`) on any exception or non-Android.

### Kotlin worker

`android/.../QueueReminderWorker.kt`, `class QueueReminderWorker : CoroutineWorker` `:36-39`.

**Separate job from the observed-sources poller** — unique work names differ:

| Worker | `WORK_NAME` | Citation |
|---|---|---|
| `QueueReminderWorker` | `"queue-reminders-poll"` | `QueueReminderWorker.kt:43` |
| `ObservedSourcesPollWorker` | `"observed-sources-poll"` | `ObservedSourcesPollWorker.kt:53` |

Both use `enqueueUniquePeriodicWork` / `cancelUniqueWork` independently.

Scheduling `:66-81` — `PeriodicWorkRequestBuilder<QueueReminderWorker>(interval.coerceAtLeast(15L), MINUTES, 15L, MINUTES)`: **15-minute flex**, `ExistingPeriodicWorkPolicy.UPDATE`, constraint `setRequiresBatteryNotLow(true)` only. KDoc `:30-34`: *"Inexact periodic scheduling via WorkManager (JobScheduler-backed, Doze-aware). Never touches exact alarms (avoids SCHEDULE_EXACT_ALARM). Fires ONLY while the offline queue is non-empty. Automatically cancels itself with WorkManager when the queue empties."*

`doWork()` `:86-110` — reads `FlutterSharedPreferences`; cancels + `Result.success()` if `flutter.queueReminderEnabled` is false (`:89-94`) or `readQueueCount(prefs) <= 0` (`:96-101`); else posts a notification. Any exception → `Result.success()` (`:106-109`).

`readQueueCount` `:112-163` — tries the `flutter.offlineQueueCount` int first, then `getStringSet`/`getString` on `flutter.grablytic_offline_link_queue` with a Java-`ArrayList` prefix sentinel (`LIST_IDENTIFIER = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"`, `:51`), plus JSON-array and Base64/`ObjectInputStream` fallbacks.

Notification `:165-219` — channel `"grablytic_queue_reminders"` / `"Queue Reminders"` (`:44`), fixed id `8815` (`:45`), title `"Offline Links Pending"` (`:205`), body `"You have N queued link(s) waiting to be downloaded."` (`:198-202`), icon `android.R.drawable.stat_notify_sync` (`:207`), `setAutoCancel(true)` (`:209`).

Handler: `MainActivity.kt:961-970` — `"queue_reminder/sync"` with `intervalMinutes = (interval_minutes ?: 180).coerceAtLeast(15L)`.

`POST_NOTIFICATIONS` is already declared (`android/app/src/main/AndroidManifest.xml:14`).

## Known gaps

- **Dead deep link:** `QueueReminderWorker.kt:189` writes intent extra `putExtra("open_offline_queue", true)`, but **nothing in the repo ever reads it** (repo-wide grep returns exactly that one match). Tapping the notification just opens `MainActivity`.
- **Three UI surfaces for one setting:** `PermissionsSettingsScreen` (`settings_screen.dart:265-298`), `AutomationSettingsScreen` (`:782-815` + interval select `:816-840`), and the banner icon (`offline_queue_banner.dart:168-217`).

## Tests

`test/core/utils/offline_link_queue_test.dart` — `normalizeQueueUrl` (`:22-46`), `isDeviceOffline` (`:48-64`), store persistence/dedupe/remove/clear and *"persists explicitly across store instances (restarts)"* (`:66-163`).
`test/features/home/offline_queue_banner_test.dart` — hidden when empty (`:33-49`), count/expand/clear (`:51-101`), one-tap Download All starts a batch and clears the queue when online (`:103-165`), offline guard preserves the queue (`:167-211`).
`test/core/utils/queue_reminder_test.dart` — presets/format strings (`:12-24`), defaults + persistence + restart restore (`:27-63`), `offlineQueueCount` on add/clear (`:66-103`), permission helper (`:105-117`).

## Links

- [[index|index]]
- [[share-intent-flow|share-intent-flow]]
- [[batch-system|batch-system]]
- [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]
- [[method-channel-surface|method-channel-surface]]
- [[engine-service-methods|engine-service-methods]]
- [[dart-providers|dart-providers]]
- [[settings-navigation|settings-navigation]]
- [[storage-layout|storage-layout]]
- [[open-questions|open-questions]]
