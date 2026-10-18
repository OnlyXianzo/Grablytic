"""The SSRF guard must fail CLOSED and must not hang.

The guard used to return "not blocked" on any resolver failure, which
is exactly the window a DNS-rebinding attacker needs. DNS resolution is
now bounded by a deadline and a failed lookup BLOCKS the URL.
"""

import socket

import pytest


def _ug():
    import grablytic_engine.url_guard as ug
    return ug


@pytest.mark.unit
def test_dns_failure_fails_closed(monkeypatch):
    ug = _ug()

    def _raise(host, port, *args, **kwargs):
        raise socket.gaierror("mocked DNS outage")

    monkeypatch.setattr(socket, "getaddrinfo", _raise)
    # We could not prove the host is public -> block.
    assert ug.is_safe_media_url("https://example.com/video") is False


@pytest.mark.unit
def test_empty_dns_answer_fails_closed(monkeypatch):
    ug = _ug()
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [])
    assert ug.is_safe_media_url("https://example.com/video") is False


@pytest.mark.unit
def test_dns_timeout_fails_closed(monkeypatch):
    ug = _ug()

    def _hang(host, port, *args, **kwargs):
        import time
        time.sleep(5)

    monkeypatch.setattr(socket, "getaddrinfo", _hang)
    monkeypatch.setattr(ug, "_DNS_TIMEOUT_S", 0.2)
    assert ug.is_safe_media_url("https://example.com/video") is False


@pytest.mark.unit
def test_metadata_hostnames_are_blocked_by_name(monkeypatch):
    ug = _ug()
    called = []

    def _spy(host, port, *args, **kwargs):
        called.append(host)
        return []

    monkeypatch.setattr(socket, "getaddrinfo", _spy)
    for host in ("metadata.google.internal", "metadata",
                 "instance-data.ec2.internal"):
        assert ug.is_safe_media_url(f"http://{host}/latest/meta-data/") is False
    # Blocked BEFORE the resolver was consulted.
    assert called == []


@pytest.mark.unit
def test_resolver_returns_the_resolved_addresses(monkeypatch):
    ug = _ug()
    monkeypatch.setattr(
        socket, "getaddrinfo",
        lambda host, port, *a, **k: [
            (2, 1, 6, "", ("93.184.216.34", port or 80)),
        ],
    )
    assert ug._resolve_host("example.com") == ["93.184.216.34"]


@pytest.mark.unit
def test_resolver_returns_empty_on_error(monkeypatch):
    ug = _ug()

    def _raise(*args, **kwargs):
        raise OSError("boom")

    monkeypatch.setattr(socket, "getaddrinfo", _raise)
    assert ug._resolve_host("example.com") == []


@pytest.mark.unit
def test_rebinding_to_loopback_is_still_blocked(monkeypatch):
    ug = _ug()
    monkeypatch.setattr(
        socket, "getaddrinfo",
        lambda host, port, *a, **k: [
            (2, 1, 6, "", ("127.0.0.1", port or 80)),
        ],
    )
    assert ug.is_safe_media_url("https://rebind.test/video") is False


@pytest.mark.unit
def test_public_address_is_allowed(monkeypatch):
    ug = _ug()
    monkeypatch.setattr(
        socket, "getaddrinfo",
        lambda host, port, *a, **k: [
            (2, 1, 6, "", ("93.184.216.34", port or 80)),
        ],
    )
    assert ug.is_safe_media_url("https://example.com/video") is True
