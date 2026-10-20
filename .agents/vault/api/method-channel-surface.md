---
title: MethodChannel Surface
date: 2026-10-08
tags: [grablytic, api, ipc]
status: complete
---

# MethodChannel Surface (IPC Contract)

Wire contract shared by both transports. Repo paths: `engine/grablytic_engine/__main__.py` (`_dispatch_method`, `_FAST_IPC_METHODS`), `lib/core/engine/engine_codec.dart` (`EngineMethods`), `android/.../MainActivity.kt` (`when` branches), `docs/architecture.md` (IPC section).

> **Corrected 2026-10-08.** The original 2026-09-30 table listed 16 ids and was **incomplete** — 11 more exist. The authoritative list is the 27 `static const String` in `engine_codec.dart:18-44`, cross-checked against the Python dispatch chain (`__main__.py:162-205`, `:241`) and the Kotlin `when` (`MainActivity.kt:420-961`).

## Method IDs

Legend: **P** = handled in Python, **K** = handled in Kotlin only.

### Python (`__main__.py:162-205`, `:241`)

| Method | Fast lane | Purpose |
|---|---|---|
| `engine/bootstrap` | | Binaries, manifest, yt-dlp version |
| `paths/set` | **yes** | Dirs, binary paths, cookies, PO token |
| `download/start` | | Spawn thread, return immediately |
| `download/cancel` | **yes** | Cancel event |
| `download/queue_status` | **yes** | Parked IDs + active count + limit |
| `download/set_concurrency` | **yes** | 1–5 clamp |
| `download/clear_archive` | **yes** | Delete archive file |
| `formats/get` | | Stream list (+ `preview_stream`, see [[format-ladder\|format-ladder]]) |
| `playlist/info` | | Flat entries |
| `search/query` | | Search extractors |
| `resume/scan` | | `.part` scan |
| `resume/report` | | Strike-count one attempt |
| `engine/update_check` | | CDN re-check |
| `engine/set_update_channel` | | stable / nightly / master |

`_FAST_IPC_METHODS` = `{download/cancel, download/queue_status, download/set_concurrency, download/clear_archive}` (`__main__.py:46-51`); `paths/set` is handled inline separately (`:241`, `:376`). Unknown method → `ERROR_UNKNOWN_METHOD` (`:209-211`).

### Kotlin-only (`MainActivity.kt:420-961`)

| Method | Line | Purpose |
|---|---|---|
| `activity/finish` | `:420` | Finish a transparent activity — used by the [[share-intent-flow\|share overlay]] `_finish()` |
| `notification/show_error` | `:424` | `showErrorNotification` surface |
| `intent/get_shared` | `:431` | Drain the shared-URL queue |
| `intent/open_url` | `:443` | System browser resolver |
| `intent/open_file` | `:467` | FileProvider (Android) |
| `system/battery_status` | `:795` | Battery exemption query |
| `system/battery_request` | `:814` | Request exemption |
| `system/network_metered` | `:798` | Wi-Fi-Only gate |
| `system/notification_status` | `:836` | Android 13+ permission query |
| `system/notification_settings` | `:840` | Open notification settings |
| `system/notification_request` | `:871` | Request permission |
| `log/export_to_downloads` | `:915` | **Export path** — see [[logging-diagnostics\|logging-diagnostics]] |
| `schedule/sync` | `:946` | WorkManager constraints for [[system-overview\|observed sources]] |
| `queue_reminder/sync` | `:961` | WorkManager sync for [[offline-queue-reminders\|queue reminders]] |

Note `log/export_to_downloads` is Kotlin-handled but **flushes Python sinks first** — it calls both `persistent_flush` and `flush_log_sinks` on the Chaquopy engine (`MainActivity.kt:923-934`).

### Event names (not method ids)

- `intent/shared_url` — **EventChannel**, not a method (`engine_codec.dart:29`). See [[share-intent-flow|share-intent-flow]].
- `com.theonly.grablytic/progress` — EventChannel name.

## Android transport

`MethodChannel com.theonly.grablytic/engine` (calls) + `EventChannel com.theonly.grablytic/progress` (events) + `intent/shared_url`. Payloads are JSON strings. Kotlin callback `onEvent(json)` is the primary event path; thread-queue is the fallback.

## Desktop transport (JSON-RPC stdio)

- Request: `{"id": "uuid", "method": "download/start", "params": {...}}`
- Response: `{"id": "uuid", "result": {...}}` or `{"id": "uuid", "error": {...}}`
- Interleaved: `{"type": "event", "event": "downloading", "download_id": "...", ...}` and `{"type": "log", ...}`.
- Fast lane (inline in reader thread): `download/cancel`, `download/queue_status`, `download/set_concurrency`, `download/clear_archive`, `paths/set`. Slow extractions on an 8-worker pool (`_MAX_IPC_WORKERS = 8`, `__main__.py:42`); stdout under one lock; EOF drains in-flight workers then `shutdown_downloads(timeout=5)`.
- Malformed lines produce an `ERROR_INTERNAL` envelope (never kill the loop); `set_paths` verdict is forwarded fail-closed (T0-2).
- Desktop also serves the Kotlin-only ids as graceful no-ops: `syncQueueReminder` → `{'success': true, 'supported': false}` (`desktop_engine_service.dart:876-880`), so the [[offline-queue-reminders|reminder]] degrades silently off-Android.

## Event shapes

- Streaming: `{type:event, event:downloading, download_id, progress (≤0.99), downloaded_bytes, total_bytes, speed, eta, stage?}`.
- Terminal `finished`: `{event:finished, download_id, filesize_bytes, total_bytes, file_path, thumbnail_path}` (100%).
- Terminal `error`: `{event:error, download_id, error_type, error_message, recoverable, suggests_vpn}`.
- Terminal `cancelled`: `{event:cancelled, download_id, error_type:ERROR_CANCELLED}`.
- Contract: streaming capped at 99%; only `finished` carries 100% + `filesize_bytes`.

Terminal events are constructed in the reader loop (`__main__.py:117-145`); `ERROR_CANCELLED` maps to a distinct `cancelled` event, never `error`.

## URL safety gate

Every Python-side entry point validates before doing work — see [[url-guard-ssrf|url-guard-ssrf]]. On rejection `download/start`, `formats/get` and `playlist/info` all return `{"success": False, "error_type": "ERROR_INVALID_PARAM", "error_message": "URL must be a public http(s) address"}`, and `download/start` rejects **before** admission/queueing/thread spawn (`downloader.py:1254-1268`).

## Links

- [[index|index]]
- [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]
- [[engine-service-methods|engine-service-methods]]
- [[download-pipeline|download-pipeline]]
- [[dart-providers|dart-providers]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[share-intent-flow|share-intent-flow]]
- [[logging-diagnostics|logging-diagnostics]]
- [[open-questions|open-questions]]
