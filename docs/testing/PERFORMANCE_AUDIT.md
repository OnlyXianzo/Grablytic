# Performance Audit

## Frame Rate Targets

| Target | Device Class | Expected |
|--------|-------------|----------|
| 120 fps | 120 Hz displays (flagship Android, high-refresh desktops) | Primary target |
| 60 fps  | Standard displays (60 Hz panels) | Minimum acceptable |
| 30 fps  | Low-end / legacy devices | Acceptable floor |

All screens must meet 60 fps minimum under normal conditions. 120 fps
target applies to high-refresh-rate devices with Impeller rendering enabled.

## Known Performance Considerations Per Screen

### Onboarding Screen
- `_ParticlesPainter` uses `CustomPaint` — trivial cost (< 0.1 ms)
- `AnimatedSwitcher` + `flutter_animate` sequences trigger rebuilds during
  beat transitions. Each beat stabilises within 600 ms after the last animation
- Black background avoids GPU fill-rate pressure
- **Risk**: beat transitions may drop frames if CPU is under load from
  font loading. Mitigation: pre-cache `GoogleFonts.instrumentSans` before
  onboarding starts

### Home Screen
- `IndexedStack` keeps all 3 tab screens alive. Home screen rebuilds
  whenever `downloadProvider`, `engineStatusProvider`, or `resumeProvider`
  emit new values
- `_DownloadCard` list may grow unbounded. Beyond ~20 items, switch to
  `ListView.builder` to lazily build cards
- `_UrlInput` uses `TextEditingController` — no performance concern
- **Risk**: `engineStatusProvider` is a `FutureProvider` that awaits
  `engine.bootstrap()`. If bootstrap takes > 2 seconds, the UI may show
  an empty banner (intentional) but the scaffold is fully interactive

### Library Screen
- Uses `TabController` with 2 tabs (`Videos`, `Playlists`). Both tabs
  render via `TabBarView` which does lazy build — only visible tab builds
- `_LibraryItem` widgets grow with download count. Filter with
  `downloads.where(...).toList()` on every build — O(n) per rebuild.
  For > 100 items, pre-compute filtered lists with `select()` or a
  computed state
- **Risk**: `playlistProvider` reads from `SharedPreferences` on init.
  Blocking I/O on first frame. Mitigation: lazy-load playlists after
  first frame with `addPostFrameCallback`

### Settings Screen
- Pure `ConsumerWidget` reading `settingsProvider`. Rebuilds on any
  settings change (theme toggle, path change, etc.) — entire column
  rebuilds
- `flutter_animate` on each row — 8 sequential animation controllers
  staggered by 40-80 ms. Acceptable for ~8 items, but if setting rows
  grow to 20+, batch with `AnimatedList` or single `Animate` manager
- **Risk**: `FilePicker.getDirectoryPath()` is a native call that may
  pause the frame for 100-500 ms. This happens on user tap, not during
  scroll, so it's acceptable

## How to Run Performance Tests

```bash
# Frame rate audit (all screens)
flutter test test/performance/frame_rate_audit.dart

# Platform test matrix validation
flutter test test/performance/platform_test_matrix.dart

# Full test suite
flutter test
```

Tests use `tester.binding.setSurfaceSize()` to ensure consistent
viewport dimensions across runs. Frame times are reported to `debugPrint`
and can be parsed by CI tooling.

## Impeller Rendering Engine Requirements

Grablytic uses Impeller as the default rendering engine. This provides
deterministic frame pipelines and eliminates Skia shader compilation jank.

### Device Requirements
- **Android**: API 29+ (Android 10+). Impeller enabled by default in
  Flutter 3.22+
- **Windows**: DirectX 12 or Vulkan-capable GPU. Fallback to Skia if
  neither available.
- **Linux**: Vulkan 1.1+ required. Test on Mesa drivers (radeonsi,
  ANV) and NVIDIA proprietary drivers separately.

### Enabling Impeller
Impeller is enabled by default on Flutter 3.24+. Verify in
`android/app/build.gradle`:

```groovy
android {
    defaultConfig {
        // ...
    }
}
```

To force Impeller on desktop:
```bash
flutter run --enable-impeller
```

### Monitoring
Add the `PerformanceOverlay` for ad-hoc profiling in debug builds:

```dart
MaterialApp(
  showPerformanceOverlay: true,  // debug only
  // ...
)
```

### Known Impeller Issues
- Custom `ShaderMask` operations may fall back to CPU on older GPU drivers
- `BackdropFilter` with `ImageFilter.blur()` has higher GPU cost vs Skia
- Text rendering with `GoogleFonts.instrumentSans` may have minor
  alignment differences — test each platform visually before release

## Alerting

Add frame rate monitoring to CI via the `frame_rate_audit.dart` test.
If any screen's render time exceeds 500 ms on the reference device
(pixel 8, 1080p viewport), tag the commit as a performance regression:

```bash
flutter test test/performance/frame_rate_audit.dart --machine \
  | jq 'select(.type == "debug" and .message | contains("Render time"))'
```
