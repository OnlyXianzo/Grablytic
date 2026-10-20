---
title: Storage Layout
date: 2026-10-08
tags: [grablytic, architecture, storage]
status: complete
---

# Storage Layout

Where bytes live on device/desktop. Repo paths: `lib/providers/settings_provider.dart` (`getDefaultDownloadPath`), `lib/core/database/download_history_db.dart`, `lib/core/utils/offline_link_queue.dart`, `local_analytics.dart`, `thumbnail_cache.dart`, `picker_session_state.dart`, `docs/troubleshooting.md` (rename migration).

> Updated 2026-10-08 against `redesign/ui` @ `bad0851`. The media/log/SQLite layout is unchanged. What is new is a whole class of **non-media state that lives in SharedPreferences**, plus an app-private thumbnail cache — see "Local-only state" below.

## Directories

| Content | Android | Desktop | Notes |
|---|---|---|---|
| Finished media | `/storage/emulated/0/Download/Grablytic` (via `getDefaultDownloadPath`) | `<Downloads>/Grablytic` (`getDownloadsDirectory`) | User-configurable in Settings; legacy `Download/TrueStream` renamed best-effort on first run |
| App data (`data_dir`) | app-private files dir | app support dir | Injected via `paths/set`; hosts `logs/` |
| Flutter logs | `app_logs.txt` + `log_YYYY-MM-DD.txt` in app data | same | 30 s flush; see [[logging-diagnostics|logging-diagnostics]] |
| Engine logs | `logs/server_logs.log` (+ `.1…` backups) + `engine_*.txt` | same | `RotatingFileHandler`; flushed before export |
| Cache (`.part`, `.info.json`) | `cache_dir` from `paths/set` | same | Resume scan scope; 24 h expiry |
| SQLite | `grablytic.db` (app documents dir) | same (+ `sqflite_common_ffi`) | Schema v4; see [[db-schema|db-schema]] |
| Log exports | MediaStore `Download/Grablytic-logs/` (timestamped) | `~/Downloads/Grablytic-logs/` | >5 MB exports as a **tail** (Android only); fallback app-private `log-exports/`. See [[logging-diagnostics|logging-diagnostics]] |
| Thumbnails (sidecar) | next to media (`writethumbnail` kept) | same | `thumbnail_path` on finish events; local-first rendering |
| Thumbnails (cache, T07) | `<documents>/thumbnails/` | same | 2 MB per image, `.jpg`, sanitized name ≤64 chars |

## Thumbnail cache (T07)

`lib/core/utils/thumbnail_cache.dart` — app-private prefetch cache, `subdir = 'thumbnails'` (`:12`), `maxBytes = 2 MB` (`:15`), `fileNameFor` sanitizes to `[A-Za-z0-9_-]` with a `'thumb'` fallback and a 64-char cap, `.jpg` extension (`:18-23`).

`fetchToCache` (`:27-78`): `http`/`https` only (`:34-36`); creates the dir recursively; short-circuits if the destination exists (`:44`); `HttpClient` with 15 s connect / 20 s response timeouts (`:45-47`); requires HTTP 200 (`:48`), `image/*` MIME (`:50`) and `contentLength <= 2 MB` (`:51`); streams chunks with a running 2 MB abort that deletes the partial file (`:52-69`); **never throws**, returns `null` on failure (`:71-72`); `client.close(force: true)` in `finally` (`:73-77`).

Called at job creation from `lib/providers/download_provider.dart:318` (`_prefetchThumbnail`, `:326-350`), also on redownload (`:824`) and one other path (`:931`). Skips an empty URL or an existing path (`:328`), runs `unawaited` (`:329`), writes to `'${docs.path}/thumbnails'` (`:331-333`), then re-checks provider state and writes only if still empty (`:338-347`), re-persisting the DB row.

Render chain (`lib/features/home/screens/home_screen.dart:721-755`, comment *"T07 artwork chain: app-private cache file → network URL → status icon"*): `Image.file(File(cached), 112×68, errorBuilder: → _remoteOrPlaceholder())` then `Image.network(remote, …, errorBuilder: → _statusPlaceholder())`.

Tests: `test/core/utils/thumbnail_cache_test.dart` (safe/capped filenames; rejects empty/non-http/garbage without network), `test/providers/download_thumbnail_test.dart` (path recorded + `DownloadRecord` round-trip).

## Local-only state (SharedPreferences) — deliberately not SQLite

| Key | Type | Cap | Note |
|---|---|---|---|
| `grablytic_offline_link_queue` | `StringList` of JSON | — | [[offline-queue-reminders|offline-queue-reminders]] |
| `offlineQueueCount` | `int` | — | mirrored count, read cheaply by Kotlin (`QueueReminderWorker.readQueueCount`) |
| `local_analytics_events_v1` | JSON string | **2000 events**, tail-truncated | [[local-analytics|local-analytics]] |
| `queueReminderEnabled` / `queueReminderIntervalMinutes` | bool / int | — | defaults `false` / `180` |
| `share_behavior` (+ legacy `autoStartDownloadOnShare`) | string / bool | — | [[share-intent-flow|share-intent-flow]] |
| `logoVariant` | string | — | allowlist `{system,dark,light,legacy}`, anything else → `system`; [[design-system|design-system]] |
| `useGridView`, `qualityCeiling`, … | various | — | ordinary settings |

**In-memory only (dies with the process):** `PickerSessionState` (T03 toggles, [[format-ladder|format-ladder]]), `ExtractionCache` (T01, 30-min TTL), `LogBuffer` (5000 entries, though it also mirrors to file).

## Conventions

- **Partials stream to the output dir** (not cache) — ended cache-eviction crashes; `writeinfojson` sidecar cleaned on success; FFmpeg merges serialized (600 s guard).
- **Download archive:** `download_archive` file skips repeats; optional per-folder archives; `clearArchive` recovery for archive-skipped re-downloads — see [[bulk-archival-workflow|bulk-archival-workflow]].
- **Output templates:** default `%(uploader)s - %(title)s` + custom templates; `output_tmpl` confined by `trust_boundary` validator (blocks `-o`/`--paths` escapes), `template-arg` validator in Dart.
- **Temp dirs** `0700`; checksum-or-fail downloads; no silent unverified fetches. Media/profile URLs and the archive path are validated by [[url-guard-ssrf|url_guard]] before use.
- **Rename migration** (TrueStream → Grablytic): app ID changed so Android treats it as a new app; app-private data does NOT carry over; `Download/TrueStream` → `Download/Grablytic` best-effort; Linux `.deb` `Replaces/Conflicts`, AUR `replaces`; v0.0.1 assets keep `truestream-*` names.

## Links

- [[index|index]]
- [[db-schema|db-schema]]
- [[batch-system|batch-system]]
- [[logging-diagnostics|logging-diagnostics]]
- [[bulk-archival-workflow|bulk-archival-workflow]]
- [[dev-setup|dev-setup]]
- [[design-system|design-system]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[local-analytics|local-analytics]]
- [[open-questions|open-questions]]
