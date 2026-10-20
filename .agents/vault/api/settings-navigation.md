---
title: Settings Navigation and Screen Map
date: 2026-10-08
tags: [grablytic, api, settings, navigation, screens]
status: complete
---

# Settings Navigation and Screen Map

Settings information architecture after the T14/T15 restructure (commits `f924045`, `eb3d044`, 2026-10-02) and the C7 re-skin (2026-10-04). Repo paths: `lib/features/settings/screens/`, `lib/features/home/screens/`, `lib/features/library/screens/`.

> **Not on `main`.** Before this wave the settings root was a flat list of every option; it is now a **category list of 10 entries over 9 sub-screens**, all declared in `settings_screen.dart`. Note the *files* behind the sub-screens are mostly old — T14/T15 introduced the **classes and the navigation**, not new screens.

## Root — `SettingsScreen` (`settings_screen.dart:25`)

`// T14: root is a category list; options live in sub-menus.` (`:49-50`). Only two sections + ten `_SettingNavItem`s.

### Downloads group (`:51-121`)

| Entry | Lines |
|---|---|
| General | `:55-67` |
| Storage | `:68-80` |
| Network and speed | `:81-93` |
| Media and subtitles | `:94-106` |
| Automation | `:107-119` |

### App group (`:122-192`)

| Entry | Lines |
|---|---|
| Appearance | `:126-138` |
| Permissions | `:139-151` |
| Cookies | `:152-164` |
| Packages & Updates | `:165-177` |
| System & Diagnostics | `:178-190` |

Leftover move markers at `:194-206` (`// (T14: moved to StorageSettingsScreen)`, `// (T14: moved to SystemSettingsScreen)`).

## Sub-screens (9 classes, all in `settings_screen.dart`)

| Class | Line | `AppBar` title |
|---|---|---|
| `PermissionsSettingsScreen` | `:239` | `'Permissions'` |
| `AppearanceSettingsScreen` | `:308` | `'Appearance'` |
| `GeneralSettingsScreen` | `:354` | — |
| `StorageSettingsScreen` | `:389` | — |
| `NetworkSettingsScreen` | `:499` | `'Network & Acceleration'` |
| `MediaSettingsScreen` | `:640` | — |
| `AutomationSettingsScreen` | `:726` | — |
| `PackagesSettingsScreen` | `:849` | — |
| `SystemSettingsScreen` | `:930` | — |

Notable contents:

- **Appearance** — `_SettingThemeSelector` (`:324-329`), `_SettingLogoSelector` (`:330-336`, see [[design-system|design-system]]), Library Grid View switch bound to `settings.useGridView` (`:337-345`).
- **Permissions** — Download Completion Alerts (`:255-264`), **Queue Reminders** (`:265-298`, gated by `requestQueueReminderPermission` at `:274-277`, snackbar `'Notification permission is required for queue reminders'`), `_BackgroundPermissionsSection()` (`:299`).
- **Automation** — Observed Sources entry, **Queue Reminders duplicate** (`:782-815`) + interval select (`:816-840`), see [[offline-queue-reminders|offline-queue-reminders]].
- **System & Diagnostics** — Analytics nav item (`:966-976`), Packages/Diagnostics entry. The `INSTALLED PACKAGES` card lives at `:2119-2130` (see [[triage-export-workflow|triage-export-workflow]] for the aria2c row).
- **Storage** — `StorageMeterCard(key: ValueKey(settings.downloadPath), downloadPath: settings.downloadPath)` (`:487-490`), see [[batch-system|storage meter]].

## Screen inventory

> **Provenance verified with `git log --diff-filter=A` per file**, not inferred. Most of these screens are *older* than the 2026-09-30 vault scope — the 2026-10-04 wave redesigned them rather than adding them. Only three files and the sub-screen classes are genuinely new.

### `lib/features/settings/screens/` (13 files)

