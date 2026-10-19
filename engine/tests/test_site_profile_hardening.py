"""Remote site profiles are UNTRUSTED INPUT.

A site-profile payload is fetched from a URL the user points at, and its
`format_code` / `container` reach yt-dlp verbatim. These tests pin the
gate: amplifying selectors are rejected, the container name comes from an
allowlist, an unsafe entry is dropped WHOLE, and a failed fetch never
poisons the cache.
"""

import http.server
import json
import os
import socket
import threading
import urllib.error

import pytest


def _sp():
    import grablytic_engine.site_profiles as sp_mod

    return sp_mod


def _fs():
    import grablytic_engine.format_selector as fs_mod

    return fs_mod


def _cfg():
    import grablytic_engine.config as cfg_mod

    return cfg_mod


@pytest.fixture(autouse=True)
def _reset_cache():
    sp = _sp()
    sp.reset_site_profiles_cache()
    yield
    sp.reset_site_profiles_cache()


@pytest.mark.unit
def test_pinned_profile_connection_uses_the_validated_address(monkeypatch):
    from grablytic_engine import url_guard as ug

    received_hosts = []

    class _Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            received_hosts.append(self.headers.get("Host"))
            body = b'{"Good":{"format_code":"best","container":"mp4"}}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            """Suppress default HTTP access logging in tests."""

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
    original_blocked = ug._ip_is_blocked

    def _resolve(host, requested_port):
        lookups.append((host, requested_port))
        return [record]

    monkeypatch.setattr(ug, "_resolve_address_records", _resolve)
    monkeypatch.setattr(
        ug,
        "_ip_is_blocked",
        lambda ip: False if ip.is_loopback else original_blocked(ip),
    )
    try:
        with ug.pinned_urlopen(
            f"http://profiles.example:{port}/profiles.json", timeout=2
        ) as response:
            assert response.read(1024).startswith(b'{"Good"')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    assert lookups == [("profiles.example", port)]
    assert received_hosts == [f"profiles.example:{port}"]


@pytest.mark.unit
def test_pinned_connection_shares_one_total_connect_timeout(monkeypatch):
    from grablytic_engine import url_guard as ug

    now = [100.0]
    timeouts = []

    class _Socket:
        @staticmethod
        def settimeout(value):
            timeouts.append(value)

        @staticmethod
        def connect(_address):
            now[0] += 0.6
            raise socket.timeout("mocked connect timeout")

        @staticmethod
        def close():
            """The fake socket has no resources to release."""

    monkeypatch.setattr(ug.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(ug.socket, "socket", lambda *_args: _Socket())
    addresses = (
        (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443)),
        (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443)),
    )

    with pytest.raises(socket.timeout, match="mocked connect timeout"):
        ug._connect_vetted_addresses(addresses, 1.0)

    assert timeouts == pytest.approx([1.0, 0.4])


@pytest.mark.unit
def test_pinned_https_handler_keeps_certificate_validation_enabled():
    import ssl

    from grablytic_engine import url_guard as ug

    context = ug._PinnedHTTPSHandler()._context
    assert context.check_hostname is True
    assert context.verify_mode == ssl.CERT_REQUIRED


@pytest.mark.unit
def test_https_connection_keeps_original_hostname_for_tls(monkeypatch):
    import ssl

    from grablytic_engine import url_guard as ug

    seen = {}

    class _Socket:
        @staticmethod
        def close():
            """The fake socket has no resources to release."""

    class _Context:
        check_hostname = True
        verify_mode = ssl.CERT_REQUIRED

        @staticmethod
        def wrap_socket(raw_socket, *, server_hostname):
            seen["socket"] = raw_socket
            seen["server_hostname"] = server_hostname
            return raw_socket

    raw_socket = _Socket()
    monkeypatch.setattr(ug, "_connect_vetted_addresses", lambda *args: raw_socket)
    connection = ug._PinnedHTTPSConnection(
        "profiles.example",
        ((socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443)),),
        context=_Context(),
    )
    connection.connect()
    connection.close()

    assert seen == {"socket": raw_socket, "server_hostname": "profiles.example"}


