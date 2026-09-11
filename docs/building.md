# Building From Source

> Last updated: **2026-09-11** — covers bundled jniLibs packages, Deno/QuickJS,
> `lintVital` workaround, and the 181-test engine suite.

## Prerequisites

| Dependency | Version | Notes |
|---|---|---|
| Flutter SDK | stable (3.x) | Install via `flutter upgrade` or your package manager |
| Dart | Bundled with Flutter (3.11+) | Ships with the Flutter SDK |
| Python | 3.11+ | Required for the engine and Chaquopy (Android) |
| Android SDK | 34+ | Required for Android builds |
| NDK | Flutter-bundled | Managed via `flutter.ndkVersion` in Gradle |
| Java | 17 | Required for Android builds |
| CMake | 3.31+ | Required for Android Chaquopy builds |
| uv | latest | Desktop bootstrap + CI (`pip install uv`) |

### Runtime Dependencies

| Binary | Android | Desktop |
|---|---|---|
| **yt-dlp** (+ `yt-dlp-ejs`) | Bundled via Chaquopy pip block | Installed into uv venv at bootstrap |
| **FFmpeg** | 🆕 Bundled in jniLibs (`libffmpeg.so`, SHA-256 pinned) | Auto-downloaded on first launch (SHA-256 verified) |
| **Deno** (JS runtime) | 🆕 Bundled in jniLibs (`libdeno.so`) | Auto-downloaded on first launch (SHA-256 verified) |
| **aria2c** | System/`bin/` path (optional) | Auto-downloaded on first launch (SHA-256 verified) |
| **QuickJS** | `python-quickjs` binding (fallback JS runtime) | Optional (`qjs` on PATH) |

Custom binary paths can be configured in **Settings → Binaries**.
On Android, bundled jniLibs paths always win (only APK-origin files
execute on targetSdk > 28).

## Clone & Setup

```bash
git clone https://github.com/OnlyXianzo/TrueStream.git
cd TrueStream
```

### Flutter Dependencies

```bash
flutter pub get
```

### Python Engine Setup (for local development / testing)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r engine/requirements.txt
pip install -e engine/    # install truestream-engine in editable mode
```

> On Windows use `.venv\Scripts\activate` and `pip` as appropriate.

`engine/requirements.txt` currently pins:

```
yt-dlp>=2025.0.0
yt-dlp-ejs>=0.8.0
# python-quickjs>=0.8.0  # uncomment for Android/QuickJS PO Token support
```

## Build Commands

### Android

Chaquopy bundles Python 3.11 and the engine into the APK. yt-dlp and curl_cffi
are installed via pip during the Gradle build. The Python source lives in
`engine/` and is compiled into the APK automatically.

🆕 **Native packages:** `android/app/packages.gradle.kts` fetches verified
`ytdlnis-packages` APKs at build time (SHA-256 pinned), extracts the `lib` `.so`
files into our own jniLibs, and `BinaryPackageManager` resolves + probes them
at runtime. No helper APKs, no `REQUEST_INSTALL_PACKAGES`, manifest unchanged
(`INTERNET` + capped storage only).

```bash
# Release APK (signed with key.properties if present)
flutter build apk --release

# Debug APK
flutter build apk --debug

# Contributor build WITHOUT bundled ffmpeg/deno (falls back to bin/ paths)
flutter build apk --debug -PskipNativePackages
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

**Platform notes:**
- `minSdk = 24` (Chaquopy requirement; Android 7.0+ devices)
- `targetSdk` / `compileSdk` managed by Flutter Gradle plugin
- ABI filters: `arm64-v8a`, `x86_64`
- Signing: place `key.properties` in `android/` with `storeFile`, `storePassword`, `keyPassword`, `keyAlias`
- CMake 3.31+ required (install via Android SDK manager if needed)
- `lintVital*` tasks are disabled (`android/app/build.gradle.kts`) — works around
  an AGP/Kotlin-script analysis crash on `KaModule`; re-enable after AGP fix
- `zip.so` stripping is skipped so `libffmpeg.zip.so` / `libdeno.zip.so`
  support trees survive packaging
- 🆕 `DownloadService` (`dataSync` FGS) needs no new permissions
  (`FOREGROUND_SERVICE` + `DATA_SYNC` are install-time); declared in
  `AndroidManifest.xml`

