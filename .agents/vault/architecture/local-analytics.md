---
title: Local Analytics
date: 2026-10-08
tags: [grablytic, architecture, analytics, privacy, settings]
status: complete
---

# Local Analytics (strictly local)

On-device download counters and a failed-jobs list. Feature T21, commit `92e7116` (2026-10-02). Repo paths: `lib/core/utils/local_analytics.dart`, `lib/features/settings/screens/analytics_screen.dart`, `lib/providers/download_provider.dart`, `lib/features/shell/screens/app_shell.dart`, `lib/features/home/screens/home_screen.dart`.

> **Not on `main`.** Deliberately **not** in SQLite — see [[db-schema|db-schema]].

## Privacy guarantee, and how it is provable

Class docstring (`local_analytics.dart:5-9`):

> "Strictly local download analytics (T21). / No network, no SDK, no telemetry — events persist as JSON in / SharedPreferences on this device only."

Three independent checks back this up:

1. **Imports are exhaustive and inert** — `local_analytics.dart:1-3` imports only `dart:convert` (`jsonDecode`, `jsonEncode`) and `package:shared_preferences/shared_preferences.dart`. No `dart:io`, no `http`, no engine call.
2. **No analytics SDK in `pubspec.yaml`** — dependencies are all UI/state/local packages.
3. **Writers are only `recordIntake`/`recordOutcome`/`clear`** — `summary()` and `failures()` are read-only (`:113-169`).

## Storage — SharedPreferences JSON, capped

```dart
static const String _keyEvents  = 'local_analytics_events_v1';  // :14
static const int    _maxEvents  = 2000;                          // :15
```

`local_analytics.dart:41-52` reads `prefs.getString(_keyEvents)` + `jsonDecode`; `:54-62` writes `prefs.setString(_keyEvents, jsonEncode(capped))` with **tail truncation at 2000 events**. `clear()` `:172-177` = `prefs.remove(_keyEvents)`.

### Event shape

| Phase | Fields | Line |
|---|---|---|
| Intake | `{ts, kind, domain, outcome: null}` | `:78-83` |
| Outcome | `{ts, kind: null, domain, outcome, jobId, title, errorType}` — `title` truncated to 120 chars | `:101-109` |

**Incognito guard:** both recorders drop the event (`:76`, `:95`).

### Domain bucketing

`domainOf` `:32-37` — `youtu` prefix → `youtube`, `instagram` prefix → `instagram`, else `other`.

### `summary()` — nine counters

`shares, pastes, success, retries, failures, youtube, instagram, other, total` (`:145-155`), range-filtered by `ts >= sinceMs` (`:115-117`).

## Dashboard — `lib/features/settings/screens/analytics_screen.dart`

`class AnalyticsScreen` `:9`, `AppBar('Analytics')` `:59`, header text `'On this device only — no tracking, no uploads.'` `:64`.

- Range `SegmentedButton<int?>` = `7 days / 30 days / All`, default **30** (`:17`, `:70-78`).
- **Eight stat tiles** `:98-124`: Shares, Pastes, Success, Retries, Failures, YouTube, Instagram, Other.
- **Failed jobs** list `:130-186` from `LocalAnalytics.failures()`, showing `title` (or `jobId`) with `'domain · errorType'` subtitle (`:170-180`).
- `Clear analytics` outlined button behind a confirm dialog (`:26-51`, `:188-195`).

Reachable from the settings root: `_SettingNavItem(icon: Icons.query_stats_outlined, title: 'Analytics', subtitle: 'On-device counts, no tracking')` in `SystemSettingsScreen` (`settings_screen.dart:966-976`) — see [[settings-navigation|settings-navigation]].

## Producers

| Event | Call site |
|---|---|
| share intake | `app_shell.dart:226` `unawaited(LocalAnalytics.recordIntake(LocalAnalytics.kindShare, url))` |
| paste intake | `home_screen.dart:437` `unawaited(LocalAnalytics.recordIntake(LocalAnalytics.kindPaste, input))` |
| success | `download_provider.dart:528-533` |
| failure + `errorType` | `download_provider.dart:569-576` |
| retry | `download_provider.dart:826-832`, `:933` |

**Coverage gap:** neither `ShareOverlayScreen` nor any `FormatPickerScreen` records analytics — grep of `LocalAnalytics.` finds no hit there. So shares arriving through the overlay path ([[share-intent-flow|share-intent-flow]]) are not counted, and the dashboard under-reports.

## Tests

`test/core/utils/local_analytics_test.dart` — domain classification (`:12-23`), aggregate + range filter + failures + clear (`:25-79`), `incognito jobs are never recorded` (`:81-94`).

## Links

- [[index|index]]
- [[dart-providers|dart-providers]]
- [[db-schema|db-schema]]
- [[share-intent-flow|share-intent-flow]]
- [[download-pipeline|download-pipeline]]
- [[settings-navigation|settings-navigation]]
- [[open-questions|open-questions]]
