"""Pytest test configuration and global fixtures for grablytic_engine tests.

The SSRF guard resolves DNS. Without a deterministic resolver the suite
would hit the real resolver on every URL check — slow, flaky and
network-dependent (a CI box with no DNS would fail every media-URL
assertion for the wrong reason).
"""

import pytest
import grablytic_engine.downloader as dl_mod

# A public address used for the test-only hostnames below.
_PUBLIC_IP = "93.184.216.34"
_TEST_SUFFIXES = (".test", ".example", ".invalid", ".localhost.test")
_TEST_HOSTS = {"example.com", "www.example.com", "example.test"}


@pytest.fixture(scope="session", autouse=True)
def _deterministic_dns_for_tests():
    """Map the test-only hostnames to a public IP; delegate the rest."""
    import socket as _socket

    original = _socket.getaddrinfo

    def _fake(host, port, *args, **kwargs):
        h = str(host or "").lower().rstrip(".")
        if h in _TEST_HOSTS or h.endswith(_TEST_SUFFIXES):
            return [(2, 1, 6, "", (_PUBLIC_IP, port or 80))]
        return original(host, port, *args, **kwargs)

    _socket.getaddrinfo = _fake
    yield
    _socket.getaddrinfo = original


@pytest.fixture(autouse=True)
def _reset_logger_context():
    """The logger's download_id lives in a ContextVar.

    A test that sets it and does not reset it leaks the value into the
    next test in the same context, which then sees a `download_id` it
    never asked for. Clear it around every test.
    """
    from grablytic_engine.logger import set_current_download_id
    set_current_download_id(None)
    yield
    set_current_download_id(None)


@pytest.fixture(autouse=True)
def _auto_reset_downloader_shutdown():
    """Ensure every test starts and ends with a clean shutdown state."""
    if hasattr(dl_mod, "reset_shutdown_for_tests"):
        dl_mod.reset_shutdown_for_tests()
    yield
    if hasattr(dl_mod, "reset_shutdown_for_tests"):
        dl_mod.reset_shutdown_for_tests()
    if hasattr(dl_mod, "stop_cleanup_thread"):
        dl_mod.stop_cleanup_thread()
