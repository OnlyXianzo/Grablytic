import re
from yt_dlp import YoutubeDL

from grablytic_engine.paths import get_paths
from grablytic_engine.config import coerce_config
from grablytic_engine.errors import classify_error, GrablyticError
from grablytic_engine.logger import get_logger


log = get_logger("grablytic_engine.playlist")

_PLAYLIST_PATTERNS = [
    r"list=",
    r"/playlist",
    r"/sets/",
    r"playlist\?",
    r"channel/",
    r"/c/",
    r"/@",
    r"user/",
]


def detect_playlist(url: str) -> bool:
    return any(re.search(p, url) for p in _PLAYLIST_PATTERNS)


# yt-dlp flat-extraction placeholder titles for entries that cannot be
# downloaded. get_playlist_info() surfaces these as unavailable so callers
# can exclude them from build_playlist_items() before downloading.
_UNAVAILABLE_TITLES = frozenset({"[Deleted video]", "[Private video]"})


def build_playlist_items(selected: list) -> str:
    """Translate user-selected playlist entry indices into a yt-dlp
    ``playlist_items`` string.

    ``selected`` holds the 1-based ``index`` values reported by
    :func:`get_playlist_info` (yt-dlp's ``playlist_items`` syntax is
    1-indexed — ``PlaylistEntries[1:10] => (0, 1, ... 9)`` per installed
    yt-dlp ``utils/_utils.py`` — so NO 0→1 adjustment happens here; the
    values pass straight through after validation).

    Each value is validated with yt-dlp's own ``parse_playlist_items``
    parser, so a malformed index raises ``ValueError`` instead of silently
    downloading the wrong entries. Duplicates are dropped, order is kept.
    Empty input returns ``""`` (caller should skip the download).
    """
    from yt_dlp.utils import PlaylistEntries

    seen: list[int] = []
    for raw in selected or []:
        # Strict: only ints and digit-strings. int(2.5) would silently
        # truncate to 2 and download the WRONG entry — reject instead.
        if isinstance(raw, bool):
            raise ValueError(f"Invalid playlist index: {raw!r}")
        if isinstance(raw, int):
            idx = raw
        elif isinstance(raw, str) and raw.strip().isdigit():
            idx = int(raw.strip())
        else:
            raise ValueError(f"Invalid playlist index: {raw!r}")
        if idx < 1:
            raise ValueError(f"Invalid playlist index (1-based): {raw!r}")
        # Validate against yt-dlp's own grammar — single source of truth
        # for what the downloader will accept.
        list(PlaylistEntries.parse_playlist_items(str(idx)))
        if idx not in seen:
            seen.append(idx)
    return ",".join(str(i) for i in seen)


def get_playlist_info(url: str, config: dict | None = None) -> dict:
    from grablytic_engine.url_guard import is_safe_media_url, sanitized_proxy
    if not is_safe_media_url(url):
        return {
            "success": False,
            "error_type": "ERROR_INVALID_PARAM",
            "error_message": "URL must be a public http(s) address",
        }
    log.info(f"Fetching playlist info for {url.split('?', 1)[0] if isinstance(url, str) else '<url>'}")

    paths = get_paths()
    cfg = coerce_config(config)

    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "force_generic_extractor": False,
    }

    cookies = cfg.get("cookies_path") or paths.get("cookies_path")
    if cookies:
        opts["cookiefile"] = cookies
    proxy = sanitized_proxy(cfg.get("proxy"))
    if proxy:
        opts["proxy"] = proxy

    try:
        with YoutubeDL(opts) as ydl:
            data = ydl.extract_info(url, download=False)

        if data is None:
            log.warn(f"No data returned for playlist {url}")
            return {"success": False, "error_type": "ERROR_UNAVAILABLE", "error_message": "Could not fetch playlist"}

        entries_raw = data.get("entries") if "entries" in data and data.get("entries") is not None else [data]
        entries = []
        idx = 1
        for e in entries_raw:
            if not e or not isinstance(e, dict):
                continue

            title = e.get("title")
            if not title or title == "[Deleted video]":
                title = "[Deleted video]"
            raw_url = e.get("url") or e.get("webpage_url") or ""
            if raw_url and not raw_url.startswith("http") and not raw_url.startswith("/"):
                # Plain YouTube 11-char video ID from flat extraction
                if re.match(r"^[a-zA-Z0-9_-]{11}$", raw_url):
                    raw_url = f"https://www.youtube.com/watch?v={raw_url}"

            thumb = e.get("thumbnail")
            if not thumb and e.get("thumbnails"):
                thumbs = e.get("thumbnails")
                if isinstance(thumbs, list) and len(thumbs) > 0 and isinstance(thumbs[-1], dict):
                    thumb = thumbs[-1].get("url")

            item_index = e.get("playlist_index") or idx

            entries.append({
                "index": item_index,
                "title": title,
                "url": raw_url,
                "duration_seconds": e.get("duration"),
                "thumbnail_url": thumb,
                "uploader": e.get("uploader"),
                # Flat extraction reports removed entries as title=None or a
                # "[Deleted video]"/"[Private video]" placeholder with no
                # playable URL — all three mean "cannot be downloaded".
                "is_available": (
                    e.get("title") is not None
                    and e.get("title") not in _UNAVAILABLE_TITLES
                    and e.get("availability") != "private"
                ),
            })
            idx += 1

        playlist_title = data.get("title", "Unknown Playlist")
        log.info(f"Playlist '{playlist_title}' has {len(entries)} entries")
        return {
            "success": True,
            "title": playlist_title,
            "uploader": data.get("uploader"),
            "count": len(entries),
            "estimated_total_bytes": None,
            "entries": entries,
        }

    except Exception as exc:
        log.log_exception(exc, f"Playlist fetch failed: {url}")
        err = classify_error(exc)
        return {
            "success": False,
            "error_type": err.error_type,
            "error_message": err.message,
        }
