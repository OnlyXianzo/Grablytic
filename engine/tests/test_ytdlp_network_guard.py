import http.client
import http.server
import socket
import threading
import urllib.error
import urllib.request

import pytest


@pytest.mark.unit
def test_guarded_ytdlp_uses_the_pinned_urllib_handler_only():
    from grablytic_engine.ytdlp_network import GuardedYoutubeDL

    with GuardedYoutubeDL({"quiet": True, "no_warnings": True}) as ydl:
        assert set(ydl._request_director.handlers) == {"Urllib"}
        handler = ydl._request_director.handlers["Urllib"]
        assert handler.__class__.__name__ == "_GuardedUrllibRH"
        assert handler._SUPPORTED_URL_SCHEMES == ("http", "https", "data")


@pytest.mark.unit
def test_untrusted_socks_marker_cannot_bypass_direct_address_validation():
    from grablytic_engine.ytdlp_network import _PinnedUrllibHTTPHandler

    handler = _PinnedUrllibHTTPHandler(trusted_socks_proxies=())
    request = urllib.request.Request("http://example.com/resource")
    request.add_header("Ytdl-socks-proxy", "socks5h://127.0.0.1:9050")

    with pytest.raises(urllib.error.URLError, match="Untrusted SOCKS proxy marker"):
        handler._make_conn_class(http.client.HTTPConnection, request)


@pytest.mark.unit
def test_guarded_ytdlp_connects_to_the_vetted_socket_and_keeps_host(monkeypatch):
    from grablytic_engine import url_guard as ug
    from grablytic_engine.ytdlp_network import GuardedYoutubeDL
    from yt_dlp.networking import Request

    received_hosts = []

    class _Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            received_hosts.append(self.headers.get("Host"))
            body = b"pinned-ytdlp-response"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]
    lookups = []
    record = (
        socket.AF_INET,
        socket.SOCK_STREAM,
        socket.IPPROTO_TCP,
        "",
        ("127.0.0.1", port),
    )
    original_is_blocked = ug._ip_is_blocked

    def _resolve(host, requested_port):
        lookups.append((host, requested_port))
        return [record]

    monkeypatch.setattr(ug, "_resolve_address_records", _resolve)
    monkeypatch.setattr(
        ug,
        "_ip_is_blocked",
        lambda ip: False if ip.is_loopback else original_is_blocked(ip),
    )
    try:
        with GuardedYoutubeDL({"quiet": True, "no_warnings": True}) as ydl:
            response = ydl.urlopen(Request(f"http://profiles.example:{port}/resource"))
            body = response.read()
            response.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    assert body == b"pinned-ytdlp-response"
    assert lookups == [("profiles.example", port)]
    assert received_hosts == [f"profiles.example:{port}"]


@pytest.mark.unit
def test_guarded_ytdlp_preserves_explicit_http_proxy_support():
    from grablytic_engine.ytdlp_network import GuardedYoutubeDL
    from yt_dlp.networking import Request

    proxy_targets = []

    class _Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            proxy_targets.append(self.path)
            body = b"proxy-response"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    proxy_url = f"http://127.0.0.1:{server.server_port}"
    try:
        with GuardedYoutubeDL(
            {
                "quiet": True,
                "no_warnings": True,
                "proxy": proxy_url,
            }
        ) as ydl:
            response = ydl.urlopen(Request("http://example.com/resource"))
            body = response.read()
            response.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    assert body == b"proxy-response"
    assert proxy_targets == ["http://example.com/resource"]


@pytest.mark.unit
def test_guarded_ytdlp_rejects_private_redirect_before_connect(monkeypatch):
    from grablytic_engine import url_guard as ug
    from grablytic_engine.ytdlp_network import GuardedYoutubeDL
    from yt_dlp.networking import Request
    from yt_dlp.networking.exceptions import HTTPError

    class _Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(302)
            self.send_header("Location", "http://10.0.0.1/private")
            self.end_headers()

        def log_message(self, *_args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]
    record = (
        socket.AF_INET,
        socket.SOCK_STREAM,
        socket.IPPROTO_TCP,
        "",
        ("127.0.0.1", port),
    )
    original_is_blocked = ug._ip_is_blocked
    lookups = []

    def _resolve(host, requested_port):
        lookups.append((host, requested_port))
        return [record]

    monkeypatch.setattr(ug, "_resolve_address_records", _resolve)
    monkeypatch.setattr(
        ug,
        "_ip_is_blocked",
        lambda ip: False if ip.is_loopback else original_is_blocked(ip),
    )
    try:
        with GuardedYoutubeDL({"quiet": True, "no_warnings": True}) as ydl:
            with pytest.raises(HTTPError):
                ydl.urlopen(Request(f"http://profiles.example:{port}/redirect"))
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    assert lookups == [("profiles.example", port)]
