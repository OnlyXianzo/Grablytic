"""Profile-control fetches fail closed on DNS errors; media keeps the documented availability policy."""

import socket
import threading
import urllib.error

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
    # Control-plane profile retrieval must not continue when DNS is unknown.
    assert ug.is_safe_profile_url("https://example.com/profiles.json") is False
    # Media is user-selected; preserve availability when DNS has no answer.
    assert ug.is_safe_media_url("https://example.com/video") is True


@pytest.mark.unit
def test_empty_dns_answer_policy_is_sink_specific(monkeypatch):
    ug = _ug()
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [])
    assert ug.is_safe_profile_url("https://example.com/profiles.json") is False
    assert ug.is_safe_media_url("https://example.com/video") is True


@pytest.mark.unit
def test_dns_timeout_policy_is_sink_specific(monkeypatch):
    ug = _ug()

    def _hang(host, port, *args, **kwargs):
        import time

        time.sleep(5)

    monkeypatch.setattr(socket, "getaddrinfo", _hang)
    monkeypatch.setattr(ug, "_DNS_TIMEOUT_S", 0.2)
    assert ug.is_safe_profile_url("https://example.com/profiles.json") is False
    assert ug.is_safe_media_url("https://example.com/video") is True


@pytest.mark.unit
def test_metadata_hostnames_are_blocked_by_name(monkeypatch):
    ug = _ug()
    called = []

    def _spy(host, port, *args, **kwargs):
        called.append(host)
        return []

    monkeypatch.setattr(socket, "getaddrinfo", _spy)
    for host in ("metadata.google.internal", "metadata", "instance-data.ec2.internal"):
        assert ug.is_safe_media_url(f"http://{host}/latest/meta-data/") is False
    # Blocked BEFORE the resolver was consulted.
    assert called == []


@pytest.mark.unit
def test_resolver_returns_the_resolved_addresses(monkeypatch):
    ug = _ug()
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
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
def test_profile_url_length_is_bounded_before_dns(monkeypatch):
    ug = _ug()
    lookups = []
    monkeypatch.setattr(
        ug,
        "_resolve_address_records",
        lambda host, port: lookups.append((host, port)) or [],
    )

    with pytest.raises(
        urllib.error.URLError, match="Unsafe or unresolved profile destination"
    ):
        ug.pinned_urlopen("https://example.com/" + "a" * 2048)

    assert lookups == []


@pytest.mark.unit
def test_hung_dns_lookups_cannot_create_unbounded_resolver_threads(monkeypatch):
    ug = _ug()
    slots = threading.BoundedSemaphore(1)
    entered = threading.Event()
    release = threading.Event()
    finished = threading.Event()
    calls = []

    def _hang(host, port, *args, **kwargs):
        calls.append(host)
        entered.set()
        release.wait(timeout=2)
        finished.set()
        return []

    monkeypatch.setattr(ug, "_dns_resolution_slots", slots)
    monkeypatch.setattr(ug, "_DNS_TIMEOUT_S", 0.02)
    monkeypatch.setattr(socket, "getaddrinfo", _hang)
    try:
        assert ug._resolve_address_records("first.example", 80) == []
        assert entered.wait(timeout=1)
        # The first resolver is still blocked, so a second lookup is refused
        # rather than creating another thread.
        assert ug._resolve_address_records("second.example", 80) == []
        assert calls == ["first.example"]
    finally:
        release.set()
        assert finished.wait(timeout=1)


@pytest.mark.unit
def test_rebinding_to_loopback_is_still_blocked(monkeypatch):
    ug = _ug()
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda host, port, *a, **k: [
            (2, 1, 6, "", ("127.0.0.1", port or 80)),
        ],
    )
    assert ug.is_safe_media_url("https://rebind.test/video") is False


@pytest.mark.unit
def test_public_address_is_allowed(monkeypatch):
    ug = _ug()
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda host, port, *a, **k: [
            (2, 1, 6, "", ("93.184.216.34", port or 80)),
        ],
    )
    assert ug.is_safe_media_url("https://example.com/video") is True
