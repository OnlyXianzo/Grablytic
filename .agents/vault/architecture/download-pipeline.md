---
title: Download Pipeline
date: 2026-10-08
tags: [grablytic, architecture, downloads, engine]
status: complete
---

# Download Pipeline

End-to-end lifecycle of one download. Repo paths: `engine/grablytic_engine/downloader.py`, `opts_builder.py`, `hooks.py`, `errors.py`, `formats.py`, `lib/providers/download_provider.dart`, `lib/core/utils/thumbnail_cache.dart`, `engine/grablytic_engine/__main__.py`.

> Updated 2026-10-08 against `redesign/ui` @ `bad0851`. Changes: a URL-safety gate moved **ahead** of admission, extraction caching, a free-space log line, engine-side transient auto-retry, and a much wider set of entry points.

## Sequence

1. **URL capture** — `HomeScreen` URL field, the in-app share handler (`app_shell.dart:249-342`), the standalone [[share-intent-flow|share overlay]], or clipboard on foreground (`app_shell.dart:81-114`). Offline devices divert to the [[offline-queue-reminders|offline queue]] instead of starting. Every share/paste is counted by [[local-analytics|local analytics]].
2. **Format discovery** — Dart [[engine-service-methods|getFormats]] → Python `formats.py` `get_formats()` (`extract_info(download=False)`, JS runtime resolves n-sig/SABR) → [[download-pipeline|FormatPickerScreen]] (thumbnail + duration + stream counts header, muxed badges). Results pass through the **T01 extraction cache** (30-min TTL, in-flight dedup) and the result may carry a `preview_stream` for T08 — both covered in [[format-ladder|format-ladder]].
3. **URL safety gate (new, before admission)** — `start_download` calls [[url-guard-ssrf|`is_safe_media_url(url)`]] and returns `ERROR_INVALID_PARAM` **before** the FIFO admission, the queue depth check, or any thread spawn (`downloader.py:1254-1268`). Same gate on `formats/get` (`formats.py:18-24`) and `playlist/info` (`playlist.py:74-80`).
4. **Admission** — Dart [[engine-service-methods|startDownload]] (`url`, `downloadId`, `config`, `networkType`); engine FIFO queue (default 2 concurrent, 1–5 clamped; `_MAX_PENDING_QUEUE=500`); same-URL-under-different-ID rejected; returns immediately (`queued:true` when parked).
5. **Thread spawn** — `start_download()` registers in `_active_downloads` **before** `t.start()`, spawns `threading.Thread → download_thread()` with cancel `threading.Event`.
6. **Free-space log (new)** — at download start the engine logs `Disk output (<out_dir>): <N>MB free` via `shutil.disk_usage` (`downloader.py:904-912`), wrapped in `except Exception: pass`. **Log only — no threshold, no abort, no `ERROR_QUOTA_EXCEEDED`.** Bootstrap logs the same for `data`, `cache`, `output` (`bootstrap.py:835-847`). ENOSPC stays invisible until a write actually fails.
7. **Option build** — `opts_builder.py` `build_ydl_opts()`: [[format-ladder|format string]] + validated aria2c opts (native downloader for DASH/HLS) + canonical PP chain (EmbedSubtitle → ModifyChapters → Metadata) + `updatetime:False`, `writethumbnail`, `download_range_func` sections, `_configure_js_runtime()` (deno > node > quickjs, `remote_components=ejs:github` only when a runtime exists), `player_client=["default","mweb"]`, `continuedl=True`. If aria2c is enabled but the binary is missing/not executable, it now **warns with the reason** and falls back to the native downloader (`opts_builder.py:277-294`) instead of failing silently.
8. **Filename bound** — the name yt-dlp is about to write is capped in **bytes** by `GuardedYoutubeDL._prepare_filename` (`filename_guard.py`, 200 bytes/component, 55 reserved for `.f<format_id>`/`.part`/`.temp`), because yt-dlp's `trim_file_name` counts characters and gives up on dotted titles. A kernel `ENAMETOOLONG` surfaces as non-retryable `ERROR_FILENAME_TOO_LONG`. See `docs/output_templates.md`.
9. **Transfer** — `YoutubeDL.download([url])`; concurrent fragments (aria2c progressive only); progress hook → [[flutter-chaquopy-python-ipc|event_callback.onEvent()]] (Android) or progress queue → `poll_queues` → stdout (desktop). Streaming events capped at **99%**; EMA smoothing in Dart (speed α=0.3, ETA α=0.15, 60-sample ring, `DownloadSparkline` painter).
10. **Post-processing** — FFmpeg merge/embed/chapters/tags serialized process-wide (1-permit semaphore, 600 s hung-merge guard; wording avoids "timeout" so `classify_error` doesn't misroute to network).
11. **Terminal event** — `finished` (100% + `filesize_bytes` + `file_path` + `thumbnail_path`) | `error` (`error_type`, `error_message`, `recoverable`, `suggests_vpn`) | `cancelled` (`ERROR_CANCELLED`). Dual-written (callback + queue) so the callback path honors the filesize contract; delayed-pop avoids the polling race.
12. **Flutter handling** — [[dart-providers|downloadProvider]] `handleProgressEvent()` → state; `DownloadService.update/done()` notification; [[db-schema|history write]]; [[logging-diagnostics|per-download logs]]; completion/error alerts; `BootReceiver` + startup sweep cover death/reboot (see [[batch-system|batch-system]]). T07 prefetches the artwork to an app-private cache at job creation and re-renders from it — see [[storage-layout|storage-layout]].

## Transient auto-retry (engine, new)

`downloader.py:726-814`, "Transient auto-retry (FEATURE 5)".

- `_MAX_AUTO_RETRIES = 2` (`:735`), `_RETRY_BACKOFF_SECONDS = (5.0, 15.0)` (`:736`) — so up to 3 attempts.
- Permanent denylist `_NO_RETRY_PERMANENT` (`:737-745`): `ERROR_PRIVATE`, `ERROR_UNAVAILABLE`, `ERROR_DRM`, `ERROR_QUOTA_EXCEEDED`, `ERROR_FORMAT_UNAVAILABLE`, `ERROR_FFMPEG_MISSING`, `ERROR_FILENAME_TOO_LONG`, `ERROR_CANCELLED`.
- `_is_transient_retryable` (`:748-759`) requires `err.recoverable` **and** a type not on the denylist; any exception → `False`.
- `_maybe_retry_transient` (`:777-814`) aborts if cancelled or the budget is spent, logs `Transient failure (<type>); auto-retry attempt <n>/3 after <d>s`, sleeps, re-checks cancel and raises `KeyboardInterrupt` so the normal cancelled path runs.
- **The retry loop runs inside the already-admitted slot** (same `slot_token`, one terminal event, one pump in `finally`) so retries respect the concurrency gate and admission queue instead of bypassing them (`downloader.py:981-990`). Fresh `YDLogger` per attempt; `_note_attempt` writes additive `attempts`/`retries` keys onto the slot (`:762-774`).
- Also applies to single-item logger errors (`:1037-1040`).

Tests: `engine/tests/test_retry_transient.py` — success path (`:96`), private-never-retries-never-sleeps (`:104-118`), budget exhaustion (`:139`), single-item `ydl_logger.error` transient (`:148-168`).

## Cancel / errors / resume hooks

- Cancel: [[engine-service-methods|cancelDownload]] sets the threading event → `cancelled` event (honest intermediate `cancelling` UI state + wedge watchdog).
- Errors: `errors.py` `classify_error()` → typed codes (`GEO_BLOCKED`, `RATE_LIMITED`, …) + `recoverable` + `suggests_vpn` → Error Recovery card (one-tap fix). The same `recoverable` flag now also drives [[download-pipeline|engine auto-retry]].
- Resume: `writeinfojson` default-ON (URL sidecar, cleaned on success); partials stream to output dir; `.part` + `.info.json` <24 h fallback scan; SQLite v3 snapshots + 5 s heartbeat (see [[batch-system|batch-system]], [[storage-layout|storage-layout]]).
- Source-URL metadata (T06): `webpage_url` maps to **both** `purl` and `comment` for every container through one `-metadata` path — `opts_builder.py:638-649` keeps the `FFmpegMetadata` PP enabled by default (`add_metadata: cfg.get("addmetadata", True)`, `add_chapters: True`, `add_infojson: False`). Locked by `engine/tests/test_source_url_metadata.py` (81 lines), which asserts the mapping against the installed yt-dlp with no network, across `mp4, m4a, mkv, webm, mp3, opus`.

## Links

- [[index|index]]
- [[system-overview|system-overview]]
- [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]
- [[format-ladder|format-ladder]]
- [[batch-system|batch-system]]
- [[method-channel-surface|method-channel-surface]]
- [[engine-service-methods|engine-service-methods]]
- [[dart-providers|dart-providers]]
- [[db-schema|db-schema]]
- [[logging-diagnostics|logging-diagnostics]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[share-intent-flow|share-intent-flow]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[local-analytics|local-analytics]]
- [[open-questions|open-questions]]
