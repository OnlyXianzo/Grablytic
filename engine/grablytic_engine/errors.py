from grablytic_engine.logger import get_logger
from grablytic_engine.persistent import sanitize as _sanitize

import re


log = get_logger("grablytic_engine.errors")

_VPN_TYPES = frozenset({
    "ERROR_GEO_BLOCKED",
    "ERROR_AGE_RESTRICTED",
    "ERROR_FORBIDDEN",
    "ERROR_RATE_LIMITED",
    "ERROR_SSL_BLOCKED",
})


class GrablyticError(Exception):
    def __init__(self, error_type: str, message: str, recoverable: bool = True):
        self.error_type = error_type
        self.message = message
        self.recoverable = recoverable
        self.suggests_vpn = error_type in _VPN_TYPES

    def to_dict(self) -> dict:
        return {
            "error_type": self.error_type,
            "error_message": self.message,
            "recoverable": self.recoverable,
            "suggests_vpn": self.suggests_vpn,
        }


_ERROR_MAP = {
    "not available in your country": ("ERROR_GEO_BLOCKED", True),
    "sign in to confirm your age": ("ERROR_AGE_RESTRICTED", True),
    # YouTube bot-check wall: the fix is cookies, not VPN — map to
    # FORBIDDEN so the UI offers 'Try with Cookies' (zero UI churn).
    "confirm you're not a bot": ("ERROR_FORBIDDEN", True),
    "sign in to confirm": ("ERROR_FORBIDDEN", True),
    "this video is private": ("ERROR_PRIVATE", True),
    "video unavailable": ("ERROR_UNAVAILABLE", False),
    "HTTP Error 429": ("ERROR_RATE_LIMITED", True),
    "HTTP Error 403": ("ERROR_FORBIDDEN", True),
    "no video formats found": ("ERROR_FORMAT_UNAVAILABLE", True),
}

# T3-14: "drm" as a bare substring false-positives on filenames
# ("mydrmvideo.mkv"). Whole-word only — genuine yt-dlp DRM errors always
# carry the word ("DRM protected", "DRM"). Checked at the map position
# below to preserve long-standing precedence.
_DRM_RE = re.compile(r"\bdrm\b")

_ERROR_MAP_TAIL = {
    "jsinterpreter": ("ERROR_JS_RUNTIME", True),
    "unable to download": ("ERROR_NETWORK", True),
    "file sharing violation": ("ERROR_FILE_LOCKED", True),
    "quota exceeded": ("ERROR_QUOTA_EXCEEDED", False),
    "no space left": ("ERROR_QUOTA_EXCEEDED", False),
}

# T3-14: genuine TLS failures only. Timeouts/DNS/refused/reset are
# congestion, not censorship — they used to map to ERROR_SSL_BLOCKED and
# trigger a bogus VPN upsell (SSL_BLOCKED ∈ _VPN_TYPES).
_SSL_KEYWORDS = frozenset({
    "ssl", "handshake", "certificate",
})

_NETWORK_TRANSIENT = frozenset({
    "timeout", "timed out",
    "name or service not known", "dns",
    "connection refused", "connection reset",
    "temporary failure",
})

_MAX_MESSAGE = 500


def _safe_message(exc: Exception) -> str:
    """User-facing message: credentials/tokens scrubbed, length-capped.

    T3-14: str(exc) used to reach Flutter logs verbatim (proxy creds,
    cookie paths, signed URLs). sanitize() covers tokens + userinfo;
    the cap bounds log/DB rows.
    """
    try:
        text = str(exc)
    except Exception:
        text = repr(exc)
    try:
        cleaned = _sanitize(text)
        text = cleaned if isinstance(cleaned, str) else str(exc)
    except Exception:
        pass
    if len(text) > _MAX_MESSAGE:
        text = text[:_MAX_MESSAGE] + "... [truncated]"
    return text


def classify_error(exc: Exception, stderr: str = "") -> GrablyticError:
    msg = _safe_message(exc)
    combined = (msg + " " + stderr).lower()

    for keyword, (error_type, recoverable) in _ERROR_MAP.items():
        if keyword.lower() in combined:
            log.warn(f"Classified error: {error_type} — {msg}")
            return GrablyticError(error_type, msg, recoverable)

    if _DRM_RE.search(combined):
        log.warn(f"Classified error: ERROR_DRM — {msg}")
        return GrablyticError("ERROR_DRM", msg, False)

    for keyword, (error_type, recoverable) in _ERROR_MAP_TAIL.items():
        if keyword.lower() in combined:
            log.warn(f"Classified error: {error_type} — {msg}")
            return GrablyticError(error_type, msg, recoverable)

    if "http error" in combined:
        log.warn(f"Classified error: ERROR_NETWORK — {msg}")
        return GrablyticError("ERROR_NETWORK", msg, True)

    if any(kw in combined for kw in _SSL_KEYWORDS):
        log.warn(f"Classified error: ERROR_SSL_BLOCKED — {msg}")
        return GrablyticError("ERROR_SSL_BLOCKED", msg, True)

    if any(kw in combined for kw in _NETWORK_TRANSIENT):
        log.warn(f"Classified error: ERROR_NETWORK — {msg}")
        return GrablyticError("ERROR_NETWORK", msg, True)

    log.warn(f"Classified error: ERROR_UNKNOWN — {msg}")
    return GrablyticError("ERROR_UNKNOWN", msg, True)
