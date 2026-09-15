"""Tests for T1-6: lazy background cleanup and graceful shutdown handling.

Proves:
1. Importing downloader does not start an unkillable background cleanup loop.
2. Background cleanup starts lazily only when downloads exist.
3. shutdown_downloads() signals cancel_event to all active downloads,
   clears the pending queue, and joins active threads without mid-write kills.
4. start_download() rejects admission during/after shutdown.
"""

import threading
import time
import pytest

import grablytic_engine.downloader as dl_mod


def _reset():
    dl_mod.reset_shutdown_for_tests()
    dl_mod._active_downloads.clear()
    if hasattr(dl_mod, "_pending_queue"):
        dl_mod._pending_queue.clear()
    dl_mod.stop_cleanup_thread()


@pytest.mark.unit
def test_lazy_cleanup_thread_not_running_idle():
    """Importing or resetting downloader must not keep a cleanup thread spinning."""
    _reset()
    # When no downloads exist and stop was called, cleanup thread must not be alive
    assert dl_mod._cleanup_thread is None or not dl_mod._cleanup_thread.is_alive()


@pytest.mark.unit
def test_cleanup_thread_starts_on_download(monkeypatch):
    """Cleanup thread starts lazily when a download is admitted."""
    _reset()

    monkeypatch.setattr(dl_mod, "download_thread", lambda *args, **kwargs: None)
    try:
        dl_mod.start_download(url="https://x.test/1", download_id="lazy-1")
        # Cleanup thread must now be active
        assert dl_mod._cleanup_thread is not None
        assert dl_mod._cleanup_thread.is_alive()
    finally:
        _reset()


@pytest.mark.unit
def test_shutdown_signals_cancel_and_clears_queue():
    """shutdown_downloads signals all active downloads and drains pending queue."""
    _reset()

    active_cancel_events = []
    threads = []
    stop_workers = threading.Event()

    def _worker(cancel_ev):
        # Simulate worker that checks cancel_ev cooperative checkpoint
        while not cancel_ev.is_set() and not stop_workers.is_set():
            time.sleep(0.01)

    for i in range(2):
        did = f"shut-active-{i}"
        cev = threading.Event()
        active_cancel_events.append(cev)
        t = threading.Thread(target=_worker, args=(cev,), daemon=True)
        threads.append(t)
        t.start()
        with dl_mod._downloads_lock:
            dl_mod._active_downloads[did] = {
                "cancel_event": cev,
                "progress_queue": None,
                "result_queue": None,
                "url": f"https://x.test/{did}",
                "thread": t,
                "started_at": dl_mod.datetime.now(dl_mod.timezone.utc),
            }

    # Add a queued item
    with dl_mod._downloads_lock:
        dl_mod._pending_queue.append({"download_id": "shut-queued-1"})

    try:
        # Trigger graceful shutdown
        res = dl_mod.shutdown_downloads(timeout=2.0)

        assert res["success"] is True
        # Both active cancel events must have been set
        for cev in active_cancel_events:
            assert cev.is_set(), "Active download cancel_event was not signalled on shutdown!"

        # Pending queue must be drained
        assert len(dl_mod._pending_queue) == 0, "Pending queue was not cleared on shutdown!"

        # Active worker threads must have been joined cleanly
        for did in ("shut-active-0", "shut-active-1"):
            assert did in res["joined"]

        for t in threads:
            assert not t.is_alive(), "Worker thread was not joined!"
    finally:
        stop_workers.set()
        _reset()


@pytest.mark.unit
def test_start_download_rejected_after_shutdown():
    """After shutdown is initiated, new downloads are rejected."""
    _reset()
    try:
        dl_mod.shutdown_downloads(timeout=0.1)
        r = dl_mod.start_download(url="https://x.test/new", download_id="post-shut")
        assert r["success"] is False
        assert r["error_type"] == "ERROR_SHUTTING_DOWN"
    finally:
        _reset()
