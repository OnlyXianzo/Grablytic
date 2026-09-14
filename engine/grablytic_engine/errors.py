from grablytic_engine.logger import get_logger


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
    "drm": ("ERROR_DRM", False),
    "jsinterpreter": ("ERROR_JS_RUNTIME", True),
    "unable to download": ("ERROR_NETWORK", True),
    "file sharing violation": ("ERROR_FILE_LOCKED", True),
    "quota exceeded": ("ERROR_QUOTA_EXCEEDED", False),
    "no space left": ("ERROR_QUOTA_EXCEEDED", False),
}

_SSL_KEYWORDS = frozenset({
    "ssl", "handshake", "certificate verify failed",
    "name or service not known", "dns", "connection refused",
    "connection reset", "timeout",
})


def classify_error(exc: Exception, stderr: str = "") -> GrablyticError:
    msg = str(exc)
    combined = (msg + " " + stderr).lower()

    for keyword, (error_type, recoverable) in _ERROR_MAP.items():
        if keyword.lower() in combined:
            log.warn(f"Classified error: {error_type} — {msg}")
            return GrablyticError(error_type, msg, recoverable)

    if "http error" in combined:
        log.warn(f"Classified error: ERROR_NETWORK — {msg}")
        return GrablyticError("ERROR_NETWORK", msg, True)

    if any(kw in combined for kw in _SSL_KEYWORDS):
        log.warn(f"Classified error: ERROR_SSL_BLOCKED — {msg}")
        return GrablyticError("ERROR_SSL_BLOCKED", msg, True)

    log.warn(f"Classified error: ERROR_UNKNOWN — {msg}")
    return GrablyticError("ERROR_UNKNOWN", msg, True)
