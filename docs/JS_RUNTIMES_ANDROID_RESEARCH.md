# JS Runtimes on Android ARM64 — Research Findings

**Date**: 2026-09-11  
**Purpose**: Determine how to get Deno, Node.js, and QuickJS binaries working on Android ARM64 for yt-dlp EJS challenge solving.

---

## 1. Deno on Android ARM64

### Official Deno Builds
- **No official Android builds exist.** Deno releases (v2.9.6 latest as of 2026-08-27) only ship for:
  - `aarch64-apple-darwin` (macOS ARM64)
  - `x86_64-apple-darwin` (macOS x64)
  - `aarch64-unknown-linux-gnu` (Linux ARM64)
  - `x86_64-unknown-linux-gnu` (Linux x64)
  - `x86_64-pc-windows-msvc` (Windows x64)
  - `aarch64-pc-windows-msvc` (Windows ARM64)
- The download domain `dl.deno.land` does not list any Android target tuple.
- **No 32-bit Android support.**
- **Minimum version for yt-dlp**: v2.0.0 (per yt-dlp wiki); yt-dlp recommends ≥2.3.0 for npm remote-components support.
- **Source**: https://dl.deno.land/ (retrieved 2026-09-11) — **Confidence: HIGH**

### Termux Deno Package (Cross-Compiled for Android)
- Termux maintains a Deno build script at `packages/deno/build.sh` in `termux/termux-packages`.
- It **cross-compiles Deno from source** using Android NDK + Rust toolchain.
- **Excluded architectures**: i686, arm (per `TERMUX_PKG_EXCLUDED_ARCHES`). Only `aarch64` and `x86_64` are supported.
- **Build complexity**: Very high — requires:
  - Building `librusty-v8` from source with Android NDK patches
  - Multiple patch files for Android errno, ioctl types, WebGPU, etc.
  - Snapshot generation via proot
  - Full Rust/Cargo cross-compilation setup
- **Dependencies**: `libandroid-stub`, `libffi`, `libsqlite`, `zlib`
- **Source**: https://github.com/termux/termux-packages/blob/master/packages/deno/build.sh (2026-09-11) — **Confidence: HIGH**

### Can We Use Termux's Pre-built Deno .deb?
- Termux packages Deno as a `.deb` for its own package manager.
- The `.deb` binary links against Termux's custom libc/bionic environment, NOT standard Android NDK bionic.
- **It may or may not work** outside Termux depending on how it's linked. Would need testing.
- **Confidence: MEDIUM** — Needs empirical verification.

---

## 2. Node.js on Android ARM64

### Official Node.js Builds
- **No official Android builds.** Node.js releases (v26.x current) only ship:
  - `linux-x64`, `linux-arm64`
  - `darwin-x64`, `darwin-arm64`
  - `win-x64`, `win-arm64`
- **Source**: https://nodejs.org/en/download/ (2026-09-11) — **Confidence: HIGH**

### Unofficial Builds (nodejs/unofficial-builds)
- Provides musl, glibc-217, riscv64, loong64 variants.
- **No Android builds** in the unofficial builds project.
- **Source**: https://github.com/nodejs/unofficial-builds (2026-09-11) — **Confidence: HIGH**

### Community Android Node.js Builds
- **sjitech/build-nodejs-for-android** (GitHub) provides prebuilt Node.js binaries for Android: arm, arm64, x86, x64.
  - Source: https://github.com/sjitech/build-nodejs-for-android
  - Docker build environment provided.
  - **Confidence: MEDIUM** — Community project, may be outdated.
- **sjitech/nodejs-android-prebuilt-binaries** — Prebuilt binaries with optional features (no snapshot, no inspector, no intl).
  - Source: https://github.com/sjitech/nodejs-android-prebuilt-binaries
  - **Confidence: MEDIUM**

