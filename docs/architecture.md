# Architecture Overview

TrueStream uses a layered architecture with a Flutter frontend and a Python
download engine. The frontend and engine communicate through a platform-specific
IPC layer.

## Tech Stack

| Layer | Technology | Role |
|---|---|---|
| UI framework | Flutter with Impeller renderer | Cross-platform UI at 120fps. Single Dart codebase for Android, Windows, and Linux. |
| State management | Riverpod (StateNotifier + FutureProvider + Provider) | Download queue, active downloads, settings, engine status, presets, playlists, resume. |
| Download engine | Python with yt-dlp (YoutubeDL class API) | Media extraction, format selection, downloading, and post-processing. Never subprocess. |
| Python bridge (Android) | Chaquopy (Gradle plugin) | Embeds CPython 3.11 into the APK. Flutter calls Python via Platform Channels. |
| Python bridge (Desktop) | JSON over stdin/stdout | Flutter spawns Python as a managed subprocess. Structured JSON-RPC messages over stdio. |
| JS runtime (Android) | QuickJS (python-quickjs, embedded via NDK) | Executes YouTube's JS decryption challenges and PO Token generation. |
| JS runtime (Desktop) | Deno (lazy-loaded via bootstrap) | V8-based runtime for YouTube JS decryption. Downloaded on first run. |
| Media processing | FFmpeg (static binary, CDN-distributed) | Muxing DASH streams, audio extraction, subtitle/thumbnail embedding, chapter splitting. |
| Download accelerator | aria2c (static binary, CDN-distributed) | Parallel fragment downloading — configurable chunks. |
| Persistence | SharedPreferences | Settings, presets, playlists, auth state, cookies path. |
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
│  │  Format Picker · Batch Download · Playlist      │            │
│  │  Details · Media Preview · Presets · About      │            │
│  │  Cookie WebView · Subtitles · Schedule ·        │            │
│  │  SponsorBlock · Templates · Observed Sources    │            │
│  └────────────────────────────────────────────────┘            │
├────────────────────────────────────────────────────────────────┤
│                     RIVERPROD STATE LAYER                       │
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
│                                                                │
├────────────────────────────────────────────────────────────────┤
│                  ENGINE SERVICE ABSTRACTION                     │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐    │
│  │                EngineService (abstract)                 │    │
│  │  bootstrap · setPaths · startDownload · cancelDownload  │    │
│  │  progressStream · getFormats · getPlaylistInfo           │    │
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
│  │          │  │          │  │          │  │              │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐  │
│  │downloader│  │ bootstrap│  │  resume  │  │  site_       │  │
│  │(Thread)  │  │ (CDN)    │  │          │  │  profiles    │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘  │
│  ┌──────────┐                                                │
│  │ po_token │                                                │
│  │ (JS gen) │                                                │
│  └──────────┘                                                │
└────────────────────────────────────────────────────────────────┘
```

## Flutter Layer — Screens

| Screen | File | Navigation |
|---|---|---|
| Onboarding | `lib/features/onboarding/screens/onboarding_screen.dart` | Shown before first launch, routes to AppShell |
| App Shell | `lib/features/shell/screens/app_shell.dart` | BottomNav (narrow) / NavigationRail (wide), IndexedStack |
| Home | `lib/features/home/screens/home_screen.dart` | Tab 0 — URL input, active downloads, format picker |
| Format Picker | `lib/features/home/screens/format_picker_screen.dart` | Modal — format list, quality selection, container |
| Batch Download | `lib/features/home/screens/batch_download_screen.dart` | Multi-URL paste, list management |
| Media Preview | `lib/features/home/screens/media_preview_screen.dart` | Thumbnail + metadata before download |
| Batch Import | `lib/features/home/screens/batch_import_dialog.dart` | Dialog — import from clipboard or file |
| Library | `lib/features/library/screens/library_screen.dart` | Tab 1 — completed downloads, grid/list toggle |
| Playlist Details | `lib/features/library/screens/playlist_details_screen.dart` | Playlist entry list, add/remove items |
| Settings | `lib/features/settings/screens/settings_screen.dart` | Tab 2 — all settings grouped by section |
| About | `lib/features/settings/screens/about_screen.dart` | Version info, licenses, links |
| Presets | `lib/features/settings/screens/presets_screen.dart` | Download preset CRUD (7 predefined + custom) |
| Profile Editor | `lib/features/settings/screens/profile_editor_screen.dart` | Site profile configuration |
| Cookie WebView | `lib/features/settings/screens/cookie_webview_screen.dart` | In-app browser for cookie-based auth |
| Subtitle Settings | `lib/features/settings/screens/subtitle_settings_screen.dart` | Language selection, auto-subs toggle |
| SponsorBlock | `lib/features/settings/screens/sponsorblock_settings_screen.dart` | Category selection for SponsorBlock |
| Schedule | `lib/features/settings/screens/schedule_settings_screen.dart` | Download scheduling config |
| Templates | `lib/features/settings/screens/command_templates_screen.dart` | Custom output template management |
| Observed Sources | `lib/features/settings/screens/observed_sources_screen.dart` | Channel/source monitoring |

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
  │
  └── presetsProvider (StateNotifierProvider<PresetsNotifier, PresetsState>)

sharedUrlProvider (StateProvider<String?>)  ← independent, set by share intent
```

