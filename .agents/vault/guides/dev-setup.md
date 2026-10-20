---
title: Dev Setup
date: 2026-10-08
tags: [grablytic, guides, setup]
status: complete
---

# Dev Setup

Per-platform contributor setup. Sources: `README.md`, `docs/building.md`, `docs/contributing.md`, `pubspec.yaml`, `engine/requirements.txt`, `.github/workflows/verify.yml`.

> Test counts were last measured 2026-10-08. CI is the current gate; see the table below. Three runtime dependencies were added, and five font families are bundled in-repo.

## Prerequisites

Flutter stable 3.x (Dart 3.11+), Python 3.11+, Android SDK 34+ / NDK (Flutter-bundled) / Java 17 / CMake 3.31+, `uv` (desktop bootstrap + CI).

## Clone + deps

```bash
git clone https://github.com/OnlyXianzo/Grablytic.git
cd Grablytic
flutter pub get
python3 -m venv .venv && source .venv/bin/activate  # Windows: .venv\Scripts\activate
pip install -r engine/requirements.txt
pip install -e engine/
```

`engine/requirements.txt` pins `yt-dlp>=2025.11.12`, `yt-dlp-ejs>=0.8.0` (QuickJS line commented unless needed). CI installs via `uv pip install --system yt-dlp pytest -e engine/`.

**If pytest collection fails with `ModuleNotFoundError: No module named 'grablytic_engine'`**, either install the package (`pip install -e engine/`) or run with `PYTHONPATH=engine python3 -m pytest engine/tests/`. The bare `pytest engine/tests/` form works in CI because CI installs `-e engine/`.

## Verify (must pass before any commit)

```bash
flutter analyze            # zero-error required
flutter test
PYTHONPATH=engine python3 -m pytest engine/tests/ -q
```

### Test counts

| Suite | 2026-10-08 measured | Current gate |
|---|---|---|
| Engine (`pytest`) | **564 collected, 564 passed in 56.78 s** | `Python Engine Tests 3.11` and `3.12` passed on PR #14 (merge `4f35d27`) |
| Flutter (`flutter test`) | Not run locally; 524 declarations at the time | `Flutter Analyze & Test` passed on PR #14; 583 declarations across 84 files on 2026-10-20 |

The 583 figure is a static count of `test(` / `testWidgets(` declarations, not an executed count. Read the CI log for the passed total.

`engine/tests/` now spans **41** `test_*.py` files. Coverage gate in CI is `pytest … --cov-fail-under=75` — note `verify.yml:5` still advertises ">=70%" in its header comment, a doc/CI inconsistency (see [[open-questions|open-questions]]).

Watch `app_logger.dart` `_redact()` regexes: use triple-quoted raw strings or 181 cascading analyzer errors return.

## Added runtime dependencies (2026-10-02 → 2026-10-06)

| Package | Version | Needed by |
|---|---|---|
| `connectivity_plus` | `^7.1.1` | [[offline-queue-reminders\|offline detection]] |
| `file_picker` | `^11.0.2` | [[batch-system\|batch file import]] (`.txt`/`.csv`) |
| `video_player` | `^2.9.2` | [[format-ladder\|T08 in-app preview]] |

`shimmer` and `webview_flutter` were already present; `shimmer` now drives the format-picker loading skeleton.

## Bundled fonts (offline by design)

Five families are committed under `assets/fonts/` and declared in `pubspec.yaml:82-138` — **BricolageGrotesque**, **Figtree**, **InstrumentSans** (400/500/600/700), **IosevkaCharon**, **IosevkaCharonMono** (8 faces each) — with OFL licenses shipped alongside. `BricolageGrotesque` + `Figtree` are declared as single-face families with **no `weight:`**, so Flutter synthesises all weights. Rationale is recorded in `app_theme.dart:186-190` (*"zero runtime font fetches, zero network beacons"*). Full role map in [[design-system|design-system]].

**Widget tests do not get bundled fonts.** The current suite does not load custom fonts in widget tests, and no screenshot tests are tracked. Do not add screenshot scratch files to the repo.

## Builds

| Platform | Command | Output |
|---|---|---|
| Android | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |
| Windows | `flutter build windows --release` + copy `engine/grablytic_engine` into bundle | `build/windows/x64/runner/Release/` |
| Linux | `flutter build linux --release` + copy `engine/grablytic_engine` into bundle (+ `ninja-build libgtk-3-dev liblzma-dev`) | `build/linux/x64/release/bundle/` |

Android notes: `minSdk 24`; ABIs `arm64-v8a` (+ `armeabi-v7a`, `x86_64` for universal) via `ndk.abiFilters` (Chaquopy-mandated; never combine with `--split-per-abi` or Gradle `splits{}`/flavors). `packages.gradle.kts` fetches pinned `ytdlnis-packages` APKs → jniLibs; `-PskipNativePackages` for contributor builds without ffmpeg/deno; `-PtargetAbi=… -PjsRuntime=deno|node|both` selects release variants (Deno ≈91 MB/152 MB vs Node ≈50 MB/82 MB; armv7 takes Node — no upstream Deno armv7 build). `lintVital*` disabled (AGP/Kotlin-script bug); `zip.so` stripping skipped (keeps `libffmpeg.zip.so`/`libdeno.zip.so` trees). Signing via `android/key.properties`. `DownloadService` needs no new permissions.

## Conventions (see `docs/contributing.md`)

Conventional commits (`type(scope): …`), one logical change per commit, feature branches from `main`, squash-merge PRs with motivation + verification + platforms tested. Python: `YoutubeDL` API, threads + cancel, hardened extract helpers, JS allowlist, aware-UTC. Kotlin: public `EngineEventListener`, jniLibs-win, `dataSync` + `START_NOT_STICKY`, never `REQUEST_INSTALL_PACKAGES`. Never commit private `.agents/` files, worklogs, or scratch. `AGENTS.md` and `.agents/vault/` are tracked on purpose. Check `git status --short` before staging.

> The 2026-10-02 → 2026-10-06 redesign wave landed on `redesign/ui` and merged into `main` in v0.0.5. The vault was written against `bad0851`; re-check line numbers before relying on them.

## Links

- [[index|index]]
- [[nightly-release-workflow|nightly-release-workflow]]
- [[system-overview|system-overview]]
- [[storage-layout|storage-layout]]
- [[design-system|design-system]]
- [[triage-export-workflow|triage-export-workflow]]
- [[open-questions|open-questions]]
