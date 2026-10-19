# Architectural teardown — 30 hard questions, answered

**Implementation branch:** `fix/architectural-teardown-hardening`
**Answer date:** 2026-10-19
**Implementation/research notes:** [`TEARDOWN_HARDENING_PLAN.md`](TEARDOWN_HARDENING_PLAN.md) and the linked research reports.

> **Numbering distinction:** Finding **#11** is the desktop IPC lifecycle issue: pending request completers must not hang across an engine-process exit/restart. Hard question **#11** below is a different item: whether `format_code: "all"` can still reach yt-dlp through the direct config/IPC path.

## Answers

### 1. What does yt-dlp's `all` selector actually do, and why is it dangerous?

`all` selects all available formats separately; `mergeall` selects/merges all formats and depends on multistream behavior. This can turn one user request into many files/fetches, so it is treated as an amplification policy rather than an ordinary format label. Source research and recency are in [`TEARDOWN_RESEARCH_PYTHON_GUARDS_AND_WORKER_BOUNDS.md`](TEARDOWN_RESEARCH_PYTHON_GUARDS_AND_WORKER_BOUNDS.md).

### 2. How are remote site-profile selectors sanitized?

`sanitize_profiles()` rejects the entire profile entry if its `format_code` expression or `container` is unsafe. It does not partially trust an entry. Unknown fields survive intentionally for extractor-specific hints. See `engine/grablytic_engine/site_profiles.py` and `engine/tests/test_site_profile_hardening.py`.

### 3. What does the format-expression validator reject?

`is_safe_format_expression()` accepts only a nonempty string of at most 512 characters, rejects control characters, and rejects selector atoms beginning with `all` as well as `mergeall` (including forms such as `allvideo` and `(all)`). Filter contents are stripped before checking selector atoms, so a harmless filter value containing the word `all` is not confused with the selector keyword. See `engine/grablytic_engine/format_selector.py` and `engine/tests/test_format_selector.py`.

### 4. Are output containers and filenames constrained against unsafe values and collisions?

The container allowlist is `mp4`, `mkv`, `webm`, `mov`, `m4a`, `mp3`, `opus`, `flac`, `aac`, `ogg`, `wav`, and `vorbis`, case-insensitively and with an optional leading dot; unsupported values fall back to the safe default. The default filename contains `%(id)s`; output-template traversal/length checks still apply, and a custom template without `%(id)s`, `%(playlist_index)s`, or `%(autonumber)s` emits a one-time collision warning. User `verbose` is no longer forced on. See `config.py`, `opts_builder.py`, `docs/output_templates.md`, and `test_output_template_and_verbosity.py`.

### 5. Can a large or invalid remote profile replace the working cache?

The HTTP body is read with a `256 KiB + 1` bound; an oversized body is rejected before JSON parsing. Network/parse failure, an empty payload, or a payload whose entries are all rejected leaves the existing cache/defaults in place. The cached profile set is replaced only after a nonempty sanitized result. See `site_profiles.py` and `test_site_profile_hardening.py`.

### 6. Are redirects checked, or is only the initial profile URL checked?

Both. The initial URL is checked, and `_SafeProfileRedirectHandler` validates each new destination before urllib follows it. On an unsafe target it raises `urllib.error.HTTPError`, the documented way to stop other redirect handlers from processing that redirect. `test_profile_redirect_to_unsafe_target_is_rejected` covers this behavior.

### 7. What is the DNS-failure policy for profile-fetch URLs?

Fail closed. A profile URL is an application control-plane fetch; if DNS yields no answer or times out, it is rejected. A known private/local result is always rejected. See `url_guard.py` and `test_url_guard_fail_closed.py`.

### 8. What is the DNS-failure policy for user-selected media URLs?

Fail open only when resolution yields no answer, preserving availability through transient DNS trouble for content the user selected. If any known answer is private/local/reserved, the URL is rejected. This does not make DNS failure evidence of safety; it is an explicit availability trade-off for that sink. See `test_url_guard_ssrf.py`.

### 9. Which URL/address forms are blocked?

