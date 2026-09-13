import re
from yt_dlp import YoutubeDL

from truestream_engine.paths import get_paths
from truestream_engine.config import coerce_config
from truestream_engine.errors import classify_error
from truestream_engine.logger import get_logger


log = get_logger("truestream_engine.search")


def _build_search_url(query: str, site: str, limit: int) -> str:
    site_lower = site.lower().strip() if site else "youtube"
    if site_lower == "soundcloud":
        prefix = f"scsearch{limit}:"
    else:
        prefix = f"ytsearch{limit}:"
    return f"{prefix}{query.strip()}"


def search(
    query: str,
    site: str = "youtube",
    limit: int = 20,
    config: dict | None = None,
) -> dict:
    """Execute a flat search query using yt-dlp search extractors."""
    query_clean = (query or "").strip()
    if not query_clean:
        return {
            "success": False,
            "error_type": "ERROR_INVALID_PARAM",
            "error_message": "Search query cannot be empty",
        }

    try:
        limit_val = max(1, min(int(limit), 100))
    except (ValueError, TypeError):
        limit_val = 20

    search_url = _build_search_url(query_clean, site, limit_val)
    log.info(f"Searching on {site} for '{query_clean}' (limit={limit_val})")

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
        from truestream_engine.opts_builder import _apply_js_runtime
        _apply_js_runtime(opts, paths)
    except Exception:
        pass

    try:
        with YoutubeDL(opts) as ydl:
            data = ydl.extract_info(search_url, download=False)

        if data is None:
            log.warn(f"No search data returned for {search_url}")
            return {
                "success": True,
                "query": query_clean,
                "site": site,
                "count": 0,
                "entries": [],
            }

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

            uploader = e.get("uploader") or e.get("channel") or e.get("uploader_id")

            entries.append({
                "index": idx,
                "title": title,
                "url": raw_url,
                "duration_seconds": e.get("duration"),
                "thumbnail_url": thumb,
                "uploader": uploader,
                "is_available": e.get("title") is not None and e.get("availability") != "private",
            })
            idx += 1

        log.info(f"Search for '{query_clean}' returned {len(entries)} entries")
        return {
            "success": True,
            "query": query_clean,
            "site": site,
            "count": len(entries),
            "entries": entries,
        }

    except Exception as exc:
        log.log_exception(exc, f"Search failed: {search_url}")
        err = classify_error(exc)
        return {
            "success": False,
            "error_type": err.error_type,
            "error_message": err.message,
        }


search_query = search