All state that survives app restarts is persisted to `SharedPreferences` (settings, presets, playlists). Transient state (active downloads, progress) is held in memory by `DownloadNotifier`.

## Engine Service Abstraction

`EngineService` (`lib/core/engine/engine_service.dart`) defines the unified interface:

```dart
abstract class EngineService {
  Future<Map<String, dynamic>> bootstrap();
  Future<void> setPaths(Map<String, dynamic> paths);
  Future<Map<String, dynamic>> startDownload({String url, String downloadId, Map config, String networkType});
  Future<Map<String, dynamic>> cancelDownload(String downloadId);
  Stream<Map<String, dynamic>> get progressStream;
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
   - `MethodCallHandler` for `intent/shared_url` — receives share intents from Kotlin
   - All payloads serialized as JSON strings, decoded by Python via `jsonDecode`

2. **`DesktopEngineService`** (Windows/Linux via JSON stdin/stdout):
   - Spawns `python -m truestream_engine` as a managed subprocess
   - `.venv` detection in `engine/` directory first, falls back to `python3`
   - JSON-RPC over line-delimited stdin/stdout with UUID request IDs
   - `_pending` map of `Completer`s for request/response correlation
   - Progress events identified by `{"type": "event", ...}` — broadcast via `StreamController`
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

## IPC Contract

The IPC payload shapes are defined below and are identical across platforms — only the transport differs. The payload
shapes are identical across platforms — only the transport differs.

### Android (MethodChannel + EventChannel)

```
Flutter Dart → MethodChannel.invokeMethod() → Kotlin/Java → Python function call
Python return → Kotlin/Java → MethodChannel → Flutter Future<Map>

Progress stream:
Python threading.Queue → queue_reader thread → EventChannel.StreamSink → Flutter Stream<Map>
```

### Desktop (JSON-RPC over stdin/stdout)

```
Flutter Dart → JSON encode → stdin write → Python reads line
Python → JSON encode → stdout write → Flutter reads line → JSON decode → Future<Map>

Request:  {"id": "uuid", "method": "download/start", "params": {...}}
Response: {"id": "uuid", "result": {...}}  or  {"id": "uuid", "error": {...}}

