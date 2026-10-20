---
title: DB Schema
date: 2026-10-08
tags: [grablytic, api, sqlite, database]
status: complete
---

# DB Schema (`grablytic.db`)

SQLite history + resume + scheduler ledger. Repo path: `lib/core/database/download_history_db.dart` (510 lines, singleton `DownloadHistoryDb`, `Database? _db` cached, `dbPathForTesting` override for unit tests). Desktop uses `sqflite_common_ffi`.

> **Re-verified 2026-10-08 against `redesign/ui` @ `bad0851`: still `version: 4`** (`download_history_db.dart:191`). Despite 64 new commits, **no migration was added.** New local stores went to SharedPreferences instead — see [[storage-layout|storage-layout]] → "Local-only state". That is the single most useful thing to know about this file today.

## Tables

**`downloads`** (history + execution snapshots):

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | UUID (Dart `_uuid.v4()`) |
| `url` / `title` | TEXT NOT NULL | |
| `platform` / `format` / `quality` | TEXT | |
| `fileSize` | INTEGER | Mirrored from `totalBytes` by heartbeat |
| `filePath` | TEXT | Null until finished; drives play affordance |
| `status` | TEXT DEFAULT 'pending' | `pending, queued, downloading, cancelling, completed, error, interrupted` |
| `progress` | REAL DEFAULT 0 | 0–1 |
| `timestamp` | TEXT NOT NULL | ISO-8601 creation |
| `thumbnailUrl` / `thumbnailPath` | TEXT | Remote URL vs local sidecar (v2); local-first rendering |
| `configJson` (v3) | TEXT | Full execution snapshot for resume |
| `queuePosition` (v3) | INTEGER | FIFO order for recovery sweep |
| `attempts` (v3) | INTEGER DEFAULT 0 | Retry count |
| `lastErrorType` / `lastErrorMessage` (v3) | TEXT | Classified error carry-over |
| `bytesDownloaded` (v3) | INTEGER DEFAULT 0 | Heartbeat counter |
| `totalBytes` (v3) | INTEGER | Expected size |
| `updatedAt` (v3) | TEXT | Heartbeat timestamp |

Index: `idx_downloads_status`.

**`seen_source_videos`** (v4 scheduler ledger): `(source_url TEXT, video_id TEXT, seen_at TEXT)`, PK `(source_url, video_id)`, index `idx_seen_source_url`.

## Migrations (`onCreate` = v4 fresh; `onUpgrade` idempotent via `PRAGMA table_info` guards)

- v1 → v2: `ADD COLUMN thumbnailPath`.
- v2 → v3: resume columns (`configJson`, `queuePosition`, `attempts`, `lastErrorType`, `lastErrorMessage`, `bytesDownloaded`, `totalBytes`, `updatedAt`) + status index.
- v3 → v4: `CREATE TABLE IF NOT EXISTS seen_source_videos` + index.

## Key queries (methods)

- `insert` (replace on conflict), `update`, `delete`, `getById`, `getAll({search, statusFilter, limit, offset})` (title/URL LIKE, `timestamp DESC`), `getCompleted(limit=500)` (dup/overwrite checks; video-id match in Dart `history_guard`), `clearAll`.
- `sweepActiveToInterrupted({now})`: `downloading/queued/pending/cancelling → interrupted` (returns affected rows; called at startup + by `BootReceiver` path).
- `getInterrupted({limit})` (recovery sweep, `queuePosition ASC, timestamp ASC`), `markInterrupted(id)`, `updateHeartbeat(id, bytesDownloaded, totalBytes?, progress)` (5 s throttle), `getPending(limit=50)` (scheduler/startup admission).
- `getSeenSourceVideoIds / recordSeenSourceVideos (batch, replace) / filterNewSourceVideoIds (dedups + de-dupes input) / clearSeenSourceVideos({sourceUrl?})`.

## What is deliberately **not** in SQLite

Worth stating explicitly, because the 2026-10-02 → 2026-10-06 wave added a lot of persisted state and none of it touched this schema:

| Feature | Where it went instead | Note |
|---|---|---|
| [[local-analytics\|Analytics events]] | SharedPreferences JSON, 2000-cap | [[local-analytics\|local-analytics]] |
| [[offline-queue-reminders\|Offline link queue]] | SharedPreferences `StringList` + mirrored int | read cheaply by Kotlin |
| T07 [[storage-layout\|thumbnail cache paths]] | `thumbnailPath` column (already existed, v2) + app-private files | no new column |
| T01 extraction cache | memory only | 30-min TTL |
| T03 picker toggles | memory only | app session |
| [[batch-system\|skip-existing]] | *reads* `getCompleted()`; no new table | 2s timeout, fail-open |

Consequence: only `getCompleted()` powers skip-existing, and deleting a media file via the [[batch-system|storage meter]] keeps the history row, so the item stays skipped (stated in the delete dialog, `storage_meter_card.dart:176-177`).

## Links

- [[index|index]]
- [[batch-system|batch-system]]
- [[dart-providers|dart-providers]]
- [[storage-layout|storage-layout]]
- [[download-pipeline|download-pipeline]]
- [[local-analytics|local-analytics]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[bulk-archival-workflow|bulk-archival-workflow]]
- [[open-questions|open-questions]]
