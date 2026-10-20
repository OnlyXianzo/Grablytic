---
title: Logging and Diagnostics
date: 2026-10-08
tags: [grablytic, architecture, logging, diagnostics]
status: complete
---

# Logging and Diagnostics

Aggressive persistent logging on both layers + live viewer + export + auto-report. Repo paths: `lib/core/utils/app_logger.dart`, `log_rotation.dart`, `log_buffer.dart`, `lib/providers/log_provider.dart`, `lib/features/settings/screens/log_viewer_screen.dart`, `engine/grablytic_engine/logger.py`, `persistent.py`, `github_notifier.py`, `lib/core/utils/github_reporter.dart`, `android/.../MainActivity.kt`.

> Updated 2026-10-08 against `redesign/ui` @ `bad0851`. Two retention policies changed: Dart-side chunking is now **1 MB × 5 chunks with no day-based retention** (T11), and the export default is **Downloads via MediaStore** (T10). The Python side is unchanged at 2 MB × 5.

## Flutter (`AppLogger`)

- Buffered logger, 30 s flush worker, **instant flush on ERROR/FATAL**; mirror to `app_logs.txt` (+ daily `log_YYYY-MM-DD.txt`); cap-trimmed; `_redact()` sanitizes (triple-quoted raw strings — plain raw strings once caused 181 analyzer errors).
- `LogBuffer` (5K circular) → `logEntriesProvider` (filtered) ← `logIngesterProvider` (subscribes `engine.logStream` + `AppLogger`); DEBUG kept off the UI bridge (10-download hang fix); retention bounded (5000 global / 500 per download / LRU-50).
- Observers: navigation, Riverpod, engine tracing; `download_id` correlation end-to-end → per-download log bottom sheet (queue card, history row, overflow menu) + live per-download overlay on cards. Log level colors come from `GrablyticLogColors` — see [[design-system|design-system]].
- `flush_log_sinks()` (2026-09-30, commit `8b681f6`): flush-without-close exported from engine; Dart flushes BOTH `server_logs.log` and `engine_*.txt` before export.

### Dart rotation policy (changed — T11)

| Constant | Value | Citation |
|---|---|---|
| `LogRotation.chunkMaxBytes` | **1 MB** | `lib/core/utils/log_rotation.dart:9` |
| `LogRotation.forceRotateBytes` | 4 MB | `log_rotation.dart:33` |
| `AppLogger._maxSealedChunks` | **5** | `lib/core/utils/app_logger.dart:28` |

The retention-days preference was **removed**. The in-code rationale (`app_logger.dart:223-225`) is explicit: *"spec caps chunk size, not count; 5 x 1 MB bounds disk without a day-based retention pref"*.

In-memory ring buffer is unchanged: `LogBuffer(maxEntries: 5000)` (`lib/main.dart:37,157`).

## Python (`logger` + `persistent`)

- `EngineLogger`: 5 levels (`DEBUG=10` … `FATAL=50`, `logger.py:13-17`), IPC queue forwarding, thread-local context (`download_context`), trace timing, exception logging with tracebacks; `set_global_event_callback()` push bridge wired in `start_download`.
- **Two distinct thresholds**, and the split matters:
  - `self._min_level = DEBUG` (`logger.py:52`) — gates the daily file write + the in-memory queue (`:120-129`).
  - `self._bridge_min_level = INFO` (`logger.py:63`) — gates the Chaquopy/EventChannel push to Flutter (`:139`). Rationale verbatim at `:53-58`: *"the Chaquopy/EventChannel callback feeds the Flutter UI thread… yt-dlp emits per-block DEBUG at tens of Hz per download; forwarding all of it hung flagships with 10+ queued items (63k lines/7.5MB per field session)… Deliberately NOT per-download."*
  - Module-global override `set_global_bridge_min_level` (`logger.py:359-372`), default `_global_bridge_min_level = INFO` (`:311`).
