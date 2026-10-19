import re
from urllib.parse import urlparse

from grablytic_engine.ytdlp_network import GuardedYoutubeDL as YoutubeDL

from grablytic_engine.paths import get_paths
from grablytic_engine.config import coerce_config
from grablytic_engine.errors import classify_error
from grablytic_engine.logger import get_logger
from grablytic_engine.url_guard import is_youtube_url, redact_url


log = get_logger("grablytic_engine.playlist")

# A real PLAYLIST: a `list=` parameter, or a /playlist / /sets path.
_PLAYLIST_PATTERNS = [
    r"list=",
    r"/playlist",
    r"/sets/",
    r"playlist\?",
]

# YouTube channel / user / handle path prefixes.
_CHANNEL_PREFIXES = ("channel", "c", "u", "user")

# Hard cap on the entries reported for one playlist. The cap is
# REPORTED (`truncated` / `max_entries`) — a silently cut list looks
# like "that is the whole playlist".
_MAX_PLAYLIST_ENTRIES = 500


def _is_channel_path(path: str) -> bool:
    if path.startswith("/@") or "/@" in path:
        return True
    segments = [segment for segment in path.split("/") if segment]
    return len(segments) >= 2 and segments[0] in _CHANNEL_PREFIXES


def detect_channel(url: str) -> bool:
    """True for a channel, user, or @handle URL (never a playlist)."""
    if not isinstance(url, str) or not url:
        return False
    try:
        path = urlparse(url).path or ""
    except Exception:
        return False
    return _is_channel_path(path)


def detect_playlist(url: str) -> bool:
    """True only for a real PLAYLIST URL.

    A channel, user or @handle is NOT a playlist — see
    :func:`detect_channel`.
    """
    if not isinstance(url, str) or not url:
        return False
    if detect_channel(url):
        return False
    return any(re.search(p, url) for p in _PLAYLIST_PATTERNS)


# yt-dlp flat-extraction placeholder titles for entries that cannot be
# downloaded. get_playlist_info() surfaces these as unavailable so callers
# can exclude them from build_playlist_items() before downloading.
_UNAVAILABLE_TITLES = frozenset({"[Deleted video]", "[Private video]"})


def _playlist_index_value(raw) -> int:
    from yt_dlp.utils import PlaylistEntries

    if isinstance(raw, bool):
        raise ValueError(f"Invalid playlist index: {raw!r}")
    if isinstance(raw, int):
        index = raw
    elif isinstance(raw, str) and raw.strip().isdigit():
        index = int(raw.strip())
    else:
        raise ValueError(f"Invalid playlist index: {raw!r}")
    if index < 1:
        raise ValueError(f"Invalid playlist index (1-based): {raw!r}")
    list(PlaylistEntries.parse_playlist_items(str(index)))
    return index


def build_playlist_items(selected: list) -> str:
    """Validate and serialize selected one-based playlist indices."""
    seen = []
    for raw in selected or []:
        index = _playlist_index_value(raw)
        if index not in seen:
            seen.append(index)
    return ",".join(str(index) for index in seen)


def _validate_playlist_url(url: str) -> dict | None:
    from grablytic_engine.url_guard import is_safe_media_url

    if is_safe_media_url(url):
        return None
    return {
        "success": False,
        "error_type": "ERROR_INVALID_PARAM",
        "error_message": "URL must be a public http(s) address",
    }


def _build_playlist_options(url: str, config: dict | None) -> dict:
    from grablytic_engine.opts_builder import _configure_js_runtime, sanitize_cookiefile
    from grablytic_engine.url_guard import sanitized_proxy

    paths = get_paths()
    cfg = coerce_config(config)
    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "force_generic_extractor": False,
    }
    _configure_js_runtime(opts, paths)
    if is_youtube_url(url):
        youtube_args = opts.setdefault("extractor_args", {}).setdefault("youtube", {})
        youtube_args["player_client"] = ["default", "mweb"]
        from grablytic_engine.po_token import generate_po_token

        po_token = generate_po_token(url) or paths.get("po_token")
        if po_token:
            youtube_args["po_token"] = [po_token]
    cookiefile = sanitize_cookiefile(
        cfg.get("cookies_path") or paths.get("cookies_path")
    )
    if cookiefile:
        opts["cookiefile"] = cookiefile
    proxy = sanitized_proxy(cfg.get("proxy"))
    if proxy:
        opts["proxy"] = proxy
    return opts


