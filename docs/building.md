# Building From Source

## Prerequisites

| Dependency | Version | Notes |
|---|---|---|
| Flutter SDK | stable (3.x) | Install via `flutter upgrade` or your package manager |
| Dart | Bundled with Flutter | Ships with the Flutter SDK |
| Python | 3.11+ | Required for the engine and Chaquopy (Android) |
| Android SDK | 34+ | Required for Android builds |
| NDK | Flutter-bundled | Managed via `flutter.ndkVersion` in Gradle |
| Java | 17 | Required for Android builds |
| CMake | 3.31+ | Required for Android Chaquopy builds |

### Runtime Dependencies (auto-downloaded on first launch)

- **yt-dlp** — video download library (bundled via Chaquopy pip on Android)
- **FFmpeg** — media processing (SHA-256 verified before extraction)
- **aria2c** — download accelerator (SHA-256 verified before extraction)

Custom binary paths can be configured in Settings.

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

## Build Commands

### Android

Chaquopy bundles Python 3.11 and the engine into the APK. yt-dlp and curl_cffi
are installed via pip during the Gradle build. The Python source lives in
`engine/` and is compiled into the APK automatically.

```bash
# Release APK (signed with key.properties if present)
flutter build apk --release

# Debug APK
flutter build apk --debug
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

**Platform notes:**
- `minSdk = 24` (Chaquopy requirement)
- `targetSdk` / `compileSdk` managed by Flutter Gradle plugin
- ABI filters: `arm64-v8a`, `x86_64`
- Signing: place `key.properties` in `android/` with `storeFile`, `storePassword`, `keyPassword`, `keyAlias`
- CMake 3.31+ required (install via Android SDK manager if needed)

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

Runs 93+ unit tests covering config, errors, format selection, opts building,
paths, playlists, and miscellaneous engine modules.

## Static Analysis

```bash
dart analyze
```

Must pass with zero errors before committing.

## GitHub Actions

Two workflows are available in `.github/workflows/`:

### Verification (`verify.yml`)

Triggers on every push/PR to `main`. Runs:
- `flutter analyze`
- `flutter test`
- `pytest engine/tests/ -v`

### Build & Release (`build.yml`)

Manual trigger only (`workflow_dispatch`). Builds all three platforms:
- **Android** — APK uploaded as artifact
- **Windows** — release bundle with engine copied alongside
- **Linux** — release bundle with engine copied alongside

To trigger: go to GitHub → Actions → **Build and Release** → **Run workflow**.

## Platform-Specific Notes

- **Android minSdk**: 24 (required by Chaquopy; devices running Android 7.0+)
- **Python bundling (Android)**: `ChaquoPy` Gradle plugin compiles `engine/` into the APK. yt-dlp and curl_cffi are installed via `pip {}` block in `build.gradle.kts`.
- **Python bundling (Desktop)**: Not bundled. The engine directory must be copied alongside the binary, or the built-in bootstrapper will download it on first launch.
- **Binary bootstrapper**: FFmpeg and aria2c are downloaded at runtime, SHA-256 verified, and extracted. Users can also point to custom paths in Settings.
- **FFmpeg**: Required for media processing (merging, remuxing). ~25-35 MB.
- **aria2c**: Download accelerator for faster concurrent chunked downloads. ~3-5 MB.
- **iOS / Web**: Not currently supported as target platforms.