Progress events interleaved on stdout:
{"type": "event", "event": "downloading", "download_id": "...", ...}
```

### Channels

| Channel | Direction | Purpose |
|---|---|---|
| `engine/bootstrap` | F → P | App startup — check binaries, manifest, yt-dlp version |
| `paths/set` | F → P | Inject data/output/cache dirs, binary paths, cookies |
| `download/start` | F → P | Start download in thread, returns immediately |
| `download/cancel` | F → P | Set threading.Event cancel flag |
| `progress/stream` | P → F | Continuous progress/error/complete events |
| `formats/get` | F → P | List available streams for URL |
| `playlist/info` | F → P | List playlist entries with metadata |
| `resume/scan` | F → P | Scan cache dir for .part files |
| `engine/update_check` | F → P | Force re-check binaries from CDN |
| `engine/set_update_channel` | F → P | Set stable/nightly/master channel |

## Python Engine — 13 Modules

| Module | File | Responsibility |
|---|---|---|
| `paths` | `engine/truestream_engine/paths.py` | Global path store. `set_paths()`, `get_paths()`, `is_initialized()`. Injects binary directories to PATH, prepends site-packages to sys.path for dynamic yt-dlp updates. |
| `config` | `engine/truestream_engine/config.py` | `DEFAULT_CFG` dict with all configurable fields: format, container, quality ceiling, subtitles, SponsorBlock, retries, network, auth, archive, playlist, live. |
| `opts_builder` | `engine/truestream_engine/opts_builder.py` | `build_ydl_opts()` — merges config with paths, applies aria2c opts, builds post-processor chain (FFmpegMetadata, EmbedThumbnail, FFmpegExtractAudio, SponsorBlock, SplitChapters), sets subtitles, hooks. |
| `format_selector` | `engine/truestream_engine/format_selector.py` | `build_format_string()` — tiered format string: explicit ID > audio-only > quality ceiling cascade (AV1 → VP9 → H264). |
| `site_profiles` | `engine/truestream_engine/site_profiles.py` | 6 built-in profiles (YouTube 1080p, YouTube 4K, Podcast Audio, Lossless FLAC, Opus Compact, Twitter/X Video). CDN-fetchable overrides. |
| `downloader` | `engine/truestream_engine/downloader.py` | `start_download()` spawns `threading.Thread` → `download_thread()`. Creates `YoutubeDL` with built opts, adds progress hook + cancel check. Tracks active downloads in `_active_downloads` dict with threading.Lock. |
| `hooks` | `engine/truestream_engine/hooks.py` | `build_progress_hook()` — yt-dlp progress hook → JSON events to queue. `build_postprocessor_hook()` — post-processing stage events. Maps yt-dlp status to named stages (merging, muxing, extracting_audio, etc.). |
| `errors` | `engine/truestream_engine/errors.py` | `TrueStreamError` with typed error codes (ERROR_GEO_BLOCKED, ERROR_RATE_LIMITED, etc.) + recoverable flag + suggests_vpn. `classify_error()` matches exception text against keyword map. |
| `formats` | `engine/truestream_engine/formats.py` | `get_formats()` — extract info without downloading, parse format list into structured objects with codec/resolution/bitrate. Returns recommended video/audio format IDs. |
| `playlist` | `engine/truestream_engine/playlist.py` | `get_playlist_info()` — flat-extract playlist entries. Marks deleted/unavailable entries. Pattern-based playlist URL detection. |
| `bootstrap` | `engine/truestream_engine/bootstrap.py` | CDN manifest fetch, SHA-256 verification, binary download/extract (ffmpeg, aria2c). yt-dlp background update via site-packages injection. JS runtime detection (QuickJS vs Deno vs none). |
| `resume` | `engine/truestream_engine/resume.py` | `scan_resume_candidates()` — scans cache dir for .part files, checks age vs 24h expiry, recovers URL from .info.json metadata. |
| `po_token` | `engine/truestream_engine/po_token.py` | PO Token generation stub. Invokes JS runtime (QuickJS on Android, Deno on Desktop) to generate YouTube Proof-of-Origin tokens. |

### `__main__.py` — Entry Point

The desktop IPC entry point (`python -m truestream_engine`):
1. Starts a daemon thread (`poll_queues`) that drains download progress/result queues
2. Enters a persistent JSON-RPC stdin loop, dispatching to module functions by method name
3. Supports CLI mode for one-shot commands (e.g., `python -m truestream_engine bootstrap`)

## Data Flow — Complete Download Lifecycle

```
┌──────────────────────────────────────────────────────────────────────┐
│ USER PASTES URL                                                      │
│   ↓                                                                   │
│ Flutter: HomeScreen captures URL                                      │
│   ↓                                                                   │
│ Flutter: EngineService.getFormats(url, config)                        │
│   ├─ Android: MethodChannel('formats/get') → Python get_formats()     │
│   └─ Desktop: JSON-RPC stdin → formats/get → stdout                   │
│   ↓                                                                   │
│ Python: yt_dlp.YoutubeDL.extract_info(url, download=False)            │
│   ↓                                                                   │
│ Flutter: FormatPickerScreen displays available streams                │
│   ↓                                                                   │
│ USER PICKS FORMAT (or uses preset/default)                            │
│   ↓                                                                   │
│ Flutter: EngineService.startDownload(url, downloadId, config, net)    │
│   ├─ Android: MethodChannel('download/start') → Python                │
│   └─ Desktop: JSON-RPC stdin → download/start                         │
│   ↓                                                                   │
│ Python: start_download() spawns threading.Thread                      │
│   ↓                                                                   │
│ Python: build_ydl_opts() → format string + post-processors            │
│   ↓                                                                   │
│ Python: YoutubeDL(download_opts).download([url])                      │
│   ↓ concurrent DASH fragment fetching                                 │
│ Python: progress_hook → progress_queue                                 │
│   ├─ Android: EventChannel → Flutter Stream<Map>                      │
│   └─ Desktop: poll_queues → stdout → Flutter line reader              │
│   ↓                                                                   │
│ Flutter: downloadProvider.handleProgressEvent() → state update        │
│   ↓                                                                   │
│ Python: FFmpeg post-processing (merge, embed thumbnail, subs, tags)   │
│   ↓                                                                   │
│ Python: result_queue → finished/error event                           │
│   ↓                                                                   │
│ Flutter: DownloadItem marked completed/error → UI update              │
└──────────────────────────────────────────────────────────────────────┘
```

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

## Test Coverage

```
test/
├── widget_test.dart              # 3 widget tests (onboarding, settings, navigation)
└── performance/
    ├── frame_rate_audit.dart      # Frame rate audit for all screens
    └── platform_test_matrix.dart # Platform-specific test definitions

