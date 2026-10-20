---
title: Dart Providers
date: 2026-10-08
tags: [grablytic, api, flutter, riverpod]
status: complete
---

# Dart Providers (Riverpod Graph)

Shared-state ownership in Flutter. Repo paths: `lib/providers/` (11 files), `lib/core/engine/engine_provider.dart`, `lib/core/utils/` (20 files, where several feature-local providers now live), `docs/architecture.md` (provider graph).

> Updated 2026-10-08 against `redesign/ui` @ `bad0851`. **`lib/providers/` still holds exactly 11 files** — the new features did *not* add providers there. Instead the offline queue declares its own providers inside a feature util, and several stores are plain singletons with no provider at all. That is the most surprising structural fact of this update.

## Dependency graph

```
sharedPreferencesProvider
├── settingsProvider (AppSettings: quality ceiling, containers, network, aria2c, subs, SponsorBlock, schedule, archive, templates, auth, updates)
│   └── engineProvider (selects Platform/Desktop/Mock; reads settings for paths)
│       ├── engineStatusProvider (FutureProvider<EngineStatus>; awaits setPaths → bootstrap)
│       ├── downloadProvider (List<DownloadItem>; subscribes progressStream; owns heartbeats + recovery sweep)
│       └── resumeProvider (AsyncValue<List<ResumeCandidate>>; scanResumeCandidates)
├── playlistProvider (playlists + entry add/remove)
├── presetsProvider (7 built-in + custom; activePreset drives batch/single config)
├── batchProvider (BatchState machine; see [[batch-system|batch-system]])
└── downloadHistoryProvider (SQLite via DownloadHistoryDb; see [[db-schema|db-schema]])
```

Independent: `sharedUrlProvider` (share intent), `searchProvider`, `meteredGuard` (Wi-Fi-Only verdict), `logBufferProvider` (5K circular) → `logEntriesProvider` (filtered) ← `logIngesterProvider` (engine.logStream + AppLogger).

## Providers declared outside `lib/providers/` (new)

`lib/core/utils/offline_link_queue.dart` owns its own graph (`:310-324`):

```
connectivityProvider          // :310
offlineQueueStoreProvider     // :313-316
offlineQueueProvider          // :319-324  StateNotifierProvider<OfflineQueueNotifier, List<QueuedLink>>
                               //   seeded from OfflineQueueStore.load() in the notifier ctor (:220)
```

Full detail in [[offline-queue-reminders|offline-queue-reminders]].

## Provider-less singletons (new)

These are static/singleton state with no Riverpod provider at all — so they cannot be overridden in tests and do not trigger rebuilds:

| Singleton | File | Scope | Note |
|---|---|---|---|
| `ExtractionCache.instance` | `lib/core/engine/extraction_cache.dart:9-10` | 30-min TTL, in-memory | [[format-ladder\|T01]]; one consumer only |
| `PickerSessionState.instance` | `lib/core/utils/picker_session_state.dart:6-7` | app session | [[format-ladder\|T03]] |
| `LocalAnalytics` (static-only class) | `lib/core/utils/local_analytics.dart:3` | SharedPreferences | [[local-analytics\|T21]]; static methods, no instance |
| `OfflineQueueStore` | `lib/core/utils/offline_link_queue.dart` | SharedPreferences | wrapped by `offlineQueueStoreProvider` |
| `ThumbnailCache` (static methods) | `lib/core/utils/thumbnail_cache.dart` | app-private files | [[storage-layout\|T07]] |

## `engineProvider` gained three reminder-sync points

`lib/core/engine/engine_provider.dart` now syncs [[offline-queue-reminders|queue reminders]] to WorkManager from three places, each wrapped in `try/catch (_) {}`:

1. `:89-104` — settings-change listener (fires when `queueReminderEnabled` or `queueReminderIntervalMinutes` changes).
2. `:107-121` — queue-transition listener (early-returns unless enabled).
3. `:140-151` — startup, so a queue persisted from a previous session is honoured.

## Analytics producers

`LocalAnalytics` is called from `app_shell.dart:226` (share intake), `home_screen.dart:437` (paste intake) and `download_provider.dart:528-533` / `:569-576` / `:826-832` / `:933` (success, failure+`errorType`, retry). Neither the [[share-intent-flow|share overlay]] nor any `FormatPickerScreen` records anything — see the coverage gap in [[local-analytics|local-analytics]].

## Key providers

| Provider | File | Owns |
|---|---|---|
| `settingsProvider` | `[[dart-providers|settings_provider.dart]]` | `AppSettings`, defaults incl. `getDefaultDownloadPath()`; persisted to SharedPreferences |
| `engineProvider` | `[[dart-providers|engine_provider.dart]]` | Transport selection + disposal of all impls |
| `engineStatusProvider` | `[[dart-providers|engine_status_provider.dart]]` | Bootstrap health for banners/gates (share sheet, format picker) |
| `downloadProvider` | `[[dart-providers|download_provider.dart]]` (~1179 lines) | `DownloadItem` (progress/speed/eta/sparkline ring/stage/thumbnail/file/error/vpn/config/attempts/queuePosition), `handleProgressEvent`, EMA smoothing, heartbeat, sweep |
| `resumeProvider` | `[[dart-providers|resume_provider.dart]]` | Resume candidates UI |
| `batchProvider` | `[[dart-providers|batch_provider.dart]]` | Sequential batch runner + quality snapshot |
| `playlistProvider` | `[[dart-providers|playlist_provider.dart]]` | Playlists in SharedPreferences |
| `presetsProvider` | `[[dart-providers|preset_provider.dart]]` | Presets incl. real 480p ceiling (2026-09-30) |
| `downloadHistoryProvider` | `[[dart-providers|download_history_provider.dart]]` | SQLite history (search/filter) |
| `searchProvider` | `[[dart-providers|search_provider.dart]]` | Search UI state |
| log trio | `[[dart-providers|log_provider.dart]]` | Buffer/view/ingester; see [[logging-diagnostics|logging-diagnostics]] |

## Rules

- Shared state in providers only (`ConsumerWidget`/`Notifier`); never `setState` for shared state.
- Restart-surviving state: SharedPreferences (settings/presets/playlists) or SQLite (history). Transient (active downloads, progress) in `DownloadNotifier` memory.
- Shell (`AppShell`) listens for engine status + progress + share intents; schedule-gated dialogs pause rather than silently start.
- New since 2026-10-02: offline capture intercepts the share/paste/clipboard paths *before* they reach the picker, and the picker toggles are session-scoped — so "restart-surviving" is now a per-feature decision rather than a blanket rule. See [[format-ladder|format-ladder]] and [[offline-queue-reminders|offline-queue-reminders]].

## Links

- [[index|index]]
- [[system-overview|system-overview]]
- [[engine-service-methods|engine-service-methods]]
- [[batch-system|batch-system]]
- [[db-schema|db-schema]]
- [[logging-diagnostics|logging-diagnostics]]
- [[format-ladder|format-ladder]]
- [[share-intent-flow|share-intent-flow]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[local-analytics|local-analytics]]
- [[open-questions|open-questions]]
