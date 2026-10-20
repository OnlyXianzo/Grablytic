---
title: Batch System
date: 2026-10-08
tags: [grablytic, architecture, batch, queue, resume]
status: complete
---

# Batch System

Multi-URL batch, playlists, FIFO queue, per-item controls, and DB resume. Repo paths: `lib/providers/batch_provider.dart`, `lib/features/home/screens/batch_download_screen.dart`, `playlist_selection_screen.dart`, `batch_import_screen.dart`, `lib/features/home/widgets/batch_quality_dialog.dart`, `lib/providers/download_provider.dart`, `engine/grablytic_engine/downloader.py` (queue + auto-retry), `lib/providers/resume_provider.dart`, `engine/grablytic_engine/resume.py`, `lib/features/settings/widgets/storage_meter_card.dart`, `lib/core/utils/link_importer.dart`, `lib/core/utils/history_guard.dart`.

> Updated 2026-10-08 against `redesign/ui` @ `bad0851`. Commit `eae1657` added retry-failed, file import, skip-existing, a storage meter and auto-retry. Queue mechanics and the DB resume path are unchanged.

## Batch (Dart)

- `BatchState`: `items` (`BatchItem`: url/title/status/progress/thumbnailUrl), `currentIndex`, `isRunning`, `playlistId`, **`qualityCeiling` snapshot** (2026-09-30).
- `BatchNotifier.startBatch(items, {playlistId, qualityCeiling})` → `processNext()`: sequential runner; skips schedule window (pauses, leaves pending); skips already-downloading URLs; builds per-item config from active preset + `settingsDownloadConfig` with the **snapshot ceiling winning over the live preset** (mid-queue preset change cannot split the batch); `engine.startDownload` with fresh UUID; success → `downloadProvider.addDownload` (+ playlist link), fail → item failed; recurses.
- Entry points: Batch Download screen (multi-URL paste, clipboard/file import dialog), playlist selection start, share flows. Every entry point enforces the queue + schedule gates.
- **2026-09-30 batch quality dialog** (commit `6cea501`): `480p/720p/1080p/Best` picker before batch + playlist start; choice snapshotted into `BatchState` and persisted as the next batch default.

## Playlist selection

`PlaylistSelectionScreen`: entry multi-select, reverse/shuffle, unavailable-entry marking; ranges (`1-10`), single-item (`no_playlist`); wired to the tested engine contract (`build_playlist_items`); engine side `[[batch-system|playlist.py]]` `get_playlist_info()` (flat extract, generator guards, expanded video IDs, deleted-entry marking, storage sanitization); playlist ranges sanitized (`sanitize_playlist_items`, ≤500 items).

## Engine FIFO queue

- Default **2 concurrent** (recommended: 2 ≤8 cores, 3 flagships; Seal-proven), **1–5** configurable in Settings; semaphore backstop for direct engine callers; `_MAX_PENDING_QUEUE=500`; FIFO promotion; slot-close idempotent; `queued` card status; `queueStatus` / `setConcurrency` surfaced via [[method-channel-surface|method-channel-surface]].
- Admission guards: same-URL-under-different-ID rejected; depth limit + input bounds enforced.

## Per-item controls

Overflow menu per item: redownload, audio re-fetch, delete (file + history), per-download logs (see [[logging-diagnostics|logging-diagnostics]]), and **Copy Link** (T05, `lib/features/home/widgets/download_overflow_menu.dart`: `PopupMenuItem(value: 'copy_link', enabled: item.url.isNotEmpty)` `:112-137`, handler `:258-270` → `Clipboard.setData` + snackbar `'Link copied'`, `'No link to copy'` when empty). Scoped redownload flags + `clearArchive` recovery (see [[bulk-archival-workflow|bulk-archival-workflow]]).

`copy_link` currently has **no test coverage** — neither `download_overflow_menu_test.dart` nor `download_overflow_test.dart` asserts anything about the clipboard.

## Batch improvements (commit `eae1657`)

### retry-failed

`BatchNotifier.retryFailed()` `lib/providers/batch_provider.dart:246-263`.

