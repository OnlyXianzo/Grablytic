# Architecture Overview

> Last updated: **2026-09-11** — reflects bundled jniLibs binaries, `DownloadService`,
> Kotlin-callback event delivery, JS runtimes, persistent logging + GitHub auto-report.

TrueStream uses a layered architecture with a Flutter frontend and a Python
download engine. The frontend and engine communicate through a platform-specific
IPC layer. Android adds a Kotlin native layer (binary resolution + keep-alive +
event bridge) between Flutter and Python.

## Tech Stack

| Layer | Technology | Role |
|---|---|---|
| UI framework | Flutter with Impeller renderer | Cross-platform UI at 120fps. Single Dart codebase for Android, Windows, and Linux. |
| State management | Riverpod (StateNotifier + FutureProvider + Provider) | Download queue, history, settings, engine status, presets, playlists, resume, batch, logs. |
| Download engine | Python with yt-dlp (YoutubeDL class API) | Media extraction, format selection, downloading, and post-processing. Never subprocess. |
| Python bridge (Android) | Chaquopy (Gradle plugin) | Embeds CPython 3.11 into the APK. Flutter calls Python via Platform Channels. |
| Python bridge (Desktop) | JSON over stdin/stdout | Flutter spawns Python as a managed subprocess. Structured JSON-RPC messages over stdio. |
| Event bridge (Android) | Kotlin `EngineEventListener.onEvent` callback | yt-dlp hooks push JSON straight to Kotlin → EventChannel. Replaces queue polling (no GIL/polling lag). Public interface so R8 cannot strip it. |
| Native binaries (Android) | `BinaryPackageManager` + jniLibs | `libffmpeg.so` / `libdeno.so` shipped in our own jniLibs (SHA-256 pinned at build time). Executed **in place** in `nativeLibraryDir` (copies won't run on targetSdk > 28). Support trees extracted to `noBackupFilesDir/packages`. |
| Keep-alive (Android) | `DownloadService` (`dataSync` FGS) | Ongoing progress notification, `START_NOT_STICKY`, `onTimeout` stop. Covers process *survival*; process *death* still needs DB resume (follow-up). |
| JS runtime (Android) | Deno `.so` (primary) · QuickJS (`python-quickjs`) | Executes YouTube's EJS challenges + PO Token generation. Priority: deno > node > quickjs. |
| JS runtime (Desktop) | Deno (bootstrapped via GitHub releases) | V8-based runtime for YouTube JS decryption. Downloaded on first run, SHA-256 gated. |
| Challenge scripts | `yt-dlp-ejs` + `remote_components=ejs:github` | Solver scripts auto-fetched; only SHA-256-allowlisted JS ever executes. |
| Media processing | FFmpeg (static binary / jniLibs `.so`) | Muxing DASH streams, audio extraction, subtitle/thumbnail embedding, chapter splitting/cutting. |
| Download accelerator | aria2c (static binary) | Parallel fragments (`-x1..16`, validated). **Never** for DASH/HLS (native downloader instead — CVE-2026-50574). |
| Persistence | SharedPreferences + SQLite | Settings/presets/playlists/auth in prefs; download history in SQLite (`sqflite` + `sqflite_common_ffi` on desktop). |
| Logging | `AppLogger` (Dart) + `logger`/`persistent` (Python) | Buffered 30 s flush, `app_logs.txt` mirror, `RotatingFileHandler` (`server_logs.log`), traced IPC, global handlers, Riverpod/nav/engine observers. |
| Crash reporting | `GithubReporter` (Dart) + `github_notifier` (Python) | Search-based dedup so the same crash isn't filed twice. |
| Fonts | Instrument Sans (body) / Iosevka Charon Mono (mono) | Typography via Google Fonts + TrueStreamTextStyles extension. |

## Layered Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                     FLUTTER UI LAYER                            │
│                                                                │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐               │
│  │Onboarding  │  │   Home     │  │  Library   │               │
│  │  Screen    │  │   Screen   │  │   Screen   │               │
│  └────────────┘  └─────┬──────┘  └──────┬─────┘               │
│                        │                │                      │
│  ┌────────────────────────────────────────────────┐            │
│  │           AppShell (BottomNav / NavRail)        │            │
│  │           Home · Library · Settings             │            │
│  └────────────────────────────────────────────────┘            │
│                        │                                        │
│  ┌────────────────────────────────────────────────┐            │
│  │  Format Picker · Batch · Playlist Details       │            │
│  │  Media Preview · Presets · Profile Editor       │            │
│  │  Cookie WebView · Subtitles · Schedule ·        │            │
│  │  SponsorBlock · Templates · Observed Sources ·  │            │
│  │  Download History · Diagnostics & Logs          │            │
│  └────────────────────────────────────────────────┘            │
├────────────────────────────────────────────────────────────────┤
│                     RIVERPOD STATE LAYER                       │
│                                                                │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│  │  settings    │  │  download    │  │   engine_status   │     │
│  │  Provider    │  │  Provider    │  │   Provider        │     │
│  │(StateNotifier│  │(StateNotifier│  │(FutureProvider)   │     │
│  │ + SharedPref)│  │ + Stream)    │  │                   │     │
│  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘     │
│         │                 │                   │                │
│  ┌──────┴───────┐  ┌──────┴───────┐  ┌────────┴─────────┐     │
│  │   preset     │  │  playlist    │  │    resume         │     │
│  │   Provider   │  │  Provider    │  │    Provider       │     │
│  │(StateNotifier│  │(StateNotifier│  │(StateNotifier     │     │
│  │ + SharedPref)│  │ + SharedPref)│  │ + FutureProvider) │     │
│  └──────────────┘  └──────────────┘  └──────────────────┘     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐     │
│  │    batch     │  │   history    │  │   logBuffer /     │     │
│  │   Provider   │  │  (SQLite)    │  │   logIngester     │     │
│  └──────────────┘  └──────────────┘  └──────────────────┘     │
│                                                                │
├────────────────────────────────────────────────────────────────┤
│                  ENGINE SERVICE ABSTRACTION                     │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐    │
│  │                EngineService (abstract)                 │    │
│  │  bootstrap · setPaths · startDownload · cancelDownload  │    │
│  │  progressStream · logStream · getFormats · getPlaylist  │    │
│  │  getSharedUrl · sharedUrlStream · scanResumeCandidates  │    │
│  │  updateCheck · setUpdateChannel                         │    │
│  └──────────────────────┬─────────────────────────────────┘    │
│                         │                                       │
│         ┌───────────────┼───────────────┐                      │
│         │               │               │                      │
│  ┌──────┴──────┐  ┌─────┴──────┐  ┌────┴──────┐               │
│  │ Platform    │  │  Desktop   │  │   Mock    │               │
│  │ Channel     │  │  Engine    │  │   Engine  │               │
│  │ Engine      │  │  Service   │  │   Service │               │
│  │ (Android)   │  │(Win/Lin)   │  │ (Test)    │               │
│  └──────┬──────┘  └─────┬──────┘  └───────────┘               │
│         │               │                                       │
├─────────┴───────────────┴───────────────────────────────────────┤
│                KOTLIN NATIVE LAYER (Android)                    │
│                                                                │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐ │
│  │  MainActivity     │  │ BinaryPackage    │  │ Download     │ │
│  │  MethodChannel +  │  │ Manager          │  │ Service      │ │
│  │  EventChannel +   │  │ jniLibs resolve  │  │ dataSync FGS │ │
│  │  onEvent callback │  │ + probe + extract│  │ + notif      │ │
│  └────────┬─────────┘  └────────┬─────────┘  └──────────────┘ │
│           │                     │                              │
├───────────┴─────────────────────┴──────────────────────────────┤
│                      IPC TRANSPORT LAYER                        │
│                                                                │
│  ┌─────────────────────┐    ┌──────────────────────────┐       │
│  │  Android:           │    │  Desktop:                │       │
│  │  MethodChannel      │    │  JSON-RPC over stdin/    │       │
│  │  "com.theonly.      │    │  stdout subprocess IPC   │       │
│  │  truestream/engine"  │    │  (UTF-8, \n delimited)   │       │
│  │                     │    │                          │       │
│  │  EventChannel       │    │  Progress events:        │       │
│  │  "com.theonly.      │    │  {"type":"event",...}    │       │
│  │  truestream/progress"│    │  multiplexed on stdout   │       │
│  │                     │    │                          │       │
│  │  Kotlin callback:   │    │  + {"type":"log",...}    │       │
│  │  onEvent(json)      │    │  filtered to logStream   │       │
│  └─────────────────────┘    └──────────────────────────┘       │
├────────────────────────────────────────────────────────────────┤
│                      PYTHON ENGINE LAYER                       │
│                                                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  paths   │  │  config  │  │  opts_   │  │  format_     │  │
│  │          │  │          │  │  builder │  │  selector    │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │  hooks   │  │  errors  │  │  formats │  │  playlist    │  │
│  │+callback │  │+vpn hints│  │          │  │  +guards     │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │downloader│  │ bootstrap│  │  resume  │  │  site_       │  │
│  │(Thread)  │  │ (CDN+jni)│  │ +sanitize│  │  profiles    │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │ po_token │  │  logger  │  │persistent│  │ github_      │  │
│  │ (JS gen) │  │(struct)  │  │ (files)  │  │ notifier     │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

## Flutter Layer — Screens

| Screen | File | Navigation |
|---|---|---|
| Onboarding | `lib/features/onboarding/screens/onboarding_screen.dart` | Shown before first launch, routes to AppShell |
| App Shell | `lib/features/shell/screens/app_shell.dart` | BottomNav (narrow) / NavigationRail (wide), IndexedStack |
| Home | `lib/features/home/screens/home_screen.dart` | Tab 0 — URL input, active downloads, format picker |
| Format Picker | `lib/features/home/screens/format_picker_screen.dart` | Modal — format list, quality selection, container, muxed badges |
| Batch Download | `lib/features/home/screens/batch_download_screen.dart` | Multi-URL paste, list management |
| Media Preview | `lib/features/home/screens/media_preview_screen.dart` | Thumbnail + metadata before download |
| Batch Import | `lib/features/home/screens/batch_import_dialog.dart` | Dialog — import from clipboard or file |
| Library | `lib/features/library/screens/library_screen.dart` | Tab 1 — completed downloads, grid/list toggle |
| Download History | `lib/features/library/screens/download_history_screen.dart` | SQLite history, search & filters |
| Playlist Details | `lib/features/library/screens/playlist_details_screen.dart` | Playlist entry list, add/remove items |
| Settings | `lib/features/settings/screens/settings_screen.dart` | Tab 2 — all settings grouped by section |
| About | `lib/features/settings/screens/about_screen.dart` | Version info, licenses, links |
| Presets | `lib/features/settings/screens/presets_screen.dart` | Download preset CRUD (7 predefined + custom) |
| Profile Editor | `lib/features/settings/screens/profile_editor_screen.dart` | Site profile configuration |
| Cookie WebView | `lib/features/settings/screens/cookie_webview_screen.dart` | In-app browser for cookie-based auth |
| Subtitle Settings | `lib/features/settings/screens/subtitle_settings_screen.dart` | Language selection, auto-subs toggle, embed switch |
| SponsorBlock | `lib/features/settings/screens/sponsorblock_settings_screen.dart` | Category selection for SponsorBlock |
| Schedule | `lib/features/settings/screens/schedule_settings_screen.dart` | Download scheduling config |
| Templates | `lib/features/settings/screens/command_templates_screen.dart` | Custom output template management |
| Observed Sources | `lib/features/settings/screens/observed_sources_screen.dart` | Channel/source monitoring |
| Diagnostics & Logs | `lib/features/settings/screens/log_viewer_screen.dart` | Troubleshooting flow + live log stream + export |

## Navigation

**AppShell** uses `IndexedStack` with 3 tabs:
- Narrow (<600px): BottomNavigationBar with custom-styled `_NavItem` widgets
- Wide (≥600px): `NavigationRail` with `VerticalDivider` + `Expanded`

The engine status banner and download progress are surfaced via Riverpod listeners in the shell. Share intent URLs arrive through `EngineService.sharedUrlStream` and are handled by the shell's `_initSharedUrlListening`.

## Riverpod Provider Dependency Graph

```
sharedPreferencesProvider (Provider<SharedPreferences>)
  │
  ├── settingsProvider (StateNotifierProvider<SettingsNotifier, AppSettings>)
  │     └── engineProvider (Provider<EngineService>)  ← reads settings for paths
  │           ├── engineStatusProvider (FutureProvider<EngineStatus>)  ← calls engine.bootstrap()
  │           ├── downloadProvider (StateNotifierProvider<DownloadNotifier, List<DownloadItem>>)
  │           │     └── subscribes to engine.progressStream
  │           └── resumeProvider (StateNotifierProvider<ResumeNotifier, AsyncValue<List<ResumeCandidate>>>)
  │                 └── calls engine.scanResumeCandidates()
  │
  ├── playlistProvider (StateNotifierProvider<PlaylistNotifier, List<Playlist>>)
  ├── presetsProvider (StateNotifierProvider<PresetsNotifier, PresetsState>)
  ├── batchProvider (StateNotifierProvider — multi-URL queue)
  └── downloadHistoryProvider (SQLite-backed history)
```

Plus independent providers:
- `sharedUrlProvider (StateProvider<String?>)` — set by share intent
- `logBufferProvider` (5K circular buffer) → `logEntriesProvider` (filtered view) ← `logIngesterProvider` (subscribes `engine.logStream` + `AppLogger`)

All state that survives app restarts is persisted to `SharedPreferences` (settings, presets, playlists) or SQLite (history). Transient state (active downloads, progress) is held in memory by `DownloadNotifier`.

## Engine Service Abstraction

`EngineService` (`lib/core/engine/engine_service.dart`) defines the unified interface:

```dart
abstract class EngineService {
  Future<Map<String, dynamic>> bootstrap();
  Future<void> setPaths(Map<String, dynamic> paths);
  Future<Map<String, dynamic>> startDownload({String url, String downloadId, Map config, String networkType});
  Future<Map<String, dynamic>> cancelDownload(String downloadId);
  Stream<Map<String, dynamic>> get progressStream;
  Stream<Map<String, dynamic>> get logStream;
  Future<Map<String, dynamic>> getFormats({String url, Map config});
  Future<Map<String, dynamic>> getPlaylistInfo({String url, Map config});
  Future<String?> getSharedUrl();
  Stream<String> get sharedUrlStream;
  Future<Map<String, dynamic>> scanResumeCandidates({required String cacheDir});
  Future<Map<String, dynamic>> updateCheck();
  Future<Map<String, dynamic>> setUpdateChannel(String channel);
}
```

### Platform Implementations

1. **`PlatformChannelEngineService`** (Android via Chaquopy):
   - MethodChannel `com.theonly.truestream/engine` — request/response
   - EventChannel `com.theonly.truestream/progress` — streaming progress events
   - Kotlin `EngineEventListener.onEvent(json)` — direct hook → Flutter path (no polling)
   - `MethodCallHandler` for `intent/shared_url` — receives share intents from Kotlin
   - All payloads serialized as JSON strings, decoded by Python via `jsonDecode`

2. **`DesktopEngineService`** (Windows/Linux via JSON stdin/stdout):
   - Spawns `python -m truestream_engine` as a managed subprocess
   - `.venv` detection in `engine/` directory first, falls back to `python3`
   - JSON-RPC over line-delimited stdin/stdout with UUID request IDs
   - `_pending` map of `Completer`s for request/response correlation
   - Progress events identified by `{"type": "event", ...}` — broadcast via `StreamController`
   - Log lines identified by `{"type": "log", ...}` — filtered into `logStream`
   - Auto-restart on unexpected process exit (up to 3 attempts)
   - 30-second request timeout

3. **`MockEngineService`** (testing):
   - Returns realistic fake data for all methods
   - Simulates progress stream with timed delays
   - Used by widget tests and frame rate audits

Selection is automatic via `engineProvider`:
- Android → `PlatformChannelEngineService`
- Windows/Linux/macOS → `DesktopEngineService`
- Other (web, etc.) → `MockEngineService`

## Kotlin Native Layer (Android)

| Class | File | Responsibility |
|---|---|---|
| `MainActivity` | `MainActivity.kt` | Chaquopy startup, MethodChannel/EventChannel setup, `paths/set` (bundled jniLibs win over Dart `bin/` paths), `EngineEventListener` callback sink, share-intent receiver, `DownloadService` start/update/done wiring |
| `BinaryPackageManager` | `BinaryPackageManager.kt` | Resolves `libffmpeg.so`/`libdeno.so` in `nativeLibraryDir`, extracts `lib*.zip.so` support trees to `noBackupFilesDir/packages`, `--version` probes, zip-slip guard, size-marker skip |
| `DownloadService` | `DownloadService.kt` | `dataSync` foreground service: progress notification, `START_NOT_STICKY`, `onTimeout` stop, swipe-away handling. No new runtime permissions. |

> Binary updates ride **app updates**: downloaded files can't execute on
> targetSdk > 28, so silent in-app binary updating is impossible on Android.
> Desktop keeps the CDN bootstrap path.

## IPC Contract

The IPC payload shapes are defined below and are identical across platforms — only the transport differs. The payload
shapes are identical across platforms — only the transport differs.

### Android (MethodChannel + EventChannel + callback)

```
Flutter Dart → MethodChannel.invokeMethod() → Kotlin → Python function call
Python return → Kotlin → MethodChannel → Flutter Future<Map>

Progress stream (new, Sept 2026):
Python hooks → EngineEventListener.onEvent(json) → EventChannel.Sink → Flutter Stream<Map>
(fallback: threading.Queue → queue_reader thread → EventChannel)

Terminal vs stream contract: streaming events are capped at 99%;
only the terminal `finished` event carries 100% + filesize_bytes.
```

### Desktop (JSON-RPC over stdin/stdout)

```
Flutter Dart → JSON encode → stdin write → Python reads line
Python → JSON encode → stdout write → Flutter reads line → JSON decode → Future<Map>

Request:  {"id": "uuid", "method": "download/start", "params": {...}}
Response: {"id": "uuid", "result": {...}}  or  {"id": "uuid", "error": {...}}

Progress events interleaved on stdout:
{"type": "event", "event": "downloading", "download_id": "...", ...}
Log lines interleaved on stdout:
{"type": "log", "level": "...", "message": "...", ...}
```

### Channels

| Channel | Direction | Purpose |
|---|---|---|
| `engine/bootstrap` | F → P | App startup — check binaries, manifest, yt-dlp version |
| `paths/set` | F → P | Inject data/output/cache dirs, binary paths (incl. `deno_path`), cookies, PO token (8 args) |
| `download/start` | F → P | Start download in thread, returns immediately |
| `download/cancel` | F → P | Set threading.Event cancel flag |
| `progress/stream` | P → F | Continuous progress/error/complete events |
| `formats/get` | F → P | List available streams for URL |
| `playlist/info` | F → P | List playlist entries with metadata |
| `resume/scan` | F → P | Scan cache dir for .part files |
| `engine/update_check` | F → P | Force re-check binaries from CDN |
| `engine/set_update_channel` | F → P | Set stable/nightly/master channel |

## Python Engine — 16 Modules + Entry Point

| Module | File | Responsibility |
|---|---|---|
| `paths` | `engine/truestream_engine/paths.py` | Global path store. `set_paths()`, `get_paths()`, `is_initialized()`. Injects binary directories to PATH, prepends site-packages to sys.path for dynamic yt-dlp updates. |
| `config` | `engine/truestream_engine/config.py` | `DEFAULT_CFG` dict: format, container, quality ceiling, subtitles, SponsorBlock, sections, retries, network, auth, archive, playlist, live. |
| `opts_builder` | `engine/truestream_engine/opts_builder.py` | `build_ydl_opts()` — merges config with paths, validated aria2c opts (native for DASH/HLS), canonical PP chain (EmbedSubtitle → ModifyChapters → Metadata), `updatetime: False`, `writethumbnail`, sections via `download_range_func`, JS runtime via `_configure_js_runtime()`. |
| `format_selector` | `engine/truestream_engine/format_selector.py` | `build_format_string()` — tiered format string: explicit ID > audio-only > quality ceiling cascade (AV1 → VP9 → H264). Muxed-stream support for non-YouTube. |
| `site_profiles` | `engine/truestream_engine/site_profiles.py` | 6 built-in profiles (YouTube 1080p, YouTube 4K, Podcast Audio, Lossless FLAC, Opus Compact, Twitter/X Video). CDN-fetchable overrides. |
| `downloader` | `engine/truestream_engine/downloader.py` | `start_download()` spawns `threading.Thread` → `download_thread()`. Creates `YoutubeDL` with built opts, progress hook + cancel check. `_active_downloads` updated in place; terminal `finished` carries `filesize_bytes`; errors carry `suggests_vpn`. Accepts `event_callback`. |
| `hooks` | `engine/truestream_engine/hooks.py` | `build_progress_hook()` — yt-dlp progress hook → queue **or** `callback.onEvent(json)`. 99 % cap on streaming progress; `filesize_bytes` on finished. `pp_key`-keyed stage lookup with real PP names. |
| `errors` | `engine/truestream_engine/errors.py` | `TrueStreamError` with typed error codes (ERROR_GEO_BLOCKED, ERROR_RATE_LIMITED, …) + recoverable flag + suggests_vpn. `classify_error()` matches exception text against keyword map. `ERROR_CANCELLED` maps to `cancelled` event on desktop. |
| `formats` | `engine/truestream_engine/formats.py` | `get_formats()` — extract info without downloading, parse format list into structured objects with codec/resolution/bitrate. Returns recommended video/audio format IDs. |
| `playlist` | `engine/truestream_engine/playlist.py` | `get_playlist_info()` — flat-extract playlist entries with generator guards, expanded video IDs, deleted-entry marking, storage sanitization. |
| `bootstrap` | `engine/truestream_engine/bootstrap.py` | CDN manifest fetch, SHA-256-or-fail, Zip/Tar-Slip-hardened extraction, parallel ffmpeg/aria2c/deno fetch, uv venv + yt-dlp install (desktop), Android fail-closed + bundled-jniLibs fallback with live `--version` probes, QuickJS + Deno detection. |
| `resume` | `engine/truestream_engine/resume.py` | `scan_resume_candidates()` — scans cache dir for .part files, checks age vs 24h expiry, recovers URL from .info.json metadata, sanitizes storage paths. |
| `po_token` | `engine/truestream_engine/po_token.py` | Allowlisted JS (`verify_js_code`), `detect_js_runtime()` (paths module first), QuickJS-context + Deno-subprocess generation. |
| `logger` | `engine/truestream_engine/logger.py` | 5-level structured logger, daily rotation, IPC queue forwarding, thread-local context, trace timing, exception logging with tracebacks. |
| `persistent` | `engine/truestream_engine/persistent.py` | `RotatingFileHandler` (`server_logs.log`), `traced_request` IPC middleware. |
| `github_notifier` | `engine/truestream_engine/github_notifier.py` | Crash search-based dedup + auto-report pipeline. |

### `__main__.py` — Entry Point

The desktop IPC entry point (`python -m truestream_engine`):
1. Starts a daemon thread (`poll_queues`) that drains download progress/result queues
2. Enters a persistent JSON-RPC stdin loop, dispatching to module functions by method name
3. Supports CLI mode for one-shot commands (e.g., `python -m truestream_engine bootstrap`)

## Data Flow — Complete Download Lifecycle

```
┌──────────────────────────────────────────────────────────────────────┐
│ USER PASTES URL (or SHARE INTENT)                                    │
│   ↓                                                                   │
│ Flutter: HomeScreen captures URL (or shell receives sharedUrlStream)  │
│   ↓                                                                   │
│ Flutter: EngineService.getFormats(url, config)                        │
│   ├─ Android: MethodChannel('formats/get') → Python get_formats()     │
│   └─ Desktop: JSON-RPC stdin → formats/get → stdout                   │
│   ↓                                                                   │
│ Python: yt_dlp.YoutubeDL.extract_info(url, download=False)            │
│   (+ JS runtime resolves n-sig/SABR via deno/quickjs + ejs)           │
│   ↓                                                                   │
│ Flutter: FormatPickerScreen displays available streams                │
│   ↓                                                                   │
│ USER PICKS FORMAT (or uses preset/default)                            │
│   ↓                                                                   │
│ Flutter: DownloadService.start(id, title) [Android keep-alive]        │
│ Flutter: EngineService.startDownload(url, downloadId, config, net)    │
│   ├─ Android: MethodChannel('download/start') → Python                │
│   └─ Desktop: JSON-RPC stdin → download/start                         │
│   ↓                                                                   │
│ Python: start_download() spawns threading.Thread                      │
│   ↓                                                                   │
│ Python: build_ydl_opts() → format string + PP chain + JS runtime      │
│   ↓                                                                   │
│ Python: YoutubeDL(download_opts).download([url])                      │
│   ↓ concurrent fragment fetching (aria2c for progressive, native DASH)│
│ Python: progress_hook → event_callback.onEvent() [Android]            │
│                        → progress_queue → poll → stdout [Desktop]      │
│   ├─ Android: EventChannel → Flutter Stream<Map>                      │
│   └─ Desktop: poll_queues → stdout → Flutter line reader              │
│   ↓                                                                   │
│ Flutter: downloadProvider.handleProgressEvent() → state update        │
│ Flutter: DownloadService.update(id, percent) [Android notif]          │
│   ↓                                                                   │
│ Python: FFmpeg post-processing (merge, embed thumbnail/subs, tags)    │
│   ↓                                                                   │
│ Python: result_queue → terminal finished/error/cancelled event        │
│   (finished carries filesize_bytes; errors carry suggests_vpn)        │
│   ↓                                                                   │
│ Flutter: DownloadItem marked completed/error → UI update + history    │
│ Flutter: DownloadService.done(id) [Android stop when idle]            │
└──────────────────────────────────────────────────────────────────────┘
```

## JS Runtime & YouTube Bypass

YouTube requires a JS runtime (yt-dlp 2025.11.12+). Priority: **deno >
node > quickjs**, resolved by `_configure_js_runtime()` with absolute paths:

- Android: bundled `libdeno.so` (via `BinaryPackageManager` → `deno_path`)
  wins; QuickJS binding is the lightweight fallback.
- Desktop: bootstrapped Deno binary (SHA-256 gated) or system `deno`/`node`.
- `remote_components = ["ejs:github"]` always set so challenge scripts
  stay fresh without app updates.
- PO Tokens generated via `po_token.generate_po_token()` (allowlisted stubs;
  real challenge scripts arrive via `yt-dlp-ejs`).
- Extractor args use `player_client = ["default", "mweb"]` — never force a
  single client (multi-client returns 31+ formats incl. AV1/VP9).

Full research: `docs/JS_RUNTIMES_ANDROID_RESEARCH.md`.

## Logging & Diagnostics Pipeline

```
Flutter: AppLogger (buffered, 30 s worker, ERROR/FATAL instant flush)
   → app_logs.txt mirror + LogBuffer (5K circular) → LiveLogView
   → GithubReporter (search dedup) → auto-filed issues
   → observers: navigation / Riverpod / engine tracing

Python: EngineLogger (5 levels, rotation, thread-local ctx)
   → server_logs.log (RotatingFileHandler) + IPC queue ({"type":"log"})
   → traced_request middleware → github_notifier (dedup)
```

View live: **Settings → Diagnostics & Logs → Live Stream** (level/tag/search/
source filters, tap-to-expand, auto-scroll, export).

## Theme System

Colors follow the "Earth & Ethos" palette defined in DESIGN.md tokens.
`TrueStreamColors` provides light and dark color constants used by `AppTheme`.

- `AppTheme.light()` and `AppTheme.dark()` build Material 3 `ThemeData` from `ColorScheme`
- Typography wraps `GoogleFonts.instrumentSansTextTheme(base)` for body text
- Monospace text uses `TrueStreamTextStyles.mono` extension on `TextTheme` (Iosevka Charon Mono)

## Accessibility

All screens pass WCAG 2.2 compliance:
- Semantic labels via `Semantics` widget on all interactive elements
- 48x48 minimum touch targets via `ConstrainedBox(minWidth: 48, minHeight: 48)`
- Screen reader support with descriptive `label` properties
- Navigation labels on all BottomNav and NavigationRail items

See `docs/testing/ACCESSIBILITY_AUDIT.md` for the audit trail.

## Test Coverage

```
test/
├── widget_test.dart              # onboarding, settings, navigation widget tests
└── performance/
    ├── frame_rate_audit.dart      # Frame rate audit for all screens
    └── platform_test_matrix.dart # Platform-specific test definitions

engine/tests/  (181 tests)
├── test_config.py                # Config defaults, merge behavior
├── test_errors.py                # Error classification, edge cases
├── test_format_selector.py       # Format string generation + storage guards
├── test_misc.py                  # Miscellaneous utility tests
├── test_opts_builder.py          # yt-dlp opts: PP order, sections, aria2c, JS runtime
├── test_paths.py                 # Path injection, PATH management
├── test_playlist.py              # Playlist detection, generators, IDs, sanitization
├── test_downloader.py            # Cancel, VPN hints, filesize, finished contract
├── test_hooks.py                 # 99% cap, pp_key stages, callback vs queue
├── test_bootstrap_extract.py     # Zip-Slip / Tar-Slip hardening
├── test_packages.py              # Bundled .so fallback, shutil.which mocks
└── test_logger.py                # Structured logger, rotation, IPC queue
```

Total: **181 Python unit tests**, Flutter widget + unit tests, 2 performance audit files.

## Build & Deploy

### GitHub Actions

**Build workflow** (`build.yml`):
- Manual trigger (`workflow_dispatch`)
- 3 parallel jobs: Android APK, Windows app, Linux app
- Android: Java 17 + CMake 3.31.4 + Python 3.11 + Flutter stable → `flutter build apk --release`
  - `packages.gradle.kts` fetches pinned ytdlnis-packages APKs → extracts `.so` → jniLibs
  - `lintVital*` disabled (AGP/Kotlin-script analysis bug); `zip.so` stripping skipped
- Windows: Flutter → `flutter build windows --release` + copy engine bundle
- Linux: apt deps + Flutter → `flutter build linux --release` + copy engine bundle
- APK: uploaded as artifact (app-release.apk)
- Desktop: full runner release directory uploaded as artifact (includes engine files)

**Verification workflow** (`verify.yml`):
- On push/PR to main
- `flutter analyze` + `flutter test` (Dart)
- `pytest engine/tests/ -v` with uv-installed yt-dlp + engine (Python)

### Binary Distribution

- Desktop FFmpeg/aria2c/Deno + yt-dlp updates via CDN/GitHub releases (SHA-256-or-fail)
- Manifest JSON lists available versions per platform with SHA-256 checksums
- Bootstrap on first download, SHA-verified on every launch via `engine/bootstrap`
- yt-dlp updates applied via uv venv + site-packages injection (desktop)
- Android binaries ride app updates (jniLibs) — no runtime execution of downloads
- Dynamic `PYTHONPATH` injection ensures updated modules load before system packages

### Desktop Virtual Environment

- `.venv` at `engine/.venv/` or project root `.venv/` auto-detected by `DesktopEngineService`
- Falls back to system `python3` if no venv found
- `PYTHONPATH` extended with `engine/` directory for module discovery in development
- Production bundles include the `truestream_engine` directory as a resource

## Performance

- Impeller renderer enabled for 120fps UI
- Frame rate audit in `test/performance/frame_rate_audit.dart`
- All downloads run in `threading.Thread` (never main thread)
- Progress events stream at hook rate; Kotlin callback removes polling latency
- aria2c external downloader for progressive fragments (native for DASH/HLS)
- `continuedl=True` for resume support
- No `setState()` for shared state — all Riverpod, minimizing rebuilds
