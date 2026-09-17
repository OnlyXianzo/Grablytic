import os
import re

from grablytic_engine.config import DEFAULT_CFG, coerce_config, sanitize_config
from grablytic_engine.paths import get_paths
from grablytic_engine.format_selector import build_format_string
from grablytic_engine.hooks import build_progress_hook, build_postprocessor_hook


_PLAYLIST_SEGMENT_RE = re.compile(r"^(\d+)(?:([-:])(\d+))?$")
_SUBTITLE_LANG_RE = re.compile(r"^-?(?:all|[a-zA-Z0-9_-]{1,32})$")

SAFE_COMPAT_OPTIONS = frozenset({
    "no-live-chat",
    "no-youtube-channel-redirect",
    "no-youtube-unavailable-videos",
    "no-youtube-prefer-utc-upload-date",
    "prefer-vp9-sort",
    "format-sort",
    "format-spec",
    "multistreams",
    "no-playlist-metafiles",
    "no-attach-info-json",
    "embed-metadata",
    "seperate-video-versions",
    "no-clean-infojson",
    "no-keep-subs",
    "mtime-by-default",
    "manifest-filesize-approx",
    "abort-on-error",
})


def sanitize_playlist_items(val: str | list | tuple | None, max_items: int = 500, max_index: int = 10000) -> str | None:
    """Sanitize and validate playlist_items specification.

    Prevents flat-fetch DoS attacks and unhandled parser ValueError exceptions.
    Returns sanitized string if valid, None if invalid or out of bounds.
    """
    if val is None:
        return None
    if isinstance(val, (list, tuple)):
        items = []
        for x in val:
            try:
                n = int(x)
                if 1 <= n <= max_index:
                    items.append(str(n))
                else:
                    return None
            except (ValueError, TypeError):
                return None
        if not items or len(items) > max_items:
            return None
        return ",".join(items)

    if not isinstance(val, str):
        return None

    val_str = val.strip()
    if not val_str:
        return None

    tokens = val_str.split(",")
    if any(not t.strip() for t in tokens):
        return None

    total_items = 0
    clean_parts = []
    for token in tokens:
        token = token.strip()
        m = _PLAYLIST_SEGMENT_RE.match(token)
        if not m:
            return None
        start_str, sep, end_str = m.group(1), m.group(2), m.group(3)
        start = int(start_str)
        if start <= 0 or start > max_index:
            return None
        if sep is not None:
            end = int(end_str)
            if end <= 0 or end > max_index or start > end:
                return None
            span = end - start + 1
            if span > max_items:
                return None
            total_items += span
            clean_parts.append(f"{start}{sep}{end}")
        else:
            total_items += 1
            clean_parts.append(str(start))

    if total_items > max_items:
        return None

    return ",".join(clean_parts)


def sanitize_ratelimit(val) -> int | None:
    """Coerce and clamp rate_limit string/number to integer bytes/sec.

    yt-dlp expects numeric ratelimit (int or float). Strings cause TypeError
    during active transfers. Zero causes ZeroDivisionError. Very low values
    cause thread hangs.
    """
    if val is None:
        return None
    if isinstance(val, (int, float)):
        num = int(val)
    elif isinstance(val, str):
        s = val.strip().upper()
        if not s:
            return None
        units = {"K": 1024, "KB": 1024, "M": 1024**2, "MB": 1024**2, "G": 1024**3, "GB": 1024**3}
        multiplier = 1
        num_str = s
        for unit, mult in sorted(units.items(), key=lambda x: -len(x[0])):
            if s.endswith(unit):
                multiplier = mult
                num_str = s[:-len(unit)].strip()
                break
        try:
            num = int(float(num_str) * multiplier)
        except (ValueError, TypeError):
            return None
    else:
        return None

    if num <= 0:
        return None
    return max(1024, min(num, 1073741824))


def sanitize_cookiefile(path: str | None) -> str | None:
    """Validate cookies file path for security and existence.

    Must be an absolute path to an existing, readable regular file.
    Rejects directories, nonexistent paths, relative paths, and unreadable files.
    """
    if not path or not isinstance(path, str):
        return None
    path_str = path.strip()
    if not os.path.isabs(path_str):
        return None
    try:
        real_path = os.path.realpath(path_str)
        if not os.path.isfile(real_path):
            return None
        if not os.access(real_path, os.R_OK):
            return None
        return real_path
    except Exception:
        return None


