"""Input guards for engine network/file sinks (SSRF + traversal + proxy).

Every IPC-controlled string used to reach the network (media URLs, site
profile override URLs) or the filesystem (download-archive path) or to
redirect all traffic (proxy) passes through here first. stdlib only.
Malformed values fail closed. DNS failure is sink-specific: profile fetches
fail closed, while user-selected media keeps the documented availability
policy. The profile and guarded yt-dlp transports pin validated direct socket
addresses and revalidate redirects; explicitly configured media proxies remain
a trusted egress boundary.
"""

import http.client
import ipaddress
import os
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urljoin, urlparse

_ALLOWED_MEDIA_SCHEMES = ("http", "https")
_ALLOWED_PROXY_SCHEMES = ("http", "https", "socks4", "socks5", "socks5h")

_LOCAL_HOSTS = {"localhost", "localhost.", "0.0.0.0", "::", "::1"}

# Cloud metadata endpoints, blocked BY NAME before any DNS lookup. The
# numeric address is blocked too (see _ip_is_blocked), but a hostname
# that resolves to it must never reach the resolver at all.
_METADATA_HOSTNAMES = frozenset(
    {
        "metadata",
        "metadata.google.internal",
        "metadata.goog",
        "instance-data",
        "instance-data.ec2.internal",
    }
)

# `socket.getaddrinfo` has no timeout, so resolver calls run in deadline-bound
# threads. A small semaphore limits stuck workers when the system resolver hangs.
_DNS_TIMEOUT_S = 5.0
_DNS_MAX_INFLIGHT = 4
_dns_resolution_slots = threading.BoundedSemaphore(_DNS_MAX_INFLIGHT)
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


def _embedded_address_is_blocked(ip) -> bool:
    for attribute in ("ipv4_mapped", "sixtofour", "teredo"):
        try:
            embedded = getattr(ip, attribute, None)
        except Exception:
            embedded = None
        if embedded is not None and _ip_is_blocked(embedded):
            return True
    return False


def _has_nonpublic_ip_flag(ip) -> bool:
    return any(
        (
            ip.is_private,
            ip.is_loopback,
            ip.is_link_local,
            ip.is_multicast,
            ip.is_reserved,
            ip.is_unspecified,
        )
    )


def _ipv6_address_is_blocked(ip) -> bool:
    if getattr(ip, "version", 4) != 6:
        return False
    return any(
        (
            ip in _IPV6_LINK_LOCAL,
            ip in _IPV6_UNIQUE_LOCAL,
            ip == _IPV6_LOOPBACK,
        )
    )


def _ip_is_blocked(ip) -> bool:
    """True when an ipaddress object targets a non-public range."""
    try:
        if _embedded_address_is_blocked(ip):
            return True
        if _has_nonpublic_ip_flag(ip) or ip == _CLOUD_METADATA_IPV4:
            return True
        return _ipv6_address_is_blocked(ip)
    except Exception:
        return True


def _normalize_host(host: str) -> str:
    return (host or "").strip().lower().rstrip(".")


def _host_is_immediately_blocked(host: str) -> bool:
    return (
        not host
        or "%" in host
        or host in _LOCAL_HOSTS
        or host.endswith(".local")
        or host.endswith(".localhost")
        or host in _METADATA_HOSTNAMES
    )


def _numeric_host_block_status(host: str) -> tuple[bool, bool]:
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None:
        return True, _ip_is_blocked(address)
    alternate = _alt_ipv4_to_int(host)
    if alternate is None:
        return False, False
    try:
        address = ipaddress.IPv4Address(alternate)
    except Exception:
        return True, True
    return True, _ip_is_blocked(address)


def _dns_host_is_blocked(host: str, fail_closed_dns: bool) -> bool:
    addresses = _resolve_host(host)
    if not addresses:
        return fail_closed_dns
    for address_text in addresses:
        try:
            address = ipaddress.ip_address(str(address_text).split("%", 1)[0])
        except ValueError:
            return True
        if _ip_is_blocked(address):
            return True
    return False


def _host_is_blocked(host: str, *, fail_closed_dns: bool) -> bool:
    normalized = _normalize_host(host)
    if _host_is_immediately_blocked(normalized):
        return True
    is_numeric, blocked = _numeric_host_block_status(normalized)
    if is_numeric:
        return blocked
    return _dns_host_is_blocked(normalized, fail_closed_dns)


def _resolve_address_records(host: str, port: int):
    """Resolve once with a deadline, preserving the exact socket addresses.

    A caller which uses the returned records for the connect must not perform
    another hostname lookup; otherwise the validation and connection can see
    different DNS answers.
    """
    if not _dns_resolution_slots.acquire(blocking=False):
        return []
    found = []
    done = threading.Event()

    def _resolve():
        try:
            found.extend(socket.getaddrinfo(host, port, type=socket.SOCK_STREAM))
        except Exception:
            pass
        finally:
            _dns_resolution_slots.release()
            done.set()

    try:
        thread = _real_thread(target=_resolve, daemon=True)
        thread.start()
    except Exception:
        _dns_resolution_slots.release()
        return []
    # Read the budget at call time so tests and platform policy can override it.
    if not done.wait(_DNS_TIMEOUT_S):
        return []
    return list(found)


