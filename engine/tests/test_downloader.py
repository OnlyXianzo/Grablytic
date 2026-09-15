"""Downloader thread timestamps (aware UTC) and error enrichment."""

import queue
import stat
from datetime import timezone

import pytest

import grablytic_engine.downloader as dl_mod
from grablytic_engine.paths import set_paths


def _fake_ffmpeg(tmp_path):
    exe = tmp_path / "ffmpeg"
    exe.write_text("#!/bin/sh\necho 'ffmpeg version test'\n")
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(exe)


@pytest.fixture()
def _env(tmp_path, monkeypatch):
    import grablytic_engine.paths as paths_mod
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    set_paths(
        data_dir=str(tmp_path), output_dir=str(tmp_path),
        ffmpeg_path=_fake_ffmpeg(tmp_path), cache_dir=str(tmp_path),
    )
    yield
    dl_mod._active_downloads.clear()


def _boom(*args, **kwargs):
    raise RuntimeError("not available in your country")


class TestAwareTimestamps:
    @pytest.mark.unit
    def test_started_and_finished_are_aware_utc(self, _env, monkeypatch):
        monkeypatch.setattr(dl_mod, "YoutubeDL", _boom)
        res_q: queue.Queue = queue.Queue()
        dl_mod.download_thread(
            url="https://x.test/v", download_id="aware1",
            result_queue=res_q,
        )
        res = res_q.get(timeout=10)
        assert res["success"] is False
        info = dl_mod._active_downloads["aware1"]
        assert info["started_at"].tzinfo == timezone.utc
        assert info["finished_at"].tzinfo == timezone.utc
        # Aware ISO gains an explicit offset (never silently naive).
        assert info["started_at"].isoformat().endswith("+00:00")

    @pytest.mark.unit
    def test_error_carries_suggests_vpn(self, _env, monkeypatch):
        monkeypatch.setattr(dl_mod, "YoutubeDL", _boom)
        res_q: queue.Queue = queue.Queue()
        dl_mod.download_thread(
            url="https://x.test/v", download_id="vpn1",
            result_queue=res_q,
        )
        res = res_q.get(timeout=10)
        assert res["error_type"] == "ERROR_GEO_BLOCKED"
        assert res["suggests_vpn"] is True


class TestYDLoggerAndCompletion:
    @pytest.mark.unit
    def test_ydlogger_extracts_paths(self):
        logger = dl_mod.YDLogger()
        logger.debug("[download] /path/to/video.mkv has already been downloaded")
        logger.info('[Merger] Merging formats into "/path/to/merged.mkv"')
        logger.info('[Metadata] Adding metadata to "/path/to/merged.mkv"')
        assert "/path/to/video.mkv" in logger.output_files
        assert "/path/to/merged.mkv" in logger.output_files

    @pytest.mark.unit
    def test_already_downloaded_file_reports_disk_filesize_and_path(self, _env, tmp_path, monkeypatch):
        # Create a pre-existing target file on disk
        target_file = tmp_path / "existing_video.mkv"
        target_file.write_bytes(b"A" * 10240)  # 10 KB file
        assert target_file.exists()

        class FakeYoutubeDL:
            def __init__(self, opts):
                self.opts = opts
                self.logger = opts.get("logger")

            def add_progress_hook(self, hook):
                pass

            def download(self, urls):
                # Simulate yt-dlp skipping download because file already exists
                if self.logger:
                    self.logger.debug(f"[download] {target_file} has already been downloaded")
                    self.logger.info(f'[Metadata] Adding metadata to "{target_file}"')
                return 0

        monkeypatch.setattr(dl_mod, "YoutubeDL", FakeYoutubeDL)
        res_q: queue.Queue = queue.Queue()
        dl_mod.download_thread(
            url="https://x.test/v", download_id="existing1",
            result_queue=res_q,
        )
        res = res_q.get(timeout=10)
        assert res["success"] is True
        assert res["download_id"] == "existing1"
        assert res["file_path"] == str(target_file)
        assert res["filesize_bytes"] == 10240


