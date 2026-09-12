import re
from yt_dlp import YoutubeDL

from truestream_engine.paths import get_paths
from truestream_engine.config import coerce_config
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
    if cfg.get("proxy"):
        opts["proxy"] = cfg["proxy"]

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

            entries.append({
                "index": idx,
                "title": title,
                "url": raw_url,
                "duration_seconds": e.get("duration"),
                "thumbnail_url": e.get("thumbnail"),
                "uploader": e.get("uploader"),
                "is_available": e.get("title") is not None and e.get("availability") != "private",
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
