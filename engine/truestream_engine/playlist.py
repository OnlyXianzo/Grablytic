import re
from yt_dlp import YoutubeDL

from truestream_engine.paths import get_paths
from truestream_engine.errors import classify_error, TrueStreamError
from truestream_engine.logger import get_logger


log = get_logger("truestream_engine.playlist")

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


def get_playlist_info(url: str, config: dict | None = None) -> dict:
    log.info(f"Fetching playlist info for {url}")

    paths = get_paths()
    cfg = config or {}

    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "force_generic_extractor": False,
    }

    cookies = cfg.get("cookies_path") or paths.get("cookies_path")
    if cookies:
        opts["cookiefile"] = cookies
    if cfg.get("proxy"):
        opts["proxy"] = cfg["proxy"]

    try:
        with YoutubeDL(opts) as ydl:
            data = ydl.extract_info(url, download=False)

        if data is None:
            log.warn(f"No data returned for playlist {url}")
            return {"success": False, "error_type": "ERROR_UNAVAILABLE", "error_message": "Could not fetch playlist"}

        entries_raw = data.get("entries", []) if "entries" in data else [data]
        entries = []
        for i, e in enumerate(entries_raw, 1):
            title = e.get("title")
            if not title or title == "[Deleted video]":
                title = "[Deleted video]"

            entries.append({
                "index": i,
                "title": title,
                "url": e.get("url") or e.get("webpage_url") or "",
                "duration_seconds": e.get("duration"),
                "thumbnail_url": e.get("thumbnail"),
                "uploader": e.get("uploader"),
                "is_available": e.get("title") is not None and e.get("availability") != "private",
            })

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