### Minimum Version for yt-dlp
- yt-dlp requires Node.js ≥22.0.0 (per current EJS wiki) or ≥20.0.0 (per older wiki revision).

---

## 3. QuickJS on Android ARM64

### yt-dlp Built-in QuickJS Support
- yt-dlp supports QuickJS via `--js-runtimes quickjs` or `--js-runtimes quickjs:/path/to/qjs`.
- QuickJS is a tiny, statically-linkable runtime — ideal for Android.
- Minimum version: 2023-12-9. QuickJS-NG: any version.
- **The executable must be named `qjs`** or path specified via `--js-runtimes`.
- **Source**: https://github.com/yt-dlp/yt-dlp/wiki/ejs (2026-09-11) — **Confidence: HIGH**

### QuickJS Android Libraries
- **OpenQuickJS/quickjs-android** (GitHub) — Provides Android AAR with JNI bindings.
  - Includes `libquickjs_bridge.so` for arm64-v8a, armeabi-v7a, x86_64, x86.
  - But this is a **library**, not a standalone CLI binary.
  - Source: https://github.com/OpenQuickJS/quickjs-android — **Confidence: HIGH**
- **HLahwani/yt-dlp-android** — Embeds QuickJS in AAR for YouTube n-param/signature solving, but not the full yt-dlp JS runtime path.
  - Source: https://github.com/HLahwani/yt-dlp-android — **Confidence: HIGH**

### QuickJS-NG
- QuickJS-NG is a maintained fork with better performance.
- Provides prebuilt binaries at https://quickjs-ng.github.io/quickjs/installation
- Would need to verify if they ship Android binaries.
- **Confidence: MEDIUM**

---

## 4. Termux Cross-Compilation for Deno/Node.js

### Termux Build System
- Uses Docker-based Ubuntu build environment with Android NDK cross-compilation.
- Key variables: `TERMUX_ARCH` (default aarch64), `TERMUX_PKG_API_LEVEL` (default 24).
- Build command: `./build-package.sh deno` (cross-compiles from Linux host).
- **On-device builds are NOT supported** for Deno (`TERMUX_PKG_ON_DEVICE_BUILD_NOT_SUPPORTED=true`).
- Requires: Android SDK + NDK, Docker, Rust toolchain, GN/Ninja build systems.
- **Source**: https://github.com/termux/termux-packages/wiki/Building-packages (2026-09-11) — **Confidence: HIGH**

### Key Challenge
- Building Deno for Android is non-trivial: requires V8 from source with Android-specific patches.
- Building Node.js for Android is similarly complex (V8 snapshot generation, etc.).
- QuickJS is trivially cross-compilable since it's a single C file.

---

## 5. bgutil-ytdlp-pot-provider-rs (Rust Binary)

### Current Release (v0.8.1, 2026-03-12)
- **Pre-built binaries available**:
  - `bgutil-pot-linux-x86_64` (48.6 MB)
  - `bgutil-pot-linux-aarch64` (51.6 MB)
  - `bgutil-pot-macos-aarch64`, `bgutil-pot-macos-x86_64`
  - `bgutil-pot-windows-x86_64.exe`
- **No Android-specific binaries.** The `linux-aarch64` binary targets Linux ARM64 (glibc), NOT Android (bionic).
- **Source**: https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/releases/tag/v0.8.1 — **Confidence: HIGH**

### Does it include a JS Runtime?
- **Yes** — It uses V8 (via `rustypipe-botguard` crate) for BotGuard challenge solving.
- It does NOT require an external JS runtime — V8 is compiled in.
- **Source**: https://docs.rs/crate/bgutil-ytdlp-pot-provider (2026-09-11) — **Confidence: HIGH**

### FFI Mode
- v0.8.0+ provides C-compatible FFI (cdylib) mode: `libbgutil_ytdlp_pot_provider.so/.dylib/.dll`
- This could theoretically be compiled for Android and loaded via JNI/Chaquopy.
- FFI functions: `ffi_generate()` (POT token generation) and `ffi_free_string()` (memory deallocation).
- **Source**: https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs (2026-09-11) — **Confidence: MEDIUM** (Android cross-compilation not proven)

