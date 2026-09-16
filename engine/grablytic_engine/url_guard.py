"""Input guards for engine network/file sinks (SSRF + traversal + proxy).

Every IPC-controlled string used to reach the network (media URLs, site
profile override URLs) or the filesystem (download-archive path) or to
redirect all traffic (proxy) passes through here first. stdlib only.
Never raises: validators return ""/None on garbage (fail closed).
"""

import ipaddress
import os
from urllib.parse import urlparse

_ALLOWED_MEDIA_SCHEMES = ("http", "https")
_ALLOWED_PROXY_SCHEMES = ("http", "https", "socks4", "socks5", "socks5h")

_LOCAL_HOSTS = {"localhost", "localhost.", "0.0.0.0", "::", "::1"}


def _host_is_blocked(host: str) -> bool:
    h = (host or "").strip().lower().rstrip(".")
    if not h:
        return True
    if h in _LOCAL_HOSTS or h.endswith(".local") or h.endswith(".localhost"):
        return True
    try:
        ip = ipaddress.ip_address(h)
    except ValueError:
        return False
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    )


def is_safe_media_url(url) -> bool:
    """True only for fetchable public http(s) media URLs.

    Rejects non-string input, non-http(s) schemes (file://, ftp://,
    javascript:, …), embedded userinfo, and local/private targets
    (localhost, LAN, link-local, metadata endpoints).
    """
    if not isinstance(url, str):
        return False
    text = url.strip()
    if not text or len(text) > 2048:
        return False
    try:
        parts = urlparse(text)
    except Exception:
        return False
    if parts.scheme.lower() not in _ALLOWED_MEDIA_SCHEMES:
        return False
    if parts.username or parts.password:
        return False
    host = parts.hostname or ""
    if not host:
        return False
    if _host_is_blocked(host):
        return False
    return True


def is_safe_profile_url(url) -> bool:
    """Site-profile override URLs obey the same SSRF policy as media."""
    return is_safe_media_url(url)


def sanitized_proxy(proxy):
    """Return a usable proxy string or "" (fail closed, never raises).

    Accepts http/https/socks{4,5,5h} with a parseable host. Auth userinfo
    (user:pass@host) is preserved — proxies legitimately carry credentials
    (including localhost ones such as Tor on 127.0.0.1:9050), so unlike
    media URLs there is no private-host block here, only scheme+host
    validation that drops pasted garbage before it can hijack traffic.
    """
    if not isinstance(proxy, str):
        return ""
    text = proxy.strip()
    if not text or len(text) > 1024:
        return ""
    try:
        parts = urlparse(text)
    except Exception:
        return ""
    if parts.scheme.lower() not in _ALLOWED_PROXY_SCHEMES:
        return ""
    if not parts.hostname:
        return ""
    return text


def safe_archive_path(candidate, data_dir: str | None) -> str | None:
    """Resolve an archive path strictly inside data_dir, else None.

    Mirrors clear_download_archive's real-path containment (symlink-safe).
    Never raises.
    """
    try:
        if not candidate or not isinstance(candidate, str):
            return None
        base = os.path.realpath(data_dir) if data_dir else None
        if not base:
            return None
        resolved = os.path.realpath(os.path.abspath(candidate))
        if os.path.commonpath([base, resolved]) != base:
            return None
        if os.path.isdir(resolved):
            return None
        return resolved
    except Exception:
        return None
