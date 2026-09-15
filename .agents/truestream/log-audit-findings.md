# TrueStream — Real Log Audit Findings (Task 1)

Agent: Aarav · branch: `aarav/log-audit` · build in logs: `48edd3f` (= current `origin/main` tip)
Input: all 12 files in `~/storage/downloads/truestream-logs/` (4) + `~/storage/downloads/truestream-logs-multi/` (8) read in full — 31,896 lines / ~6.8 MB, no sampling. Every WARN/ERROR/FAIL line extracted by full-file scan, then root-caused against current source with file:line citations.
Log realtime record: `.agents/truestream/aarav.md`.

## Sessions found in the logs (3, on ≥2 devices)

| Session | Files | Device-local span | Engine (UTC) span | Kernel (engine) | Outcome |
|---|---|---|---|---|---|
| A | `*-multi/* (1).*` | 17:42–17:46 | 12:13–12:27 | Linux-6.1.138-android14, aarch64 | 2/2 downloads completed (`303+251`, `248+251`) |
| B | `*-multi/*` main + `truestream-logs/` base | 16:44–16:59 | 11:18–11:29 | Linux-6.1.138-android14, aarch64 | 3/3 completed (`400+251-drc`, `399+251-2`, `399+251-1`, incl. split-chapters long video) |
| C | `truestream-logs/` tail only | 18:27–18:35 | 12:58–13:05 | Linux-4.19.191, aarch64 (different device) | 0/5 — 3× SoundCloud fail, 2× FLAC fail |

Sessions A and B are healthy end-to-end (bootstrap → formats → download → merge → metadata → split-chapters → MoveFiles → "Download completed"). All failures concentrate in session C and use the **default format ladder**, never explicit format IDs.

## Genuine new bugs

### BUG-1 [HIGH] Audio-preset (FLAC) download fetches video+audio, then Merger fails — hands off to Task 6
- Symptom (`truestream-logs/app_logs.txt:3786,3873-3917`, retry `3957-4091`): user picks "Lossless Audio (FLAC)"-style audio intent (`container=flac`), but engine runs `format=bestvideo[height<=2160][ext=mp4]+bestaudio[ext=m4a]/…`, downloads f399.mp4 (AV1 video!) + f140.m4a, then `ffmpeg -c copy -map 0:v:0 -map 1:a:0 … .temp.flac` fails:
  `[flac] Invalid audio stream. Exactly one FLAC audio stream is required` → `Conversion failed!` → `FFmpegPostProcessorError`, followed by cascade `FileNotFoundError: …/yatashi - MONTAGEM AUTOMOTIVO.flac` from the Metadata PP (lines 3929-3947 — cascade, not a second bug). Flutter surfaces `Download failed … [ERROR_POSTPROCESS_FAILED]` (line 3951). Occurred 2× (identical retry).
- Root-cause chain (all current source): `lib/features/home/screens/format_picker_screen.dart:307-319` never sends `audio_only` (other paths do — `playlist_selection_screen.dart:202`, `batch_provider.dart:145`, `download_provider.dart:738`); with the audio preset `_selectedVideoFormat=null` (`format_picker_screen.dart:140-141`), so both `explicit_format_id`/`explicit_audio_format_id` are null → `opts_builder.py:256-262` skips the explicit override (null is falsy; `coerce_config` in `config.py:6-27` passes dicts as-is) → `build_format_string` (`format_selector.py:18-39`) takes the video ladder because `audio_only` defaults False (`config.py:37`) → `is_audio=False` (`opts_builder.py:130`), so no `FFmpegExtractAudio` PP (`opts_builder.py:159-167`) and `merge_output_format=flac` is applied to an AV mix (`opts_builder.py:339-344`). This is exactly Task 6's "two selections / no container" hypothesis, confirmed with the missing link: **the picker drops the audio-only signal; the engine's audio path (`format_selector.py:18-26`) is correct but unreachable from this UI.**
- Severity High: user pays full video bandwidth, gets no file.

### BUG-2 [HIGH] SoundCloud downloads never work — YouTube-shaped format string on an audio-only HLS track — hands off to Task 6
- Symptom (`truestream-logs/app_logs.txt:3527,3553-3559`; repeats `3573,3596-3602` and `3654,3677-3683`): `format=bestvideo[height<=2160][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=2160]+bestaudio/best[height<=2160]` against SoundCloud track 159813448 ("Vessel - Red Sex") → `ExtractorError: [soundcloud] 159813448: Requested format is not available` via `process_ie_result` → `process_video_result` (yt-dlp `YoutubeDL.py:3096`). Occurred 3× (two retries of one download id + one fresh id).
- Log proves the extractor side is fine: `Downloading hls_aac / hls_mp3 format info JSON`, `Found 3 formats` (engine `Fetching formats` → `Found 3 formats`), search works (`Search succeeded with 20 results`). SoundCloud offers only audio HLS (`hls_aac`, `hls_mp3`; `hls_abr` skipped as broken by yt-dlp itself) — no `bestvideo` exists, so the YouTube-default ladder can never resolve. Confirms Task 6's suspicion that `scsearch:`/search was added without verifying the download path.
- Sub-observation (Task 6-adjacent, lead to assign): a format-resolution failure is reported as `ERROR_POSTPROCESS_FAILED` (`engine/truestream_engine/downloader.py:448-469` — any `ydl_logger.errors` entry on a single item maps to postprocess). Misleading error taxonomy; the message text is preserved, so user impact is low.
- Severity High: entire SoundCloud source is download-dead.