class TestFindThumbnailPath:
    def test_preferred_format_found(self, tmp_path):
        media = tmp_path / "video.mkv"
        media.write_bytes(b"media")
        thumb = tmp_path / "video.jpg"
        thumb.write_bytes(b"thumb")
        got = dl_mod._find_thumbnail_path(str(media), {"thumbnail_format": "jpg"})
        assert got == str(thumb)

    def test_falls_back_to_other_extensions(self, tmp_path):
        media = tmp_path / "video.mp4"
        media.write_bytes(b"media")
        thumb = tmp_path / "video.png"
        thumb.write_bytes(b"thumb")
        got = dl_mod._find_thumbnail_path(str(media), {"thumbnail_format": "jpg"})
        assert got == str(thumb)

    def test_missing_sidecar_returns_none(self, tmp_path):
        media = tmp_path / "video.mp4"
        media.write_bytes(b"media")
        assert dl_mod._find_thumbnail_path(str(media), {}) is None

    def test_missing_media_or_none_returns_none(self, tmp_path):
        assert dl_mod._find_thumbnail_path(None, {}) is None
        assert dl_mod._find_thumbnail_path("", {}) is None
        assert dl_mod._find_thumbnail_path(str(tmp_path / "nope.mp4"), {}) is None
        # Never raises on garbage input.
        assert dl_mod._find_thumbnail_path(12345, None) is None

    @pytest.mark.unit
    def test_finished_event_carries_thumbnail_path(self, _env, tmp_path, monkeypatch):
        # End-to-end through download_thread with a faked YoutubeDL: the
        # sidecar next to the output file must be reported as thumbnail_path
        # in BOTH the callback event and the result-queue dict.
        target_file = tmp_path / "thumb_video.mkv"
        target_file.write_bytes(b"A" * 4096)
        sidecar = tmp_path / "thumb_video.jpg"
        sidecar.write_bytes(b"B" * 512)

        seen_events: list = []

        class FakeYoutubeDL:
            def __init__(self, opts):
                self.logger = opts.get("logger")

            def add_progress_hook(self, hook):
                pass

            def download(self, urls):
                if self.logger:
                    self.logger.debug(f"[download] {target_file} has already been downloaded")
                return 0

        monkeypatch.setattr(dl_mod, "YoutubeDL", FakeYoutubeDL)
        res_q: queue.Queue = queue.Queue()
        dl_mod.download_thread(
            url="https://x.test/v", download_id="thumb1",
            result_queue=res_q,
            event_callback=type("CB", (), {
                "onEvent": lambda self, s: seen_events.append(s),
            })(),
        )
        import json as _json
        finished = [ _json.loads(s) for s in seen_events if '"finished"' in s]
        assert finished, "expected a terminal finished callback event"
        assert finished[0]["thumbnail_path"] == str(sidecar)
        assert finished[0]["file_path"] == str(target_file)


class TestSafeUrlScoping:
    @pytest.mark.unit
    def test_failure_before_safe_url_assignment_reports_real_error(self, _env):
        """T1-9: the worker's except-handler logs safe_url, which is bound
        inside try. A failure before that assignment must surface the REAL
        error — never NameError (previously masked as
        ERROR_DOWNLOADER_CRASH "Downloader stopped unexpectedly (NameError)")."""

        class _SplitBoom(str):
            def split(self, *args, **kwargs):
                raise RuntimeError("boom-before-safe_url")

        res_q: queue.Queue = queue.Queue()
        dl_mod.download_thread(
            url=_SplitBoom("https://x.test/v"), download_id="safeurl1",
            result_queue=res_q,
        )
        res = res_q.get(timeout=10)
        assert res["success"] is False
        assert res["error_type"] == "ERROR_UNKNOWN"
        assert res["error_message"] == "boom-before-safe_url"


class TestErrorLogCap:
    @pytest.mark.unit
    def test_ydlogger_errors_bounded_most_recent_kept(self):
        """T3-9: ignoreerrors playlists must not grow YDLogger.errors
        without bound — cap retains the most recent (diagnostically
        relevant) tail."""
        logger = dl_mod.YDLogger()
        for i in range(3000):
            logger.error(f"boom {i}")
        assert len(logger.errors) <= 200
        assert logger.errors[-1] == "boom 2999"


class TestPublicQueueScan:
    @pytest.mark.unit
    def test_last_known_uses_only_public_queue_api(self):
        """T3-8: terminal filesize scan must not reach into CPython
        internals (prog_q.mutex/prog_q.queue). A queue exposing only the
        public API works, and every drained item is restored in order."""
        import json as _json

        class _PublicOnlyQueue:
            def __init__(self):
                self._items = []

            def put(self, it):
                self._items.append(it)

            def get_nowait(self):
                if not self._items:
                    raise queue.Empty
                return self._items.pop(0)

        q = _PublicOnlyQueue()
        assert not hasattr(q, "mutex") and not hasattr(q, "queue")
        for i, name in enumerate(["a.mkv", "b.mkv", "c.mkv"]):
            q.put(_json.dumps({
                "filesize_bytes": (i + 1) * 1000,
                "filename": f"/tmp/{name}",
            }))
        size, path = dl_mod._last_known_file_info(q)
        assert size == 3000
        assert path == "/tmp/c.mkv"
        # Nothing lost, order preserved.
        rest = []
        try:
            while True:
                rest.append(q.get_nowait())
        except queue.Empty:
            pass
        assert len(rest) == 3
        assert _json.loads(rest[0])["filename"] == "/tmp/a.mkv"


class TestErrorTaxonomy:
    @pytest.mark.unit
    def test_format_failure_not_mislabeled_postprocess(self, _env, monkeypatch):
        """AARAV-1: a format-resolution failure swallowed by ignoreerrors
        must not surface as ERROR_POSTPROCESS_FAILED — classify it."""

        class FakeYDL:
            def __init__(self, opts):
                self.logger = opts.get("logger")

            def add_progress_hook(self, hook):
                pass

            def download(self, urls):
                self.logger.error(
                    "[soundcloud] 159813448: Requested format is not available")
                return 0

        monkeypatch.setattr(dl_mod, "YoutubeDL", FakeYDL)
        res_q: queue.Queue = queue.Queue()
        dl_mod.download_thread(
            url="https://soundcloud.com/x/y", download_id="tax1",
            result_queue=res_q,
        )
        res = res_q.get(timeout=10)
        assert res["success"] is False
        assert res["error_type"] == "ERROR_FORMAT_UNAVAILABLE"
        assert "not available" in res["error_message"]