- Guard `:247-250` — no-op when `failedCount == 0` **or** `state.isRunning`, so it cannot double-dispatch.
- Each failed item → `pending`, `progress: 0`, `clearError: true` (`:251-260`). `clearError` exists because `copyWith` uses `null` to mean "keep" (`:74-86`).
- Completed items untouched; then `isRunning: true` + `processNext()` (`:261-262`).
- Retry **reuses the snapshotted `qualityCeiling`** (`:298`) rather than re-reading the preset — asserted by `test/providers/batch_provider_test.dart:220-225` (all three items get `480p`).

UI: `OutlinedButton.icon` labelled `'Retry <N> failed'`, shown only when `failedCount > 0 && !isRunning` (`batch_download_screen.dart:154-176`), plus an all-skipped hint (`:166-175`).

Failure triage: `kBatchNoVideoErrorTypes = {'ERROR_FORMAT_UNAVAILABLE','ERROR_PRIVATE'}` (`:96-99`) → `batchItemSkipped` (`:102-104`) → label `'no video — skipped'` (`:109-116`).

### skip-existing — SQLite history, **not** the archive and **not** the filesystem

`markAlreadyHaveItems(items, completedRecords)` `batch_provider.dart:24-39`; suffix `const alreadyHaveSuffix = ' (already have)'` (`:17`). Verbatim docstring (`:19-23`, state field doc `:131-135`): *"Client-side skip-existing pre-filter (FEATURE 3) … so the engine archive behavior becomes per-batch visible. **Engine archive semantics are unchanged — this only avoids dispatch.**"*

- Identity matching in `lib/core/utils/history_guard.dart`: `findDuplicate` **skips any record whose `status != 'completed'`** (`:53`), then `isSameVideo` (`:43-48`) = exact normalized URL (trailing `/` stripped, `:34-40`) **or** equal YouTube video id via `extractVideoId` (`:11-32` — handles `youtu.be/<code>`, `watch?v=`, `/shorts/`, `/embed/`, `/live/`, `youtube-nocookie.com`).
- Wired as `BatchNotifier.startBatch(..., {bool skipExisting = true})` (`:175-190`), default `true` on both the param and `BatchState.skipExisting` (`:144`).
- Async pre-filter `_prefilterAlreadyHave(int generation)` (`:196-213`) reads `DownloadHistoryDb.instance.getCompleted()` with a **2-second timeout that returns `[]`** (`:199-201`) — **fail-open**, comment `:195`: *"History unavailable/slow means the batch proceeds unfiltered (engine archive still applies server-side)."* A monotonic `_generation` counter (`:171`, `:205`, `:210`) guards against `cancelAll` or a superseding `startBatch`.
- Idempotent: already-suffixed titles are skipped (`:31`); only `pending` items are considered (`:30`).

**Consequence worth knowing:** deleting a media file keeps the history row, so a re-download stays skipped unless the history entry is cleared. The storage-meter delete dialog states this outright (`storage_meter_card.dart:176-177`). Filesystem existence is never checked.

Tests: `test/providers/batch_dedupe_test.dart` — pure group (`:61-107`: canonical dup across `watch?v=` vs `youtu.be/`, non-completed ignored, no double suffix, empty pass-through) and notifier group (`:109-186`: dup never reaches the engine `:142`; `skipExisting: false` dispatches both `:151-173`; empty history proceeds unfiltered `:175-185`).

### File import

Entry: `home_screen.dart:558-569` pushes `BatchImportScreen`.

- Picker `lib/features/home/screens/batch_import_screen.dart:49-78` — `FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['txt','csv'], withData: true)`; prefers `utf8.decode(file.bytes!, allowMalformed: true)`, falls back to `File(path).readAsString()`; `_csvMode` auto-set for `.csv` (`:69-74`). Requires `file_picker: ^11.0.2`.
- Parser `lib/core/utils/link_importer.dart`: `maxBatchLinks = 500` (`:24`); `parseLinkImport(text, {csvMode})` → `LinkImportResult{links, overflowCount, totalFound}` (`:52-71`). Plain mode skips blank and `#`-comment lines and takes the **first** `http(s)` token (`:77-92`, `:212-216`). CSV mode is quote-aware (`:98-124`, `_splitCsvLine` `:127-149`, splits on `,` `;` `\t`) and scans **every** URL token per cell. Bare-Instagram-shortcode expansion (`:165-206`, `:242-253`) with a header-word stoplist — and a documented all-lowercase blind spot (`:235-241`). Scheme-less `instagram.com/p|/reel/…` normalized (`:159-161`, `:230-233`). Trailing punctuation stripped (`:220-228`).
- UI reports overflow: `'$count links ready (+N over the 500 cap)'` (`:186-196`). Keys: `batchImportInput`, `batchImportPickFile`, `batchImportCount`, `batchImportStart` (`:123,141,191,200`).
- `_startBatch` maps links 1:1 to `BatchItem(url: url, title: url)` then pushes `BatchDownloadScreen` (`:80-93`).