| File | Purpose | First added | New? |
|---|---|---|---|
| `settings_screen.dart` | root category list + the 9 sub-screens | 2026-06-08 | root known; **sub-screen classes new (T14/T15, 2026-10-02)** |
| `analytics_screen.dart` | [[local-analytics\|analytics dashboard]] | **2026-10-02** | **new** |
| `cookies_screen.dart` | cookie master switch, per-site login profiles, paste-cookie import (`AppBar 'Cookies'` `:261-262`) | 2026-09-12 | no — re-skinned (C8) |
| `cookie_webview_screen.dart` | in-app WebView cookie login launched from Cookies | 2026-06-10 | no |
| `subtitle_settings_screen.dart` | subtitle languages, auto-captions, embedding (`AppBar 'Subtitle Settings'` `:38-39`) | 2026-06-10 | no |
| `sponsorblock_settings_screen.dart` | SponsorBlock category toggles (`AppBar 'SponsorBlock'` `:26-27`) | 2026-06-10 | no |
| `schedule_settings_screen.dart` | download time-window scheduler (`AppBar 'Download Schedule'` `:19-25`) | 2026-06-10 | no |
| `presets_screen.dart` | quality preset list (`AppBar 'Download Presets'` `:20-21`) | 2026-06-09 | no |
| `profile_editor_screen.dart` | create/edit preset form (`AppBar 'Create Preset'/'Edit Preset'` `:52-53`) | 2026-06-08 | no |
| `observed_sources_screen.dart` | monitored channels & playlists (`AppBar 'Observed Sources'` `:17-18`) | 2026-06-10 | no |
| `command_templates_screen.dart` | custom yt-dlp argument templates (`AppBar 'Command Templates'` `:17-18`) | 2026-06-10 | no |
| `log_viewer_screen.dart` | Diagnostics & Logs: view/export/delete/report (`AppBar 'Diagnostics & Logs'` `:250-251`) | 2026-06-23 | known |
| `about_screen.dart` | contact + repo links (open-or-copy), licenses, version; hosts `AdaptiveLogo` + `BackHeader` | 2026-06-09 | no |

### `lib/features/home/screens/` (9 files)

| File | Purpose | First added | New? |
|---|---|---|---|
| `home_screen.dart` | Download tab: hero, URL/search field (offline intercept `:430-456`), active cards, resume scan | 2026-06-08 | known, heavily changed |
| `format_picker_screen.dart` | stream picker + T01 cache, T03 toggles, T08 preview, shimmer skeleton | 2026-06-08 | known, heavily extended |
| `batch_download_screen.dart` | live batch runner, retry-failed UI | 2026-06-08 | known |
| `playlist_selection_screen.dart` | playlist subset selection (reverse/shuffle) | 2026-06-08 | known |
| `share_overlay_screen.dart` | [[share-intent-flow\|T04 share overlay]] root + picker host + T02 auto-download | **2026-10-02** | **new** |
| `batch_import_screen.dart` | paste links or pick `.txt`/`.csv` chunk file → start batch | **2026-10-01** | **new** |
| `search_results_screen.dart` | site-scoped search grid → picker, error-recovery card | 2026-09-13 | no |
| `media_preview_screen.dart` | on-device file metadata/size/play surface | 2026-06-10 | no |

### `lib/features/library/screens/` (3 files)

All three pre-date the vault scope; the 2026-10-04 wave redesigned them (C4), and `346a6b3` added segmented tabs + search + chips + in-row delete.

| File | Purpose | First added | New? |
|---|---|---|---|
| `library_screen.dart` | Videos / History / Playlists tabs, search + status chips, grid/list toggle, per-row overflow | 2026-06-08 | no |
| `download_history_screen.dart` | full history with thumbnails, playback (`playHistoryRecord` `:21-54`), re-download, delete | 2026-06-10 | no |
| `playlist_details_screen.dart` | playlist member list, multi-select → batch, add existing downloads | 2026-06-09 | no |

`lib/features/shell/screens/app_shell.dart` and `lib/features/onboarding/screens/onboarding_screen.dart` remain single files and were already known.

Totals: `lib/` = **84** Dart files, `test/` = **79** Dart files, `lib/providers/` = 11, `lib/core/utils/` = 20, `lib/core/widgets/` = 1.

## Tests

`test/features/settings/reorganized_settings_test.dart` — asserts all ten category labels present and that `'Wi-Fi Only Downloads'` **findsNothing** on the root (`:37-79`), then finds it after tapping `Network and speed`; Wi-Fi toggle writes `wifiOnly` (`:81-111`); Automation → ObservedSources (`:113-141`); proxy/verbose/update-channel (`:143-208`); storage keys survive regrouping unchanged (`:210-238`).
`test/features/settings/about_screen_test.dart` — pins `AdaptiveLogo` + `BackHeader`.

## Links

- [[index|index]]
- [[design-system|design-system]]
- [[system-overview|system-overview]]
- [[triage-export-workflow|triage-export-workflow]]
- [[batch-system|batch-system]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[local-analytics|local-analytics]]
- [[share-intent-flow|share-intent-flow]]
- [[open-questions|open-questions]]
