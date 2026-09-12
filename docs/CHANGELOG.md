# Changelog

> Distilled from commit history (`git log --oneline`). Current version: `0.0.1-beta+1`.

## Unreleased — 2026-09-12 (Linker Closure, Fail-Closed Probes & Library UI)

### Fixed
- **FFmpeg Bionic Linker Gap (`CANNOT LINK EXECUTABLE: library "libexpat.so.1" not found`)**:
  - Replaced flawed `ytdlnis-packages` FFmpeg bundle with official, production-proven `io.github.junkfood02.youtubedl-android:ffmpeg:0.17.2` from Maven Central (used in Seal & upstream ytdlnis).
  - Clean `DT_NEEDED` closure verified across all bundled libraries (0 missing symbols).
  - Dropped flawed build-time native shim tasks that attempted to package `.so.1` files (rejected by Android Gradle Plugin and AOSP `NativeLibraryHelper`).
  - Gated binary assignments in `MainActivity.kt` with live `binStatuses[name].ok` checks.
- **Engine Binary Health-Check Fail-Closed Gating**:
  - Fixed `bootstrap.py` marking broken executables as `ok=True` based purely on file existence.
  - Binaries are now evaluated strictly fail-closed: an executable path is only marked `ok=True` if the live `--version` probe returns exit code 0.
  - On probe failure (e.g. linker crashes, missing libs, permission errors), `ok` is set to `False`, the binary is scheduled for update, and the exact diagnostic probe output is recorded.
  - Added unit tests in `engine/tests/test_binstatus.py` simulating linker failure to prevent regressions.
- **Library Screen Vanishing Card & Redraw Glitch**:
  - Fixed bug where downloads transitioning to `status: 'error'` vanished completely from the Library screen.
  - `LibraryScreen` now categorizes items into `pending`, `failed`, and `completed` buckets.
  - Added dedicated `FAILED` section in list view and failed cards in grid view with error styling, error details, and an inline `Retry` button.
  - Eliminates the UX failure where a blank screen caused users to frantically toggle `useGridView`.

## Night loop 2026-09-11

### Security (applied)
- SEC-01: backups locked down (`allowBackup=false` + extraction/backup
  rules excluding prefs, databases, cookies, logs).
- SEC-02: `sig=`/`lsig=`/`signature` redaction in Dart logs (disk + buffer
  entries) and engine `bridge_event` before disk.
- SEC-03: 8 KB cap on inbound SEND-intent text.
- Binaries: additive `binaries[]` provenance in bootstrap (bundled /
  downloaded / system / runtime / unsupported / missing) + `yt_dlp_outdated`
  advisory; UI shows effective JS runtime (no more phantom QuickJS pending)
  and honest aria2c-unavailable state; per-row sources, details, and
  actionable Redownload gating.
- SEC-04: template-arg validator (blocks `-o`/`--paths` escapes), `--exec`
  warning, engine `output_tmpl` confinement.
- Fixed all Android downloads crashing in `<1s` with
  `TypeError: 'HashMap' object is not a mapping`: Chaquopy delivers Kotlin
  Maps as live proxies, killing `{**config}`. Kotlin now sends config as
  JSON; Python `coerce_config()` normalizes (None/dict/str/proxy-safe).
- Download threads survive `BaseException` with a terminal error event
  (no more silent ghosts); per-download config summary + query-stripped
  URLs in engine logs; build-SHA in every log and report.
- Bootstrap probe now records returncode/output (linker/permission verdict
  for bundled binaries) + exec-environment line; single-video downloads
  with swallowed post-processing failures report `ERROR_POSTPROCESS_FAILED`
  instead of a false `finished` (playlists stay lenient).
- `LD_LIBRARY_PATH` carries EVERY support tree (ffmpeg + deno + native
  dir); `set_paths` accepts colon-joined dirs.
- Linker fix: support-tree extraction recreates Unix symlinks
  (`commons-compress`, mirroring ytdlnis) — `java.util.zip` had been
  writing link targets as text files. Marker bump re-extracts once.
- Linker, endgame: FFmpeg now comes self-contained from
  `youtubedl-android:ffmpeg` (Maven Central, production-proven in Seal —
  zero missing libs, so no expat shim needed; a same-night shim attempt
  was correctly dropped: the OS only extracts `*.so` from APKs).
- Live per-download engine-log overlay on download cards (ytdlnis-style).
- Extreme-but-sane logging: settings-change diffs (masked secrets),
  disk snapshots at bootstrap + download start, 25/50/75% stall
  milestones (bounded), slow-call WARNs over 10 s, sanitized full-opts
  dump on verbose.