- **Daily files are appended forever** — `engine_YYYY-MM-DD.txt` (`logger.py:229`) has no size cap, no file-count cap and no day-based prune. Buffered writes: cached handles opened `buffering=1 << 16` (64 KiB, `:233`), `_FILE_FLUSH_INTERVAL_S = 5.0` (`:216`); INFO+ and `force_flush` (ERROR+) are write-through per line, DEBUG rides the 5 s cadence (`:221-225`, `:238-241`). `close_log_sinks()` registered with `atexit` (`:296-300`).
- `flush_log_sinks()` (`logger.py:269-293`) flushes **without** closing handles — docstring `:270-277`: *"a reader that opens `engine_YYYY-MM-DD.txt` directly — e.g. the Android MediaStore export — can miss the newest bytes. Call this before any out-of-band file copy."* Test: `engine/tests/test_logger.py:876-915` writes 5 DEBUG lines, flushes, asserts all 5 landed and the handle stays open.
- `persistent`: `RotatingFileHandler` → `server_logs.log`, `DEFAULT_MAX_BYTES = 2 * 1024 * 1024` (2 MB, `persistent.py:28`), `DEFAULT_BACKUP_COUNT = 5` (`:29`), level `logging.DEBUG` (`:140`), handler built `:166-169`. **`FLUSH_INTERVAL_S = 30.0`** (`:30`) with a 30 s flush worker (`:231-247`) and instant flush on ERROR/FATAL in `bridge_event` (`:209-210`). Format `%(asctime)s.%(msecs)03d [%(levelname)s] [%(name)s] %(message)s` (`:171-174`). `read_log_tail(max_bytes=100 * 1024)` (`:262`). Redaction list `_SENSITIVE_SUBSTRINGS` incl. `cookie/token/password/passwd/secret/auth/proxy/api_key/apikey/session/po_token` (`:32-35`).
- **No retention-days logic exists in Python** — before or after this window. A repo-wide grep for `days|retention|mtime|purge|prune` in `engine/grablytic_engine/` returns only `resume.py:214` (strike tracking), `po_token.py:15` (comment), `opts_builder.py:28,405` (yt-dlp `updatetime`), `hooks.py:18` (queue bound comment). Python retention is purely `backupCount`.
- `traced_request` IPC middleware (latency, sanitized payloads, tracebacks); `sanitize()` scrubs proxy creds, po_token, `sig=`/`lsig=` before disk/IPC.
- `poll_queues` multiplexes `{"type":"log"}` lines to Dart `logStream`.

## Export — Downloads via MediaStore is now the default

T10, commit `eb01514` (2026-10-02). There is **no Python-side export function** — the copy is Kotlin/Dart; Python only flushes so the bytes exist.

### Chain

1. **UI** — `lib/features/settings/screens/log_viewer_screen.dart:185-216` `_saveToDownloads()`; button `'Export to Downloads'`; comment `:548` *"T10: single default export = Downloads via MediaStore."* Calls `AppLogger.flushNow()` (`:189`) then `engine.exportLogToDownloads(sourcePath: file.path, displayName: AppLogger.exportFileName())` (`:192-195`).
2. **Filename** — `lib/core/utils/app_logger.dart:741-747` `'grablytic logs - YYYY-MM-DD HH-mm-ss.log'`. Comment `:738-740`: *"colons are illegal in MediaStore display names on some launchers/MTP"*.
3. **Method** — `EngineMethods.exportLog = 'log/export_to_downloads'` (`engine_codec.dart:34`), Kotlin-only handler at `MainActivity.kt:915-945`.
4. **Double flush (Kotlin → Python)** — `MainActivity.kt:923-934` calls **both** `engine?.callAttr("persistent_flush")` and `engine?.callAttr("flush_log_sinks")`, with the comment: *"persistent_flush covers `server_logs.log` (stdlib handler); flush_log_sinks covers `engine_YYYY-MM-DD.txt` (64 KiB / 5 s DEBUG batch in logger.py) — without both, the copy can miss the newest bytes."*
5. **The copy** — `MainActivity.kt:1047-1136` `exportFileToDownloads(src, displayName)`:
   - Name hardening `:1052-1054` — `replace(Regex("[/\\\\:]"), "_").trim()`, fallback `"grablytic logs - export.log"`, append `.log` if missing.
   - **Threshold `maxBytes = 5 * 1024 * 1024L`** (`:1055`).
   - Tail window `:1060-1064` — under the cap returns `null` (full copy); over it writes header `"... [TRUNCATED — showing last 5 MB of <KB> KB] ..."` and seeks to `srcLen - maxBytes`.
   - **API ≥ 29 (`:1065-1106`)** — `MediaStore.Downloads.EXTERNAL_CONTENT_URI`, `RELATIVE_PATH = Environment.DIRECTORY_DOWNLOADS + "/Grablytic-logs"`, `MIME_TYPE = "text/plain"`, `IS_PENDING = 1`; tail written via `RandomAccessFile.seek` + 64 KiB buffer (`:1085-1093`); failure deletes the URI and rethrows (`:1098-1101`); success clears `IS_PENDING` and returns the **synthetic** path string `"Download/Grablytic-logs/$safeName"` (`:1106`).
   - **API < 29 (`:1107-1134`)** — legacy `getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)/"Grablytic-logs"`, same tail logic, real absolute path.
