"""Engine-wide default configuration + cross-bridge config coercion."""

import json


def coerce_config(config) -> dict:
    """Normalize an IPC-supplied config into a plain dict (never raises).

    - None → {}
    - dict → as-is (desktop JSON-RPC, unit tests)
    - str → json.loads (Android bridge: Kotlin pre-serializes Maps because
      Chaquopy delivers them as live java.util.HashMap proxies, which are
      NOT real mappings — ``{**proxy}`` dies with
      ``TypeError: 'HashMap' object is not a mapping``)
    - anything else → {} (fail closed, never crash the caller)
    """
    if config is None:
        return {}
    if isinstance(config, dict):
        return config
    if isinstance(config, str):
        try:
            parsed = json.loads(config)
            return parsed if isinstance(parsed, dict) else {}
        except Exception:
            return {}
    return {}


DEFAULT_CFG = {
    # ── Update ────────────────────────────────────────────────────────────
    "update_channel": "stable",
    # ── Format ──────────────────────────────────────────────────────────
    # None = auto ladder (AV1 → VP9 → H264 + ceiling). Any non-empty string
    # is passed to yt-dlp verbatim (site profiles, power users).
    "format_code": None,
    "audio_only": False,
    "container": "mkv",
    "audio_format": "opus",
    "quality_ceiling": "4k",
    # ── Metadata ────────────────────────────────────────────────────────
    "embedthumbnail": True,
    "thumbnail_format": "jpg",
    "addmetadata": True,
    # ── Subtitles ───────────────────────────────────────────────────────
    "writesubtitles": False,
    "writeautomaticsub": False,
    "subtitleslangs": ["en"],
    "embedsubtitles": True,
    # ── SponsorBlock ────────────────────────────────────────────────────
    "sponsorblock_cats": [],
    # ── Section cutting (FFmpeg-only, no JS runtime needed) ─────────────
    # e.g. ["*10:15-20:00", "0-60"] — same syntax as --download-sections.
    "download_sections": [],
    "force_keyframes_at_cuts": False,
    # ── Chapters ────────────────────────────────────────────────────────
    "split_chapters": False,
    # ── Network ─────────────────────────────────────────────────────────
    "rate_limit": "",
    "use_aria2": False,
    "aria2c_enabled": False,
    "aria2c_chunks": 5,
    "aria2c_max_speed": None,
    "concurrent_fragments": 4,
    "socket_timeout": 30,
    "proxy": "",
    "geo_bypass": True,
    # ── Retry ───────────────────────────────────────────────────────────
    "retries": 10,
    "fragment_retries": 10,
    "sleep_interval": "0",
    # ── Playlist ────────────────────────────────────────────────────────
    "no_playlist": False,
    "playlist_items": "",
    "playlist_rev": False,
    "playlist_rand": False,
    # ── Archive ─────────────────────────────────────────────────────────
    "use_archive": False,
    "archive_path": None,
    # Single-call redownload scopes (never persisted as preferences):
    # force_overwrite = re-fetch intact files (--force-overwrites semantics);
    # ignore_archive = bypass download_archive for this call (redownload-
    # after-delete recovery; cf. Seal #2065 trap).
    "force_overwrite": False,
    "ignore_archive": False,
    # Subfolder split: Video/<name> vs Audio/<name> under output_dir.
    "organize_by_folder": False,
    # ── Live ────────────────────────────────────────────────────────────
    "live_from_start": False,
    # ── Auth / bypass ───────────────────────────────────────────────────
    "anonymous_first": True,
    "quality_threshold_height": 720,
    # ── Extras ──────────────────────────────────────────────────────────
    "write_description": False,
    "write_info_json": False,
    "compat_options": "",
    "verbose": False,
    "output_tmpl": "%(uploader)s - %(title)s.%(ext)s",
    # ── Explicit override (Format Picker) ───────────────────────────────
    "explicit_format_id": None,
    "explicit_audio_format_id": None,
}
