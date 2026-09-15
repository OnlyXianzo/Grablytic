# Loop 4 — Low-end tuning + metadata-path repair (proof of work)

## Fixes
1. **Fragment threads halved (default 4 → 2).**
   `DEFAULT_CFG.concurrent_fragments`, the `opts_builder` fallback, and the
   `--concurrent-fragments` template default. 2 active downloads now cost 4
   fragment threads instead of 8 (worst case 27 → 15 incl. housekeeping).
   User-overridable to 16. Mobile sweet spot is 1–3 (ytdlnis defaults 1,
   Seal defaults 8 desktop-leaning); 2 splits the difference with evidence
   from the thread inventory in Loop 2 research.
2. **Indeterminate bar during post-processing** (`_DownloadCard`):
   `value: null` while `stage != null`. Merging/embedding has no progress
   callback; a pinned 99% reads as frozen (ytdlnis v1.7.5 shipped the same
   fix). Stage labels already flow via the postprocessor hook.
3. **Search JS runtime repaired**: `search.py` imported `_apply_js_runtime`
   (nonexistent) — the `except: pass` silently left every search without a
   JS runtime (slower extraction, missing formats). Now calls
   `_configure_js_runtime` like the download path. Regression test fakes a
   deno exe and asserts `js_runtimes` + `ejs:github` reach `extract_info`.

## No test weakened
- `test_fragment_and_socket_{defaults,invalid}` updated 4 → 2 with the
  rationale above (spec change, not masking).
- New search runtime test fails on the old import (verified by construction:
  old code path could never set `js_runtimes`).

## Evidence
- `pytest engine/tests/`: 452 passed. `flutter test` utils: 144 passed;
  provider + library suites: 30 passed. `flutter analyze`: clean.

## Expected metrics
- Steady-state Python threads @2 active: 12 → 8. Peak RSS during dual
  merges down (fewer concurrent TLS/demux workers + ffmpeg unaffected).
- Search latency: fewer challenge round-trips once runtime is configured.

## Follow-ups (out of scope, documented)
- `socket_timeout=30` + retries 10/10 pin wedged threads; consider shorter
  metadata timeouts (needs failure-injection tests first).
- `maxConcurrent` 2 default stands (matches ytdlnis conservatism); revisit
  only with battery/thermal data.