def _resolve_host(host: str) -> list[str]:
    """Resolve `host` to IP strings, bounded in time; return [] on failure."""
    addresses = []
    for record in _resolve_address_records(host, 80):
        try:
            addresses.append(str(record[4][0]))
        except (IndexError, TypeError):
            continue
    return addresses


def _media_url_host(url):
    if not isinstance(url, str):
        return None
    text = url.strip()
    if not text or len(text) > 2048:
        return None
    try:
        parts = urlparse(text)
    except Exception:
        return None
    if parts.scheme.lower() not in _ALLOWED_MEDIA_SCHEMES:
        return None
    if parts.username or parts.password:
        return None
    return parts.hostname or None


def is_safe_media_url(url) -> bool:
    """Validate a public HTTP(S) media URL before yt-dlp use.

    DNS failures remain available to yt-dlp's retry policy; this check is
    not a DNS-pinning guarantee for later extractor requests.
    """
    host = _media_url_host(url)
    if host is None:
        return False
    return not _host_is_blocked(host, fail_closed_dns=False)


def is_safe_profile_url(url) -> bool:
    """Fail closed on DNS errors for control-plane profile URLs."""
    host = _media_url_host(url)
    if host is None:
        return False
    return not _host_is_blocked(host, fail_closed_dns=True)


_MAX_PINNED_DNS_ANSWERS = 32
_PINNED_REQUEST_ATTR = "_grablytic_vetted_addresses"


def _pinned_url_input_is_valid(url) -> bool:
    return isinstance(url, str) and bool(url) and len(url) <= 2048


def _pinned_url_parts(parts):
    scheme = parts.scheme.lower()
    host = parts.hostname or ""
    port = parts.port or (443 if scheme == "https" else 80)
    if (
        scheme not in _ALLOWED_MEDIA_SCHEMES
        or not host
        or parts.username
        or parts.password
    ):
        return None
    return host, port


def _parse_pinned_url(url: str):
    if not _pinned_url_input_is_valid(url):
        return None
    try:
        parts = urlparse(url)
    except Exception:
        return None
    parsed_parts = _pinned_url_parts(parts)
    if parsed_parts is None:
        return None
    host, port = parsed_parts
    return host, _normalize_host(host), port


def _pinned_host_is_clean(host: str) -> bool:
    return not _host_is_immediately_blocked(host)


