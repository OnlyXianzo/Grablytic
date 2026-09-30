"""FEATURE 5: engine transient auto-retry (failing-first repro).

Retry rules under test:
- Transient failures (per classify_error verdict: recoverable AND not in the
  permanent denylist) are retried up to 2 times with backoff 5s, 15s.
- Permanent failures (private/deleted/no-video/photo-post class) are attempted
  exactly once and never sleep.
"""

import queue
import stat
import threading
import time

import grablytic_engine.downloader as dl_mod
from grablytic_engine.paths import set_paths


def _fake_ffmpeg(tmp_path):
    exe = tmp_path / "ffmpeg"
    exe.write_text("#!/bin/sh\necho 'ffmpeg version test'\n")
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(exe)


def _env_setup(tmp_path, monkeypatch):
    import grablytic_engine.paths as paths_mod  # noqa: F401
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    set_paths(
        data_dir=str(tmp_path), output_dir=str(tmp_path),
        ffmpeg_path=_fake_ffmpeg(tmp_path), cache_dir=str(tmp_path),
    )


def _teardown():
    dl_mod._active_downloads.clear()
    if hasattr(dl_mod, "_pending_queue"):
        dl_mod._pending_queue.clear()


def _run_thread(monkeypatch, tmp_path, fake_ydl_cls, download_id):
    """Run download_thread with Fake YDL class; record sleep calls."""
    _env_setup(tmp_path, monkeypatch)
    monkeypatch.setattr(dl_mod, "YoutubeDL", fake_ydl_cls)
    sleeps = []
    # ISOLATION: time.sleep is process-global, and earlier suites leave
    # background daemons alive (e.g. __main__.poll_queues' 0.1s loop) that
    # share it. download_thread runs synchronously on THIS thread, so
    # record only the test thread's sleeps; throttle anyone else with a
    # real 1ms nap (also avoids an unthrottled hot-spin while patched).
    owner = threading.current_thread()
    real_sleep = time.sleep

    def _fake_sleep(s):
        if threading.current_thread() is owner:
            sleeps.append(s)
        else:
            real_sleep(0.001)

    monkeypatch.setattr("time.sleep", _fake_sleep)
    res_q: queue.Queue = queue.Queue()
    try:
        dl_mod.download_thread(
            url="https://x.test/v", download_id=download_id,
            result_queue=res_q,
        )
        res = res_q.get(timeout=10)
    finally:
        _teardown()
    return res, sleeps


class TestTransientAutoRetry:
    def test_transient_empty_media_retried_then_succeeds(
        self, tmp_path, monkeypatch,
    ):
        """Empty-media-response failure must be retried and succeed on 2nd try."""
        target = tmp_path / "retry_ok.mkv"
        target.write_bytes(b"A" * 4096)
        calls = {"n": 0}

        class FakeYDL:
            def __init__(self, opts):
                self.logger = opts.get("logger")

            def add_progress_hook(self, hook):
                pass

            def download(self, urls):
                calls["n"] += 1
                if calls["n"] == 1:
                    raise RuntimeError("empty media response")
                self.logger.debug(f"[download] Destination: {target}")
                return 0

        res, sleeps = _run_thread(monkeypatch, tmp_path, FakeYDL, "retry-ok-1")
        assert res["success"] is True, res
        assert calls["n"] == 2
        assert sleeps == [5.0]

    def test_permanent_private_attempted_exactly_once(
        self, tmp_path, monkeypatch,
    ):
        """Private videos must NEVER retry and must never sleep."""
        calls = {"n": 0}

        class FakeYDL:
            def __init__(self, opts):
                pass

            def add_progress_hook(self, hook):
                pass

            def download(self, urls):
                calls["n"] += 1
                raise RuntimeError("This video is private")

        res, sleeps = _run_thread(monkeypatch, tmp_path, FakeYDL, "retry-no-1")
        assert res["success"] is False
        assert res["error_type"] == "ERROR_PRIVATE"
        assert calls["n"] == 1
        assert sleeps == []

    def test_backoff_delays_and_attempt_budget(self, tmp_path, monkeypatch):
        """Persistent transient failure: initial + 2 retries, sleeps 5s, 15s."""
        calls = {"n": 0}

        class FakeYDL:
            def __init__(self, opts):
                pass

            def add_progress_hook(self, hook):
                pass

            def download(self, urls):
                calls["n"] += 1
                raise RuntimeError("Connection reset by peer")

        res, sleeps = _run_thread(monkeypatch, tmp_path, FakeYDL, "retry-budget-1")
        assert res["success"] is False
        assert res["error_type"] == "ERROR_NETWORK"
        assert calls["n"] == 3
        assert sleeps == [5.0, 15.0]

    def test_single_item_logger_transient_error_retried(
        self, tmp_path, monkeypatch,
    ):
        """Single-item ydl_logger.error with a transient message must retry."""
        target = tmp_path / "retry_log.mkv"
        target.write_bytes(b"A" * 4096)
        calls = {"n": 0}

        class FakeYDL:
            def __init__(self, opts):
                self.logger = opts.get("logger")

            def add_progress_hook(self, hook):
                pass

            def download(self, urls):
                calls["n"] += 1
                if calls["n"] == 1:
                    self.logger.error("ERROR: empty media response (transient)")
                    return 0
                self.logger.debug(f"[download] Destination: {target}")
                return 0

        res, sleeps = _run_thread(monkeypatch, tmp_path, FakeYDL, "retry-log-1")
        assert res["success"] is True, res
        assert calls["n"] == 2
        assert sleeps == [5.0]