@pytest.mark.unit
def test_profile_redirect_to_private_address_is_rejected(monkeypatch):
    from grablytic_engine import url_guard as ug

    class _Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(302)
            self.send_header("Location", "http://10.0.0.1/private")
            self.end_headers()

        def log_message(self, *_args):
            """Suppress default HTTP access logging in tests."""

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
    original_blocked = ug._ip_is_blocked
    monkeypatch.setattr(ug, "_resolve_address_records", lambda *_args: [record])
    monkeypatch.setattr(
        ug,
        "_ip_is_blocked",
        lambda ip: False if ip.is_loopback else original_blocked(ip),
    )
    try:
        with pytest.raises(
            urllib.error.HTTPError, match="Unsafe or unresolved profile redirect"
        ):
            ug.pinned_urlopen(f"http://profiles.example:{port}/redirect", timeout=2)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


@pytest.mark.unit
def test_oversized_profile_response_keeps_the_existing_cache(monkeypatch):
    sp = _sp()
    good = {"Good": {"format_code": "best", "container": "mp4"}}
    sp._set_site_profiles_cache(good)
    requested_sizes = []

    class _Resp:
        @staticmethod
        def read(size=-1):
            requested_sizes.append(size)
            return b" " * size

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    monkeypatch.setattr(sp, "urlopen", lambda *a, **k: _Resp())
    assert sp.load_site_profiles_from_url("https://example.com/profiles.json") == good
    assert sp._get_site_profiles_cache() == good
    assert requested_sizes == [sp._MAX_PROFILE_BYTES + 1]


# ─────────────────────────────────────────────────── format expression gate


@pytest.mark.unit
@pytest.mark.parametrize(
    "expr",
    [
        "all",
        "allvideo",
        "allformats",
        "all*",
        "mergeall",
        "bestvideo+all",
        "best/all",
        "bestaudio[ext=m4a]/all",
    ],
)
def test_amplifying_format_expressions_are_rejected(expr):
    """`all`/`mergeall` select every format separately — one file each."""
    assert _fs().is_safe_format_expression(expr) is False


@pytest.mark.unit
@pytest.mark.parametrize(
    "expr",
    [
        "best",
        "251",
        "bestvideo[height<=1080]+bestaudio",
        "bestvideo*[height<=1080][aspect_ratio>=1]+bestaudio[ext=m4a]/best",
        "bestaudio[ext=m4a]/bestaudio",
        "18+m140",
    ],
)
def test_ordinary_format_expressions_are_accepted(expr):
    assert _fs().is_safe_format_expression(expr) is True


@pytest.mark.unit
def test_overlong_format_expression_is_rejected():
    assert _fs().is_safe_format_expression("b" * 513) is False
    assert _fs().is_safe_format_expression("b" * 512) is True


@pytest.mark.unit
def test_control_characters_are_rejected():
    assert _fs().is_safe_format_expression("best\x00video") is False
    assert _fs().is_safe_format_expression("best\nvideo") is False


@pytest.mark.unit
def test_non_string_format_expression_is_rejected():
    for bad in (None, 123, [], {}):
        assert _fs().is_safe_format_expression(bad) is False


@pytest.mark.unit
def test_empty_format_expression_is_rejected():
    assert _fs().is_safe_format_expression("") is False


# ─────────────────────────────────────────────────────── container allowlist


@pytest.mark.unit
def test_container_allowlist():
    cfg = _cfg()
    assert cfg.is_safe_container("mp4") is True
    assert cfg.is_safe_container("MKV") is True
    assert cfg.is_safe_container("m4a") is True
    assert cfg.is_safe_container("exe") is False
    assert cfg.is_safe_container("mp4/../../etc") is False
    assert cfg.is_safe_container(None) is False


@pytest.mark.unit
def test_sanitize_container_fails_closed():
    cfg = _cfg()
    assert cfg.sanitize_container("webm") == "webm"
    assert cfg.sanitize_container("evil") == "mkv"
    assert cfg.sanitize_container(None) == "mkv"
    assert cfg.sanitize_container(123) == "mkv"


# ────────────────────────────────────────────────────────── profile filter


@pytest.mark.unit
def test_sanitize_profiles_drops_unsafe_entries_wholesale():
    profiles = {
        "Good": {"format_code": "best", "container": "mp4", "extra": 1},
        "Amplifying": {"format_code": "all", "container": "mp4"},
        "BadContainer": {"format_code": "best", "container": "../../evil"},
    }
    safe = _sp().sanitize_profiles(profiles)
    assert set(safe) == {"Good"}
    # The surviving entry keeps its unknown keys (filter, not projection).
    assert safe["Good"]["extra"] == 1


