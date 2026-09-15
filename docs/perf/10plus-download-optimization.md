# 10+ Downloads Hang — Optimization Log (proof of work)

Field symptom: flagship phone hangs while downloading 10+ videos. Exported
session: **63k log lines / 7.5 MB**, tens-of-Hz `[download]` progress ticks
per active download, 233× repeated FATAL from a throwing progress handler.

Loop 0 (merged PR #2): `download_provider.dart` now parses byte counts as
`num` (was `as int?`), killing the crash→log→rebuild feedback loop.

## Loop 1 — DEBUG flood off the UI bridge (this change)

### Root cause
yt-dlp emits per-block DEBUG at tens of Hz per download. `EngineLogger._log`
forwarded **every** level over the Chaquopy/EventChannel callback straight
into the Flutter UI thread (`LogBuffer.add` + overlay/sheet rebuilds), while
`_min_level` gated only the file and queue. One log event with 3 cards
mounted = 1 buffer op (O(5000) eviction when saturated) + 3 overlay rebuilds.
At ~105 lines/s field rate: **~400 UI rebuilds/s**. That composition — not any
single widget — hangs the phone.

### Fix (both sides, one coherent contract)
- `engine/grablytic_engine/logger.py`: new `_bridge_min_level` (default
  INFO) + `set_global_bridge_min_level()`. File log + in-memory queue keep
  **every** level (diagnostics lossless); only the UI callback is gated.
  Deliberately process-global, not per-download (loggers are shared
  singletons — a per-download flag would race across concurrent downloads).
- `lib/core/utils/log_ingester.dart`: DEBUG engine entries are file-only,
  never buffered (covers desktop queue→stdout path + older engines).
- Existing `TestVerboseOpts` updated to the new contract: verbose triage
  dump asserted in the **file** (sanitized), asserted absent from bridge.

### Famous-example grounding
- **ytdlnis** (`deniscerri/ytdlnis`, main@4918fb2): `log_downloads` defaults
  `false` (`downloading_preferences.xml`); failure-only log insert
  (`DownloadWorker.kt`); 500 KB extractor cap (`StreamProcessExtractor.kt`);
  progress deliberately excluded from `DiffUtil` identity with tag-targeted
  bar updates (`ActiveDownloadAdapter.kt`, `ActiveDownloadsFragment.kt`).
- **Seal** (`JunkFood02/Seal`, main@63bd8a4): `Running(progress: Float)` state
  model, raw output behind DEBUG flag (default off), error card + copy-report
  instead of log tail, hardcoded `MAX_CONCURRENCY=3` (`DownloaderV2.kt`).
- **yt-dlp upstream**: `--progress-delta` (PR #9082, 2024.04.09) exists
  precisely so embedders stop hand-rolling flood control — planned for Loop 2
  at the hook source.

### Evidence
- `pytest engine/tests/` — 454 passed (incl. 3 new bridge-gate tests).
- `flutter test` log suites + provider/overlay/sheet suites — all passed.
- `flutter analyze` on touched files — clean.

### Expected metrics
- Bridge log events: −90%+ (INFO+ milestones only: 25/50/75% + stage lines).
- Overlay rebuilds: ~300/s → <10/s. File log bytes unchanged.

### Profile next (to verify on-device)
1. Export logs after 2 parallel downloads; count `type:log` vs `type:event`
   lines per minute — DEBUG must be file-only.
2. Flutter DevTools timeline: frame build time during active downloads;
   confirm overlay rebuild count/s in widget rebuild tracker.
3. `LogBuffer.add` call rate + eviction frequency under 10 queued items.

## Queued loops
- Loop 2: hook-source throttle (`progress_delta` ≈ 1 s / 1%) + bounded
  progress queue (drop-oldest) + buffered daily file writer.
- Loop 3: per-card `select()` providers (one card rebuilds per tick, not 3
  screens) + overlay scoped subscription + sheet render clamp.
- Loop 4: low-end tuning (fragment default 2 on low RAM, concurrency review,
  indeterminate post-processing state, mature status strings).
