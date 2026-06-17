import os
import json
import tempfile
from truestream_engine.resume import scan_resume_candidates
from truestream_engine.site_profiles import (
    load_site_profiles,
    load_profiles_from_disk,
    save_profiles_to_disk,
)
from truestream_engine.po_token import generate_po_token
from truestream_engine.bootstrap import bootstrap, _detect_js_runtime
from truestream_engine.paths import set_paths, _paths


class TestScanResumeCandidates:
    def test_empty_cache_dir(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            result = scan_resume_candidates(tmpdir)
            assert result["success"] is True
            assert result["candidates"] == []

    def test_nonexistent_dir(self):
        result = scan_resume_candidates("/nonexistent/path/12345")
        assert result["success"] is True
        assert result["candidates"] == []

    def test_ignores_non_part_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            open(os.path.join(tmpdir, "video.mp4"), "w").close()
            result = scan_resume_candidates(tmpdir)
            assert len(result["candidates"]) == 0

    def test_detects_part_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "video.f137.part")
            open(path, "w").close()
            result = scan_resume_candidates(tmpdir)
            assert len(result["candidates"]) == 1
            assert result["candidates"][0]["filename"] == "video.f137.part"
            assert result["candidates"][0]["size_bytes"] == 0

    def test_marks_expired_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "old.part")
            with open(path, "w") as f:
                f.write("data")
            old_mtime = 1000  # way in the past
            os.utime(path, (old_mtime, old_mtime))
            result = scan_resume_candidates(tmpdir)
            assert len(result["candidates"]) == 1
            assert result["candidates"][0]["expired"] is True

    def test_recovers_likely_url_from_info_json(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            part_path = os.path.join(tmpdir, "video.mp4.part")
            info_path = os.path.join(tmpdir, "video.mp4.info.json")
            open(part_path, "w").close()
            with open(info_path, "w", encoding="utf-8") as f:
                json.dump({"webpage_url": "https://youtube.com/watch?v=dQw4w9WgXcQ"}, f)
            result = scan_resume_candidates(tmpdir)
            assert len(result["candidates"]) == 1
            assert result["candidates"][0]["likely_url"] == "https://youtube.com/watch?v=dQw4w9WgXcQ"


class TestSiteProfiles:
    def test_load_default_profiles(self):
        profiles = load_site_profiles()
        assert "YouTube 1080p" in profiles
        assert "YouTube 4K" in profiles
        assert "Podcast Audio" in profiles
        assert "Lossless FLAC" in profiles
        assert "Opus Compact" in profiles
        assert "Twitter/X Video" in profiles

    def test_youtube_1080p_format(self):
        profiles = load_site_profiles()
        cfg = profiles["YouTube 1080p"]
        assert "1080" in cfg["format_code"]
        assert cfg["container"] == "mp4"

    def test_youtube_4k_format(self):
        profiles = load_site_profiles()
        cfg = profiles["YouTube 4K"]
        assert "2160" in cfg["format_code"]
        assert cfg["container"] == "mkv"

    def test_save_and_load_from_disk(self):
        profiles = {"Custom": {"format_code": "best", "container": "mp4"}}
        with tempfile.TemporaryDirectory() as tmpdir:
            path = os.path.join(tmpdir, "profiles.json")
            save_profiles_to_disk(profiles, path)
            loaded = load_profiles_from_disk(path)
            assert loaded == profiles

    def test_load_from_disk_missing_file(self):
        result = load_profiles_from_disk("/nonexistent/profiles.json")
        assert result == {}


class TestGeneratePoToken:
    def test_returns_none(self):
        assert generate_po_token("https://youtube.com/watch?v=abc") is None


class TestBootstrap:
    def test_returns_error_when_not_initialized(self):
        _paths["data_dir"] = None
        result = bootstrap()
        assert result["success"] is False
        assert result["error_type"] == "ERROR_BOOTSTRAP_FAILED"

    def test_returns_success_when_initialized(self):
        set_paths(
            data_dir="/tmp/data",
            output_dir="/tmp/output",
            ffmpeg_path="/usr/bin/ffmpeg",
            cache_dir="/tmp/cache",
        )
        result = bootstrap()
        assert result["success"] is True
        assert "yt_dlp_version" in result
        assert "js_runtime" in result
        assert result["contract_version"] == "1.0"

    def test_detect_js_runtime_default_none(self):
        result = _detect_js_runtime()
        assert result["name"] in ("quickjs", "deno", "none")

    def test_download_and_extract_binary_zip(self, monkeypatch):
        import io
        import zipfile
        import hashlib
        import tempfile
        import urllib.request
        from truestream_engine.bootstrap import _download_and_extract_binary

        zip_buffer = io.BytesIO()
        with zipfile.ZipFile(zip_buffer, "w") as z:
            z.writestr("ffmpeg", "dummy_ffmpeg_content")
        zip_bytes = zip_buffer.getvalue()
        zip_sha = hashlib.sha256(zip_bytes).hexdigest()

        class MockResponse:
            def __init__(self, data):
                self.data = data
                self.read_done = False
            def read(self, *args, **kwargs):
                if self.read_done:
                    return b""
                self.read_done = True
                return self.data
            def __enter__(self):
                return self
            def __exit__(self, exc_type, exc_val, exc_tb):
                pass

        monkeypatch.setattr(urllib.request, "urlopen", lambda req, timeout=None: MockResponse(zip_bytes))

        with tempfile.TemporaryDirectory() as tmpdir:
            dest_path = os.path.join(tmpdir, "bin", "ffmpeg")
            _download_and_extract_binary("https://example.com/ffmpeg.zip", zip_sha, dest_path, tmpdir)
            
            assert os.path.exists(dest_path)
            with open(dest_path, "r") as f:
                assert f.read() == "dummy_ffmpeg_content"

    def test_download_and_extract_binary_tar(self, monkeypatch):
        import io
        import tarfile
        import hashlib
        import tempfile
        import urllib.request
        from truestream_engine.bootstrap import _download_and_extract_binary

        tar_buffer = io.BytesIO()
        with tarfile.open(fileobj=tar_buffer, mode="w:gz") as t:
            tar_info = tarfile.TarInfo(name="ffmpeg")
            tar_info.size = len("dummy_ffmpeg_tar_content")
            t.addfile(tar_info, io.BytesIO(b"dummy_ffmpeg_tar_content"))
        tar_bytes = tar_buffer.getvalue()
        tar_sha = hashlib.sha256(tar_bytes).hexdigest()

        class MockResponse:
            def __init__(self, data):
                self.data = data
                self.read_done = False
            def read(self, *args, **kwargs):
                if self.read_done:
                    return b""
                self.read_done = True
                return self.data
            def __enter__(self):
                return self
            def __exit__(self, exc_type, exc_val, exc_tb):
                pass

        monkeypatch.setattr(urllib.request, "urlopen", lambda req, timeout=None: MockResponse(tar_bytes))

        with tempfile.TemporaryDirectory() as tmpdir:
            dest_path = os.path.join(tmpdir, "bin", "ffmpeg")
            _download_and_extract_binary("https://example.com/ffmpeg.tar.gz", tar_sha, dest_path, tmpdir)
            
            assert os.path.exists(dest_path)
            with open(dest_path, "r") as f:
                assert f.read() == "dummy_ffmpeg_tar_content"

    def test_set_update_channel(self):
        from truestream_engine.paths import set_update_channel, get_paths
        res = set_update_channel("nightly")
        assert res == {"success": True}
        assert get_paths()["update_channel"] == "nightly"

    def test_update_check(self):
        from truestream_engine.bootstrap import update_check
        from truestream_engine.paths import set_paths
        set_paths(
            data_dir="/tmp/data",
            output_dir="/tmp/output",
            ffmpeg_path="/usr/bin/ffmpeg",
            cache_dir="/tmp/cache",
        )
        res = update_check()
        assert res["success"] is True
        assert "yt_dlp_current" in res
        assert "yt_dlp_latest" in res
        assert "binaries" in res
        assert "updates_queued" in res

    def test_bootstrap_github_binary_missing_sha256(self, monkeypatch):
        import shutil
        import sys
        import truestream_engine.bootstrap as bootstrap_dummy  # ensure module is loaded
        from truestream_engine.bootstrap import _bootstrap_github_binary

        bootstrap_mod = sys.modules["truestream_engine.bootstrap"]

        # Mock resolve_latest_release to return an asset but no sha256 checksum asset
        monkeypatch.setattr(bootstrap_mod, "_resolve_latest_release", lambda repo: {
            "tag_name": "v1.0.0",
            "assets": [
                {
                    "name": "ffmpeg-linux.tar.gz",
                    "browser_download_url": "https://example.com/ffmpeg-linux.tar.gz"
                }
            ]
        })

        # Ensure dest_path does not exist and is not on system path
        monkeypatch.setattr(shutil, "which", lambda name: None)

        dest_path = "/tmp/does_not_exist_ffmpeg"
        if os.path.exists(dest_path):
            os.remove(dest_path)

        res = _bootstrap_github_binary(
            "ffmpeg",
            "foo/bar",
            "linux",
            dest_path,
            "/tmp/cache"
        )
        assert res == (False, None)
