"""Input guards for engine network/file sinks (SSRF + traversal + proxy).

Every IPC-controlled string used to reach the network (media URLs, site
profile override URLs) or the filesystem (download-archive path) or to
redirect all traffic (proxy) passes through here first. stdlib only.
Never raises: validators return ""/None on garbage (fail closed).
"""

import ipaddress
import os
import socket
import threading
from urllib.parse import urlparse

_ALLOWED_MEDIA_SCHEMES = ("http", "https")
_ALLOWED_PROXY_SCHEMES = ("http", "https", "socks4", "socks5", "socks5h")

_LOCAL_HOSTS = {"localhost", "localhost.", "0.0.0.0", "::", "::1"}

# Cloud metadata endpoints, blocked BY NAME before any DNS lookup. The
# numeric address is blocked too (see _ip_is_blocked), but a hostname
# that resolves to it must never reach the resolver at all.
_METADATA_HOSTNAMES = frozenset({
    "metadata",
    "metadata.google.internal",
    "metadata.goog",
    "instance-data",
    "instance-data.ec2.internal",
})

# DNS lookup budget. `socket.getaddrinfo` takes no timeout, so the lookup
# runs in a thread with a deadline.
_DNS_TIMEOUT_S = 5.0
# Captured at import: the test suite patches `threading.Thread` globally
# and the resolver must still be able to run.
_real_thread = threading.Thread

_CLOUD_METADATA_IPV4 = ipaddress.ip_address("169.254.169.254")
_IPV6_LINK_LOCAL = ipaddress.ip_network("fe80::/10")
_IPV6_UNIQUE_LOCAL = ipaddress.ip_network("fc00::/7")
_IPV6_LOOPBACK = ipaddress.ip_address("::1")


def _parse_numeric_part(part: str) -> int | None:
    """Parse one numeric IPv4 part allowing decimal/octal/hex.

    - ``0x..``/``0X..`` → hex, ``0o..`` → octal,
    - leading-``0`` with only 0-7 digits → octal (``0177`` == 127),
    - otherwise decimal (``09`` falls back to decimal, matching browsers).
    Returns None when the part is not numeric.
    """
    p = (part or "").strip()
    if not p:
        return None
    try:
        low = p.lower()
        if low.startswith("0x"):
            if len(p) <= 2:
                return None
            return int(p, 16)
        if low.startswith("0o"):
            if len(p) <= 2:
                return None
            digits = p[2:]
            if not digits or any(c not in "01234567" for c in digits):
                return None
            return int(digits, 8)
        if len(p) > 1 and p.startswith("0") and all(c in "01234567" for c in p):
            return int(p, 8)
        if p.isascii() and p.isdigit():
            return int(p, 10)
        return None
    except ValueError:
        return None


def _alt_ipv4_to_int(host: str) -> int | None:
    """Canonicalize alternative IPv4 literals to a 32-bit int.

    Covers dotted decimal/octal/hex per-part (``0177.0.0.1``,
    ``0x7f.0.0.1``), bare decimal/hex/octal ints (``2130706433``,
    ``0x7f000001``), and short inet_aton forms (``127.1``,
    ``10.1``). Returns None when the host is not such a literal.
    """
    h = (host or "").strip().lower()
    if not h:
        return None
    try:
        if "." not in h:
            # Bare integer form.
            n = _parse_numeric_part(h)
            if n is None:
                return None
            if 0 <= n <= 0xFFFFFFFF:
                return n
            return None
        parts = h.split(".")
        if not 2 <= len(parts) <= 4:
            return None
        nums: list[int] = []
        for part in parts:
            n = _parse_numeric_part(part)
            if n is None:
                return None
            nums.append(n)
        if len(nums) == 4:
            if any(n < 0 or n > 255 for n in nums):
                return None
            return (nums[0] << 24) | (nums[1] << 16) | (nums[2] << 8) | nums[3]
        if len(nums) == 3:
            if nums[0] < 0 or nums[0] > 255 or nums[1] < 0 or nums[1] > 255:
                return None
            if nums[2] < 0 or nums[2] > 65535:
                return None
            return (nums[0] << 24) | (nums[1] << 16) | nums[2]
        # len == 2: a.b → a is 8 bits, b is 24 bits.
        if nums[0] < 0 or nums[0] > 255:
            return None
        if nums[1] < 0 or nums[1] > 16777215:
            return None
        return (nums[0] << 24) | nums[1]
    except Exception:
        return None