Only HTTP(S) URLs without embedded username/password are eligible, and the URL text is capped at 2,048 characters. The guard blocks localhost names, `.local`/`.localhost`, metadata hostnames and `169.254.169.254`, private/loopback/link-local/multicast/reserved/unspecified ranges, IPv6 unique-local/link-local/loopback, IPv4-mapped/6to4/Teredo embedded private addresses, and alternate numeric IPv4 spellings such as octal/hex/short forms. It rejects a hostname if any resolved address is non-public. See `engine/grablytic_engine/url_guard.py`.

### 10. Does the DNS precheck eliminate DNS rebinding?

No. It checks DNS answers and re-checks redirect hops, but urllib resolves again when it makes the socket connection; the validated IP is not pinned to that connection. A DNS-rebinding/time-of-check-to-time-of-use race remains. Stronger assurance requires a pinning transport or network egress controls. This residual is explicitly recorded in the research report and must not be described as fully eliminated.

### 11. Can `format_code: "all"` bypass the profile filter through direct config or IPC?

No. IPC config reaches `build_format_string()`, which independently calls `is_safe_format_expression()` on `format_code`; this prevents bypassing the remote-profile sanitation path. Unsafe custom selectors are ignored and the normal quality-safe selector ladder is used. Tests cover `all`, `mergeall`, `allvideo`, and `(all)` through the direct selector/options path as well as remote-profile sanitation. This is separate from Finding #11 above.

### 12. What prevents a corrupt or oversized resume `.info.json` from controlling recovery?

Resume sidecars are bounded to 1 MiB before JSON decoding. The parsed value must have the expected object/string shapes, and the candidate media URL is revalidated before use. Oversized, malformed, or unsafe sidecars do not provide a resume URL. Separately, the app restores interrupted records with their persisted progress/byte totals instead of resetting the UI to zero. See `engine/grablytic_engine/resume.py`, `engine/tests/test_resume_hardening.py`, and `lib/providers/download_provider.dart`.

### 13. Are local profile writes crash-safe, and how are playlist previews bounded?

`save_profiles_to_disk()` creates a temporary file in the destination directory, writes JSON, flushes and `fsync`s it, then atomically replaces the destination with `os.replace`; failure cleans up the temporary file. Playlist previews are capped at 500 returned entries and carry `truncated` plus `max_entries` metadata so a cut list is not presented as complete. This bounds the returned preview; it does not guarantee yt-dlp never internally fetches more metadata before returning. See `site_profiles.py`, `playlist.py`, and their tests.

### 14. What happens if yt-dlp changes or removes the FFmpeg serialization hook?

Startup verifies that one supported seam was actually installed and remains identifiable (`real_run_ffmpeg`, with `Popen.run` as the fallback). If neither can be verified or installation raises, a download returns a terminal FFmpeg-gate error before constructing `YoutubeDL`; it does not silently proceed with concurrent post-processing. The gate is one-at-a-time, bounded by 600 seconds, and responds to cancellation while waiting. See `downloader.py` and `test_ffmpeg_gate_verification.py`.

### 15. What are the download admission and queue limits?

Default concurrency is two; users can set one through five. The FIFO pending queue is capped at 500, the live-URL index avoids repeated full scans, and the active-record map is capped at 2,000 terminal/live entries with only terminal records eligible for overflow trimming. See `downloader.py`, `test_queue.py`, and `test_live_url_index.py`.

### 16. How many automatic retries happen, and do they hold a download slot?

At most two retries (three attempts total), after 5-second and 15-second backoffs, only for retryable errors not on the permanent-error denylist. Up to five workers can back off concurrently; the download releases its concurrency slot while waiting, then reacquires through the normal admission gate. A user cancel interrupts the wait. See `test_retry_transient.py` and `test_backoff_slot_release.py`.

### 17. Can cancelled but wedged downloads create unlimited watchdog threads?

No. Cancellation uses a fixed four-worker watchdog pool with a 500-job bounded queue and a deadline set at cancellation time. After 120 seconds, a still-alive worker is treated as presumed stopped and a terminal cancellation is emitted. Generation and slot-token checks stop stale watchdog work from closing a later download under a reused ID. See `test_watchdog_pool.py` and `test_slot_identity.py`.

### 18. How are thread-start failures, same-ID reuse, duplicate URLs, and channel URLs handled?

