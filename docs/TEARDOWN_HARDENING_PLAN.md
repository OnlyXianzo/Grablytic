# Architectural Teardown Hardening — Verified Implementation Plan

Source: full-depth architectural teardown (34 findings + 30 hard questions).
Method: `verified-implementation` skill (Research → Verify → Implement → Prove).

## Research findings (Phase 1)

| # | Question | Sources | Verdict | Confidence |
|---|----------|---------|---------|-----------|
| R1 | Does `format_code: "all"` amplify a download? | yt-dlp manpage (`all: Select all formats separately`), Arch manpage, deepwiki yt-dlp, yt-dlp#3562 (`-f allvideo` → "Downloading 21 format(s)") | Confirmed: one HTTP fetch + one file per format. `mergeall` merges all. Amplification is real and unbounded. | High |
| R2 | Deno sandbox flags available? | docs.deno.com/runtime/reference/permissions, deno.land/manual@v1.36.4, OpenReplay blog | `--deny-read/--deny-write/--deny-net/--deny-env/--deny-run/--deny-sys/--deny-ffi/--deny-import` all exist since Deno 1.36 (Aug 2023). Deny wins over allow. | High |
| R3 | yt-dlp `real_run_ffmpeg` still present? | Local yt-dlp 2026.08.19 introspection | Present, signature `(self, input_path_opts, output_path_opts, *, expected_retcodes=(0,))`. Patch target is valid *today* but brittle by design. | High |
| R4 | `Queue.empty()` reliability | Python stdlib docs | Documented as unreliable in multi-threaded contexts. The existing comment's invariant ("worker puts terminal BEFORE stamping finished_at") is an engine-internal invariant, not an upstream yt-dlp contract. | High |
| R5 | Deno `deny-write` bypass | CVE-2025-61785 | `Deno.utime` could bypass `--deny-write`; fixed in 2.5.3/2.2.15. Sandbox hardening must also deny env/run/sys. | Medium |

## Written research reports

- [Python guards and worker bounds](TEARDOWN_RESEARCH_PYTHON_GUARDS_AND_WORKER_BOUNDS.md)
- [Dart secure storage and history search](TEARDOWN_RESEARCH_DART_STORAGE_AND_SEARCH.md)
- [Android service concurrency and native-package integrity](TEARDOWN_RESEARCH_ANDROID_CONCURRENCY_AND_INTEGRITY.md)
- [CI integration testing and coverage](TEARDOWN_RESEARCH_CI_TESTING_AND_COVERAGE.md)
- [30 hard questions and implementation-scoped answers](TEARDOWN_HARD_QUESTIONS_ANSWERS.md)

## Verified approach (Phase 2 gate)

Reconcile rule applied: **most recent + most authoritative + corroborated**. Where sources
disagreed (none materially), noted inline.

1. **IPC framing** — treat stdout as a write-once protocol channel. Redirect stray
   `sys.stdout` writes to stderr; only the protocol writer touches the real stdout.
   Bound slow-lane in-flight requests; shed load with an explicit `ERROR_BUSY`
   envelope rather than an unbounded pool queue. (Finding 1)
2. **FFmpeg serialization** — never rely on a silent monkey-patch. Verify the patch
   target exists at runtime, expose `is_ffmpeg_serialized()`, and fail *closed to
   serialized-or-error*, never to "unserialized and quiet". (Finding 2)
3. **Concurrency bookkeeping** — `collections.deque` for the pending queue, an
   index map for live-URL dedup, and a bounded watchdog pool. (Findings 3, 4)
4. **Retry backoff** — release the concurrency slot during backoff and re-queue at
   the *front* of the pending queue. (Finding 10)
5. **Site profiles** — remote profiles are *untrusted input*: validate `format_code`
   (length cap + amplifying-keyword ban), validate `container` against an allowlist,
   and never cache a failed/empty payload. (Findings 6, 8, 18, 25)
6. **Auto-report** — redact secrets from free-text exception strings and log tails
   before they leave the device; make the target repo configurable per build. (Finding 5)
7. **SSRF** — DNS failure must fail *closed* for profile URLs (a control-plane
   fetch) while staying fail-open for media URLs (user content). (Finding 29)
8. **Deno** — run the PO-Token solver with an explicit deny-all permission set.
   (Finding 30)
9. **Secrets at rest** — proxy credentials must not sit in plaintext
   `SharedPreferences` / `DownloadRecord.configJson`. (Findings 12, 21)
10. **Android** — `DownloadService` state guarded by a lock; wake-lock renewal off
    the main thread; `BootReceiver` must not start a foreground service. (Findings 7, 17, 26)