def _ip_is_blocked(ip) -> bool:
    """True when an ipaddress object targets a non-public range."""
    try:
        # Unwrap embedded IPv4 first (IPv4-mapped IPv6 ::ffff:a.b.c.d,
        # 6to4, Teredo) so ::ffff:127.0.0.1 cannot smuggle loopback.
        for attr in ("ipv4_mapped", "sixtofour", "teredo"):
            try:
                embedded = getattr(ip, attr, None)
            except Exception:
                embedded = None
            if embedded is not None and _ip_is_blocked(embedded):
                return True
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
        ):
            return True
        # Explicit per-policy pins (redundant with the flags above on most
        # Pythons, but pinned so behaviour can't drift with ipaddress data):
        # cloud-metadata endpoint + IPv6 link-local / unique-local / loopback.
        if ip == _CLOUD_METADATA_IPV4:
            return True
        if getattr(ip, "version", 4) == 6:
            if ip in _IPV6_LINK_LOCAL or ip in _IPV6_UNIQUE_LOCAL:
                return True
            if ip == _IPV6_LOOPBACK:
                return True
        return False
    except Exception:
        # Fail closed: an uninspectable address never counts as public.
        return True


def _host_is_blocked(host: str) -> bool:
    h = (host or "").strip().lower().rstrip(".")
    # Strip IPv6 zone id (%eth0); DNS names never legitimately contain %.
    if "%" in h:
        h = h.split("%", 1)[0]
        if not h:
            return True
    if not h:
        return True
    if h in _LOCAL_HOSTS or h.endswith(".local") or h.endswith(".localhost"):
        return True
    # 1) Direct literals: dotted decimal, IPv6, IPv4-mapped IPv6.
    try:
        ip = ipaddress.ip_address(h)
    except ValueError:
        ip = None
    if ip is not None:
        return _ip_is_blocked(ip)
    # 2) Alternative IPv4 encodings → canonical int BEFORE any allow check.
    try:
        alt = _alt_ipv4_to_int(h)
    except Exception:
        alt = None
    if alt is not None:
        try:
            return _ip_is_blocked(ipaddress.IPv4Address(alt))
        except Exception:
            return True
    # 3) Hostname: DNS-resolve and reject if ANY result is non-public
    # (DNS-rebinding guard: 127.0.0.1.nip.io, 169.254.169.254.nip.io, …).
    if h in _METADATA_HOSTNAMES:
        return True
    ips = _resolve_host(h)
    if not ips:
        # FAIL CLOSED. We could not prove the host is public, and this
        # guard is the only thing between a user-supplied URL and the
        # device's private network. Failing open here is precisely the
        # window an attacker needs: a name that does not resolve now
        # resolves to 127.0.0.1 later (DNS rebinding).
        return True
    for ip_str in ips:
        if "%" in str(ip_str):
            ip_str = str(ip_str).split("%", 1)[0]
        try:
            rip = ipaddress.ip_address(ip_str)
        except ValueError:
            continue
        if _ip_is_blocked(rip):
            return True
        if str(ip_str) == "169.254.169.254":
            return True
    return False



def _resolve_host(host: str) -> list[str]:
    """Resolve `host` to a list of IP strings, bounded in time.

    `socket.getaddrinfo` accepts no timeout, so the lookup runs in a REAL
    thread with a deadline — a hung resolver would otherwise hang the
    guard (and the whole download) forever.

    Returns [] on timeout, resolver error or an empty answer. The caller
    then fails CLOSED.
    """
    found: list[str] = []
    done = threading.Event()

    def _resolve():
        try:
            infos = socket.getaddrinfo(host, 80, type=socket.SOCK_STREAM)
        except Exception:
            infos = []
        for info in infos or []:
            try:
                sockaddr = info[4] if len(info) > 4 else None
                if sockaddr:
                    found.append(str(sockaddr[0]))
            except Exception:
                continue
        done.set()

    try:
        t = _real_thread(target=_resolve, daemon=True)
        t.start()
    except Exception:
        return []
    # `_DNS_TIMEOUT_S` is read at CALL time on purpose: a default argument
    # would bind it at def time, and patching the module global would
    # then have no effect.
    if not done.wait(_DNS_TIMEOUT_S):
        return []
    return found

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
