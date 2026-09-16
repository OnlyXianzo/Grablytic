"""SSRF / traversal / proxy input guards (E1 regression)."""

import pytest

from grablytic_engine.url_guard import (
    is_safe_media_url,
    is_safe_profile_url,
    safe_archive_path,
    sanitized_proxy,
)


@pytest.mark.unit
class TestMediaUrl:
    def test_public_https_ok(self):
        assert is_safe_media_url("https://www.youtube.com/watch?v=abc123XYZ_-") is True

    def test_file_scheme_rejected(self):
        assert is_safe_media_url("file:///etc/passwd") is False

    def test_localhost_rejected(self):
        assert is_safe_media_url("http://localhost:8080/x") is False
        assert is_safe_media_url("http://127.0.0.1:9050/") is False

    def test_private_lan_rejected(self):
        assert is_safe_media_url("http://192.168.1.1/video") is False
        assert is_safe_media_url("http://10.0.0.5/") is False
        assert is_safe_media_url("http://169.254.169.254/latest/meta-data/") is False

    def test_userinfo_rejected(self):
        assert is_safe_media_url("https://user:pass@evil.test/x") is False

    def test_non_string_rejected(self):
        assert is_safe_media_url(None) is False
        assert is_safe_media_url(123) is False

    def test_profile_url_same_policy(self):
        assert is_safe_profile_url("https://cdn.test/profiles.json") is True
        assert is_safe_profile_url("file:///tmp/p.json") is False


@pytest.mark.unit
class TestProxy:
    def test_valid_proxies_preserved(self):
        assert sanitized_proxy("http://proxy.test:8080") == "http://proxy.test:8080"
        assert sanitized_proxy("socks5h://127.0.0.1:9050") == "socks5h://127.0.0.1:9050"
        assert sanitized_proxy("http://user:pw@proxy.test:3128") == "http://user:pw@proxy.test:3128"

    def test_garbage_dropped(self):
        assert sanitized_proxy("--proxy http://evil:8080") == ""
        assert sanitized_proxy("not a url") == ""
        assert sanitized_proxy("") == ""
        assert sanitized_proxy(None) == ""


@pytest.mark.unit
class TestArchive:
    def test_inside_data_dir_ok(self, tmp_path):
        target = str(tmp_path / "download_archive.txt")
        assert safe_archive_path(target, str(tmp_path)) == target

    def test_outside_rejected(self, tmp_path):
        assert safe_archive_path("/etc/cron.d/evil", str(tmp_path)) is None
        assert safe_archive_path(str(tmp_path / ".." / "escape.txt"), str(tmp_path)) is None

    def test_directory_rejected(self, tmp_path):
        assert safe_archive_path(str(tmp_path), str(tmp_path)) is None


@pytest.mark.unit
class TestWiring:
    def test_start_download_rejects_ssrf_without_thread(self, monkeypatch):
        import grablytic_engine.downloader as dl_mod

        started = []
        orig_thread = dl_mod.threading.Thread

        class _SpyThread:
            def __init__(self, *a, **k):
                pass

            def start(self):
                started.append(True)

        monkeypatch.setattr(dl_mod.threading, "Thread", _SpyThread)
        try:
            r = dl_mod.start_download(
                url="file:///etc/passwd", download_id="ssrf-1")
            assert r["success"] is False
            assert r["error_type"] == "ERROR_INVALID_PARAM"
            assert started == []
        finally:
            dl_mod._active_downloads.pop("ssrf-1", None)
            monkeypatch.setattr(dl_mod.threading, "Thread", orig_thread)

    def test_get_formats_rejects_ssrf_without_network(self):
        from grablytic_engine.formats import get_formats
        r = get_formats("http://169.254.169.254/x")
        assert r["success"] is False
        assert r["error_type"] == "ERROR_INVALID_PARAM"

    def test_profile_from_url_falls_back_on_ssrf(self):
        from grablytic_engine.site_profiles import (
            load_site_profiles,
            load_site_profiles_from_url,
        )
        assert load_site_profiles_from_url("file:///tmp/evil.json") == load_site_profiles()

    def test_opts_builder_contains_archive_and_drops_bad_proxy(self, tmp_path):
        from grablytic_engine.opts_builder import build_ydl_opts
        from grablytic_engine.paths import set_paths
        set_paths(
            data_dir=str(tmp_path),
            output_dir=str(tmp_path),
            ffmpeg_path=None,
            cache_dir=str(tmp_path),
        )
        # User-chosen absolute archive locations stay honored (setting,
        # not remote input); malformed proxies are dropped.
        custom = str(tmp_path / "custom_archive.txt")
        opts = build_ydl_opts(
            config={"use_archive": True, "archive_path": custom,
                    "proxy": "not a url"},
            url="https://www.youtube.com/watch?v=abc123XYZ_-",
        )
        import os as _os
        assert opts["download_archive"] == _os.path.abspath(custom)
        assert "proxy" not in opts
        # Directories are never valid archive targets.
        opts2 = build_ydl_opts(
            config={"use_archive": True, "archive_path": str(tmp_path)},
            url="https://www.youtube.com/watch?v=abc123XYZ_-",
        )
        assert opts2["download_archive"] != _os.path.abspath(str(tmp_path))
