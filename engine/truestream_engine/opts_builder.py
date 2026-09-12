from truestream_engine.config import DEFAULT_CFG, coerce_config
from truestream_engine.paths import get_paths
from truestream_engine.format_selector import build_format_string
from truestream_engine.hooks import build_progress_hook, build_postprocessor_hook


def _is_safe_outtmpl(tmpl) -> bool:
    """True iff an output template cannot escape the output directory."""
    if not isinstance(tmpl, str) or not tmpl or len(tmpl) > 256:
        return False
    if "\x00" in tmpl:
        return False
    text = tmpl.replace("\\", "/")
    if text.startswith("/") or text.startswith("~"):
        return False
    if len(text) >= 2 and text[1] == ":":
        return False
    if text.startswith("//"):
        return False
    if any(seg == ".." for seg in text.split("/")):
        return False
    return True


def _parse_section_ranges(specs: list) -> list[tuple[float, float]]:
    """Parse section specs into [(start, end)] seconds tuples.

    Same syntax as yt-dlp --download-sections time ranges: optional "*"
    prefix, START-END with H:M:S / seconds / inf (e.g. "*10:15-20:00").
    Invalid specs are skipped with a warning — a typo must never fail the
    whole download.
    """
    from yt_dlp.utils import parse_duration
    from truestream_engine.logger import get_logger
    log = get_logger("truestream_engine.opts_builder")
    ranges: list[tuple[float, float]] = []
    for spec in specs:
        try:
            text = str(spec).strip()
            if text.startswith("*"):
                text = text[1:]
            if "-" not in text:
                log.warn(f"Ignoring malformed download section (want START-END): {spec!r}")
                continue
            start_s, end_s = text.split("-", 1)
            start = parse_duration(start_s.strip())
            end_text = end_s.strip().lower()
            end = float("inf") if end_text in ("inf", "", "none") else parse_duration(end_text)
            if start is None or end is None:
                log.warn(f"Ignoring unparseable download section: {spec!r}")
                continue
            if end != float("inf") and start >= end:
                log.warn(f"Ignoring empty download section (start >= end): {spec!r}")
                continue
            ranges.append((start, end))
        except Exception as e:
            log.warn(f"Ignoring download section {spec!r}: {e}")
    return ranges


