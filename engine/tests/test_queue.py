"""Download queue / concurrency limit (Milestone 1, TDD repro).

Expected behavior (Verified Approach):
- Default max 2 concurrent, configurable 1-5 (clamped).
- start_download admits when under limit, queues (FIFO) when at limit.
- Promotion when a slot frees up.
- Duplicate active/queued id rejected (prevents redownload-while-active collision).
- Queued cancel dequeues without spawning a thread.
"""

import queue as _queue

import truestream_engine.downloader as dl_mod


def _reset():
    dl_mod._active_downloads.clear()
    if hasattr(dl_mod, "_pending_queue"):
        dl_mod._pending_queue.clear()
    if hasattr(dl_mod, "set_max_concurrent"):
        dl_mod.set_max_concurrent(2)


class _NoopThread:
    """Thread stand-in that never runs the target (keeps slot occupied)."""

    def __init__(self, *args, **kwargs):
        pass

    def start(self):
        pass


def test_admission_under_limit_starts_thread(monkeypatch):
    _reset()
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    r1 = dl_mod.start_download(url="https://x.test/1", download_id="q-admit-1")
    r2 = dl_mod.start_download(url="https://x.test/2", download_id="q-admit-2")
    try:
        assert r1["success"] is True and r1.get("queued") is not True
        assert r2["success"] is True and r2.get("queued") is not True
        assert r1.get("thread_started") is True
    finally:
        dl_mod._active_downloads.pop("q-admit-1", None)
        dl_mod._active_downloads.pop("q-admit-2", None)


def test_queueing_when_at_limit(monkeypatch):
    _reset()
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    dl_mod.start_download(url="https://x.test/1", download_id="q-full-1")
    dl_mod.start_download(url="https://x.test/2", download_id="q-full-2")
    try:
        r3 = dl_mod.start_download(url="https://x.test/3", download_id="q-full-3")
        assert r3["success"] is True
        assert r3.get("queued") is True
        assert r3.get("position") == 1
        status = dl_mod.get_queue_status()
        assert "q-full-3" in status["queued"]
    finally:
        dl_mod._active_downloads.pop("q-full-1", None)
        dl_mod._active_downloads.pop("q-full-2", None)
        dl_mod._active_downloads.pop("q-full-3", None)
        if hasattr(dl_mod, "_pending_queue"):
            dl_mod._pending_queue.clear()


def test_promotion_when_slot_frees(monkeypatch):
    _reset()
    started = []

    class _TrackingThread:
        def __init__(self, *args, **kwargs):
            self._target = kwargs.get("target")
            self._args = kwargs.get("args", ())

        def start(self):
            # Record but do not run (avoid yt-dlp); promotion is driven
            # explicitly via _pump_queue in this unit test.
            started.append(self._args[1] if len(self._args) > 1 else None)

    monkeypatch.setattr(dl_mod.threading, "Thread", _TrackingThread)
    dl_mod.start_download(url="https://x.test/1", download_id="q-prom-1")
    dl_mod.start_download(url="https://x.test/2", download_id="q-prom-2")
    dl_mod.start_download(url="https://x.test/3", download_id="q-prom-3")
    try:
        # Simulate slot freeing: mark q-prom-1 finished, pump.
        import datetime

        dl_mod._active_downloads["q-prom-1"]["finished_at"] = (
            __import__("datetime").datetime.now(__import__("datetime").timezone.utc)
        )
        if hasattr(dl_mod, "_pump_queue"):
            dl_mod._pump_queue()
        status = dl_mod.get_queue_status()
        # q-prom-3 should have been promoted out of the queue.
        assert "q-prom-3" not in status["queued"]
        assert "q-prom-3" in dl_mod._active_downloads
    finally:
        for did in ("q-prom-1", "q-prom-2", "q-prom-3"):
            dl_mod._active_downloads.pop(did, None)
        if hasattr(dl_mod, "_pending_queue"):
            dl_mod._pending_queue.clear()


def test_duplicate_active_id_rejected(monkeypatch):
    _reset()
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    dl_mod.start_download(url="https://x.test/1", download_id="q-dup-1")
    try:
        r = dl_mod.start_download(url="https://x.test/1", download_id="q-dup-1")
        assert r["success"] is False
        assert r.get("error_type") == "ERROR_ALREADY_ACTIVE"
    finally:
        dl_mod._active_downloads.pop("q-dup-1", None)
        if hasattr(dl_mod, "_pending_queue"):
            dl_mod._pending_queue.clear()


def test_cancel_queued_dequeues(monkeypatch):
    _reset()
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    dl_mod.start_download(url="https://x.test/1", download_id="q-cancel-1")
    dl_mod.start_download(url="https://x.test/2", download_id="q-cancel-2")
    q = dl_mod.start_download(url="https://x.test/3", download_id="q-cancel-3")
    try:
        assert q.get("queued") is True
        res = dl_mod.cancel_download("q-cancel-3")
        assert res["success"] is True
        status = dl_mod.get_queue_status()
        assert "q-cancel-3" not in status["queued"]
    finally:
        for did in ("q-cancel-1", "q-cancel-2", "q-cancel-3"):
            dl_mod._active_downloads.pop(did, None)
        if hasattr(dl_mod, "_pending_queue"):
            dl_mod._pending_queue.clear()


def test_concurrency_clamped_1_to_5():
    _reset()
    try:
        dl_mod.set_max_concurrent(99)
        assert dl_mod.get_queue_status()["max_concurrent"] == 5
        dl_mod.set_max_concurrent(0)
        assert dl_mod.get_queue_status()["max_concurrent"] == 1
        dl_mod.set_max_concurrent(3)
        assert dl_mod.get_queue_status()["max_concurrent"] == 3
    finally:
        dl_mod.set_max_concurrent(2)
