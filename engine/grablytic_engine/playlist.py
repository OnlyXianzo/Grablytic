import re
from urllib.parse import urlparse

from grablytic_engine.ytdlp_network import GuardedYoutubeDL as YoutubeDL

from grablytic_engine.paths import get_paths
from grablytic_engine.config import coerce_config
from grablytic_engine.errors import classify_error, GrablyticError
from grablytic_engine.logger import get_logger


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


def detect_channel(url: str) -> bool:
    """True for a CHANNEL / user / @handle URL (never a playlist).

    A channel is a stream of every video the channel has ever posted.
    Treating it as a playlist made the engine expand a busy channel
    into thousands of items.
    """
    if not isinstance(url, str) or not url:
        return False
    try:
        parts = urlparse(url)
    except Exception:
        return False
    path = parts.path or ""
    if path.startswith("/@") or "/@" in path:
        return True
    segments = [s for s in path.split("/") if s]
    if len(segments) >= 2 and segments[0] in _CHANNEL_PREFIXES:
        return True
    return False


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
    return ",".join(str(i) for i in seen)


def _validate_playlist_url(url: str) -> dict | None:
    from grablytic_engine.url_guard import is_safe_media_url

    if not is_safe_media_url(url):
        return {
            "success": False,
            "error_type": "ERROR_INVALID_PARAM",
            "error_message": "URL must be a public http(s) address",
        }
    return None


def _build_playlist_opts(config: dict | None):
    from grablytic_engine.opts_builder import _configure_js_runtime

    paths = get_paths()
    cfg = coerce_config(config)
    opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "force_generic_extractor": False,
    }
    _configure_js_runtime(opts, paths)
    return opts, cfg, paths


def get_playlist_info(url: str, config: dict | None = None) -> dict:
    from grablytic_engine.url_guard import sanitized_proxy

    error = _validate_playlist_url(url)
    if error:
        return error

    log.info(
        f"Fetching playlist info for {url.split('?', 1)[0] if isinstance(url, str) else '<url>'}"
    )

    opts, cfg, paths = _build_playlist_opts(config)

    if "youtube.com" in url or "youtu.be" in url:
        opts.setdefault("extractor_args", {})
        opts["extractor_args"].setdefault("youtube", {})
        opts["extractor_args"]["youtube"]["player_client"] = ["default", "mweb"]

        from grablytic_engine.po_token import generate_po_token

        po_token = generate_po_token(url) or paths.get("po_token")
        if po_token:
            opts["extractor_args"]["youtube"]["po_token"] = [po_token]

    from grablytic_engine.opts_builder import sanitize_cookiefile

    cookiefile = sanitize_cookiefile(
        cfg.get("cookies_path") or paths.get("cookies_path")
    )
    if cookiefile:
        opts["cookiefile"] = cookiefile
    proxy = sanitized_proxy(cfg.get("proxy"))
    if proxy:
        opts["proxy"] = proxy

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

        entries_val = (
            data.get("entries")
            if "entries" in data and data.get("entries") is not None
            else [data]
        )
        truncated = False
        if entries_val is not None:
            if not isinstance(entries_val, list):
                try:
                    import itertools

                    # One extra element so "there were more" is detectable.
                    entries_val = list(
                        itertools.islice(entries_val, _MAX_PLAYLIST_ENTRIES + 1)
                    )
                except Exception:
                    entries_val = []
            if (
                isinstance(entries_val, list)
                and len(entries_val) > _MAX_PLAYLIST_ENTRIES
            ):
                entries_val = entries_val[:_MAX_PLAYLIST_ENTRIES]
                truncated = True
        entries_raw = entries_val or []
        entries = []
        idx = 1
        for e in entries_raw:
            if not e or not isinstance(e, dict):
                continue

            title = e.get("title")
            if not title or title == "[Deleted video]":
                title = "[Deleted video]"
            raw_url = e.get("url") or e.get("webpage_url") or ""
            if (
                raw_url
                and not raw_url.startswith("http")
                and not raw_url.startswith("/")
            ):
                # Plain YouTube 11-char video ID from flat extraction
                if re.match(r"^[a-zA-Z0-9_-]{11}$", raw_url):
                    raw_url = f"https://www.youtube.com/watch?v={raw_url}"

            thumb = e.get("thumbnail")
            if not thumb and e.get("thumbnails"):
                thumbs = e.get("thumbnails")
                if (
                    isinstance(thumbs, list)
                    and len(thumbs) > 0
                    and isinstance(thumbs[-1], dict)
                ):
                    thumb = thumbs[-1].get("url")

            item_index = e.get("playlist_index") or idx

            entries.append(
                {
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
                }
            )
            idx += 1

        playlist_title = data.get("title", "Unknown Playlist")
        playlist_thumb = data.get("thumbnail")
        if not playlist_thumb and data.get("thumbnails"):
            thumbs = data.get("thumbnails")
            if (
                isinstance(thumbs, list)
                and len(thumbs) > 0
                and isinstance(thumbs[-1], dict)
            ):
                playlist_thumb = thumbs[-1].get("url")
        if not playlist_thumb:
            for e in entries:
                if e.get("thumbnail_url"):
                    playlist_thumb = e["thumbnail_url"]
                    break
        if not playlist_thumb:
            for e in entries:
                u = e.get("url") or ""
                m = re.search(r"(?:v=|/v/|youtu\.be/|/embed/)([a-zA-Z0-9_-]{11})", u)
                if m:
                    playlist_thumb = (
                        f"https://i.ytimg.com/vi/{m.group(1)}/hqdefault.jpg"
                    )
                    break

        log.info(f"Playlist '{playlist_title}' has {len(entries)} entries")
        return {
            "success": True,
            "title": playlist_title,
            "uploader": data.get("uploader"),
            "thumbnail_url": playlist_thumb,
            "count": len(entries),
            "estimated_total_bytes": None,
            "entries": entries,
            # A truncated list must say so: a silent cut looks like
            # "that is the whole playlist".
            "truncated": truncated,
            "max_entries": _MAX_PLAYLIST_ENTRIES,
        }

    except Exception as exc:
        log.log_exception(exc, f"Playlist fetch failed: {url}")
        err = classify_error(exc)
        return {
            "success": False,
            "error_type": err.error_type,
            "error_message": err.message,
        }
