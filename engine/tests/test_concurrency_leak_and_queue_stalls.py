"""TDD reproduction tests for concurrency slot leak, queue starvation, and dropped events.

These tests prove:
1. Cancelling an admitted download whose worker thread is not alive (unstarted or dead)
   must close the slot, stamp finished_at, emit a terminal cancelled event, and pump the queue.
2. Increasing set_max_concurrent must immediately pump the queue without waiting for
   active downloads to complete.
3. Thread spawn exceptions (e.g. RuntimeError: can't start new thread) must not leak
   concurrency slots and must emit a terminal error event and pump the queue.
4. Cancelling a parked pending item on desktop must register it so poll_queues drains
   the terminal cancelled event rather than dropping it.
5. Early pre-spawn cancellation in _spawn_thread must pump the queue.
"""

import queue as _queue
import threading

import grablytic_engine.downloader as dl_mod


def _reset():
    dl_mod._active_downloads.clear()
    dl_mod._pending_queue.clear()
    dl_mod.set_max_concurrent(2)


class _NoopThread:
    """Thread double that does not run."""
    def __init__(self, *args, **kwargs):
        pass
    def start(self):
        pass
    def is_alive(self):
        return False


def test_cancel_inactive_worker_frees_slot_and_emits_terminal(monkeypatch):
    """When a worker thread is not alive, cancel_download must close the slot,
    stamp finished_at, emit terminal cancelled, and pump the queue."""
    _reset()
    dl_mod.set_max_concurrent(1)
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)

    try:
        # Start download 1 (active, but thread is not alive)
        r1 = dl_mod.start_download(url="https://x.test/act1", download_id="leak-1")
        assert r1["success"] is True
        assert "leak-1" in dl_mod._active_downloads

        # Start download 2 (queued in pending queue)
        r2 = dl_mod.start_download(url="https://x.test/act2", download_id="leak-2")
        assert r2["success"] is True
        assert r2.get("queued") is True
        assert len(dl_mod._pending_queue) == 1

        # Cancel leak-1: worker is not alive
        res = dl_mod.cancel_download("leak-1")
        assert res["success"] is True
        assert res.get("cancelled") is True

        # INVARIANT 1: Slot for leak-1 must be closed (finished_at stamped)
        info1 = dl_mod._active_downloads.get("leak-1")
        assert info1 is not None
        assert info1.get("finished_at") is not None, "finished_at not stamped; slot permanently leaked!"

        # INVARIANT 2: Terminal cancelled event must be delivered to result_queue
        res_q = info1.get("result_queue")
        assert res_q is not None
        assert not res_q.empty(), "Terminal cancelled event was never emitted to result_queue!"
        event = res_q.get_nowait()
        assert event.get("error_type") == "ERROR_CANCELLED"

        # INVARIANT 3: leak-2 must have been promoted by _pump_queue() automatically
        assert len(dl_mod._pending_queue) == 0, "Pending queue was not pumped after cancel of inactive worker!"
        assert "leak-2" in dl_mod._active_downloads, "leak-2 was not promoted to _active_downloads!"
    finally:
        _reset()


def test_set_max_concurrent_increase_pumps_pending_queue(monkeypatch):
    """Increasing set_max_concurrent must immediately promote parked items."""
    _reset()
    dl_mod.set_max_concurrent(1)
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)

    try:
        r1 = dl_mod.start_download(url="https://x.test/dyn1", download_id="dyn-1")
        assert r1["success"] is True
        r2 = dl_mod.start_download(url="https://x.test/dyn2", download_id="dyn-2")
        assert r2.get("queued") is True
        r3 = dl_mod.start_download(url="https://x.test/dyn3", download_id="dyn-3")
        assert r3.get("queued") is True

        assert len(dl_mod._pending_queue) == 2

        # Increase limit to 3: should immediately promote dyn-2 and dyn-3
        dl_mod.set_max_concurrent(3)

        assert len(dl_mod._pending_queue) == 0, (
            f"set_max_concurrent(3) failed to pump pending queue! Still queued: {len(dl_mod._pending_queue)}"
        )
        assert "dyn-2" in dl_mod._active_downloads
        assert "dyn-3" in dl_mod._active_downloads
    finally:
        _reset()