def sanitize_compat_opts(val: str | list | tuple | None) -> list[str] | None:
    """Filter compat_options against a strict allowlist of safe flags."""
    if not val:
        return None
    tokens = []
    if isinstance(val, str):
        tokens = [s.strip() for s in re.split(r"[\s,]+", val) if s.strip()]
    elif isinstance(val, (list, tuple)):
        for item in val:
            if isinstance(item, str):
                tokens.extend(s.strip() for s in re.split(r"[\s,]+", item) if s.strip())
    else:
        return None

    safe = [tok for tok in tokens if tok in SAFE_COMPAT_OPTIONS]
    return safe if safe else None


def sanitize_subtitleslangs(val: list | tuple | str | None) -> list[str]:
    """Validate and sanitize subtitleslangs tokens.

    Guards against ReDoS in yt-dlp's re.compile(val) and type errors.
    Returns a sanitized list of language codes, defaulting to ['en'].
    """
    if not val:
        return ["en"]
    tokens = []
    if isinstance(val, str):
        tokens = [s.strip() for s in val.split(",") if s.strip()]
    elif isinstance(val, (list, tuple)):
        for item in val:
            if isinstance(item, str) and item.strip():
                tokens.append(item.strip())
    else:
        return ["en"]

    valid = [tok for tok in tokens if _SUBTITLE_LANG_RE.fullmatch(tok)]
    valid = valid[:50]
    return valid if valid else ["en"]



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


def _clamped_int(config, key: str, default: int, lo: int, hi: int) -> int:
    """Coerce an IPC numeric param to [lo, hi], falling back to default with
    a warning. T3-10: unguarded int() turned garbage into a dead thread and
    absurd values into eternal hangs."""
    from grablytic_engine.logger import get_logger
    log = get_logger("grablytic_engine.opts_builder")
    try:
        val = int(config.get(key, default))
    except (ValueError, TypeError):
        log.warn(f"Ignoring invalid {key} value: {config.get(key)!r}")
        return default
    if val < lo or val > hi:
        log.warn(f"Ignoring out-of-range {key} value: {config.get(key)!r}")
        return default
    return val


