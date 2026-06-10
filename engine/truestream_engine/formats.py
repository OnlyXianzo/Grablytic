from yt_dlp import YoutubeDL

from truestream_engine.paths import get_paths
from truestream_engine.format_selector import build_format_string
from truestream_engine.errors import classify_error, TrueStreamError


def get_formats(url: str, config: dict | None = None) -> dict:
    paths = get_paths()
    cfg = config or {}

    opts = {
        "quiet": True,
        "no_warnings": True,
    }

    cookies = cfg.get("cookies_path") or paths.get("cookies_path")
    if cookies:
        opts["cookiefile"] = cookies
    if cfg.get("proxy"):
        opts["proxy"] = cfg["proxy"]

    try:
        with YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)

        if info is None:
            return {"success": False, "error_type": "ERROR_UNAVAILABLE", "error_message": "Could not extract info"}

        is_playlist = info.get("_type") == "playlist" or "entries" in info
        formats_raw = info.get("formats", [])
        if is_playlist and not formats_raw:
            first = info.get("entries", [None])[0]
            if first:
                formats_raw = first.get("formats", [])

        parsed = []
        for f in formats_raw:
            vcodec = f.get("vcodec") or "none"
            acodec = f.get("acodec") or "none"
            has_video = vcodec != "none"
            has_audio = acodec != "none"

            if not has_video and not has_audio:
                continue

            # Determine stream type: muxed (both), video-only, or audio-only
            if has_video and has_audio:
                stream_type = "muxed"
            elif has_video:
                stream_type = "video"
            else:
                stream_type = "audio"

            # Use filesize or filesize_approx
            size = f.get("filesize") or f.get("filesize_approx")

            parsed.append({
                "format_id": f.get("format_id", ""),
                "ext": f.get("ext", ""),
                "vcodec": vcodec,
                "acodec": acodec,
                "height": f.get("height"),
                "width": f.get("width"),
                "fps": f.get("fps"),
                "tbr": f.get("tbr"),
                "abr": f.get("abr"),
                "vbr": f.get("vbr"),
                "filesize": size,
                "filesize_is_estimate": f.get("filesize") is None,
                "is_hdr": "hdr" in str(f.get("dynamic_range", "")).lower(),
                "dynamic_range": f.get("dynamic_range", "SDR"),
                "stream_type": stream_type,
                "format_note": f.get("format_note", ""),
                "protocol": f.get("protocol", ""),
                "url": f.get("webpage_url") or f.get("url", ""),
            })

        # Find recommended formats
        best_video = None
        best_audio = None
        best_muxed = None
        for f in parsed:
            if f["stream_type"] == "video":
                if best_video is None or (f.get("height") or 0) > (best_video.get("height") or 0):
                    best_video = f
            elif f["stream_type"] == "audio":
                if best_audio is None or (f.get("abr") or 0) > (best_audio.get("abr") or 0):
                    best_audio = f
            elif f["stream_type"] == "muxed":
                if best_muxed is None or (f.get("height") or 0) > (best_muxed.get("height") or 0):
                    best_muxed = f

        return {
            "success": True,
            "title": info.get("title", ""),
            "duration_seconds": info.get("duration"),
            "thumbnail_url": info.get("thumbnail"),
            "is_live": info.get("is_live", False),
            "is_playlist": is_playlist,
            "extractor": info.get("extractor_key") or info.get("extractor", ""),
            "webpage_url": info.get("webpage_url", url),
            "formats": parsed,
            "recommended_video_format_id": best_video["format_id"] if best_video else None,
            "recommended_audio_format_id": best_audio["format_id"] if best_audio else None,
            "recommended_muxed_format_id": best_muxed["format_id"] if best_muxed else None,
        }

    except Exception as exc:
        err = classify_error(exc)
        return {
            "success": False,
            "error_type": err.error_type,
            "error_message": err.message,
        }