engine/tests/
├── test_config.py                # Config defaults, merge behavior
├── test_errors.py                # Error classification, edge cases
├── test_format_selector.py       # Format string generation
├── test_misc.py                  # Miscellaneous utility tests
├── test_opts_builder.py          # yt-dlp opts construction
├── test_paths.py                 # Path injection, PATH management
└── test_playlist.py              # Playlist detection, entry parsing
```

Total: 91 Python unit tests, 3 Flutter widget tests, 2 performance audit files.

## Build & Deploy

### GitHub Actions

**Build workflow** (`build.yml`):
- Manual trigger (`workflow_dispatch`)
- 3 parallel jobs: Android APK, Windows app, Linux app
- Android: Java 17 + CMake 3.31.4 + Python 3.11 + Flutter stable → `flutter build apk --release`
- Windows: Flutter → `flutter build windows --release` + copy engine bundle
- Linux: apt deps + Flutter → `flutter build linux --release` + copy engine bundle
- APK: uploaded as artifact (app-release.apk)
- Desktop: full runner release directory uploaded as artifact (includes engine files)

**Verification workflow** (`verify.yml`):
- On push/PR to main
- `flutter analyze` + `flutter test` (Dart)
- `pytest engine/tests/ -v` with uv-installed yt-dlp + engine (Python)

### Binary Distribution

- FFmpeg, aria2c, and yt-dlp updates are distributed via CDN (`cdn.truestream.app/binaries`)
- Manifest JSON lists available versions per platform with SHA-256 checksums
- Bootstrap on first download, SHA-verified on every launch via `engine/bootstrap`
- yt-dlp updates are applied in background via site-packages directory injection
- Dynamic `PYTHONPATH` injection ensures updated modules are loaded before system packages

### Desktop Virtual Environment

- `.venv` at `engine/.venv/` or project root `.venv/` auto-detected by `DesktopEngineService`
- Falls back to system `python3` if no venv found
- `PYTHONPATH` extended with `engine/` directory for module discovery in development
- Production bundles include the `truestream_engine` directory as a resource

## Performance

- Impeller renderer enabled for 120fps UI
- Frame rate audit in `test/performance/frame_rate_audit.dart`
- All downloads run in `threading.Thread` (never main thread)
- Progress events stream at 1-2 second intervals (yt-dlp hook rate)
- aria2c external downloader for parallel fragment fetching (configurable chunks)
- `continuedl=True` for resume support
- No `setState()` for shared state — all Riverpod, minimizing rebuilds
