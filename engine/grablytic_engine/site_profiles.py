import json
import os
from urllib.request import urlopen, Request
from urllib.error import URLError

from grablytic_engine.paths import get_paths


_DEFAULT_PROFILES = {
    "YouTube 1080p": {
        "format_code": "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080]",
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


def load_site_profiles() -> dict:
    global _SITE_PROFILES_CACHE

    if _SITE_PROFILES_CACHE is not None:
        return _SITE_PROFILES_CACHE

    _SITE_PROFILES_CACHE = dict(_DEFAULT_PROFILES)
    return _SITE_PROFILES_CACHE


def load_site_profiles_from_url(url: str) -> dict:
    global _SITE_PROFILES_CACHE
    try:
        from grablytic_engine.url_guard import is_safe_profile_url
        if not is_safe_profile_url(url):
            return load_site_profiles()
        req = Request(url, headers={"User-Agent": "Grablytic/1.0"})
        with urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            _SITE_PROFILES_CACHE = data
            return data
    except (URLError, json.JSONDecodeError, OSError):
        return load_site_profiles()


def load_profiles_from_disk(path: str) -> dict:
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def save_profiles_to_disk(profiles: dict, path: str):
    with open(path, "w") as f:
        json.dump(profiles, f, indent=2)
