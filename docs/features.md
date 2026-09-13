# Features

> Last updated: **2026-09-13** — complete capability catalog. Settings paths refer to
> **Settings** tabs in the app unless noted.

## 📥 Downloading

| Capability | Details | Settings |
|---|---|---|
| Max-quality ladder | AV1 → VP9 → H264 cascade, quality ceiling up to 4K, explicit format-ID override from Format Picker | Quality ceiling, Format Picker |
| Muxed streams | Non-YouTube platforms expose pre-merged streams alongside DASH | Format Picker (muxed badge) |
| Batch URLs | Multi-URL paste, clipboard/file import, per-item status | Home → Batch |
| Playlists | Selection screen: multi-select, reverse/shuffle, unavailable marking; ranges (`1-10`), single-item (`no_playlist`) | Playlist Selection |
| Queue | FIFO engine queue, default 2 concurrent (1–5), queued status, enforced at every entry point | Simultaneous downloads |
| Per-item controls | Overflow menu: redownload, audio re-fetch, delete (file + history), per-download logs | Home / Library item |
| Section cutting | FFmpeg-only `download_sections` (`*10:15-20:00`), `force_keyframes_at_cuts`; bad specs warn-and-skip | Advanced |
| Resume & DB recovery | SQLite schema v3 execution snapshots (`configJson`, byte counters, queue position), 5s heartbeat, automatic startup recovery sweep in `DownloadNotifier`, safe `BootReceiver` (reboot recovery without illegal background FGS start) + fallback `.part` scan | Automatic |
| Archive | `download_archive` skips repeats; optional per-folder archives | Download Archive |
| Scheduling | Time window + weekdays queue gating | Schedule |
| Observed sources & WorkManager | Android WorkManager `ObservedSourcesPollWorker` (`observed-sources-poll`, zero exact alarms), two-tier poll (Atom RSS tier 1, Chaquopy fallback tier 2), SQLite schema v4 `seen_source_videos` deduplication, auto-queueing to `downloads` table | Observed Sources & Settings → Schedule |
| Speed sparkline & ETA | Dual-stage EMA speed ($\alpha=0.3$) and ETA ($\alpha=0.15$) smoothing, 60-sample historical ring buffer, zero-dependency `DownloadSparkline` canvas painter | Active download cards |
| Live | `live_from_start` for livestreams | Advanced |
| Rate & retries | Rate limit, retries (10), fragment retries (10), sleep interval, concurrent fragments (4), socket timeout (30) | Network |
| Proxy & geo | HTTP/SOCKS proxy, `geo_bypass`, VPN hints on classified errors | Network / Privacy |
| aria2c | Parallel fragments `-x1..16` (default 5), `--max-download-limit` (validated), 1 MB splits; progressive only — DASH/HLS stay native | aria2c toggle |
| Keep-alive (Android) | `dataSync` foreground service with progress notification | Automatic |

## 🎨 Media & metadata

| Capability | Details | Settings |
|---|---|---|
| Merge/remux | `merge_output_format` (never combined with `remux_video`); container default `mkv` | Container |
| Audio extract | `FFmpegExtractAudio` (default `opus`, also FLAC/compact presets) | Audio only |
| Thumbnails | `writethumbnail` + `FFmpegThumbnailsConvertor` + `EmbedThumbnail` | Embed thumbnail |
| Metadata/chapters | `FFmpegMetadata` (tags + chapters), `FFmpegSplitChapters` | Add metadata / Split chapters |
| Subtitles | Download + auto-subs, language list (default `en`), **real** `FFmpegEmbedSubtitle` embedding | Subtitles |
| SponsorBlock | Mark + cut (`ModifyChapters` after embed, before metadata); categories incl. sponsor/intro/outro | SponsorBlock |
| Templates | `%(uploader)s - %(title)s` default + custom output templates | Templates |
| Site profiles | YouTube 1080p / 4K, Podcast Audio, Lossless FLAC, Opus Compact, Twitter/X | Profile Editor |
| Presets | 7 built-in + unlimited custom (format + container + template) | Presets |
| Preview | Thumbnail + duration + stream counts header in Format Picker | Format Picker |

## 🔓 Access & bypass

| Capability | Details | Settings |
|---|---|---|
| Cookie auth | In-app WebView → Netscape cookie export | Cookie WebView / cookies path |
| Session flags | Per-site login state (YouTube, Instagram, Twitter, Bilibili, Twitch) | Accounts |
| PO Tokens | `po_token` generation (QuickJS/Deno), injected into `extractor_args.youtube` | Automatic |
| JS runtimes | Deno (bundled/bootstrapped) → Node → QuickJS; `ejs:github` solvers; `yt-dlp-ejs` dependency | Diagnostics shows `js_runtime` |
| Extractor strategy | `player_client = ["default", "mweb"]` multi-client (never forced single) | Automatic |
| Anonymous first | `anonymous_first` tries no-auth before cookies | Privacy |

## 🧰 Reliability & diagnostics

| Capability | Details | Where |
|---|---|---|
| Classified errors | Typed codes + `recoverable` + `suggests_vpn`; Error Recovery cards | Home (on failure) |
| Cancel | Threading event → `cancelled` event (desktop maps `ERROR_CANCELLED`) | Download card |
| Share intent | `ACTION_SEND` text/plain → choice bottom sheet (engine-ready gated) → Format Picker; auto-start opt-in skips the sheet | System share sheet |
| Per-download logs | Own log view per download (live + post-completion), bounded retention | Queue card / History / overflow menu |
| Bootstrap status | ffmpeg/aria2c/deno/quickjs health + versions + `needs_update` | Home status card |
| Update channels | stable / nightly / master; `update_check` diffs SHA-256 | Settings → Updates |
| Persistent logs | `app_logs.txt` (Dart, 30 s flush) + `server_logs.log` (Python rotation) | Export |
| Live viewer | Color-coded, level/tag/search/source filters, expand, auto-scroll | Diagnostics & Logs |
| GitHub auto-report | Search-dedup filing from both layers | Automatic |
| Observers | Navigation + Riverpod + engine tracing | Automatic |

## ♿ Accessibility & theming

- WCAG 2.2 AA: semantics, 48×48 targets, screen-reader labels (see `docs/testing/ACCESSIBILITY_AUDIT.md`).
- Material 3 light/dark (`TrueStreamColors`), Instrument Sans + Iosevka Charon Mono.
- 120 fps Impeller renderer; frame-rate audit in `test/performance/`.