An active record is published before thread start; the thread object and spawn state are visible to cancellation before `start()`. Failed construction/start unwinds the exact slot token. A cancel racing with startup sets the event and lets spawn resolution decide the slot, avoiding orphan workers. Terminal closure and queue promotion require the matching slot token; duplicate live URLs are found via the index, keyed by audio mode. Separately, `detect_channel()` keeps channel/user/@handle URLs out of playlist mode; unless explicitly expanded, yt-dlp receives `noplaylist=True`, preventing an accidental full-channel sweep. See `test_slot_identity.py`, `test_concurrency_leak_and_queue_stalls.py`, `test_live_url_index.py`, and `test_channel_not_playlist.py`.

### 19. Does cleanup infer result delivery from `Queue.empty()`?

No. Python documents `Queue.empty()` as unreliable for synchronization. Cleanup uses an explicit `result_delivered` marker set on accepted callback delivery or after the IPC poller drains the result queue, plus a 30-second terminal-record failsafe. See `test_result_delivered_flag.py`.

### 20. What if the terminal event callback throws, or a stale worker finishes after an ID is reused?

`_emit_event()` now reports whether the callback accepted the event. A failed terminal callback falls back to the result queue instead of being marked delivered. Delivery marking is checked against the slot token, so an old completion cannot mark a new generation's result. The IPC poller captures the same generation token when draining. See `test_terminal_delivery_fallback.py` and the IPC framing tests.

### 21. Can a stray `print()` or yt-dlp log line corrupt the JSON IPC stream?

The public stdout is replaced by a firewall: unexpected writes go to stderr; protocol responses use one locked writer that appends and flushes complete JSON lines. This protects line framing from ordinary Python-level stray output. See `engine/grablytic_engine/__main__.py` and `test_ipc_framing_and_backpressure.py`.

### 22. Is IPC work admission bounded, and can cancel/status wait behind a slow extraction?

Yes. Slow work uses eight workers and a semaphore allowing at most 24 in-flight slow requests; saturation returns a retryable `ERROR_BUSY`. Cancel, queue status, concurrency/clear-archive setters, and path setup run in the inline fast lane. An IPC line over the configured 4 MiB parser limit is refused. The guard is at the engine parser; clients should still avoid constructing arbitrarily large request strings before writing them.

### 23. How does engine-contract versioning behave?

The Python and Dart contracts currently use integer `contract_version: 1` for major version 1, expose minor `0` separately, and report the display string `1.0`. A missing version remains accepted for legacy callers; malformed versions and a different major receive `ERROR_CONTRACT_MISMATCH`. Minor additions remain compatible. The dispatch registry is checked against the advertised method set at import time. See `contract.py`, `engine_contract.dart`, and `test_contract.py`.

### 24. What happens to pending desktop IPC completers across engine crash/restart?

On abnormal process exit, `_restart()` completes every outstanding completer with an `Engine process exited` error and clears `_pending`; late frames from that process are ignored because their IDs are no longer pending. A new engine can serve new requests, but in-flight operations are **not replayed** automatically. `_sendRequest()` also removes entries on write failure/timeout. `dispose()` is distinct: it completes waiters with a `success:false`, `ERROR_DISPOSED` result, then clears the map. Tests are in `test/core/engine/desktop_engine_service_test.dart`. This answers Finding #11; it is not Hard Question #11.

### 25. Where are proxy credentials stored, and what happens if secure storage fails?

The proxy URL is stored behind `ProxySecretStore` using `flutter_secure_storage` (Android Keystore-backed implementation) rather than plaintext preferences or download `configJson`. Legacy preference/record values are migrated or stripped. If secure storage is unavailable, the legacy plaintext preference is removed and downloads that need the proxy are paused/fail closed rather than silently persisting or using an unprotected value. See `lib/core/storage/proxy_secret_store.dart`, `settings_provider.dart`, and the database migration tests.

### 26. What data can auto-report send, and is reporting automatic by default?

Issue filing is opt-in via `GRABLYTIC_AUTO_REPORT=1`; otherwise the notifier returns a manual-report result. The GitHub token comes only from `GITHUB_TOKEN` or an explicit argument and is never logged. Free-text fields/log tails are redacted for token/signature/password/proxy values and URL userinfo; the target repository is build-configurable, and log-tail inclusion can be disabled. The logger's error-tail snapshot is taken under its lock. Redaction is defense in depth, not a proof against every novel secret format. See `github_notifier.py`, `logger.py`, and `test_auto_report_redaction.py`.

