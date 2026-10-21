"""Keep yt-dlp's direct HTTP requests on the validated, pinned transport.

The user-selected media URL can cause yt-dlp to make many extractor, redirect,
and fragment requests. Checking only the URL before entering yt-dlp leaves a
DNS time-of-check/time-of-use gap. This module pins each direct HTTP(S) request
at the urllib connection boundary; explicitly configured proxies remain a
trusted egress choice because the proxy resolves or connects to the origin.
"""

from __future__ import annotations

import functools
import http.client
import urllib.error
from urllib.parse import urljoin, urlparse
from urllib.request import (
    DataHandler,
    HTTPDefaultErrorHandler,
    HTTPErrorProcessor,
    HTTPCookieProcessor,
    OpenerDirector,
    UnknownHandler,
)

from yt_dlp import YoutubeDL as _YoutubeDL
import yt_dlp.networking._urllib as _yt_urllib
from yt_dlp.networking._urllib import (
    HTTPHandler as _UrllibHTTPHandler,
    RedirectHandler as _UrllibRedirectHandler,
    UrllibRH as _UrllibRH,
)

from grablytic_engine import filename_guard
from grablytic_engine.url_guard import (
    _PINNED_REQUEST_ATTR,
    _PinnedHTTPConnection,
    _PinnedHTTPSConnection,
    _validated_socket_addresses,
    is_safe_media_url,
)

_ALLOWED_REDIRECT_SCHEMES = frozenset(("http", "https"))


def _socks_proxy_header(request):
    for name, value in getattr(request, "headers", {}).items():
        if str(name).lower() == "ytdl-socks-proxy":
            return value
    return None


def _trusted_socks_proxies(proxies):
    return frozenset(
        str(value)
        for key, value in (proxies or {}).items()
        if key != "no"
        and value
        and urlparse(str(value)).scheme.lower()
        in ("socks4", "socks4a", "socks5", "socks5h")
    )


class _PinnedUrllibHTTPHandler(_UrllibHTTPHandler):
    """Use vetted sockaddr records for direct HTTP(S), retaining proxy support."""

    def __init__(self, *, trusted_socks_proxies=(), **kwargs):
        self._trusted_socks_proxies = frozenset(trusted_socks_proxies)
        super().__init__(**kwargs)

    def _make_conn_class(self, base, request):
        socks_proxy = _socks_proxy_header(request)
        if socks_proxy:
            if socks_proxy not in self._trusted_socks_proxies:
                raise urllib.error.URLError("Untrusted SOCKS proxy marker")
            return super()._make_conn_class(base, request)
        if request.has_proxy():
            return super()._make_conn_class(base, request)

        addresses = getattr(request, _PINNED_REQUEST_ATTR, ())
        if not addresses:
            addresses = _validated_socket_addresses(request.get_full_url())
        if not addresses:
            raise urllib.error.URLError("Unsafe or unresolved yt-dlp destination")

        if issubclass(base, http.client.HTTPSConnection):
            return functools.partial(_PinnedHTTPSConnection, addresses=addresses)
        if issubclass(base, http.client.HTTPConnection):
            return functools.partial(_PinnedHTTPConnection, addresses=addresses)
        return super()._make_conn_class(base, request)


class _SafeUrllibRedirectHandler(_UrllibRedirectHandler):
    """Reject unsafe redirect schemes and pin each direct redirect hop."""

    def __init__(self, trusted_socks_proxies=()):
        self._trusted_socks_proxies = frozenset(trusted_socks_proxies)

    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        target = urljoin(request.full_url, new_url)
        try:
            parts = urlparse(target)
            safe_scheme = parts.scheme.lower() in _ALLOWED_REDIRECT_SCHEMES
        except Exception:
            safe_scheme = False

        if len(target) > 2048 or not safe_scheme:
            raise urllib.error.HTTPError(
                target, code, "Unsafe yt-dlp redirect target", headers, file_pointer
            )

        socks_proxy = _socks_proxy_header(request)
        if socks_proxy and socks_proxy not in self._trusted_socks_proxies:
            raise urllib.error.HTTPError(
                target, code, "Untrusted SOCKS proxy marker", headers, file_pointer
            )
        proxied = request.has_proxy() or bool(socks_proxy)
        if proxied:
            addresses = ()
            safe_target = is_safe_media_url(target)
        else:
            addresses = _validated_socket_addresses(target)
            safe_target = bool(addresses)

        if not safe_target:
            raise urllib.error.HTTPError(
                target,
                code,
                "Unsafe or unresolved yt-dlp redirect target",
                headers,
                file_pointer,
            )

        redirected = super().redirect_request(
            request, file_pointer, code, message, headers, target
        )
        if redirected is not None and addresses:
            setattr(redirected, _PINNED_REQUEST_ATTR, addresses)
        return redirected


class _GuardedUrllibRH(_UrllibRH):
    """A urllib-only HTTP handler; other transports could bypass socket pins."""

    RH_KEY = "Urllib"
    RH_NAME = "urllib (Grablytic pinned)"
    _SUPPORTED_URL_SCHEMES = ("http", "https", "data")

    def _create_instance(self, proxies, cookiejar, legacy_ssl_support=None):
        trusted_socks = _trusted_socks_proxies(proxies)
        opener = OpenerDirector()
        handlers = [
            _yt_urllib.ProxyHandler(proxies),
            _PinnedUrllibHTTPHandler(
                debuglevel=int(bool(self.verbose)),
                context=self._make_sslcontext(legacy_ssl_support=legacy_ssl_support),
                source_address=self.source_address,
                trusted_socks_proxies=trusted_socks,
            ),
            HTTPCookieProcessor(cookiejar),
            DataHandler(),
            UnknownHandler(),
            HTTPDefaultErrorHandler(),
            HTTPErrorProcessor(),
            _SafeUrllibRedirectHandler(trusted_socks),
        ]
        for handler in handlers:
            opener.add_handler(handler)
        opener.addheaders = []
        return opener


class GuardedYoutubeDL(_YoutubeDL):
    """YoutubeDL configured to use the pinned urllib transport exclusively."""

    def build_request_director(self, handlers, preferences=None):
        return super().build_request_director([_GuardedUrllibRH], preferences)

    def _prepare_filename(self, info_dict, *args, **kwargs):
        """Bound the generated name to what the filesystem can create.

        yt-dlp's ``trim_file_name`` counts characters and gives up on
        titles containing a dot (upstream issues #2314 / #5526 /
        #6974 / #12035 / #12386), so a Facebook reel with an emoji in
        the caption produced a 521-byte component and the kernel
        answered ``[Errno 36] File name too long``. Bound by BYTES,
        after the template has been expanded, so every template and
        every caller (download, thumbnail, info.json) is covered.
        """
        # Pass-through *args/**kwargs: this is a private yt-dlp hook, and
        # a pin bump must not crash on a changed signature.
        filename = super()._prepare_filename(info_dict, *args, **kwargs)
        if not filename or filename == "-":
            return filename
        return filename_guard.bound_filename(filename)