def _playlist_entries(data: dict) -> tuple[list, bool]:
    entries = data.get("entries") if data.get("entries") is not None else [data]
    if entries is None:
        return [], False
    if not isinstance(entries, list):
        try:
            import itertools

            entries = list(itertools.islice(entries, _MAX_PLAYLIST_ENTRIES + 1))
        except Exception:
            entries = []
    truncated = len(entries) > _MAX_PLAYLIST_ENTRIES
    if truncated:
        entries = entries[:_MAX_PLAYLIST_ENTRIES]
    return entries, truncated


def _normalize_entry_url(entry: dict) -> str:
    raw_url = entry.get("url") or entry.get("webpage_url") or ""
    if not raw_url or raw_url.startswith("http") or raw_url.startswith("/"):
        return raw_url
    if re.match(r"^[a-zA-Z0-9_-]{11}$", raw_url):
        return f"https://www.youtube.com/watch?v={raw_url}"
    return raw_url


def _entry_thumbnail(entry: dict):
    thumbnail = entry.get("thumbnail")
    thumbnails = entry.get("thumbnails")
    if thumbnail or not isinstance(thumbnails, list) or not thumbnails:
        return thumbnail
    last_thumbnail = thumbnails[-1]
    if isinstance(last_thumbnail, dict):
        return last_thumbnail.get("url")
    return None


def _entry_available(entry: dict) -> bool:
    return (
        entry.get("title") is not None
        and entry.get("title") not in _UNAVAILABLE_TITLES
        and entry.get("availability") != "private"
    )


def _playlist_entry(entry: dict, fallback_index: int) -> dict | None:
    if not isinstance(entry, dict) or not entry:
        return None
    title = entry.get("title")
    if not title or title == "[Deleted video]":
        title = "[Deleted video]"
    return {
        "index": entry.get("playlist_index") or fallback_index,
        "title": title,
        "url": _normalize_entry_url(entry),
        "duration_seconds": entry.get("duration"),
        "thumbnail_url": _entry_thumbnail(entry),
        "uploader": entry.get("uploader"),
        "is_available": _entry_available(entry),
    }


def _playlist_data_thumbnail(data: dict):
    thumbnail = data.get("thumbnail")
    if thumbnail:
        return thumbnail
    thumbnails = data.get("thumbnails")
    if isinstance(thumbnails, list) and thumbnails:
        last_thumbnail = thumbnails[-1]
        if isinstance(last_thumbnail, dict):
            return last_thumbnail.get("url")
    return None


def _first_entry_thumbnail(entries: list[dict]):
    for entry in entries:
        thumbnail = entry.get("thumbnail_url")
        if thumbnail:
            return thumbnail
    return None


def _youtube_entry_thumbnail(entries: list[dict]):
    for entry in entries:
        entry_url = entry.get("url") or ""
        match = re.search(
            r"(?:v=|/v/|youtu\.be/|/embed/)([a-zA-Z0-9_-]{11})", entry_url
        )
        if match:
            return f"https://i.ytimg.com/vi/{match.group(1)}/hqdefault.jpg"
    return None


def _playlist_thumbnail(data: dict, entries: list[dict]) -> str | None:
    return (
        _playlist_data_thumbnail(data)
        or _first_entry_thumbnail(entries)
        or _youtube_entry_thumbnail(entries)
    )


def get_playlist_info(url: str, config: dict | None = None) -> dict:
    error = _validate_playlist_url(url)
    if error is not None:
        return error
    log.info(
        f"Fetching playlist info for {url.split('?', 1)[0] if isinstance(url, str) else '<url>'}"
    )
    opts = _build_playlist_options(url, config)
    try:
        with YoutubeDL(opts) as ydl:
            data = ydl.extract_info(url, download=False)
        if data is None:
            log.warn(f"No data returned for playlist {url}")
            return {
                "success": False,
                "error_type": "ERROR_UNAVAILABLE",
                "error_message": "Could not fetch playlist",
            }
        raw_entries, truncated = _playlist_entries(data)
        entries = []
        for entry in raw_entries:
            parsed_entry = _playlist_entry(entry, len(entries) + 1)
            if parsed_entry is not None:
                entries.append(parsed_entry)
        title = data.get("title", "Unknown Playlist")
        thumbnail = _playlist_thumbnail(data, entries)
        log.info(f"Playlist '{title}' has {len(entries)} entries")
        return {
            "success": True,
            "title": title,
            "uploader": data.get("uploader"),
            "thumbnail_url": thumbnail,
            "count": len(entries),
            "estimated_total_bytes": None,
            "entries": entries,
            "truncated": truncated,
            "max_entries": _MAX_PLAYLIST_ENTRIES,
        }
    except Exception as exc:
        log.log_exception(exc, f"Playlist fetch failed: {redact_url(url)}")
        error = classify_error(exc)
        return {
            "success": False,
            "error_type": error.error_type,
            "error_message": error.message,
        }