### BUG-3 [LOW] `aria2cEnabled=true` is a dead toggle on this build — hands off to Task 2
- User enabled aria2c (`truestream-logs/app_logs.txt:52`), yet every boot logs `aria2c=fail` (9× in `engine_2026-09-13.txt`) and every download config shows `aria2c=no`. `bootstrap.py:803-808`: "No Android distribution channel; the native downloader handles all traffic"; `apply_aria2c_opts` (`opts_builder.py:67-70`) silently no-ops when no binary exists. Either bundle/probe it or gate the setting UI on capability. Severity Low: native downloader works (all session A/B downloads completed at up to ~16 MiB/s).

## Expected behavior misread as error (no action)

- `aria2c=fail` / `quickjs=fail` in every `Bootstrap completed` line — by design on Android (`bootstrap.py:803-808`, `815-820`); Deno downloads ok and Node is deliberately preferred on Android (`opts_builder.py:432-437`; all downloads log `js=node`, node-25.3.0 solves SABR challenges fine).
- GVS PO Token WARN, `Detected experiment to bind GVS PO Token…`, SABR-shaping DEBUGs, `Some web client https formats have been skipped… (yt-dlp#12482)` — upstream yt-dlp/YouTube behavior; downloads succeed regardless.
- Impersonation WARN (`no impersonate target`) — advisory (no curl_cffi on Android); all session A/B downloads completed.
- Subtitle `HTTP Error 429` + `Skipping embedding en subtitle` — transient YouTube timedtext rate-limit; session continued to `Download completed`.
- `[EmbedSubtitle] Subtitles can only be embedded in mp4…`, `[flac] Video stream #0 is not an attached picture. Ignoring` — ffmpeg informational lines, harmless.
- `Slow engine call: search/query took 13703ms` (`app_logs.txt:3504`; threshold 10 s, `logging_observers.dart:187-199`) — SoundCloud search latency, succeeded with 20 results. Observation only.
- YouTube search `"red sex"` → 0 entries — platform-side restriction response, correctly propagated (`Search succeeded with 0 results`); not an app bug.
- Timestamp skew (engine UTC `12:xx` vs Dart device-local `17:xx/18:xx`, IST) and kernel/disk differences across sessions — cosmetic correlation hazard when reading mixed logs; no code impact.

## Known-already-fixed-not-in-build

None. Log build `48edd3f` equals the current `origin/main` tip — there is no newer in-repo fix for any item above.

## Infeasible as specified (with closest equivalent)

- **A04e install-failure diagnosis from these logs is infeasible as specified.** A full-content scan of all 31,896 lines found **zero** install/package-manager/ABI/signature strings (no `INSTALL_FAILED`, `PackageInstaller`, `ABI`, `minSdk`, parse/signature errors — the only "install" hits are the yt-dlp impersonation doc URL). These are runtime logs from devices where the app is installed and running (native `lib/arm64/*.so` loaded, aarch64 kernels). Per the master file's pre-research, the Helio P35/MT6765 is 64-bit-capable, so no "32-bit device" conclusion is drawn — and there is no log evidence for any install hypothesis at all.
- Closest equivalent performed (static, read-only): `android/app/build.gradle.kts:38` `minSdk=24` vs A04e's Android 14 ✓; default `abiFilters` include `arm64-v8a` + `armeabi-v7a` (`:48-52`) ✓ — nothing in build config rules out the A04e on its face.
- Handoff to Task 2 (owns `build.gradle.kts`) + **user-action carryover**: on the A04e, reinstall and capture the verbatim Package Installer / Play Protect error string (and `adb install` output if available); that string — not these runtime logs — determines between corrupted APK, signature downgrade clash, Play Protect, or storage.

## Handoff summary

| Finding | Severity | Owner |
|---|---|---|
| BUG-1 audio-preset FLAC merge failure | High | Task 6 (Priya): `format_picker_screen.dart` must send `audio_only` (and engine must honor the audio pick over the ladder) |
| BUG-2 SoundCloud download path dead | High | Task 6 (Priya): audio-only/format-agnostic fallback for non-YouTube extracts |
| BUG-2b error taxonomy (`ERROR_POSTPROCESS_FAILED` for format errors) | Low | Task 6-adjacent — lead to assign (`downloader.py:448-469`) |
| BUG-3 dead aria2c toggle on Android | Low | Task 2 (Devraj): bundle or gate; owns `bootstrap.py` conditionally + build config |
| A04e install failure | Unresolved, needs device error string | Task 2 + user action (see above) |

No code was changed by this task (read-only). No test loop applicable beyond noting zero code delta.