@pytest.mark.unit
def test_sanitize_profiles_keeps_entries_without_format_code():
    profiles = {"Plain": {"container": "mp4", "audio_only": True}}
    assert set(_sp().sanitize_profiles(profiles)) == {"Plain"}


@pytest.mark.unit
def test_sanitize_profiles_rejects_non_dicts():
    assert _sp().sanitize_profiles(None) == {}
    assert _sp().sanitize_profiles([]) == {}
    assert _sp().sanitize_profiles("nope") == {}


@pytest.mark.unit
def test_builtin_profiles_are_all_safe():
    """The shipped defaults must survive the gate they are checked by."""
    defaults = dict(_sp()._DEFAULT_PROFILES)
    assert _sp().sanitize_profiles(defaults).keys() == defaults.keys()


# ─────────────────────────────────────────────────────────────── cache state


@pytest.mark.unit
def test_failed_fetch_does_not_poison_the_cache(monkeypatch):
    sp = _sp()
    good = {"Good": {"format_code": "best", "container": "mp4"}}
    sp._set_site_profiles_cache(good)

    def _boom(*args, **kwargs):
        raise OSError("network down")

    monkeypatch.setattr(sp, "urlopen", _boom)
    result = sp.load_site_profiles_from_url("https://example.com/p.json")
    # The previous (good) cache survived the failed fetch.
    assert result == good
    assert sp._get_site_profiles_cache() == good


@pytest.mark.unit
def test_empty_remote_payload_keeps_the_previous_cache(monkeypatch):
    sp = _sp()
    good = {"Good": {"format_code": "best", "container": "mp4"}}
    sp._set_site_profiles_cache(good)

    class _Resp:
        @staticmethod
        def read(size=-1):
            return b"{}"

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(sp, "urlopen", lambda *a, **k: _Resp())
    result = sp.load_site_profiles_from_url("https://example.com/p.json")
    assert result == good
    assert sp._get_site_profiles_cache() == good


@pytest.mark.unit
def test_unsafe_remote_payload_is_not_cached(monkeypatch):
    sp = _sp()
    sp._set_site_profiles_cache(None)
    payload = json.dumps({"Evil": {"format_code": "all"}}).encode()

    class _Resp:
        @staticmethod
        def read(size=-1):
            return payload[:size] if size >= 0 else payload

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(sp, "urlopen", lambda *a, **k: _Resp())
    result = sp.load_site_profiles_from_url("https://example.com/p.json")
    assert "Evil" not in result


@pytest.mark.unit
def test_site_profiles_status_and_reset():
    sp = _sp()
    sp.reset_site_profiles_cache()
    status = sp.site_profiles_status()
    assert status["source"] == "builtin"
    sp._set_site_profiles_cache({"A": {"format_code": "best"}})
    status = sp.site_profiles_status()
    assert status["loaded"] is True
    assert status["count"] == 1
    sp.reset_site_profiles_cache()
    assert sp.site_profiles_status()["loaded"] is False


# ─────────────────────────────────────────────────────────── disk persistence


@pytest.mark.unit
def test_save_profiles_is_atomic_and_round_trips(tmp_path):
    sp = _sp()
    path = str(tmp_path / "profiles.json")
    profiles = {"A": {"format_code": "best", "container": "mp4"}}
    assert sp.save_profiles_to_disk(profiles, path) is True
    assert sp.load_profiles_from_disk(path) == profiles
    # No temp file left behind.
    leftovers = [p for p in os.listdir(str(tmp_path)) if p != "profiles.json"]
    assert leftovers == []


@pytest.mark.unit
def test_corrupt_profile_file_yields_an_empty_dict(tmp_path):
    sp = _sp()
    path = tmp_path / "broken.json"
    path.write_text("{not json", encoding="utf-8")
    assert sp.load_profiles_from_disk(str(path)) == {}


@pytest.mark.unit
def test_missing_profile_file_yields_an_empty_dict(tmp_path):
    sp = _sp()
    assert sp.load_profiles_from_disk(str(tmp_path / "nope.json")) == {}
