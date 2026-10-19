import json
import os
import tempfile
import threading
from urllib.request import Request
from urllib.error import URLError

from grablytic_engine.paths import get_paths
from grablytic_engine.url_guard import pinned_urlopen as urlopen

_MAX_PROFILE_BYTES = 256 * 1024


_DEFAULT_PROFILES = {
    "YouTube 1080p": {
        # Portrait-safe (Shorts are 1080x1920): aspect-gated dual-axis
        # ladder + /best tail so vertical video never falls to audio-only.
        "format_code": "bestvideo*[height<=1080][aspect_ratio>=1][ext=mp4]+bestaudio[ext=m4a]/bestvideo*[height<=1080][aspect_ratio>=1]+bestaudio[ext=m4a]/bestvideo*[width<=1080][aspect_ratio<1]+bestaudio[ext=m4a]/best[height<=1080]/best[width<=1080]/best",
        "container": "mp4",
        "audio_only": False,
        "embedthumbnail": True,
        "addmetadata": True,
    },
    "YouTube 4K": {
        "format_code": "bestvideo[height<=2160][ext=mp4]+bestaudio[ext=m4a]/best",
        "container": "mkv",
        "audio_only": False,
        "embedthumbnail": True,
        "addmetadata": True,
    },
    "Podcast Audio": {
        "format_code": "bestaudio[ext=m4a]/bestaudio",
        "container": "m4a",
        "audio_only": True,
        "audio_format": "m4a",
        "embedthumbnail": True,
        "addmetadata": True,
    },
    "Lossless FLAC": {
        "format_code": "bestaudio",
        "container": "flac",
        "audio_only": True,
        "audio_format": "flac",
        "embedthumbnail": False,
        "addmetadata": True,
    },
    "Opus Compact": {
        "format_code": "251",
        "container": "opus",
        "audio_only": True,
        "audio_format": "opus",
        "embedthumbnail": False,
        "addmetadata": True,
    },
    "Twitter/X Video": {
        "format_code": "best",
        "container": "mp4",
        "audio_only": False,
        "embedthumbnail": False,
        "addmetadata": False,
    },
}


_SITE_PROFILES_CACHE: dict | None = None
_CACHE_LOCK = threading.Lock()


def sanitize_profiles(profiles) -> dict:
    """Filter a site-profile payload down to the SAFE entries.

    Remote profiles are UNTRUSTED INPUT: they are fetched from a URL the
    user points at, and their `format_code` / `container` reach yt-dlp
    verbatim.

    This is a FILTER, not a schema projection: unknown keys survive (a
    profile may carry extractor-specific hints), but an entry with an
    unsafe `format_code` or `container` is dropped WHOLE. The entry is
    never partially trusted — a half-trusted profile is worse than none.
    """
    if not isinstance(profiles, dict):
        return {}
    from grablytic_engine.config import is_safe_container
    from grablytic_engine.format_selector import is_safe_format_expression

    safe: dict = {}
    for name, profile in profiles.items():
        if not isinstance(name, str) or not isinstance(profile, dict):
            continue
        fmt = profile.get("format_code")
        if fmt is not None and not is_safe_format_expression(fmt):
            continue
        container = profile.get("container")
        if container is not None and not is_safe_container(container):
            continue
        safe[name] = dict(profile)
    return safe


def load_site_profiles() -> dict:
    global _SITE_PROFILES_CACHE

    with _CACHE_LOCK:
        if _SITE_PROFILES_CACHE is not None:
            return _SITE_PROFILES_CACHE
        _SITE_PROFILES_CACHE = dict(_DEFAULT_PROFILES)
        return _SITE_PROFILES_CACHE


def load_site_profiles_from_url(url: str) -> dict:
    """Fetch remote profiles, sanitized. A failed payload NEVER lands in
    the cache — otherwise the broken payload would be served forever."""
    global _SITE_PROFILES_CACHE
    try:
        req = Request(url, headers={"User-Agent": "Grablytic/1.0"})
        with urlopen(req, timeout=5) as resp:
            payload = resp.read(_MAX_PROFILE_BYTES + 1)
        if len(payload) > _MAX_PROFILE_BYTES:
            raise ValueError("remote profile response exceeds size limit")
        data = json.loads(payload.decode("utf-8"))
        safe = sanitize_profiles(data)
        if not safe:
            # Empty or fully-rejected payload: keep the previous cache.
            try:
                from grablytic_engine.logger import get_logger
                get_logger("grablytic_engine.site_profiles").warn(
                    "Remote site profiles were empty or unsafe; keeping the "
                    "previous profiles"
                )
            except Exception:
                pass
            return load_site_profiles()
        with _CACHE_LOCK:
            _SITE_PROFILES_CACHE = safe
        return safe
    except (URLError, json.JSONDecodeError, OSError, ValueError):
        return load_site_profiles()


def site_profiles_status() -> dict:
    """Diagnostic status of the profile cache. Never raises."""
    try:
        with _CACHE_LOCK:
            cached = _SITE_PROFILES_CACHE is not None
            count = len(_SITE_PROFILES_CACHE or {})
        return {
            "loaded": cached,
            "count": count,
            "source": "remote" if cached else "builtin",
        }
    except Exception:
        return {"loaded": False, "count": 0, "source": "builtin"}


def reset_site_profiles_cache() -> None:
    """Drop the cached remote profiles (the next load re-reads them)."""
    global _SITE_PROFILES_CACHE
    with _CACHE_LOCK:
        _SITE_PROFILES_CACHE = None


def load_profiles_from_disk(path: str) -> dict:
    """Read profiles from disk. A corrupt file yields {} — never raises."""
    try:
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError, json.JSONDecodeError):
        return {}
    return {}


def save_profiles_to_disk(profiles: dict, path: str) -> bool:
    """Write profiles ATOMICALLY (temp file + os.replace).

    A crash mid-write used to leave a truncated JSON file behind, and the
    next read raised JSONDecodeError — losing every profile at once.
    Returns True on success.
    """
    tmp_path = None
    try:
        directory = os.path.dirname(os.path.abspath(path)) or "."
        os.makedirs(directory, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".profiles-",
                                        suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(profiles, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
        return True
    except Exception:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        return False