11. **Data integrity** — atomic profile writes, bounded `.info.json` reads, FTS4
    search with startup-index validation and parameterized LIKE fallback, resumable progress preservation. (Findings 13, 20, 23)
12. **Correctness** — channel URLs are not playlists; collision-safe default
    output template; user `verbose` respected; hook errors classified. (Findings 14, 15, 16, 22, 24)
13. **IPC contract** — explicit `contract_version`, negotiation, and a
    dispatch table. (Finding 33)
14. **CI** — real Android→Chaquopy→Python IPC test, dead code excluded from
    coverage, raised Flutter coverage floor. (Findings 27, 31, 32)

## Commit plan (small, independently reviewable commits)

1. `fix(engine): firewall stdout framing and bound IPC dispatch`
2. `fix(engine): fail loudly when FFmpeg serialization cannot be installed`
3. `perf(engine): deque-ify pending queue and index live-URL dedup`
4. `fix(engine): bound and reap cancel watchdog threads`
5. `fix(engine): release the concurrency slot during retry backoff`
6. `fix(engine): cancel-aware FFmpeg gate and honest cancel state`
7. `fix(engine): never cache an empty or failed site-profile payload`
8. `fix(engine): validate remote site-profile format and container`
9. `fix(engine): redact secrets from auto-report payloads`
10. `fix(engine): fail closed on DNS failure for profile URLs`
11. `fix(engine): sandbox the Deno PO-token solver`
12. `fix(engine): atomic site-profile writes`
13. `fix(engine): bound info.json reads in the resume scan`
14. `fix(engine): replace Queue.empty() with an explicit drained flag`
15. `fix(engine): do not classify channel URLs as playlists`
16. `fix(engine): collision-safe default output template`
17. `fix(engine): respect the user verbose setting`
18. `fix(engine): classify hook errors instead of assuming recoverable`
19. `fix(engine): snapshot the logger error tail under a lock`
20. `fix(ipc): version the engine contract and negotiate it`
21. `fix(desktop): release pending completers on engine restart`
22. `fix(db): FTS4-backed download history search and proxy scrub`
23. `fix(dart): preserve progress across auto-resume`
24. `fix(android): guard DownloadService state with a lock`
25. `fix(android): renew the wake lock off the main thread`
26. `fix(android): BootReceiver must not start a foreground service`
27. `fix(android): SHA-256 verify package trees and guard ZIP extraction`
28. `fix(android): keep proxy credentials out of plaintext storage`
29. `ci: exercise the real Android→Chaquopy→Python IPC path`
30. `ci: exclude non-runnable code from the coverage denominator`
31. `ci: raise the Flutter coverage floor`
32. `docs: answer the 30 hard questions and record residuals`

Previously published small commits are on `fix/architectural-teardown-hardening`; the latest known remote tip is `893fb3b1b1bf`. Follow-up changes are being committed separately on top of that tip. Push only after confirming a fast-forward; never force-push.

## Phase 3 — Blast radius (per change, checked before editing)

| Change | Consumers to update |
|---|---|
| stdout firewall | `__main__.main`, `poll_queues`, `engine/cli_test.py` harness |
| FFmpeg patch verification | `downloader._ensure_ffmpeg_serialized`, `bootstrap` (status payload) |
| pending-queue deque | `downloader._pump_queue`, `start_download`, `cancel_download`, `shutdown_downloads` |
| watchdog pool | `downloader.cancel_download`, `downloader._start_cancel_watchdog` |
| site-profile validation | `site_profiles.load_site_profiles_from_url`, `opts_builder` (format/container consumers) |
| contract version | `bootstrap()`, `desktop_engine_service`, `platform_channel_engine_service`, `mock_engine_service` |
| FTS4 | `download_history_db.getAll`, schema migration, `download_provider` |
| DownloadService lock | `DownloadService.kt`, `MainActivity.kt`, `DownloadDbSweepHelper.kt` |
| proxy secret storage | `settings_provider.dart`, `DownloadRecord.configJson` writers/readers |

## Phase 4 — Prove

* `pytest engine/tests/ -q --cov=engine/grablytic_engine --cov-fail-under=75` green.
* New tests per finding, in the same commit as the fix.
* `ruff check --select F --ignore F401 engine/` clean.
* `python3 tool/check_doc_links.py` clean.
* `PYTHONPATH=. pytest tool/tests -q` green; LCOV parser tests pass; parse all workflow YAML and verify the Android bridge job is present.
* Do not claim Flutter Pub resolution or Android/Kotlin/device behavior unless the SDK/emulator run completes. Keep the DNS-rebinding TOCTOU residual explicit.
