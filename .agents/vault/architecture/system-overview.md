---
title: System Overview
date: 2026-10-08
tags: [grablytic, architecture]
status: complete
---

# System Overview

Layered map of Grablytic (Flutter UI + Kotlin Android bridge + Python [[download-pipeline|yt-dlp engine]]). Repo paths: `lib/`, `engine/grablytic_engine/`, `android/app/.../MainActivity.kt`, `docs/architecture.md`, `README.md`, `DESIGN.md`.

> **Scope note.** Last fully verified 2026-09-30. Updated 2026-10-08 against `redesign/ui` @ `bad0851`, which is now merged into `main` and shipped in v0.0.5. Line numbers and "new" claims come from that snapshot; re-check them before relying on them.

## Layers (top → bottom)

1. **Flutter UI** — screens under `lib/features/` (`home`, `library`, `settings`, `shell`, `onboarding`); `AppShell` hosts 3 tabs (Download · Library · Settings) via `IndexedStack`, `BottomNavigationBar` <600px / `NavigationRail` wide. See [[settings-navigation|settings-navigation]] for the full screen map — the Library screens, the 9 Settings sub-screens, search results, batch import and media preview are all newer than this note's original scope.
2. **Riverpod state** — see [[dart-providers|dart-providers]]: `settingsProvider → engineProvider → engineStatusProvider / downloadProvider / resumeProvider`, plus `batchProvider`, `playlistProvider`, `presetsProvider`, `downloadHistoryProvider`, `logBuffer/logEntries/logIngester`. Offline-queue providers are declared inside a feature util, not in `lib/providers/` — see [[offline-queue-reminders|offline-queue-reminders]].
3. **Engine abstraction** — [[engine-service-methods|EngineService]] (`engine_service.dart`, now **132 lines**) with Android/Desktop/Mock implementations.
4. **Kotlin native (Android)** — [[flutter-chaquopy-python-ipc|MainActivity]] (channels + `onEvent` sink), `BinaryPackageManager` (jniLibs resolve), `DownloadService` (`dataSync` FGS keep-alive), `BootReceiver`, `ObservedSourcesPollWorker`, and now `ShareActivity` (share overlay, see [[share-intent-flow|share-intent-flow]]) + `QueueReminderWorker` (see [[offline-queue-reminders|offline-queue-reminders]]).
5. **IPC transport** — [[method-channel-surface|MethodChannel + EventChannel + Kotlin callback]] on Android; [[method-channel-surface|JSON-RPC stdio]] on desktop.
6. **Python engine** — **19 modules** + entry point: [[download-pipeline|paths, config, opts_builder, format_selector, site_profiles, downloader, hooks, errors, formats, playlist, search, bootstrap, resume, scheduler_check, po_token, logger, persistent, github_notifier]] + [[url-guard-ssrf|url_guard]] + `__main__.py`. *(Corrected from "18": `url_guard.py` was missing from the original list. It predates this note — see [[url-guard-ssrf|url-guard-ssrf]].)*
7. **Design/brand layer** — `lib/core/theme/` (tokens, typography, adaptive logo) and `lib/core/widgets/` (shared components). See [[design-system|design-system]].

## Shared utilities — `lib/core/utils/` (20 files)

Beyond the pre-existing logger/config/cookie/preset helpers, these arrived in the 2026-10-02 → 2026-10-06 waves: `link_importer.dart` ([[batch-system|batch file import]]), `local_analytics.dart` ([[local-analytics|analytics]]), `offline_link_queue.dart` ([[offline-queue-reminders|offline queue]]), `picker_session_state.dart` ([[format-ladder|picker session toggles]]), `thumbnail_cache.dart` (T07 artwork prefetch), `history_guard.dart` (video-identity matching for [[batch-system|skip-existing]]), `trust_boundary.dart` (path/filename validators), `schedule_guard.dart`. The extraction cache lives in `lib/core/engine/extraction_cache.dart`.

## Key design rules (from `docs/architecture.md`, `docs/contributing.md`, `AGENTS.md`)

- `YoutubeDL` class API only — never subprocess yt-dlp.
- Downloads in `threading.Thread` + cancel event; never block main thread.
- Riverpod for shared state, never `setState`; colors via `GrablyticColors` (no hex); 48×48 targets + semantics (WCAG 2.2 AA).
- All binary paths via `set_paths()`; never combine `merge_output_format` + `remux_video`.
- Subtitles embed via `FFmpegEmbedSubtitle`, ordered EmbedSubtitle → ModifyChapters → Metadata.
- Streaming progress capped at 99%; only terminal `finished` = 100% + `filesize_bytes`.
- aria2c validated (`-x1..16`), never for DASH/HLS (CVE-2026-50574). Since `3e22bcd`: **enabled-but-unusable warns with the reason** rather than falling back silently ([[triage-export-workflow|triage-export-workflow]]).
- Every IPC-supplied URL passes [[url-guard-ssrf|`url_guard`]] before admission — SSRF gate, fail-closed except on DNS failure.
- Zip/Tar extraction only via hardened helpers; JS locals via allowlist; aware-UTC datetimes.
- (2026-10-02 →) Transient engine failures auto-retry inside the admitted slot; permanent error types are denied. Offline capture, analytics and picker session state are all local-only by construction.

## Data-flow summary

Paste/share URL → [[engine-service-methods|getFormats]] → [[download-pipeline|FormatPickerScreen]] → [[engine-service-methods|startDownload]] → [[download-pipeline|downloader thread]] → [[flutter-chaquopy-python-ipc|progress events]] → [[dart-providers|downloadProvider]] state → FFmpeg PP → terminal `finished`/`error`/`cancelled` → [[db-schema|history write]] + [[logging-diagnostics|logs]]. Full sequence in [[download-pipeline|download-pipeline]].

Entry points have widened: share intents may divert to [[share-intent-flow|the overlay or auto-download]], and to the [[offline-queue-reminders|offline queue]] when the device has no network. Each completed job is counted by [[local-analytics|local analytics]].

## Links

- [[index|index]]
- [[flutter-chaquopy-python-ipc|flutter-chaquopy-python-ipc]]
- [[download-pipeline|download-pipeline]]
- [[format-ladder|format-ladder]]
- [[batch-system|batch-system]]
- [[logging-diagnostics|logging-diagnostics]]
- [[storage-layout|storage-layout]]
- [[engine-service-methods|engine-service-methods]]
- [[method-channel-surface|method-channel-surface]]
- [[dart-providers|dart-providers]]
- [[db-schema|db-schema]]
- [[design-system|design-system]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[offline-queue-reminders|offline-queue-reminders]]
- [[local-analytics|local-analytics]]
- [[share-intent-flow|share-intent-flow]]
- [[settings-navigation|settings-navigation]]
- [[open-questions|open-questions]]
