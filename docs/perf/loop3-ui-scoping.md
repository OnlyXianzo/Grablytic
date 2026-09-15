# Loop 3 — O(1) UI rebuilds via structural selectors (proof of work)

## Root cause
Every progress tick (`state = [...]` in `handleProgressEvent`) rebuilt
Home + Library + PlaylistDetails in full: 3 screens × N cards, each with
thumbnail/sparkline/overlay subtrees, at ~1-2 Hz per active download. The
overlay additionally subscribed to the GLOBAL log stream, so every
app-wide log line rebuilt every mounted card.

## Fix
- `lib/providers/download_provider.dart`: new `DownloadSections`
  (ordered id buckets with value equality) + `downloadSectionsProvider`
  (notifies on add/status-flip/remove only) + `downloadItemProvider`
  family (returns the identical instance for untouched items — the
  notifier already preserves instances via targeted `copyWith`).
- Home/Library/PlaylistDetails: watch sections (structural), render rows
  by id; cards/rows are per-id Consumers. One tick rebuilds exactly the
  ticking card. Library bucket semantics preserved byte-for-byte
  (queued/cancelling/interrupted stay out of sections, as before).
- `download_log_overlay.dart`: scoped `streamForDownload` subscription,
  visible-check, 500 ms batch timer (was: global stream, setState/event).
- `download_log_sheet.dart`: live updates batched 500 ms, `jumpTo`
  replaces per-event 200 ms `animateTo` (animation pile-up), rendered rows
  clamped to last 200 with an explicit hint (buffer still holds all).
- Home cards wrapped in `RepaintBoundary` (progress-bar raster isolation).

## Grounding
- ytdlnis: `DiffUtil` deliberately excludes progress + tag-targeted
  `setProgressCompat`/text updates (`ActiveDownloadAdapter.kt`,
  `ActiveDownloadsFragment.kt`) — structural identity vs hot progress.
- Seal: `SnapshotStateMap` keyed by task id + `LazyVerticalGrid key=id`
  (`DownloaderV2.kt`, `DownloadPageV2.kt`) — same isolation in Compose.
- Flutter: `select()`/family + `RepaintBoundary` + fixed `itemExtent`
  are the documented composition for high-velocity lists.

## Evidence
- New: 4 `structural selectors` unit tests (sections stable across ticks,
  instance preservation, flip notification, bucket parity).
- Updated: sheet live test now advances 600 ms (documents the batch
  cadence); TestVerboseOpts-style contract discipline kept.
- Suites: providers 59, library+search 12, sheet+overlay 9 — all passed.
- `flutter analyze` on all touched files — clean.

## Expected metrics
- Screen rebuilds per tick: 3 full screens → 1 card.
- Overlay rebuilds: per-log-line × cards → ≤2/s per visible card.
- Sheet rebuild cost: 500 RichText rows → ≤200, at 2 Hz.

## Profile next
DevTools widget-rebuild tracker during 2 active downloads: confirm only
ticking cards rebuild; overlay `setState` ≤2/s/card; sheet frame time flat
while open.