6. **Fallback** — `AppLogger.exportLogFile(File src)` `app_logger.dart:758-788`: Android → app external files dir + `sub = 'log-exports'` (`:763-767`), which docstring `:753-755` explains is *"writable with NO permission needed (scoped storage forbids raw writes to public Download on API 30+)"*; desktop → `getDownloadsDirectory()` + `sub = 'Grablytic-logs'` (`:768-772`). `-N` collision suffixing (`:775-782`). Never throws — returns `'ERROR: …'` strings.
   - Docstring `:749-751`: *"Default export is Downloads via MediaStore … this app-dir copy runs only when MediaStore is unavailable."*
7. **When the fallback fires** — `log_viewer_screen.dart:196-208`, only when `res['success'] != true || res['path'] == null`; message shape `'Downloads unavailable (<reason>) — exported instead to:\n<fallback>'` (`:205-207`).
8. **Desktop has no tail cap** — `desktop_engine_service.dart:691-737` resolves `$HOME/Downloads/Grablytic-logs` from `Platform.environment` (deliberately no `path_provider`, `:707-709`), sanitizes via `trust_boundary.dart:43-53` (`sanitizeExportFileName`: splits on `[\\/]`, drops `.`/`..`, 255-char cap), `-N` collision loop (`:724-728`), plain `src.copy(dest.path)` (`:729`). **The 5 MB truncation is Android-only.**

### Stale documentation

`docs/troubleshooting.md:40` still describes the export as *"Android: app external `log-exports/` (no permission needed); desktop: `~/Downloads/Grablytic-logs/`"* — i.e. it documents the **fallback**, not the new default. Logged in [[open-questions|open-questions]].

Also from the 2026-09-30 fix (`8b681f6`, retained): timestamped `DISPLAY_NAME` so exports never collide; Diagnostics lists `server_logs.log.N` backups (newest history was previously invisible); the fallback message carries the native error reason; share is exactly-once (native consume-once + Dart drain guard).

## Diagnostics & Logs screen

Troubleshooting flow + engine/bootstrap status cards (`ffmpeg_ok`, `aria2c_ok`, `deno_ok`, `quickjs_ok`, `js_runtime`, `yt_dlp_version`, `needs_update`) + live log stream (color-coded, level/tag/search/source filters, tap-to-expand, auto-scroll) capped at tail render (100 KB / 1000 lines + truncation banner — multi-MB logs can't hang the phone) + export. The viewer scrolls the full viewport via a collapsible card (T13). Screen location and siblings: [[settings-navigation|settings-navigation]].

The separate **INSTALLED PACKAGES** card in System & Diagnostics reports per-binary `ok`/`version`/`source`/`detail`/`actionable` (`settings_screen.dart:2119-2130`); `BinaryStatus.isActionable => ok || (source != 'unsupported' && source != 'runtime')` (`engine_status_provider.dart:55-56`). See [[triage-export-workflow|triage-export-workflow]] for the aria2c row specifically.

## GitHub auto-report

`GithubReporter` (Dart) + `github_notifier` (Python): **search-based dedup** so the same crash isn't filed twice; manual-report fingerprints unique; full-log toggle (512 KB vs 100 KB tail); Flutter SDK version stamped via `--dart-define=GRABLYTIC_FLUTTER_VERSION` (`unknown` in dev = expected).

## Links

- [[index|index]]
- [[download-pipeline|download-pipeline]]
- [[triage-export-workflow|triage-export-workflow]]
- [[storage-layout|storage-layout]]
- [[dart-providers|dart-providers]]
- [[engine-service-methods|engine-service-methods]]
- [[method-channel-surface|method-channel-surface]]
- [[design-system|design-system]]
- [[open-questions|open-questions]]
