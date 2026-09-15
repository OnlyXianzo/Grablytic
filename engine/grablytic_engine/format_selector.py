import re

# T0-3: allowlist for a SINGLE concrete yt-dlp format ID. The `format`
# option is a selector-expression language (`/ + , ( )` are structural,
# `[...]` opens filters, `all`/`mergeall` amplify one download into many —
# cf. YoutubeDL.build_format_selector, ALLOWED_OPS). Interpolating an
# IPC-supplied ID verbatim lets one config value become a whole expression
# (fallback chains, multi-download, filter predicates). So an explicit ID
# must match this class and nothing else; anything richer is rejected and
# the caller fails closed to the auto ladder. `-` stays legal (the standard
# intra-ID join delimiter, e.g. `247-dashy`); `.`/`_` cover `sb0`-style and
# `hls_aac_160k`-style IDs. There is no upstream canonical regex (format IDs
# are extractor-specific free text) — this gate is novel defense-in-depth,
# not copied practice, and is deliberately narrower than the wild.
_FORMAT_ID_RE = re.compile(r"[A-Za-z0-9_.\-]{1,64}\Z")

# Bare selector atoms that never select by ID: `all`/`mergeall` download
# many formats (availability/cost amplification), the rest select a keyword
# instead of the concrete ID. Only the amplifying two are rejected — a
# coincidental `best` still resolves to *something* safe (single stream),
# while `all` must never be reachable from an explicit-ID slot.
_AMPLIFYING_KEYWORDS = frozenset({"all", "mergeall"})


def is_safe_format_id(value) -> bool:
    """True iff `value` is a single concrete format ID (never an expression)."""
    if not isinstance(value, str):
        return False
    if not _FORMAT_ID_RE.match(value):
        return False
    if value.lower() in _AMPLIFYING_KEYWORDS:
        return False
    return True


def build_format_string(cfg: dict) -> str:
    raw_vid = cfg.get("explicit_format_id")
    raw_aid = cfg.get("explicit_audio_format_id")
    # T0-3: validate BEFORE interpolation — an invalid ID is treated as
    # absent, so a smuggled expression can never reach the `f"{vid}+{aid}"`
    # join below. `format_code` (deliberate raw power-user override) is
    # untouched by this gate by design.
    explicit_vid = raw_vid if is_safe_format_id(raw_vid) else None
    explicit_aid = raw_aid if is_safe_format_id(raw_aid) else None

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