def apply_aria2c_opts(opts: dict, config: dict) -> dict:
    import os
    import re
    from truestream_engine.logger import get_logger
    from truestream_engine.paths import get_paths
    log = get_logger("truestream_engine.opts_builder")
    aria_path = get_paths().get("aria2c_path")
    # use_aria2 is the legacy alias — honor either flag.
    aria_on = config.get("aria2c_enabled") or config.get("use_aria2")
    if aria_on and aria_path and os.path.isfile(aria_path):
        # Defense in depth: external_downloader_args is passed verbatim to
        # the child argv (no shell involved), so clamp/validate config values
        # instead of trusting them blindly.
        try:
            chunks = max(1, min(16, int(config.get("aria2c_chunks", 5))))
        except (ValueError, TypeError):
            log.warn(
                f"Ignoring invalid aria2c_chunks value: "
                f"{config.get('aria2c_chunks')!r}"
            )
            chunks = 5
        args = [f"-x{chunks}", "-k1M", "--min-split-size=1M"]
        max_speed = str(config.get("aria2c_max_speed") or "").strip()
        if max_speed:
            if re.match(r"^\d+[KkMmGg]?$", max_speed):
                args.append(f"--max-download-limit={max_speed}")
            else:
                log.warn(
                    f"Ignoring invalid aria2c_max_speed value: {max_speed!r}"
                )
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
    event_callback=None,
) -> dict:
    # Belt-and-braces: callers coerce, but a raw Chaquopy HashMap proxy
    # dies on `{**...}` below — normalize first, never crash here.
    cfg = {**DEFAULT_CFG, **coerce_config(config)}
    paths = get_paths()

    # SEC-04: confine the output template. yt-dlp honors absolute-path
    # templates and interpolates metadata fields (upstream CVE-2024-38519
    # class), so a template smuggled in via config must never escape the
    # output dir. Reject: absolute paths (posix + drive/UNC), `..`
    # segments, NUL bytes, overlong strings. Fail closed to the default.
    from truestream_engine.logger import get_logger as _get_tmpl_logger
    _tmpl_log = _get_tmpl_logger("truestream_engine.opts_builder")
    tmpl = cfg.get("output_tmpl") or DEFAULT_CFG["output_tmpl"]
    if not _is_safe_outtmpl(tmpl):
        _tmpl_log.warn(f"Rejecting unsafe output template, using default: {tmpl!r:.80}")
        tmpl = DEFAULT_CFG["output_tmpl"]

    fmt = override_format or build_format_string(cfg)
    is_audio = override_audio if override_audio is not None else cfg["audio_only"]
    container = override_container or cfg["container"]

    opts: dict = {
        "format": fmt,
        "paths": {"home": paths["output_dir"] or "."},
        "outtmpl": {"default": tmpl},
        "ignoreerrors": True,
        # yt-dlp CLI --no-mtime maps to `updatetime: False`; `no_mtime` is
        # not a recognized YoutubeDL param and is silently ignored (#7).
        "updatetime": False,
        "retries": int(cfg["retries"]),
        "fragment_retries": int(cfg["fragment_retries"]),
        "windowsfilenames": True,
        "trim_file_name": 160,
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

    # Section cutting — FFmpeg only, no JS runtime or extra binary needed.
    # Same syntax as yt-dlp --download-sections time ranges.
    section_ranges = _parse_section_ranges(cfg.get("download_sections") or [])
    if section_ranges:
        from yt_dlp.utils import download_range_func
        opts["download_ranges"] = download_range_func(None, section_ranges)
        if cfg.get("force_keyframes_at_cuts"):
            opts["force_keyframes_at_cuts"] = True

    sponsor_cats = cfg.get("sponsorblock_cats", [])
    if sponsor_cats:
        # SponsorBlock only MARKS chapters here; the ModifyChapters cutter is
        # inserted later in canonical yt-dlp order (after FFmpegEmbedSubtitle,
        # before FFmpegMetadata). See ffmpeg PP block below (#6).
        opts["postprocessors"] = opts.get("postprocessors", []) + [
            {
                "key": "SponsorBlock",
                "categories": sponsor_cats,
                "when": "after_filter",
            },
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
            # writethumbnail is the real YoutubeDL param (write_thumbnail does
            # not exist) — the thumbnail file must exist for EmbedThumbnail
            # to embed anything (#9).
            opts["writethumbnail"] = True
            pp.append({"key": "FFmpegThumbnailsConvertor", "format": "jpg"})
            pp.append({"key": "EmbedThumbnail"})

        meta_pp: list[str] = []
        if cfg.get("addmetadata"):
            meta_pp.append("add_metadata")
        if cfg.get("embedthumbnail"):
            meta_pp.append("embed_thumbnail")

        # Canonical yt-dlp PP order: ... -> EmbedSubtitle -> ModifyChapters
        # -> Metadata. Subtitles must be in the container before chapters are
        # cut, and chapter edits must land before tags are written.
        subs_enabled = cfg.get("writesubtitles", False) or cfg.get("writeautomaticsub", False)
        if subs_enabled:
            # Sidecar download is independent of embedding: a user who
            # wants .srt/.vtt files without embedding still needs these
            # keys (previously gated behind embedsubtitles — nothing was
            # ever written for sidecar-only).
            opts["writesubtitles"] = cfg.get("writesubtitles", False)
            opts["writeautomaticsub"] = cfg.get("writeautomaticsub", False)
            opts["subtitleslangs"] = cfg.get("subtitleslangs", ["en"])
        if subs_enabled and cfg.get("embedsubtitles"):
            # `embedsubs` is not a real YoutubeDL param (silently ignored).
            # The CLI maps --embed-subs to the FFmpegEmbedSubtitle PP, so we
            # append it explicitly. already_have_subtitle keeps the sidecar
            # file when the user also asked to write subtitles.
            pp.append({
                "key": "FFmpegEmbedSubtitle",
                "already_have_subtitle": bool(cfg.get("writesubtitles", False)),
            })

        if sponsor_cats:
            pp.append({
                "key": "ModifyChapters",
                "remove_sponsor_segments": list(sponsor_cats),
            })

        if meta_pp:
            if is_audio:
                pass  # metadata handled by FFmpegExtractAudio
            else:
                pp.append({
                    "key": "FFmpegMetadata",
                    "add_metadata": cfg.get("addmetadata", True),
                    "add_chapters": True,
                })

        if cfg.get("split_chapters"):
            pp.append({"key": "FFmpegSplitChapters"})

        if not is_audio:
            opts["merge_output_format"] = container
            # Do NOT also set remux_video — legacy bug avoided

        if pp:
            opts["postprocessors"] = pp

    if cfg.get("write_description"):
        opts["writedescription"] = True
    if cfg.get("write_info_json"):
        opts["writeinfojson"] = True

    if cfg.get("verbose"):
        opts["verbose"] = True

    if cfg.get("compat_options"):
        opts["compat_opts"] = [cfg["compat_options"]]

    if progress_queue is not None:
        opts["progress_hooks"] = [build_progress_hook(progress_queue, download_id or "", event_callback)]
        opts["postprocessor_hooks"] = [build_postprocessor_hook(progress_queue, download_id or "", event_callback)]

    opts["continuedl"] = True

    # Fragment + socket tuning. These config keys were accepted for months
    # but never applied (dead settings — verified against yt-dlp's
    # YoutubeDL params: concurrent_fragment_downloads [CLI -N] and
    # socket_timeout). Clamp defensively, same style as aria2c above.
    from truestream_engine.logger import get_logger as _get_logger
    _log = _get_logger("truestream_engine.opts_builder")
    try:
        frags = max(1, min(16, int(cfg.get("concurrent_fragments", 4))))
    except (ValueError, TypeError):
        _log.warn(
            "Ignoring invalid concurrent_fragments value: "
            f"{cfg.get('concurrent_fragments')!r}"
        )
        frags = 4
    opts["concurrent_fragment_downloads"] = frags
    try:
        timeout = int(cfg.get("socket_timeout", 30))
        if timeout > 0:
            opts["socket_timeout"] = timeout
        else:
            _log.warn(
                "Ignoring non-positive socket_timeout value: "
                f"{cfg.get('socket_timeout')!r}"
            )
    except (ValueError, TypeError):
        _log.warn(
            f"Ignoring invalid socket_timeout value: "
            f"{cfg.get('socket_timeout')!r}"
        )

    _configure_js_runtime(opts, paths)

    return opts


def _is_android_app() -> bool:
    """True only inside the production Chaquopy app process (NOT Termux).

    Same java-bridge sniff as bootstrap: Termux/desktop Pythons raise
    ImportError. Used to prefer Node on Android, where the bundled Deno
    cannot satisfy all of its shared-library deps.
    """
    try:
        from java.android import context  # type: ignore[import-not-found]
        return context is not None
    except Exception:
        return False


def _configure_js_runtime(opts: dict, paths: dict) -> None:
    import os
    from truestream_engine.po_token import detect_js_runtime

    # Android: Node first. Rationale: ytdlnis treats Node as the workhorse
    # (their Deno bundle has the same missing-deps fate as ours —
    # libsqlite3.so; Node links cleanly on Bionic). Desktop keeps the
    # yt-dlp-recommended Deno-first order.
    if _is_android_app():
        node_path = paths.get("nodejs_path") or os.environ.get("NODE_PATH") or shutil_which("node")
        if node_path and os.path.isfile(node_path):
            opts["js_runtimes"] = {"node": {"path": node_path}}
            opts["remote_components"] = ["ejs:github"]
            return

    # Prioritize explicit deno_path first (e.g. bundled libdeno.so on Android)
    deno_path = paths.get("deno_path") or os.environ.get("DENO_PATH") or shutil_which("deno")
    if deno_path and os.path.isfile(deno_path):
        opts["js_runtimes"] = {"deno": {"path": deno_path}}
        opts["remote_components"] = ["ejs:github"]
        return

    runtime_info = detect_js_runtime()
    runtime_name = runtime_info["name"]

    if runtime_name == "deno":
        if deno_path and os.path.isfile(deno_path):
            opts["js_runtimes"] = {"deno": {"path": deno_path}}
            opts["remote_components"] = ["ejs:github"]
            return

    if runtime_name == "quickjs":
        if shutil_which("qjs"):
            opts["js_runtimes"] = {"quickjs": {}}
            opts["remote_components"] = ["ejs:github"]
            return

    node_path = paths.get("nodejs_path") or os.environ.get("NODE_PATH") or shutil_which("node")
    if node_path and os.path.isfile(node_path):
        opts["js_runtimes"] = {"node": {"path": node_path}}
        opts["remote_components"] = ["ejs:github"]
        return

    opts["remote_components"] = ["ejs:github"]


def shutil_which(cmd):
    import shutil
    return shutil.which(cmd)
