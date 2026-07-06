from truestream_engine.config import DEFAULT_CFG
from truestream_engine.paths import get_paths
from truestream_engine.format_selector import build_format_string
from truestream_engine.hooks import build_progress_hook, build_postprocessor_hook


def apply_aria2c_opts(opts: dict, config: dict) -> dict:
    import os
    from truestream_engine.paths import get_paths
    aria_path = get_paths().get("aria2c_path")
    if config.get("aria2c_enabled") and aria_path and os.path.isfile(aria_path):
        chunks = config.get("aria2c_chunks", 5)
        args = [f"-x{chunks}", "-k1M", "--min-split-size=1M"]
        max_speed = config.get("aria2c_max_speed")
        if max_speed:
            args.append(f"--max-download-limit={max_speed}")
        # CVE-2026-50574: Avoid using aria2c for DASH/HLS fragmented manifests
        opts["external_downloader"] = {
            "default": "aria2c",
            "dash": "native",
            "hls": "native",
        }
        opts["external_downloader_args"] = args
    return opts


def build_ydl_opts(
    config: dict | None = None,
    network_type: str = "wifi",
    progress_queue=None,
    override_format: str | None = None,
    override_audio: bool | None = None,
    override_container: str | None = None,
    download_id: str | None = None,
    url: str | None = None,
) -> dict:
    cfg = {**DEFAULT_CFG, **(config or {})}
    paths = get_paths()

    fmt = override_format or build_format_string(cfg)
    is_audio = override_audio if override_audio is not None else cfg["audio_only"]
    container = override_container or cfg["container"]

    opts: dict = {
        "format": fmt,
        "paths": {"home": paths["output_dir"] or "."},
        "outtmpl": {"default": cfg["output_tmpl"]},
        "ignoreerrors": True,
        "no_mtime": True,
        "retries": int(cfg["retries"]),
        "fragment_retries": int(cfg["fragment_retries"]),
    }

    opts = apply_aria2c_opts(opts, cfg)

    if is_audio:
        opts["postprocessors"] = [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": cfg.get("audio_format", container),
                "preferredquality": "0",
            }
        ]
        opts["keepvideo"] = False

    if paths.get("ffmpeg_path"):
        opts["ffmpeg_location"] = paths["ffmpeg_path"]

    cookies = paths.get("cookies_path")
    if cookies:
        opts["cookiefile"] = cookies

    if cfg.get("rate_limit"):
        opts["ratelimit"] = cfg["rate_limit"]

    if cfg.get("proxy"):
        opts["proxy"] = cfg["proxy"]

    if cfg.get("geo_bypass"):
        opts["geo_bypass"] = True

    if cfg.get("use_archive") and cfg.get("archive_path"):
        opts["download_archive"] = cfg["archive_path"]

    sleep = cfg.get("sleep_interval", "0")
    if sleep != "0":
        opts["sleep_interval"] = int(sleep)

    if cfg.get("no_playlist"):
        opts["playlist_items"] = "1"

    if cfg.get("playlist_items"):
        opts["playlist_items"] = cfg["playlist_items"]
    if cfg.get("playlist_rev"):
        opts["playlist_reverse"] = True
    if cfg.get("playlist_rand"):
        opts["playlist_random"] = True

    if cfg.get("live_from_start"):
        opts["live_from_start"] = True

    sponsor_cats = cfg.get("sponsorblock_cats", [])
    if sponsor_cats:
        opts["postprocessors"] = opts.get("postprocessors", []) + [
            {
                "key": "SponsorBlock",
                "categories": sponsor_cats,
                "when": "after_filter",
            }
        ]

    # YouTube extractor args — never force player_client. yt-dlp's default
    # multi-client strategy (android → web → tv) returns more formats than
    # forcing a single client. The android VR API returns 31+ formats with
    # AV1/VP9 without requiring JS execution or PO Token. web client alone
    # returns only 5 formats without a PO Token.
    # Only add po_token when one is available.
    if url and ("youtube.com" in url or "youtu.be" in url):
        opts.setdefault("extractor_args", {})
        opts["extractor_args"].setdefault("youtube", {})
        opts["extractor_args"]["youtube"]["player_client"] = ["default", "mweb"]

        from truestream_engine.po_token import generate_po_token
        po_token = generate_po_token(url) or paths.get("po_token")
        if po_token:
            opts["extractor_args"]["youtube"]["po_token"] = [po_token]
    elif paths.get("po_token"):
        opts.setdefault("extractor_args", {})
        opts["extractor_args"].setdefault("youtube", {})
        opts["extractor_args"]["youtube"]["po_token"] = [paths["po_token"]]

    if cfg.get("explicit_format_id"):
        vid = cfg["explicit_format_id"]
        aid = cfg.get("explicit_audio_format_id")
        if aid:
            opts["format"] = f"{vid}+{aid}"
        else:
            opts["format"] = vid

    # Post-processing — only one of merge/remux, never both
    if paths.get("ffmpeg_path"):
        pp: list[dict] = opts.get("postprocessors", [])

        if cfg.get("embedthumbnail"):
            pp.append({"key": "FFmpegThumbnailsConvertor", "format": "jpg"})
            pp.append({"key": "EmbedThumbnail"})

        meta_pp: list[str] = []
        if cfg.get("addmetadata"):
            meta_pp.append("add_metadata")
        if cfg.get("embedthumbnail"):
            meta_pp.append("embed_thumbnail")

        if meta_pp:
            if is_audio:
                pass  # metadata handled by FFmpegExtractAudio
            else:
                pp.append({
                    "key": "FFmpegMetadata",
                    "add_metadata": cfg.get("addmetadata", True),
                    "add_chapters": True,
                })

        subs_enabled = cfg.get("writesubtitles", False) or cfg.get("writeautomaticsub", False)
        if subs_enabled and cfg.get("embedsubtitles"):
            opts["writesubtitles"] = cfg.get("writesubtitles", False)
            opts["writeautomaticsub"] = cfg.get("writeautomaticsub", False)
            opts["subtitleslangs"] = cfg.get("subtitleslangs", ["en"])
            opts["embedsubs"] = True

        if cfg.get("split_chapters"):
            pp.append({"key": "FFmpegSplitChapters"})

        if not is_audio:
            opts["merge_output_format"] = container
            # Do NOT also set remux_video — legacy bug avoided

        if pp:
            opts["postprocessors"] = pp

    if cfg.get("verbose"):
        opts["verbose"] = True

    if cfg.get("compat_options"):
        opts["compat_opts"] = [cfg["compat_options"]]

    if progress_queue is not None:
        opts["progress_hooks"] = [build_progress_hook(progress_queue, download_id or "")]
        opts["postprocessor_hooks"] = [build_postprocessor_hook(progress_queue, download_id or "")]

    opts["continuedl"] = True

    return opts
