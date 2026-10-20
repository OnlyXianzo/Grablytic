---
title: Share Intent Flow
date: 2026-10-08
tags: [grablytic, architecture, share, intent, android, entrypoint]
status: complete
---

# Share Intent Flow

The three ways a URL enters the app from outside: the in-app `AppShell` handler, the standalone translucent overlay (T04), and the overlay's auto-download path (T02). Plus clipboard capture on foreground. Repo paths: `lib/features/home/screens/share_overlay_screen.dart`, `lib/features/shell/screens/app_shell.dart`, `lib/main.dart`, `android/app/src/main/kotlin/com/theonly/grablytic/ShareActivity.kt`, `android/app/src/main/AndroidManifest.xml`.

> T04 commit `f77e833`, T02 commit `7ff3d6f`, both 2026-10-02. **Not on `main`.** Replaces the "choice bottom sheet" described in [[download-pipeline|download-pipeline]] step 1.

## Entry 1 — in-app `AppShell` (legacy path)

`app_shell.dart:249-342`. Gates, in order:

1. `settings.shareBehavior == 'auto' || settings.autoStartDownloadOnShare` (`:249-250`) — else the choice sheet.
2. `engineStatusProvider.future` readiness, with fallback to the sheet (`:252-274`).
3. Schedule-window confirm (`:275-304`).
4. `ensureUnmeteredDownload` Wi-Fi-Only gate (`:305-312`).
5. `isDownloading` duplicate guard (`:314-324`).
6. `engine.startDownload(...)` (`:334-342`); on failure `engine.showErrorNotification` (`:366-395`).

Offline interception at `:228-246` diverts to the [[offline-queue-reminders|offline queue]] when `isDeviceOffline()`. Clipboard capture on foreground at `:81-114`. Share intake is counted by [[local-analytics|local analytics]] at `:226`.

## Entry 2 — standalone overlay (`ShareActivity`)

### Native

`android/.../ShareActivity.kt`:
- `getDartEntrypointFunctionName() = "shareMain"` (`:18`)
- `BackgroundMode.transparent` (`:20-21`)
- passes `Intent.EXTRA_TEXT` as entrypoint args (`:23-26`)

Manifest (`android/app/src/main/AndroidManifest.xml:69-89`): `.ShareActivity`, `theme="@style/TranslucentTheme"`, **`taskAffinity="com.theonly.grablytic.share"`**, **`excludeFromRecents="true"`**, intent filter `ACTION_SEND` + `text/plain`.

The dedicated task affinity plus `excludeFromRecents` is what keeps the share picker from adding a second task to the back stack.

### Dart entrypoint

`lib/main.dart:146-194` — `@pragma('vm:entry-point') void shareMain(...)`; `:189-191` builds `ShareOverlayApp(initialUrl: args.first)`.

`share_overlay_screen.dart` exposes two public classes: `ShareOverlayApp` (`:23`, root `MaterialApp` with transparent scaffold backgrounds `:39-44`) and `ShareOverlayScreen` (`:50`, `ConsumerStatefulWidget` taking `initialUrl`).

### URL resolution

Constructor arg → `engine.getSharedUrl()` → `engine.sharedUrlStream` with a **1.5 s** budget, then one retry (`:95-137`, budget at `:122`).

### Overlay mechanics — all differences live in the wrapper

There is **no separate format-picker class**. The overlay hosts the *same* `FormatPickerScreen` (`format_picker_screen.dart:26-29` has only `url` and `title` fields — no embedded/overlay flag):

```dart
MaterialPage(child: isPlaylistUrl(url)
  ? PlaylistSelectionScreen(url: url, title: url)
  : FormatPickerScreen(url: url, title: url));   // share_overlay_screen.dart:361-366
```

So a playlist share still routes through [[batch-system|playlist selection]], and a video share through [[format-ladder|the normal picker]].

Wrapper-only differences:

| Behaviour | Citation |
|---|---|
| Transparent `MaterialApp`/`Scaffold` | `:39-44`, `:264`, `:278`, `:319` |
| Bottom card `FractionallySizedBox(heightFactor: 0.90)` + `ClipRRect` top radius 20 + shadow | `:335-355` |
| Tap-outside scrim calls `_finish()` | `:323-331` |
| `_finish()` = `SystemNavigator.pop()` **plus** `MethodChannel('com.theonly.grablytic/engine').invokeMethod('activity/finish')` | `:85-93` |
| Nested `Navigator` whose `onDidRemovePage` calls `_finish()` | `:356-359` |
| `PopScope(canPop: false)` on all three states | `:258-261`, `:272-275`, `:313-317` |

The `activity/finish` native call is needed because a translucent activity with `canPop: false` would otherwise leave the task alive.

## Entry 3 — auto-download (T02)

### Setting: two keys in lockstep

`lib/providers/settings_provider.dart`:
- Fields `shareBehavior` (String `'ask' | 'auto'`) and legacy bool `autoStartDownloadOnShare` — `:94-95`
- Defaults `false` / `'ask'` — `:150-151`
- Load `share_behavior`, falling back to `autoStartDownloadOnShare ? 'auto' : 'ask'` — `:334-338`
- `toggleAutoStartDownloadOnShare()` writes **both** keys — `:528-537`
- `setShareBehavior(String)` does the inverse — `:539-546`

UI: `_SettingSwitch(title: 'Auto-start Download on Share', value: settings.shareBehavior == 'auto')` in `GeneralSettingsScreen` (`settings_screen.dart:370-379`).

### Auto-download config

Identical in both entry points:

```dart
{'container': qualityCeiling == 'best' ? 'mkv' : 'mp4',
 'quality_ceiling', 'audio_only', ...settingsDownloadConfig(settings)}
```

`app_shell.dart:327-332`, `share_overlay_screen.dart:177-182`. **No `explicit_format_id`** — the engine/preset picks the format, so auto-start never touches the [[format-ladder|picker]] at all.

**Gate asymmetry:** `AppShell._handleSharedUrl` applies all five gates (readiness, schedule, metered, duplicate); `ShareOverlayScreen._triggerAutoDownload` (`:167-253`) applies **none** — no readiness check, no schedule window, no Wi-Fi-Only gate, no duplicate guard. It calls `showErrorNotification` on failure (`:219-223`, `:235-239`) and always `_finish()`s after 600 ms (`:251-252`).

## Offline + analytics interaction

- Offline share → [[offline-queue-reminders|offline queue]] with `source: 'share'`, snackbar `'Offline: Shared link saved to queue'`, `_finish()` after 600 ms (`share_overlay_screen.dart:141-154`).
- The overlay path records **no** analytics (see [[local-analytics|local-analytics]] coverage gap).

## Tests

`test/features/home/share_overlay_screen_test.dart` (219 lines) — `extractUrl` unit tests (`:44-69`), picker/playlist rendering (`:73-125`), empty state (`:127-148`), `share_behavior: 'auto'` → no `FormatPickerScreen` + snackbar `'Auto-starting download'` (`:150-183`), error notification (`:185-219`).

## Links

- [[index|index]]
- [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]
- [[download-pipeline|download-pipeline]]
- [[format-ladder|format-ladder]]
- [[batch-system|batch-system]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[local-analytics|local-analytics]]
- [[settings-navigation|settings-navigation]]
- [[open-questions|open-questions]]
