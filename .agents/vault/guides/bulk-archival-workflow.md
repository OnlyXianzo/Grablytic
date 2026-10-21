---
title: Bulk Archival Workflow
date: 2026-10-08
tags: [grablytic, guides, archival, batch, playlists]
status: complete
---

# Bulk Archival Workflow (from Field Practice)

How to archive channels/playlists/URL lists at scale without re-downloads, quality splits, or resume loss. Grounded in repo capabilities + the 2026-09-30 field session (54 portrait reels → [[format-ladder|portrait fix]]; batch quality snapshot), plus the 2026-10 batch tooling.

> **New since 2026-09-30** and directly relevant to archiving at scale: skip-existing, file import, retry-failed, a storage meter, engine auto-retry, and an offline capture queue for spotty field networks. Marked below.

## 1. Prepare (once per archive job)

1. **Output + archive file:** set the download folder (see [[storage-layout|storage-layout]]); enable `download_archive` (+ per-folder archives for multi-job separation). The archive is what makes re-runs idempotent — interrupting and restarting never re-fetches finished items.
2. **Quality contract:** pick the ceiling deliberately. After the [[format-ladder|2026-09-30 portrait fix]], portrait sources match by width — but a mixed landscape/portrait job still deserves one explicit ceiling for the whole run. Use the **batch quality dialog** (`480p/720p/1080p/Best`); the choice is snapshotted into `BatchState` so mid-queue preset edits cannot split the job across qualities.
3. **Auth for restricted sources:** capture cookies via Cookie WebView (Netscape export) + per-site login flags *before* the run; `anonymous_first` tries no-auth first. PO Token/JS runtime health must read `deno`/`quickjs` in Diagnostics.
4. **Capacity:** concurrency default 2 (1–5 in Settings; slider warns above 2 for battery/thermal); Wi-Fi-Only ON for metered safety; schedule window set if the job should only run at night (out-of-window items stay `pending`, never start silently).

## 2. Build the item list

- **Playlists/channels:** paste the URL → Playlist Selection screen → multi-select, reverse/shuffle as needed, note unavailable entries; ranges (`1-10`) for chunked archival; `no_playlist` for single-item pulls. Engine flat-extracts with generator guards + ID expansion.
- **URL lists:** Batch Download screen → multi-URL paste, clipboard/file import; per-item status tracked in `BatchState`.
- **File import (new):** `BatchImportScreen` picks a `.txt` or `.csv` and parses it — the first `http(s)` token per line in plain mode, every URL token per cell in quote-aware CSV mode (splits on `,` `;` tab), bare Instagram shortcodes expanded. Hard cap **500 links**, and the UI shows `(+N over the 500 cap)` so a silent truncation never looks like success. Keys `batchImportPickFile` / `batchImportCount` / `batchImportStart`. See [[batch-system|batch-system]].
- **Offline capture (new):** on a dead network, shares, pastes and clipboard scans are diverted into the [[offline-queue-reminders|offline queue]] instead of failing. When connectivity returns, one **"Download All"** tap converts the whole queue into a batch. Note this path takes the **active preset's** ceiling, not a per-batch dialog choice.
- **Observed sources (ongoing archival):** register channels as observed sources; WorkManager polls (Atom RSS → extractor fallback), dedups via [[db-schema|seen_source_videos]], auto-queues new videos as `pending`. This is the hands-free path for growing archives.

## 3. Run + survive interruptions

- Every entry point enforces the FIFO engine queue (`queued` status on cards) — see [[batch-system|batch-system]].
- Track progress on active cards (EMA speed/ETA + sparkline); per-download logs ride along for any item that errors.
- Death/reboot safety: SQLite v3 snapshots + 5 s heartbeat + startup sweep auto-resume `interrupted` items; `.part` + `.info.json` (<24 h) cover the rest. Do NOT wipe the cache dir mid-job.
- Failures: Error Recovery card per item (`recoverable`, `suggests_vpn`); redownload / audio re-fetch / **Copy Link** from the overflow menu; `clearArchive` only when you *intend* to re-fetch archive-skipped items (scoped redownload flags first).
- **Transient failures now retry themselves (new):** the engine retries a `recoverable` error up to **2 times** (3 attempts) with 5 s → 15 s backoff, *inside the same queue slot* so concurrency and ordering are preserved. Permanent types (`ERROR_PRIVATE`, `ERROR_UNAVAILABLE`, `ERROR_DRM`, `ERROR_QUOTA_EXCEEDED`, `ERROR_FORMAT_UNAVAILABLE`, `ERROR_FFMPEG_MISSING`, `ERROR_FILENAME_TOO_LONG`, `ERROR_CANCELLED`) never retry. So a flaky field connection may resolve itself before you see anything — check the log for `auto-retry attempt` before re-running a job by hand. See [[download-pipeline|download-pipeline]].
- **Retry the rest in bulk (new):** `BatchNotifier.retryFailed()` flips only the failed items back to `pending` and reuses the **snapshotted** quality ceiling, so retrying cannot silently change quality mid-job. The button reads `Retry <N> failed` and is hidden while a batch is running.

## 4. Verify the archive

- History/Library rows carry thumbnails (local sidecar first) + play affordance — spot-check playback from the app (FileProvider / OS resolver), not a file manager.
- Re-run the same list: archive-skipped = clean (zero new fetches). Export logs (see [[triage-export-workflow|triage-export-workflow]]) only if the re-run fetches anything unexpected.
- **skip-existing (new) — know what it actually checks.** Before dispatch, the batch marks items whose URL **or YouTube video id** matches a `status == 'completed'` history row, suffixing the title `' (already have)'` and never calling the engine. Consequences: (a) the engine archive still applies underneath, so the behaviour is now *visible per item*; (b) if the history read times out (2 s) it **fails open** and the batch runs unfiltered; (c) **filesystem existence is never checked** — deleting a media file keeps the history row, so the item stays skipped. Clear the history entry to force a re-fetch.
- **Storage meter (new):** the Storage settings sub-menu scans the download folder and shows the top 10 largest files with per-file delete. It prints the raw `downloadPath` (useful for spotting a stale path after a move). Deleting from here does **not** clear history — see the caveat above.
- Field lesson (2026-09-30): after any bulk portrait pull, sort by dimensions — pre-fix jobs averaged 551×871 (down-picked/audio-only `.m4a`); post-fix jobs should average ~996×1772 with no `.m4a` surprises.

## Links

- [[index|index]]
- [[batch-system|batch-system]]
- [[format-ladder|format-ladder]]
- [[db-schema|db-schema]]
- [[storage-layout|storage-layout]]
- [[triage-export-workflow|triage-export-workflow]]
- [[download-pipeline|download-pipeline]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[open-questions|open-questions]]