def _literal_socket_record(host: str, port: int):
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is None:
        alternate = _alt_ipv4_to_int(host)
        if alternate is None:
            return None
        address = ipaddress.IPv4Address(alternate)
    if _ip_is_blocked(address):
        return ()
    if address.version == 4:
        sockaddr = (str(address), port)
        family = socket.AF_INET
    else:
        sockaddr = (str(address), port, 0, 0)
        family = socket.AF_INET6
    return ((family, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", sockaddr),)


def _filter_resolved_records(records):
    vetted = []
    seen = set()
    for record in records:
        try:
            family, socktype, protocol, canonical_name, sockaddr = record
        except (ValueError, TypeError):
            return ()
        if (
            family not in (socket.AF_INET, socket.AF_INET6)
            or socktype != socket.SOCK_STREAM
        ):
            continue
        if not isinstance(sockaddr, tuple) or not sockaddr:
            return ()
        try:
            address = ipaddress.ip_address(str(sockaddr[0]).split("%", 1)[0])
        except (ValueError, TypeError, IndexError):
            return ()
        if _ip_is_blocked(address):
            return ()
        key = (family, socktype, protocol, sockaddr)
        if key not in seen:
            seen.add(key)
            vetted.append((family, socktype, protocol, canonical_name, sockaddr))
    return tuple(vetted)


def _resolve_and_filter_addresses(host: str, port: int):
    records = _resolve_address_records(host, port)
    if not records or len(records) > _MAX_PINNED_DNS_ANSWERS:
        return ()
    return _filter_resolved_records(records)


def _validated_socket_addresses(url: str):
    """Resolve one HTTP(S) destination, reject unsafe answers, and retain pins."""
    parsed = _parse_pinned_url(url)
    if parsed is None:
        return ()
    host, normalized, port = parsed
    if not _pinned_host_is_clean(normalized):
        return ()
    literal_records = _literal_socket_record(normalized, port)
    if literal_records is not None:
        return literal_records
    return _resolve_and_filter_addresses(host, port)


def get_global_default_timeout():
    """Return the sentinel used by HTTP connections for an unspecified timeout."""
    return socket._GLOBAL_DEFAULT_TIMEOUT


def _connection_deadline(timeout):
    if isinstance(timeout, (int, float)):
        return time.monotonic() + timeout
    return None


def _remaining_connection_timeout(timeout, deadline):
    if deadline is None:
        return timeout
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise socket.timeout("profile connection timed out")
    return remaining


def _close_failed_connection(connection) -> None:
    if connection is None:
        return
    try:
        connection.close()
    except OSError:
        pass


def _connect_one_vetted_address(record, timeout, deadline, source_address):
    family, socktype, protocol, _canonical_name, sockaddr = record
    connection = None
    try:
        remaining = _remaining_connection_timeout(timeout, deadline)
        connection = socket.socket(family, socktype, protocol)
        if timeout is not get_global_default_timeout():
            connection.settimeout(remaining)
        if source_address is not None:
            raise OSError("Pinned connections do not accept a source address")
        connection.connect(sockaddr)
        try:
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        return connection
    except OSError:
        _close_failed_connection(connection)
        raise


def _connect_vetted_addresses(addresses, timeout, source_address=None):
    """Connect only to vetted addresses within one total connection budget."""
    deadline = _connection_deadline(timeout)
    errors = []
    for record in addresses:
        try:
            return _connect_one_vetted_address(
                record, timeout, deadline, source_address
            )
        except OSError as exc:
            errors.append(exc)
            if deadline is not None and deadline <= time.monotonic():
                break
    if errors:
        raise errors[-1]
    raise OSError("No vetted public socket address is available")


class _PinnedHTTPConnection(http.client.HTTPConnection):
    def __init__(self, host, addresses, *args, **kwargs):
        self._vetted_addresses = addresses
        super().__init__(host, *args, **kwargs)

    def connect(self):
        if self._tunnel_host:
            raise OSError("Proxies are disabled for pinned profile requests")
        self.sock = _connect_vetted_addresses(
            self._vetted_addresses, self.timeout, self.source_address
        )


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, addresses, *args, **kwargs):
        self._vetted_addresses = addresses
        if kwargs.get("context") is None:
            kwargs["context"] = ssl.create_default_context()
        context = kwargs["context"]
        if (
            not getattr(context, "check_hostname", False)
            or getattr(context, "verify_mode", ssl.CERT_NONE) != ssl.CERT_REQUIRED
        ):
            raise ValueError(
                "Pinned HTTPS requires certificate and hostname validation"
            )
        super().__init__(host, *args, **kwargs)

    def connect(self):
        if self._tunnel_host:
            raise OSError("Proxies are disabled for pinned profile requests")
        raw_socket = _connect_vetted_addresses(
            self._vetted_addresses, self.timeout, self.source_address
        )
        try:
            # Keep the original DNS name for SNI and certificate validation;
            # only the TCP destination is replaced by the vetted socket address.
            self.sock = self._context.wrap_socket(raw_socket, server_hostname=self.host)
        except Exception:
            raw_socket.close()
            raise


def _request_addresses(request):
    addresses = getattr(request, _PINNED_REQUEST_ATTR, ())
    if not addresses:
        raise urllib.error.URLError("Request has no validated destination address")
    return addresses


class _PinnedHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, request):
        addresses = _request_addresses(request)

        def connection(host, **kwargs):
            return _PinnedHTTPConnection(host, addresses, **kwargs)

        return self.do_open(connection, request)


class _PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, debuglevel=0, context=None, check_hostname=None):
        if check_hostname is False:
            raise ValueError("Pinned HTTPS requires hostname validation")
        context = context or ssl.create_default_context()
        if not context.check_hostname or context.verify_mode != ssl.CERT_REQUIRED:
            raise ValueError(
                "Pinned HTTPS requires certificate and hostname validation"
            )
        super().__init__(debuglevel, context, check_hostname=True)

    def https_open(self, request):
        addresses = _request_addresses(request)

        def connection(host, **kwargs):
            return _PinnedHTTPSConnection(host, addresses, **kwargs)

        return self.do_open(connection, request, context=self._context)


class _SafeProfileRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Validate and pin each redirect destination before urllib follows it."""

    max_redirections = 5
    max_repeats = 3

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        target = urljoin(request.full_url, new_url)
        addresses = _validated_socket_addresses(target)
        if not addresses:
            raise urllib.error.HTTPError(
                target,
                code,
                "Unsafe or unresolved profile redirect target",
                headers,
                file_pointer,
            )
        redirected = super().redirect_request(
            request, file_pointer, code, message, headers, target
        )
        if redirected is not None:
            setattr(redirected, _PINNED_REQUEST_ATTR, addresses)
        return redirected


def pinned_urlopen(request, timeout=5):
    """Open a profile URL through a proxy-free, DNS-pinned urllib opener.

    The URL is resolved once per hop. Every returned address must be public;
    the same socket address is used for the actual connect, while HTTPS keeps
    the original hostname for SNI and certificate checks.
    """
    if isinstance(request, str):
        request = urllib.request.Request(request)
    addresses = _validated_socket_addresses(request.full_url)
    if not addresses:
        raise urllib.error.URLError("Unsafe or unresolved profile destination")
    setattr(request, _PINNED_REQUEST_ATTR, addresses)
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        _PinnedHTTPHandler(),
        _PinnedHTTPSHandler(),
        _SafeProfileRedirectHandler(),
    )
    return opener.open(request, timeout=timeout)


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