### 27. Why use SQLite FTS4, and what happens if it is missing or stale?

The history search uses an FTS4 virtual table with insert/update/delete triggers and a migration backfill. Startup verifies that the virtual table, all three triggers, and indexed title/URL contents agree with the source table; unavailable or stale FTS4 falls back to parameterized `LIKE` search. Token/phrase semantics can differ from substring `LIKE`, so the fallback is a compatibility path, not identical query semantics. Android system SQLite is the target for FTS4 verification; host FFI SQLite may not include it. See `download_history_db.dart` and `test/core/database/download_history_fts_test.dart`.

### 28. Is the PO-token solver enabled, and what exactly does the Deno sandbox cover?

The local PO-token stub is inert and the solver remains disabled by default. If enabled later, the local Deno invocation uses `deno run` with explicit deny-read/write/net/env/run/sys/ffi/import flags and no allow flags, alongside no-config/no-remote/no-prompt controls. This does **not** mean yt-dlp's separately fetched EJS bundle passes through Grablytic's local hash allowlist; yt-dlp supplies its own pinned-version/hash mechanism for that upstream bundle. See `po_token.py`, `test_deno_sandbox.py`, and the research report.

### 29. What does Android native-package hashing prove, and what remains unverified?

`BinaryPackageManager` writes a versioned v5 stamp containing SHA-256 digests for both the bundled archive and the extracted tree. The canonical tree digest traverses with `lstat` (without following symlinks) and includes sorted relative paths, entry kinds, executable bits, symlink targets, file sizes, and file bytes; a cache hit rechecks both archive and tree, while legacy CRC32 stamps are cache misses. ZIP validation rejects absolute/drive/backslash/NUL paths, `.`/`..` or empty segments, duplicate/colliding normalized paths, entries under non-directory ancestors, reserved stamp paths, and symlinks that escape the package tree. The temp/backup swap and recovery remain. This detects archive/cache drift; it is **not** a publisher-signature system or a per-file signed manifest. Kotlin/device behavior was not compiled or exercised locally because Android build tools are absent. The API 35 emulator IPC job compiles and runs the real bridge but skips native-package downloads, so extraction and mutation-recovery still need a dedicated on-device test. The `DownloadService` lock/executor behavior shares the Android-tooling limitation.

### 30. What is proven locally, what is only configured in CI, and what is still open?

Local proof on 2026-10-19: **718 engine tests passed in 51.90s with 79.71% coverage** (`--cov-fail-under=75`, Python 3.13); **3 coverage-tool tests passed**; the corrected contract assertions pass in the full engine suite. `ruff check --select F --ignore F401 engine/`, Python compilation, relative-doc-link checks (18 files), workflow YAML parsing (6 jobs in `verify.yml`), and `git diff --check` passed. The Flutter SDK snapshot in this workspace is incomplete (no runnable Dart cache and no Git checkout), and Gradle/Kotlin/Android build tools are absent, so Flutter analysis/tests and Android compilation/device behavior are not locally verified. `pubspec.lock` now contains the secure-storage and integration-test entries, cross-checked against pub.dev package metadata, but local `flutter pub get` could not run; CI's resolver is the final lockfile check. No local `coverage/lcov.info` exists; the LCOV parser unit tests pass. The API 35 emulator and Flutter coverage gates are configured but have not run remotely. DNS rebinding remains the explicit security residual from Answer 10; Android behavior and the GitHub Actions run await external verification.

## Code/test map

- Python URL/profile/selector: `engine/grablytic_engine/{url_guard,site_profiles,format_selector,opts_builder}.py`; `engine/tests/test_{url_guard_fail_closed,url_guard_ssrf,site_profile_hardening,format_selector}.py`
- Python work/IPC: `engine/grablytic_engine/{downloader,__main__,hooks}.py`; `engine/tests/test_{terminal_delivery_fallback,result_delivered_flag,watchdog_pool,slot_identity,ipc_framing_and_backpressure}.py`
- Dart/Android/CI: `lib/core/engine/desktop_engine_service.dart`, `android/app/src/main/kotlin/com/theonly/grablytic/`, `.github/workflows/verify.yml`, and the integration/Flutter test directories.
