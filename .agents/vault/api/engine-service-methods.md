---
title: Engine Service Methods
date: 2026-10-08
tags: [grablytic, api, engine]
status: complete
---

# Engine Service Methods

The `EngineService` abstract surface all UI code programs against. Repo path: `engine_service.dart` (now **132 lines**, was 117). Transport mapping in [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]; wire format in [[method-channel-surface|method-channel-surface]]; callers in [[dart-providers|dart-providers]].

> Updated 2026-10-08 against branch `redesign/ui` @ `bad0851`. **The abstract surface itself barely moved** — one method was added (`syncQueueReminder`) and every other method keeps its 2026-09-30 signature. Most of the 64 new commits are Dart-side (UI, local stores), not engine-surface changes; see [[settings-navigation|settings-navigation]].

## Lifecycle / paths

| Method | Signature | Notes |
|---|---|---|
| `bootstrap` | `Future<Map> bootstrap()` | Binaries, manifest, yt-dlp version; fail-closed `--version` probes |
| `setPaths` | `Future<void> setPaths(Map paths)` | data/output/cache dirs, binary paths incl. `deno_path`/`nodejs_path`, cookies, PO token; **must precede** `bootstrap` (`engineStatusProvider` awaits it) |
| `dispose` | `void dispose()` | Idempotent transport teardown; provider disposes every impl (leak fix) |

**Note:** since `T09`, responses ≥50 KB are decoded off the UI isolate via `EngineEnvelope.decodeResponseAsync` (`engine_codec.dart:63-76`, `Isolate.run`). Android transport only — the desktop stdio path does not use it. Used by `getFormats`, `getPlaylistInfo`, `search`.

## Downloads / discovery

| Method | Signature | Notes |
|---|---|---|
| `startDownload` | `(url, downloadId, config, networkType) → Map` | Admits to FIFO queue; `{success, queued?}`; never blocks |
| `cancelDownload` | `(downloadId) → Map` | Sets cancel event → `cancelled` event |
| `progressStream` | `Stream<Map>` | downloading / post-proc / finished / error / cancelled; 99% cap |
| `getFormats` | `(url, config) → Map` | Structured streams + recommendations; see [[format-ladder|format-ladder]] |
| `getPlaylistInfo` | `(url, config) → Map` | Flat entries; see [[batch-system|batch-system]] |
| `search` | `(query, site=youtube, limit=20, config) → Map` | `ytsearch`/`scsearch` extractors |
| `scanResumeCandidates` | `(cacheDir) → Map` | `.part` scan; see [[batch-system|batch-system]] |
| `reportResumeAttempt` | `(cacheDir, filepath, success) → {success, attempts}` | Strike-count to `exhausted` at 3; never throws |
| `queueStatus` / `setConcurrency` | `→ {active, queued, max_concurrent}` / clamps 1–5 | Engine backstop; Dart owns queued UI |
| `clearArchive` | `→ {success, removed, path}` | Redownload-after-delete recovery; see [[bulk-archival-workflow|bulk-archival-workflow]] |

## Updates / schedule / OS

| Method | Signature | Notes |
|---|---|---|
| `updateCheck` / `setUpdateChannel` | `→ Map` / `(channel: stable\|nightly\|master)` | SHA-256 diff; archive-to-archive compare |
| `syncSchedule` | `(enabled, intervalMinutes=60, wifiOnly, requiresCharging)` | WorkManager sync; see [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]] |
| `logStream` | `Stream<Map>` | Engine `{"type":"log"}` lines; see [[logging-diagnostics|logging-diagnostics]] |
| `exportLogToDownloads` | `(sourcePath, displayName) → {success, path?}` | Tail-capped; never throws |
| `batteryExemptionStatus` / `requestBatteryExemption` | `→ {success, supported, exempt?}` | Android-only |
| `networkMeteredStatus` | `→ {success, supported, metered}` | Wi-Fi-Only gate; failures report metered |
| `notificationPermissionStatus` / `requestNotificationPermission` | Android 13+ | Older Android always granted |
| `openNotificationSettings` / `openUrl` / `openFile` | system resolvers | `openFile`: FileProvider (Android), xdg-open/open/explorer (desktop) |
| `getSharedUrl` / `sharedUrlStream` | share intent | FIFO share queue; drains cold starts |

## Added since 2026-09-30

| Method | Signature | Notes |
|---|---|---|
| `syncQueueReminder` | `Future<Map> syncQueueReminder({required bool enabled, int intervalMinutes = 180})` (`engine_service.dart:113`) | Opt-in WorkManager reminder for the [[offline-queue-reminders\|offline queue]]. Desktop returns `{'success': true, 'supported': false}`. Android handler at `MainActivity.kt:961-970` |

## Capabilities that deliberately did **not** grow the surface

Several notable features added no `EngineService` method — they are Dart/local-only:

| Feature | Where it lives | Note |
|---|---|---|
| Extraction cache (T01) | `lib/core/engine/extraction_cache.dart` | in-memory, 30-min TTL, in-flight dedup; consumed only by `FormatPickerScreen` — see [[format-ladder\|format-ladder]] |
| Preview stream (T08) | rides inside the `getFormats` result as `preview_stream` | engine-side selection in `formats.py`; no new method |
| Picker session toggles (T03) | `lib/core/utils/picker_session_state.dart` | in-memory for the app session |
| Analytics (T21) | `lib/core/utils/local_analytics.dart` | SharedPreferences JSON |
| Offline queue (T19) | `lib/core/utils/offline_link_queue.dart` | SharedPreferences string list |
| Thumbnails (T07) | `lib/core/utils/thumbnail_cache.dart` | app-private dir, 2 MB cap |
| Batch retry-failed / skip-existing / file import / storage meter | Dart providers + `batch_import_screen.dart` | only engine-side auto-retry is new |
| Settings reorganisation (T14/T15) | pure widget tree | see [[settings-navigation\|settings-navigation]] |

## Implementations

- Android: [[flutter-chaquopy-python-ipc|PlatformChannelEngineService]]; Desktop: [[flutter-chaquopy-python-ipc|DesktopEngineService]]; Tests: `MockEngineService` (fake data + timed progress).

## Links

- [[index|index]]
- [[method-channel-surface|method-channel-surface]]
- [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]
- [[dart-providers|dart-providers]]
- [[download-pipeline|download-pipeline]]
- [[format-ladder|format-ladder]]
- [[batch-system|batch-system]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[open-questions|open-questions]]