def _parse_section_ranges(specs: list) -> list[tuple[float, float]]:
    """Parse section specs into [(start, end)] seconds tuples.

    Same syntax as yt-dlp --download-sections time ranges: optional "*"
    prefix, START-END with H:M:S / seconds / inf (e.g. "*10:15-20:00").
    Invalid specs are skipped with a warning — a typo must never fail the
    whole download.
    """
    from yt_dlp.utils import parse_duration
    from grablytic_engine.logger import get_logger
    log = get_logger("grablytic_engine.opts_builder")
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
    from grablytic_engine.logger import get_logger
    from grablytic_engine.paths import get_paths
    log = get_logger("grablytic_engine.opts_builder")
    aria_path = get_paths().get("aria2c_path")
    # use_aria2 is the legacy alias — honor either flag.
    aria_on = config.get("aria2c_enabled") or config.get("use_aria2")
    # T0-2: re-validate at the exec site (admission in set_paths is not the
    # last word — _paths can hold placeholders or legacy values). isfile +
    # X_OK, same bar as yt-dlp's own _find_exe (F_OK|X_OK).
    if (aria_on and aria_path and os.path.isfile(aria_path)
            and os.access(aria_path, os.X_OK)):
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
                # T3-10: a zero limit throttles the download to nothing —
                # reject it like any other invalid value.
                if int(max_speed.rstrip("KkMmGg")) == 0:
                    log.warn(
                        f"Ignoring zero aria2c_max_speed value: {max_speed!r}"
                    )
                else:
                    args.append(f"--max-download-limit={max_speed}")
            else:
                log.warn(
                    f"Ignoring invalid aria2c_max_speed value: {max_speed!r}"
                )
        # CVE-2026-50574: Avoid using aria2c for DASH/HLS fragmented manifests
        # T0-2: pin the ABSOLUTE validated binary, not the bare name "aria2c".
        # Verified against installed yt-dlp (downloader/__init__.py +
        # external.py): the dict value flows to get_external_downloader
        # (basename→Aria2cFD class lookup works with a path) and then to
        # available(path)→check_executable→Popen([exe,...]) — the exact file
        # is exec'd with zero PATH lookup. The old bare name resolved via the
        # process PATH that set_paths used to pollute with explicit dirnames.
        opts["external_downloader"] = {
            "default": aria_path,
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
    cfg = sanitize_config({**DEFAULT_CFG, **coerce_config(config)})
    paths = get_paths()

    # SEC-04: confine the output template. yt-dlp honors absolute-path
    # templates and interpolates metadata fields (upstream CVE-2024-38519
    # class), so a template smuggled in via config must never escape the
    # output dir. Reject: absolute paths (posix + drive/UNC), `..`
    # segments, NUL bytes, overlong strings. Fail closed to the default.
    from grablytic_engine.logger import get_logger as _get_tmpl_logger
    _tmpl_log = _get_tmpl_logger("grablytic_engine.opts_builder")
    tmpl = cfg.get("output_tmpl") or DEFAULT_CFG["output_tmpl"]
    if not _is_safe_outtmpl(tmpl):
        _tmpl_log.warn(f"Rejecting unsafe output template, using default: {tmpl!r:.80}")
        tmpl = DEFAULT_CFG["output_tmpl"]

    fmt = override_format or build_format_string(cfg)
    # T0-3: an explicit audio ID must be a VALIDATED single ID before it may
    # influence mode selection — otherwise `explicit_audio_format_id: "all"`
    # would both inject the selector and flip the download into extract-audio.
    from grablytic_engine.format_selector import is_safe_format_id as _safe_fmt_id
    _raw_vid = cfg.get("explicit_format_id")
    _raw_aid = cfg.get("explicit_audio_format_id")
    explicit_vid = _raw_vid if _safe_fmt_id(_raw_vid) else None
    explicit_aid = _raw_aid if _safe_fmt_id(_raw_aid) else None
    if (_raw_vid and not explicit_vid) or (_raw_aid and not explicit_aid):
        _tmpl_log.warn("Ignoring unsafe explicit format ID, using auto ladder")
    has_audio_only_explicit = bool(explicit_aid) and not bool(explicit_vid)
    is_audio = override_audio if override_audio is not None else (bool(cfg.get("audio_only")) or has_audio_only_explicit)
    container = override_container or cfg["container"]
    # Resolved audio codec when is_audio (None for video). Read by the
    # thumbnail block below for the m4a cover-art rule.
    audio_codec: str | None = None

    if cfg.get("organize_by_folder"):
        # Video/ vs Audio/ split. Relative subdir keeps the template
        # inside the output dir (passes _is_safe_outtmpl); yt-dlp
        # creates the subdirectories automatically.
        subdir = "Audio" if is_audio else "Video"
        tmpl = f"{subdir}/{tmpl}"
        if not _is_safe_outtmpl(tmpl):
            _tmpl_log.warn("Organize-by-folder template rejected, using default")
            tmpl = DEFAULT_CFG["output_tmpl"]

    opts: dict = {
        "format": fmt,
        "paths": {"home": paths["output_dir"] or "."},
        "outtmpl": {"default": tmpl},
        "ignoreerrors": True,
        # yt-dlp CLI --no-mtime maps to `updatetime: False`; `no_mtime` is
        # not a recognized YoutubeDL param and is silently ignored (#7).
        "updatetime": False,
        "retries": _clamped_int(cfg, "retries", 10, 0, 30),
        "fragment_retries": _clamped_int(cfg, "fragment_retries", 10, 0, 100),
        "windowsfilenames": True,
        "trim_file_name": 160,
    }

    opts = apply_aria2c_opts(opts, cfg)

    if is_audio:
        raw_container = (container or "").lower()
        audio_fmt = (cfg.get("audio_format") or "").lower()
        if raw_container in ("mp3", "m4a", "flac", "opus", "wav", "aac", "vorbis"):
            audio_codec = raw_container
        elif audio_fmt in ("mp3", "m4a", "flac", "opus", "wav", "aac", "vorbis"):
            audio_codec = audio_fmt
        elif raw_container in ("mkv", "mp4"):
            audio_codec = "m4a"
        elif raw_container == "webm":
            audio_codec = "opus"
        else:
            audio_codec = "mp3"

        opts["postprocessors"] = [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": audio_codec,
                "preferredquality": str(cfg.get("audio_quality", "0")),
            }
        ]
        opts["keepvideo"] = False

    # T0-2: ffmpeg_location is an exec sink (yt-dlp spawns it for every
    # merge/extract). Re-check isfile+X_OK here — never trust the store blind.
    _ffmpeg = paths.get("ffmpeg_path")
    if _ffmpeg:
        import os as _os
        if _os.path.isfile(_ffmpeg) and _os.access(_ffmpeg, _os.X_OK):
            opts["ffmpeg_location"] = _ffmpeg

    cookies = sanitize_cookiefile(paths.get("cookies_path"))
    if cookies:
        opts["cookiefile"] = cookies

    ratelimit = sanitize_ratelimit(cfg.get("rate_limit"))
    if ratelimit is not None:
        opts["ratelimit"] = ratelimit

    if cfg.get("proxy"):
        from grablytic_engine.url_guard import sanitized_proxy as _sanitized_proxy
        _proxy = _sanitized_proxy(cfg.get("proxy"))
        if _proxy:
            opts["proxy"] = _proxy
        else:
            try:
                from grablytic_engine.logger import get_logger as _get_logger
                _get_logger("grablytic_engine.opts").warn(
                    "Ignoring malformed proxy setting (expected "
                    "http/https/socks URL with host)")
            except Exception:
                pass

    if cfg.get("geo_bypass"):
        opts["geo_bypass"] = True

    # ignore_archive wins over use_archive: redownload-after-delete and
    # explicit fresh redownloads must actually fetch instead of hitting the
    # "already recorded in the archive" skip (Seal #2065 trap). Scoped to a
    # single call — never flips the global preference.
    if cfg.get("use_archive") and not cfg.get("ignore_archive"):
        import os as _os

        default_archive = _os.path.join(
            paths.get("data_dir") or ".", "download_archive.txt"
        )
        requested = cfg.get("archive_path") or default_archive
        # archive_path is a user-controlled setting (not remote input), so
        # custom absolute locations stay honored. Normalize and fail closed
        # only on directories/empty: the destructive sink
        # (clear_download_archive's delete) keeps strict data_dir
        # containment; yt-dlp's write path here just records video IDs.
        try:
            _norm = _os.path.abspath(requested) if isinstance(requested, str) and requested.strip() else ""
        except Exception:
            _norm = ""
        if _norm and not _os.path.isdir(_norm):
            opts["download_archive"] = _norm
        else:
            opts["download_archive"] = default_archive
            try:
                from grablytic_engine.logger import get_logger as _get_logger
                _get_logger("grablytic_engine.opts").warn(
                    "Ignoring invalid archive_path; using default")
            except Exception:
                pass

    # TEARDOWN-4: same guard as retries/fragments (T3-10) — a bare int()
    # here turned a settings typo into a ValueError that killed the whole
    # download start path. Garbage/out-of-range falls back to 0 (omitted).
    sleep = _clamped_int(cfg, "sleep_interval", 0, 0, 3600)
    if sleep:
        opts["sleep_interval"] = sleep

    if cfg.get("no_playlist"):
        opts["noplaylist"] = True

    playlist_items = sanitize_playlist_items(cfg.get("playlist_items"))
    if playlist_items:
        opts["playlist_items"] = playlist_items
    if cfg.get("playlist_rev"):
        opts["playlistreverse"] = True
    if cfg.get("playlist_rand"):
        opts["playlistrandom"] = True

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

        from grablytic_engine.po_token import generate_po_token
        po_token = generate_po_token(url) or paths.get("po_token")
        if po_token:
            opts["extractor_args"]["youtube"]["po_token"] = [po_token]
    elif paths.get("po_token"):
        opts.setdefault("extractor_args", {})
        opts["extractor_args"].setdefault("youtube", {})
        opts["extractor_args"]["youtube"]["po_token"] = [paths["po_token"]]

    # T0-3: `explicit_vid`/`explicit_aid` above are already allowlisted —
    # this join can only ever produce `<id>`, `<id>+<id>`, never an injected
    # expression. Invalid IDs were warned about at mode-selection time and
    # are simply absent here, so `fmt` (auto ladder) survives untouched.
    if explicit_vid:
        if explicit_aid:
            opts["format"] = f"{explicit_vid}+{explicit_aid}"
        else:
            opts["format"] = explicit_vid
    elif explicit_aid:
        opts["format"] = explicit_aid

    # Post-processing — only one of merge/remux, never both
    if paths.get("ffmpeg_path"):
        pp: list[dict] = opts.get("postprocessors", [])

        if cfg.get("embedthumbnail"):
            # writethumbnail is the real YoutubeDL param (write_thumbnail does
            # not exist) — the thumbnail file must exist for EmbedThumbnail
            # to embed anything (#9).
            thumb_fmt = str(cfg.get("thumbnail_format") or "jpg").lower()
            if thumb_fmt not in ("jpg", "png", "webp"):
                thumb_fmt = "jpg"
            # Field fix (ri1Ar5nEq4s class): mjpeg cover art cannot mux into
            # m4a (`[ipod] Could not find tag for codec mjpeg`) — EVERY m4a
            # audio download with JPG thumbnails died at EmbedThumbnail.
            # PNG muxes cleanly, so force png for m4a output no matter the
            # toggle (video containers keep the user's choice).
            if thumb_fmt == "jpg" and audio_codec == "m4a":
                thumb_fmt = "png"
                _tmpl_log.info(
                    "Using PNG cover art for m4a output "
                    "(mjpeg cannot embed in the ipod container)"
                )
            opts["writethumbnail"] = True
            pp.append({"key": "FFmpegThumbnailsConvertor", "format": thumb_fmt, "when": "before_dl"})

        meta_pp: list[str] = []
        if cfg.get("addmetadata"):
            meta_pp.append("add_metadata")
        if cfg.get("embedthumbnail"):
            meta_pp.append("embed_thumbnail")

        # Canonical yt-dlp PP order: ... -> EmbedSubtitle -> ModifyChapters
        # -> Metadata -> EmbedThumbnail. Subtitles must be in the container
        # before chapters are cut, and chapter edits must land before tags
        # and cover art are written.
        subs_enabled = cfg.get("writesubtitles", False) or cfg.get("writeautomaticsub", False)
        if subs_enabled:
            # Sidecar download is independent of embedding: a user who
            # wants .srt/.vtt files without embedding still needs these
            # keys (previously gated behind embedsubtitles — nothing was
            # ever written for sidecar-only).
            opts["writesubtitles"] = cfg.get("writesubtitles", False)
            opts["writeautomaticsub"] = cfg.get("writeautomaticsub", False)
            opts["subtitleslangs"] = sanitize_subtitleslangs(cfg.get("subtitleslangs"))
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
            pp.append({
                "key": "FFmpegMetadata",
                "add_metadata": cfg.get("addmetadata", True),
                "add_chapters": True,
                # Iteration 1: yt-dlp's FFmpegMetadataPP defaults
                # add_infojson='if_exists' (truthy), which would attach the
                # newly default-ON info.json sidecars into mkv/mka outputs.
                # Pin off so output bytes stay stable (verified against
                # installed yt-dlp postprocessor/ffmpeg.py __init__).
                "add_infojson": False,
            })

        if cfg.get("embedthumbnail"):
            # already_have_thumbnail=True keeps the sidecar thumbnail file on
            # disk after embedding. The flag ONLY controls post-embed deletion
            # (EmbedThumbnailPP.run → _delete_downloaded_files when False) —
            # embedding itself always happens. Keeping the sidecar is what
            # lets Library render thumbnails offline/privacy-first and lets
            # downloader.py report a local thumbnail_path (verified against
            # installed yt-dlp postprocessor/embedthumbnail.py).
            pp.append({
                "key": "EmbedThumbnail",
                "already_have_thumbnail": True,
            })

        if cfg.get("split_chapters"):
            pp.append({"key": "FFmpegSplitChapters"})

        if not is_audio:
            # WebM container cannot embed cover art (raises EmbedThumbnailPPError in yt-dlp);
            # Matroska (MKV) is the container that supports VP9/AV1/Opus plus attached pictures.
            if cfg.get("embedthumbnail") and container == "webm":
                container = "mkv"
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

    compat = sanitize_compat_opts(cfg.get("compat_options"))
    if compat:
        opts["compat_opts"] = compat

    if progress_queue is not None:
        opts["progress_hooks"] = [build_progress_hook(progress_queue, download_id or "", event_callback)]
        opts["postprocessor_hooks"] = [build_postprocessor_hook(progress_queue, download_id or "", event_callback)]

    # force_overwrite (completed-download redownload): --force-overwrites
    # semantics per yt-dlp manpage — implies --no-continue so an intact
    # existing file is actually re-fetched instead of hitting the
    # "has already been downloaded" skip. Default stays resume-capable.
    if cfg.get("force_overwrite"):
        opts["overwrites"] = True
        opts["continuedl"] = False
    else:
        opts["continuedl"] = True

    # Fragment + socket tuning. These config keys were accepted for months
    # but never applied (dead settings — verified against yt-dlp's
    # YoutubeDL params: concurrent_fragment_downloads [CLI -N] and
    # socket_timeout). Clamp defensively, same style as aria2c above.
    from grablytic_engine.logger import get_logger as _get_logger
    _log = _get_logger("grablytic_engine.opts_builder")
    try:
        frags = max(1, min(16, int(cfg.get("concurrent_fragments", 2))))
    except (ValueError, TypeError):
        _log.warn(
            "Ignoring invalid concurrent_fragments value: "
            f"{cfg.get('concurrent_fragments')!r}"
        )
        frags = 2
    opts["concurrent_fragment_downloads"] = frags
    try:
        timeout = int(cfg.get("socket_timeout", 30))
        if 1 <= timeout <= 300:
            opts["socket_timeout"] = timeout
        else:
            _log.warn(
                "Ignoring out-of-range socket_timeout value: "
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
    from grablytic_engine.po_token import detect_js_runtime

    # T0-2: runtime paths are exec sinks (yt-dlp spawns deno/node for EJS
    # challenge solving). isfile+X_OK at every branch; shutil.which results
    # are already X_OK-gated by construction.
    def _is_exec(p) -> bool:
        return bool(p) and os.path.isfile(p) and os.access(p, os.X_OK)

    # Android: Node first. Rationale: ytdlnis treats Node as the workhorse
    # (their Deno bundle has the same missing-deps fate as ours —
    # libsqlite3.so; Node links cleanly on Bionic). Desktop keeps the
    # yt-dlp-recommended Deno-first order.
    if _is_android_app():
        node_path = paths.get("nodejs_path") or os.environ.get("NODE_PATH") or shutil_which("node")
        if _is_exec(node_path):
            opts["js_runtimes"] = {"node": {"path": node_path}}
            opts["remote_components"] = ["ejs:github"]
            return

    # Prioritize explicit deno_path first (e.g. bundled libdeno.so on Android)
    deno_path = paths.get("deno_path") or os.environ.get("DENO_PATH") or shutil_which("deno")
    if _is_exec(deno_path):
        opts["js_runtimes"] = {"deno": {"path": deno_path}}
        opts["remote_components"] = ["ejs:github"]
        return

    runtime_info = detect_js_runtime()
    runtime_name = runtime_info["name"]

    if runtime_name == "deno":
        if _is_exec(deno_path):
            opts["js_runtimes"] = {"deno": {"path": deno_path}}
            opts["remote_components"] = ["ejs:github"]
            return

    if runtime_name == "quickjs":
        if shutil_which("qjs"):
            opts["js_runtimes"] = {"quickjs": {}}
            opts["remote_components"] = ["ejs:github"]
            return

    node_path = paths.get("nodejs_path") or os.environ.get("NODE_PATH") or shutil_which("node")
    if _is_exec(node_path):
        opts["js_runtimes"] = {"node": {"path": node_path}}
        opts["remote_components"] = ["ejs:github"]
        return

    # T0-6: no usable JS runtime → request NO remote solver. yt-dlp's default
    # is deny (`remote_components=()` upstream); the old fallthrough enabled
    # `ejs:github` unconditionally, triggering a solver fetch nothing could
    # execute. (With a runtime present, the branches above opt in — and the
    # integrity of that fetched solver is yt-dlp's own SHA3-512 + version pin
    # in yt_dlp/extractor/youtube/jsc/_builtin/ejs.py, NOT our stub gate in
    # po_token.py, which covers only local inert stubs. See HQ5.)


def shutil_which(cmd):
    import shutil
    return shutil.which(cmd)