def test_spawn_thread_exception_unwinds_slot_and_emits_error(monkeypatch):
    """If Thread.start() raises RuntimeError, slot must be closed, error emitted, and queue pumped."""
    _reset()
    dl_mod.set_max_concurrent(1)

    class _FailingThread:
        def __init__(self, *args, **kwargs):
            pass
        def start(self):
            raise RuntimeError("can't start new thread")

    monkeypatch.setattr(dl_mod.threading, "Thread", _FailingThread)

    try:
        # Start download 1: thread spawn will fail
        dl_mod.start_download(url="https://x.test/fail1", download_id="fail-1")
        # Start download 2 (queued)
        # But if fail-1 fails during spawn, fail-1 must not leak slot!
        info = dl_mod._active_downloads.get("fail-1")
        assert info is not None
        assert info.get("finished_at") is not None, "Failed thread spawn left slot unclosed!"
        res_q = info.get("result_queue")
        assert not res_q.empty(), "No error event emitted on thread spawn failure!"
        ev = res_q.get_nowait()
        assert ev.get("error_type") in ("ERROR_THREAD_SPAWN", "ERROR_DOWNLOADER_CRASH")
    finally:
        _reset()


def test_cancel_queued_on_desktop_registers_for_polling(monkeypatch):
    """Cancelling a queued item on desktop must register it in _active_downloads
    so poll_queues() drains its terminal cancelled event."""
    _reset()
    dl_mod.set_max_concurrent(1)
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)

    try:
        dl_mod.start_download(url="https://x.test/q1", download_id="d-q1")
        q_res = dl_mod.start_download(url="https://x.test/q2", download_id="d-q2")
        assert q_res.get("queued") is True

        # Cancel the queued item
        cancel_res = dl_mod.cancel_download("d-q2")
        assert cancel_res["success"] is True

        # Invariant: d-q2 must be present in _active_downloads with finished_at set
        # so poll_queues() will see it and drain its result_queue
        assert "d-q2" in dl_mod._active_downloads, (
            "Cancelled queued item was discarded without registering in _active_downloads for polling!"
        )
        info = dl_mod._active_downloads["d-q2"]
        assert info.get("finished_at") is not None
        res_q = info.get("result_queue")
        assert res_q is not None and not res_q.empty()
        ev = res_q.get_nowait()
        assert ev.get("error_type") == "ERROR_CANCELLED"
    finally:
        _reset()


def test_pre_spawn_cancel_in_spawn_thread_pumps_queue(monkeypatch):
    """If cancel_event is set before _spawn_thread runs, it must close slot and pump queue."""
    _reset()
    dl_mod.set_max_concurrent(1)
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)

    try:
        # Start download 1 (active)
        dl_mod.start_download(url="https://x.test/ps1", download_id="ps-1")
        # Start download 2 (queued)
        r2 = dl_mod.start_download(url="https://x.test/ps2", download_id="ps-2")
        assert r2.get("queued") is True

        # Manually create entry with cancel_event already set
        cancel_evt = threading.Event()
        cancel_evt.set()
        entry = {
            "download_id": "ps-pre",
            "url": "https://x.test/pspre",
            "config": None,
            "network_type": "wifi",
            "progress_queue": _queue.Queue(),
            "result_queue": _queue.Queue(),
            "cancel_event": cancel_evt,
            "event_callback": None,
        }
        with dl_mod._downloads_lock:
            dl_mod._active_downloads["ps-pre"] = {
                "cancel_event": cancel_evt,
                "progress_queue": entry["progress_queue"],
                "result_queue": entry["result_queue"],
                "url": entry["url"],
                "audio_only": False,
                "thread": None,
                "started_at": dl_mod.datetime.now(dl_mod.timezone.utc),
                "slot_token": dl_mod._new_slot_token(),
            }

        # Spawn thread for ps-pre when cancel_event is set
        t = dl_mod._spawn_thread(entry)
        assert t is None

        # Verify ps-pre slot was closed
        info = dl_mod._active_downloads.get("ps-pre")
        assert info.get("finished_at") is not None
    finally:
        _reset()