Tests: `test/features/home/batch_import_screen_test.dart`.

### Storage meter

`lib/features/settings/widgets/storage_meter_card.dart` (354 lines), mounted in the Storage settings sub-menu (`settings_screen.dart:487-490`) with `key: ValueKey(settings.downloadPath)` so it rescans on path change.

- `formatBytes` (`:19-32`), `StorageFileEntry` (`:35-42`), `StorageScan` + `StorageScan.missing()` (`:45-63`), `scanMediaStorage(Directory, {int topN = 10})` (`:68-103`) — recursive `list(recursive: true, followLinks: false)`, per-entry errors skipped (`:89-91`), sorted desc, `take(topN)`.
- `deleteMediaFile(filePath, baseDir)` (`:107-120`) — normalizes then `isPathWithinDir` (`lib/core/utils/trust_boundary.dart:71-79`, `p.isWithin || p.equals`), must exist and be a regular file. **Never throws.**
- Widget caches a `_scan` future with a `Refresh` button (`:161-166`, `:259-263`); subtitle `'Measuring…'` / `'Folder unavailable'` / `'{size} in {n} files'` (`:238-243`); prints the raw `downloadPath` (`:267-279`); top-10 largest with per-file delete behind a confirm dialog (`:298-348`, `:168-204`).
- Test seams `scanForTesting` / `deleteForTesting` (`:126-132`) exist because widget tests run in a `FakeAsync` zone where real disk futures never resolve (comment `:126-129`).
- Re-skinned by `85c1a8d` (C7-B2).

Tests: `test/features/settings/storage_meter_test.dart` — `formatBytes` boundaries (`:17-27`), sums/counts/largest-first (`:40-55`), missing dir (`:57-…`).

### auto-retry (engine side)

The only one of the five that touches Python: transient retry inside the already-admitted slot. Full description in [[download-pipeline|download-pipeline]] → "Transient auto-retry".

**Storage capacity is not a gate.** The engine only *logs* free space (`downloader.py:904-912`, `bootstrap.py:835-847`); `ERROR_QUOTA_EXCEEDED` exists solely as a retry-denylist entry (`downloader.py:741`). Reclamation is Dart/SQLite only, via the storage meter.

## DB-driven resume & recovery

- SQLite schema **v3** execution snapshots (`configJson`, `queuePosition`, `attempts`, byte counters) — see [[db-schema|db-schema]].
- 5 s throttled heartbeat (`updateHeartbeat`); startup recovery sweep in `DownloadNotifier` (auto-resume without user action); `BootReceiver` reboot sweep to `interrupted` (no illegal background FGS start); `.part` + `.info.json` <24 h fallback scan (`scan_resume_candidates`, `report_resume_attempt` strike-counts to `exhausted` at 3).
- `writeinfojson` default-ON (URL sidecar, cleaned on success); partials stream to output dir (no cache-eviction crashes); Wi-Fi-Only gates unattended auto-resume.

## Links

- [[index|index]]
- [[download-pipeline|download-pipeline]]
- [[format-ladder|format-ladder]]
- [[dart-providers|dart-providers]]
- [[db-schema|db-schema]]
- [[engine-service-methods|engine-service-methods]]
- [[method-channel-surface|method-channel-surface]]
- [[bulk-archival-workflow|bulk-archival-workflow]]
- [[storage-layout|storage-layout]]
- [[share-intent-flow|share-intent-flow]]
- [[open-questions|open-questions]]
