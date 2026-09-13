def build_format_string(cfg: dict) -> str:
    explicit_vid = cfg.get("explicit_format_id")
    explicit_aid = cfg.get("explicit_audio_format_id")

    if explicit_vid and explicit_aid:
        return f"{explicit_vid}+{explicit_aid}/{explicit_vid}/best"
    if explicit_vid:
        return f"{explicit_vid}/best"
    if explicit_aid:
        return f"{explicit_aid}/bestaudio/best"

    # Raw yt-dlp format string override (site profiles, power users).
    # DEFAULT_CFG leaves this None so the ladder below stays the default;
    # any non-empty value wins over audio_only/ceiling but NOT over the
    # Format Picker's explicit IDs above.
    custom = cfg.get("format_code")
    if custom:
        return custom

    if cfg.get("audio_only"):
        audio_fmt = cfg.get("audio_format", "opus")
        fmt_map = {
            "opus": "bestaudio[ext=webm]/bestaudio",
            "m4a": "bestaudio[ext=m4a]/bestaudio",
            "flac": "bestaudio[ext=flac]/bestaudio[ext=webm]/bestaudio",
            "mp3": "bestaudio[ext=mp3]/bestaudio",
        }
        return fmt_map.get(audio_fmt, "bestaudio/best")

    ceiling = cfg.get("quality_ceiling", "4k")
    height_map = {"4k": 2160, "1080p": 1080, "720p": 720, "best": 99999}
    max_h = height_map.get(ceiling, 2160)

    if max_h >= 99999:
        return "bestvideo+bestaudio/best"

    return (
        f"bestvideo[height<={max_h}][ext=mp4]+bestaudio[ext=m4a]"
        f"/bestvideo[height<={max_h}]+bestaudio"
        f"/best[height<={max_h}]"
        f"/bestaudio/best"
    )
