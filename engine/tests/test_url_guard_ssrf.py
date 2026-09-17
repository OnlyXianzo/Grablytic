"""SSRF bypass regression: alt IP encodings + DNS-rebinding hostnames."""

import socket

import pytest

from grablytic_engine.url_guard import is_safe_media_url


def _fake_getaddrinfo_factory(mapping, original=socket.getaddrinfo):
    def _fake(host, port, *args, **kwargs):
        if host in mapping:
            val = mapping[host]
            if isinstance(val, Exception):
                raise val
            return val
        return original(host, port, *args, **kwargs)

    return _fake


@pytest.mark.unit
class TestSsrfBypasses:
    def test_decimal_int_loopback_rejected(self):
        assert is_safe_media_url("http://2130706433/foo") is False

    def test_hex_loopback_rejected(self):
        assert is_safe_media_url("http://0x7f000001/foo") is False

    def test_octal_loopback_rejected(self):
        assert is_safe_media_url("http://0177.0.0.1/foo") is False

    def test_dns_rebinding_loopback_rejected(self, monkeypatch):
        fake = _fake_getaddrinfo_factory(
            {
                "127.0.0.1.nip.io": [
                    (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 0))
                ]
            }
        )
        monkeypatch.setattr(socket, "getaddrinfo", fake)
        assert is_safe_media_url("http://127.0.0.1.nip.io/foo") is False

    def test_dns_rebinding_metadata_rejected(self, monkeypatch):
        fake = _fake_getaddrinfo_factory(
            {
                "169.254.169.254.nip.io": [
                    (
                        socket.AF_INET,
                        socket.SOCK_STREAM,
                        6,
                        "",
                        ("169.254.169.254", 0),
                    )
                ]
            }
        )
        monkeypatch.setattr(socket, "getaddrinfo", fake)
        assert is_safe_media_url("http://169.254.169.254.nip.io/foo") is False

    def test_plain_loopback_still_rejected(self):
        assert is_safe_media_url("http://127.0.0.1/foo") is False


@pytest.mark.unit
class TestLegitimateUrls:
    def test_youtube_watch_ok(self, monkeypatch):
        fake = _fake_getaddrinfo_factory(
            {
                "www.youtube.com": [
                    (
                        socket.AF_INET,
                        socket.SOCK_STREAM,
                        6,
                        "",
                        ("142.250.72.14", 0),
                    )
                ],
            }
        )
        monkeypatch.setattr(socket, "getaddrinfo", fake)
        assert (
            is_safe_media_url("https://www.youtube.com/watch?v=abc123XYZ_-") is True
        )

    def test_normal_domain_ok(self, monkeypatch):
        fake = _fake_getaddrinfo_factory(
            {
                "example.com": [
                    (
                        socket.AF_INET,
                        socket.SOCK_STREAM,
                        6,
                        "",
                        ("93.184.216.34", 0),
                    )
                ],
            }
        )
        monkeypatch.setattr(socket, "getaddrinfo", fake)
        assert is_safe_media_url("https://example.com/video") is True

    def test_bad_schemes_rejected(self):
        assert is_safe_media_url("file:///etc/passwd") is False
        assert is_safe_media_url("gopher://example.com/x") is False
        assert is_safe_media_url("ftp://example.com/x") is False

    def test_private_ip_literal_rejected(self):
        assert is_safe_media_url("http://192.168.1.50:8096") is False

    def test_dns_failure_fails_open(self, monkeypatch):
        def _raise(host, port, *args, **kwargs):
            raise socket.gaierror("mocked DNS outage")

        monkeypatch.setattr(socket, "getaddrinfo", _raise)
        # Known residual: offline/broken-DNS can't prove rebinding, so allow.
        assert is_safe_media_url("https://example.com/video") is True