### Can It Be Compiled for Android ARM64?
- **Theoretically yes** — Rust supports `aarch64-linux-android` target.
- Would need to cross-compile with Android NDK toolchain.
- Dependencies: OpenSSL (can use vendored-openssl feature), V8 (complex).
- **V8 compilation for Android is the hardest part** — same challenge as Termux's Deno build.
- **Confidence: LOW-MEDIUM** — Possible but non-trivial.

### Calling from Python/Chaquopy
- If compiled as `.so` for Android, could be loaded via Chaquopy's native library support.
- Alternatively, could run as a subprocess (HTTP server mode on localhost:4416).
- **Confidence: MEDIUM**

---

## 6. yt-dlp-ejs

### What It Is
- **yt-dlp-ejs** is a Python package containing **JavaScript challenge solver scripts** for YouTube.
- It's NOT a JS runtime itself — it's the JS scripts that get executed BY a JS runtime.
- Replaces the older JSInterp/PhantomJS approach.
- **Source**: https://github.com/yt-dlp/yt-dlp/wiki/ejs (2026-09-11) — **Confidence: HIGH**

### Does It Need Separate Download?
- **It depends on installation method**:
  - **PyInstaller bundles** (yt-dlp.exe, etc.): EJS is bundled, no action needed.
  - **PyPI/pip**: Install via `pip install -U "yt-dlp[default]"` (default dependency group includes yt-dlp-ejs).
  - **Deno/Bun runtime**: Can use `--remote-components ejs:npm` to auto-download.
  - **GitHub download**: Can use `--remote-components ejs:github` to auto-download.
  - **Standalone zipimport binary**: EJS is bundled.
- **Source**: https://github.com/yt-dlp/yt-dlp/wiki/ejs (2026-09-11) — **Confidence: HIGH**

### How It Works on Android (Chaquopy)
- When running yt-dlp via Chaquopy (embedded Python), yt-dlp needs EJS scripts + a JS runtime.
- EJS scripts can be installed via pip inside the Chaquopy environment.
- A JS runtime binary (deno/qjs/node) must be available on the device.
- yt-dlp calls the runtime via subprocess: `--js-runtimes "deno:/path/to/deno"`.

---

## Summary: Practical Options for Android ARM64

| Option | Feasibility | Complexity | Notes |
|--------|------------|------------|-------|
| **QuickJS (`qjs`)** | ✅ BEST | Low | Single C file, trivially cross-compiles. Use `--js-runtimes quickjs:/path/to/qjs` |
| **Deno via Termux .deb** | ⚠️ MAYBE | Medium | May work if linked correctly. Needs testing. |
| **Deno cross-compiled from source** | ⚠️ POSSIBLE | Very High | Requires V8 from source + Android NDK. Termux does this. |
| **Node.js via sjitech builds** | ⚠️ MAYBE | Medium | Community builds, may be outdated for Node 22+. |
| **bgutil-pot-rs cross-compiled** | ⚠️ POSSIBLE | High | Rust cross-compile possible, V8 dependency is the blocker. |
| **Skip JS runtime, use bgutil HTTP server** | ✅ FEASIBLE | Low | Run bgutil-pot as HTTP server on device, call via localhost. |

### Recommended Approach
1. **Primary**: Cross-compile **QuickJS-NG** for Android ARM64 (trivial — single C file with NDK).
2. **Alternative**: Try Termux's pre-built Deno `.deb` package.
3. **POT Token**: Either cross-compile bgutil-pot-rs, or run it as an HTTP server subprocess.
4. **EJS Scripts**: Install via `pip install yt-dlp[default]` in Chaquopy, or use `--remote-components ejs:github`.
