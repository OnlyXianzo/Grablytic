---
title: Format Ladder
date: 2026-10-08
tags: [grablytic, architecture, formats, portrait-fix]
status: complete
---

# Format Ladder (incl. 2026-09-30 Portrait Fix)

Tiered format selection. Repo paths: `engine/grablytic_engine/format_selector.py` (`build_format_string`), `site_profiles.py`, `lib/core/utils/format_selector.dart`, `formats.py`, `lib/core/engine/extraction_cache.dart`, `lib/core/utils/picker_session_state.dart`.

> The **ladder itself is unchanged** since 2026-09-30 — verified against `format_selector.py`. What changed is everything *around* it: extraction caching (T01), picker-local toggles (T03), and pre-download preview (T08).

## Base ladder (unchanged semantics)

Priority: explicit format ID > audio-only request > quality-ceiling cascade **AV1 → VP9 → H264** > muxed fallback (non-YouTube pre-merged streams exposed with badges). Ceilings via `height_map`: `4k→2160`, `1080p→1080`, `720p→720`, `480p→480` (480p added 2026-09-30), `best→99999` (returns `bestvideo+bestaudio/best` immediately).

## The 2026-09-30 portrait fix (commit `6cea501`)

- **Field report:** 54+ portrait reels saved as `.m4a` audio-only. Root cause: yt-dlp `height` is literal pixel height, so `720×1280`/`1080×1920` fail every `height<=1080` rung and the old `/bestaudio/best` tail matched the always-present dash-audio. Same cause down-picked `540×960` when `1080×1920` existed (avg 551×871 → 996×1772 after fix).
- **Fix (aspect-gated ladder):** landscape rungs keep the height cap; a portrait rung matches the same cap by the short edge; tail is `/best`, never audio-only (visible error beats a wrong file):
  ```
  bestvideo*[height<=H][aspect_ratio>=1][ext=mp4]+bestaudio[ext=m4a]
  /bestvideo*[height<=H][aspect_ratio>=1]+bestaudio
  /bestvideo*[width<=H][aspect_ratio<1]+bestaudio
  /best[height<=H]
  /best[width<=H]
  /best
  ```
- **Deliberate non-goals:** NOT `height<=1920` (admits 1440p landscape, breaks the cap); NOT uncapped (4K/8K + AV1/webm surprises on metered mobile). `bv*` (not strict `bv`) so combined-only listings still match. Orientation splits on yt-dlp's auto-computed `aspect_ratio` (= width/height).
- **Companion changes (same commit):** `YouTube-1080p` site profile same fix; Dart picker pre-selection matches by height **OR** width (unknown dims no longer slip the ceiling); `preset_480p` sends a real 480p ceiling; profile editor offers 480p; batch/playlist quality dialog (see [[batch-system|batch-system]]); `height_map` gains real 480p.
- **Verification (from commit message):** real yt-dlp 2026.08 selector repro — OLD 1080p string yields dash-audio-only on hi-only portrait, NEW merges dash-1080v+dash-a; landscape unchanged. `pytest` 553/553 (8 new selector pins), `flutter analyze` clean, `flutter test` 389/389.

## Surrounding contracts

- **Dart picker** (`lib/core/utils/format_selector.dart`): pre-selects within ceiling by height OR width; header shows thumbnail + duration + stream counts.
- **Extraction** (`formats.py` `get_formats()`): no-download parse to codec/resolution/bitrate + recommended video/audio IDs.
- **Profiles** (`site_profiles.py`): 6 built-ins (YouTube 1080p/4K, Podcast Audio, Lossless FLAC, Opus Compact, Twitter/X) + CDN overrides; multi-client extractor args (`default` + `mweb`, never forced single → 31+ formats incl. AV1/VP9). Remote profile URLs are gated by [[url-guard-ssrf|`is_safe_profile_url`]].
- **Safety:** explicit format IDs allowlisted before interpolation (T0-3); `merge_output_format` never combined with `remux_video`.

## T01 — extraction cache

`lib/core/engine/extraction_cache.dart` (docstring `:3-7` marks it T01).

- **In-memory only**, private-ctor singleton `ExtractionCache.instance` (`:9-10`); `_cache` map + `_inFlight` map (`:14-15`). No disk, no SharedPreferences, no engine involvement.
- `defaultTtl = Duration(minutes: 30)` (`:12`), lazy expiry in `get()` (`:21-24`).
- `getOrFetch` joins an in-flight future for concurrent callers (`:49-52`) and caches **only** when `result['success'] == true` (`:59-61`); the in-flight entry is removed in `finally` (`:63-65`).
- Consumers: `format_picker_screen.dart:144` (`get`) and `:376` (`getOrFetch` wrapping `engine.getFormats`).
- **Gap:** the docstring claims sharing across T04/T02/T08, but `ExtractionCache` has exactly **one** production consumer. T02 auto-download never calls `getFormats` at all, so there is nothing to share. See [[share-intent-flow|share-intent-flow]].