### Windows

The Python engine is **not** embedded in the binary on desktop. You must copy
it alongside the release bundle, or use the bootstrapper (first-launch setup).

```bash
flutter build windows --release

# Copy the Python engine into the bundle
xcopy /E /I engine\truestream_engine build\windows\x64\runner\Release\truestream_engine
```

Output: `build/windows/x64/runner/Release/`

### Linux

Same approach as Windows — engine copied alongside the bundle.

```bash
# Install Linux build dependencies
sudo apt-get install -y ninja-build libgtk-3-dev liblzma-dev

flutter build linux --release

# Copy the Python engine into the bundle
cp -r engine/truestream_engine build/linux/x64/release/bundle/
```

Output: `build/linux/x64/release/bundle/`

## Running Tests

### Flutter Tests

```bash
flutter test
```

Runs widget and unit tests under `test/`.

### Python Engine Tests

```bash
# From the project root with venv activated
pytest engine/tests/ -v
```

Runs **181 unit tests** covering config, errors, format selection, opts building
(PP order, sections, aria2c validation, JS runtime), paths, playlists
(generators, IDs, sanitization), downloader, hooks, bootstrap extraction
(Zip/Tar-Slip), bundled packages, and the structured logger.

> CI installs with `uv pip install --system yt-dlp pytest -e engine/`
> (see `.github/workflows/verify.yml`). If collection fails locally, ensure
> `yt-dlp` is installed — several test modules import it.

## Static Analysis

```bash
flutter analyze
```

Must pass with zero errors before committing.

> If you touch `lib/core/utils/app_logger.dart`, watch the `_redact()` regexes:
> use triple-quoted raw strings — plain raw strings with `\` escapes once caused
> 181 cascading analyzer errors (fixed Sept 2026).

## GitHub Actions

Two workflows are available in `.github/workflows/`:

### Verification (`verify.yml`)

Triggers on every push/PR to `main`. Runs:
- `flutter analyze`
- `flutter test`
- `pytest engine/tests/ -v`

### Build & Release (`build.yml`)

Manual trigger only (`workflow_dispatch`). Builds all three platforms:
- **Android** — APK uploaded as artifact (with jniLibs packages)
- **Windows** — release bundle with engine copied alongside
- **Linux** — release bundle with engine copied alongside

To trigger: go to GitHub → Actions → **Build and Release** → **Run workflow**.

> Diagnostics reports stamp the Flutter SDK version via
> `--dart-define=FLUTTER_VERSION=...` (wired in `build.yml`; read in code
> with `String.fromEnvironment('FLUTTER_VERSION')`). Dev runs without the
> flag report `unknown` — expected, not a bug.

## Platform-Specific Notes

- **Android minSdk**: 24 (required by Chaquopy; devices running Android 7.0+)
- **Python bundling (Android)**: `ChaquoPy` Gradle plugin compiles `engine/` into the APK. yt-dlp and curl_cffi are installed via `pip {}` block in `build.gradle.kts`.
- **Native bundling (Android)**: `packages.gradle.kts` + `BinaryPackageManager.kt`. Binaries run **in place** from `nativeLibraryDir`; `LD_LIBRARY_PATH` points at the extracted `usr/lib` tree.
- **Python bundling (Desktop)**: Not bundled. The engine directory must be copied alongside the binary, or the built-in bootstrapper will download it on first launch.
- **Binary bootstrapper**: FFmpeg, aria2c (and Deno on desktop) are downloaded at runtime, SHA-256 verified (fail-closed, no checksum = no install), and extracted with Zip/Tar-Slip guards. Users can also point to custom paths in Settings.
- **JS runtimes**: Deno preferred → Node → QuickJS. `remote_components=ejs:github` keeps challenge solvers fresh. See `docs/JS_RUNTIMES_ANDROID_RESEARCH.md`.
- **FFmpeg**: Required for media processing (merging, remuxing). ~25-35 MB.
- **aria2c**: Download accelerator for faster concurrent chunked downloads. ~3-5 MB. Never used for DASH/HLS (native downloader instead).
- **iOS / Web**: Not currently supported as target platforms.
