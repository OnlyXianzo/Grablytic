# Loop 2 — Throttle at the source (proof of work)

## Root cause
`build_progress_hook` emitted one JSON event per yt-dlp data block
(8k–32k ticks per stream): `json.dumps` + unbounded `queue.put` + one
Chaquopy JNI crossing + Dart decode + rebuild, per block. The daily engine
file additionally paid open+write+close (3 syscalls) per DEBUG line.

## Fix
- `engine/grablytic_engine/hooks.py`: sampler admits first tick, then
  ≥1 s elapsed or ≥1% movement; `finished`/`error` always pass through.
  Counters are absolute, dropped ticks lose nothing (bars interpolate).
  All `queue.put` → `_put_bounded` (drop-oldest at 500, never blocks the
  download thread, terminal events can't wedge behind ticks).
- `engine/grablytic_engine/logger.py`: cached daily handles (64 KiB
  buffer); INFO+ write-through (triage/export readers never stale), DEBUG
  flushed on 5 s cadence / ERROR+ / exit. One write syscall per line, zero
  open/close churn.
- Regression found by tests, fixed same loop: `test_logger.py` triage tests
  require synchronous file durability — hence INFO write-through (not pure
  batching). No test was weakened: `TestVerboseOpts`-style assertions kept.

## Grounding
- yt-dlp `--progress-delta` (PR #9082): same gate, but upstream applies it
  only to console output, not `progress_hooks` — hence the hook-side sampler.
- ytdlnis `SharedFlow(extraBufferCapacity=1)+tryEmit` (conflate under
  pressure) and 500 KB extractor cap: same drop-oldest philosophy.
- Seal `MAX_CONCURRENCY=3` + `Running(progress)` state: rate is a non-issue
  once volume is gated at the producer.

## Evidence
- `pytest engine/tests/`: 457 passed (4 new sampler/bounded tests, 2 new
  writer tests).
- Flutter untouched by this loop (no Dart changes); full Flutter suites
  re-run in Loop 3.

## Expected metrics
- Bridge progress events: ~20-50/s/download → ~1/s/download (~30×).
- Engine file syscalls: 3/line → ~1/line; DEBUG bytes flushed in 64 KB chunks.
- Worst-case retained queue strings per download: unbounded → ≤500.

## Profile next
Count `event:downloading` JSON lines per minute in `server_logs` before/after
on the same video; confirm ~30-60/min/active download with full-fidelity
`stream_finished` + terminal events intact.