## T03 — picker-integrated toggles with session persistence

`lib/core/utils/picker_session_state.dart` — singleton `PickerSessionState.instance` (`:6-7`), fields `embedSubtitles`, `audioOnly`, `qualityCeiling`, `clipEnabled`, `clipStart`, `clipEnd` (`:9-14`), `reset()` (`:16-23`).

**In-memory for the application session only** — no SharedPreferences, nothing on disk (docstring `:2-4`: *"Retains user customizations across format picker visits within the same application session without modifying persistent Settings"*). Because it is not persisted, it does **not** survive process death.

Toggles rendered in the picker and the keys their tests use:

| Toggle | Widget | Key / test |
|---|---|---|
| Quality ceiling | dropdown `best/4k/1440p/1080p/720p/480p/360p` (`:1422-1474`), aliased by `normalizeCeiling` (`2160p→4k`, `2k→1440p`, `:121-128`) | — |
| Embed subtitles | `SwitchListTile` | `Key('embed_subtitles_toggle')` (`:1477-1497`), disabled in audio-only with subtitle `'Requires video stream'` (`:1481-1489`) |
| Clip / trim range | `_buildClipCard` (`:1578-1732`) | `clip_range_switch` (`:1618`), `clip_start_field` (`:1635`), `clip_end_field` (`:1665`) |
| Audio only | `SegmentedButton<bool>` (`:969-991`) | — |
| Format/container | dropdown M4A/MP3/Opus/FLAC vs MKV/MP4/WebM (`:1362-1419`) | — |

Read back in `initState` (`:133-142`, `session.qualityCeiling ?? settings.qualityCeiling`, same pattern for subtitles) and re-applied after extraction (`:317-326`).

Forwarded into the engine config (`:740-764`): `'quality_ceiling'`, `'embed_subtitles'`/`'download_subtitles'` when video, and for clips `'download_sections': ['*<startSec>-<endSec>']` + `'force_keyframes_at_cuts': true`. Clip validation (`_validateClip` `:162-201`): `'Enter clip end time (e.g. 01:30)'`, `'End time must be after start time'`, `'End time exceeds duration (…)'`.

## T08 — pre-download preview

Selection is engine-side, inside the **same single extraction** — no extra network round trip. `formats.py:134-191`, comment: *"T08: Select best progressive (muxed) MP4 stream <= 480p from single extraction"*.

Candidate filters: `vcodec` **and** `acodec` both not `"none"` (`:140-141`); `ext == "mp4"` (`:142-144`); protocol must not start with `m3u8` or `http_dash` (`:145-147`); URL must not end `.m3u8`/`.mpd` (`:149-150`); `height <= 480` **or** `width <= 854` (`:151-160`). Best by `(height, tbr, width)` descending (`:164-169`). Headers merge `info["http_headers"]` + candidate headers + `info["user_agent"]` + `ydl.cookiejar.get_cookie_header(stream_url)` (`:171-182`). Emitted as `result["preview_stream"]` (`:233`).

Dart side, `format_picker_screen.dart:114-119` (state), `:302-311` (unpack), `:398-483` `_togglePreviewPlay()` — builds `VideoPlayerController.networkUrl(url, httpHeaders: headers)` from `preview_stream['url']` + `['headers']`, `initialize()` then `play()`. So it is **HTTP progressive streaming of a remote progressive MP4**, not partial-file playback. Requires `video_player: ^2.9.2`.

UI: play/pause overlay on the 112×64 thumbnail (`:1783-1800`), inline player (`:1809-1882`) labelled `'Preview · ${height}p'` or `'≤480p'` (`:1872`).

Failure policy is silent by design (`:474-482`): *"403 / SABR / unsupported format: silent fallback, never blocks the picker"*, header shows italic `'Preview unavailable'` (`:1310-1319`).

Tests: `engine/tests/test_formats_preview.py` (`:15-110`) — picks format 35 (480p) over 18 (360p), asserts `User-Agent`/`X-Candidate` headers, ignores DASH/HLS, returns `None` for audio-only. `test/features/home/preview_player_test.dart:82-152`.

## Links

- [[index|index]]
- [[download-pipeline|download-pipeline]]
- [[batch-system|batch-system]]
- [[dart-providers|dart-providers]]
- [[engine-service-methods|engine-service-methods]]
- [[system-overview|system-overview]]
- [[url-guard-ssrf|url-guard-ssrf]]
- [[share-intent-flow|share-intent-flow]]
- [[open-questions|open-questions]]