- Android JS runtime is now bundled Node.js (`nodejs-25.3.0` jniLibs;
  Deno's `libsqlite3.so` doesn't ship) with node-first priority on
  Android; bot-check errors map to cookie guidance; probe output uncapped
  for verbatim linker diagnostics.

### Fixed
- Engine logs now reach Android: `logger.set_global_event_callback()` push
  bridge + wiring in `start_download`; file logging (`server_logs.log`,
  `engine_*.txt`) initialized in `set_paths` on all platforms.
- Hook events dual-write (callback + queue) so terminal `finished` honors
  the `filesize_bytes` contract on the callback path.
- Dead settings wired: `concurrent_fragments` → `concurrent_fragment_downloads`,
  `socket_timeout`, `write_description`/`write_info_json`, `use_aria2` alias,
  `format_code` override (below explicit IDs, above the ladder).
- Diagnostics: terminal download outcome lines, single-owner engine-log
  ingestion (fixes desktop double-logging), retention slider persists on
  release, unique manual-report fingerprints, log-file export, full-log
  report toggle, real Flutter version stamp.
- PageView tab animation no longer logs intermediate fly-through pages.
- `yt-dlp` floor raised to `>=2025.11.12` (EJS/JS-runtime requirement).

## Unreleased — September 2026

### Added
- Android: `ffmpeg` + `deno` bundled in our own jniLibs (SHA-256-pinned `packages.gradle.kts` fetch, `BinaryPackageManager` resolve/probe/extract).
- Android: `DownloadService` (`dataSync` foreground service) with progress notification, explicit lifetime, timeout handling.
- Engine: full JS-runtime support — Deno → Node → QuickJS priority, `ejs:github` remote components, `yt-dlp-ejs` dependency.
- Logging: buffered persistent logs both layers (`app_logs.txt`, `server_logs.log`), global error handlers, navigation/Riverpod/engine observers, GitHub search-dedup auto-report, live log viewer tab.
- Engine: FFmpeg-only `download_sections` cutting with warn-and-skip validation.
- Docs: `JS_RUNTIMES_ANDROID_RESEARCH.md` (Deno/Node/QuickJS/bgutil investigation).

### Fixed
- Subtitles never embedded (`embedsubs` is not a real param) → real `FFmpegEmbedSubtitle` PP in canonical order (EmbedSubtitle → ModifyChapters → Metadata).
- Re-audit items: `updatetime` (not ignored `no_mtime`), `writethumbnail` for `EmbedThumbnail`, SponsorBlock cutter ordering, `filesize_bytes` on terminal events, `suggests_vpn` on errors, desktop `ERROR_CANCELLED` → `cancelled`, R8-safe `EngineEventListener`.
- Event delivery: replaced queue polling with Kotlin `onEvent` callback; fixed 7→8-arg `set_paths`/`deno_path` misalignment.
- Playlists: generator guards, expanded video IDs, storage sanitization.
- Security audit: Zip-Slip/Tar-Slip-hardened extraction, `java.android`-bridge detection (Termux-safe), terminal-vs-stream 99% contract, aria2c validation, Deno path resolution, aware-UTC datetimes.
- CI: `flutter analyze` (AppLogger regex escapes), Python `deno_version` UnboundLocalError, `lintVital` disable, `zip.so` strip skip, `shutil.which` mocks.

## July 2026
- YouTube SABR format / PO-Token block resolution; aria2c DASH hardening.
- Structured engine logger (rotation, IPC queue, thread-local context) + Dart log model/circular buffer/ingester + live viewer + `logStream` plumbing.

## June 2026
- Diagnostics & Logs screen with troubleshooting flow; `AppLogger`; home/format-picker instrumentation.
- Android FFmpeg + checksum fallbacks; `setPaths`/bootstrap race fix.
- Security audits: JS execution + tmpdir fixes, executable permissions, aria2c assets.
- Format ladder: muxed streams for non-YouTube; platform-aware JS UI; duplicate-download guard; desktop IPC hardening (queueing, single startup, venv fixes, `sqflite_ffi`).
- Sprint 4–5 features: history (SQLite), archive toggle, aria2c config, scheduler, media preview, SponsorBlock settings, templates, observed sources, batch import, cookie/WebView auth, share intent, resume UI, update channels, binary bootstrapper, error-recovery UI.
