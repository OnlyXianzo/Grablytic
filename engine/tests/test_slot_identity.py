"""BRUTAL-2a slot-identity tests: a stale worker must never close a reused slot.

Contract under test:
  * Every admission mints a unique `slot_token` stored on the active entry.
  * The worker `finally`-block stamps `finished_at` ONLY when the entry
    still carries its own token (slot not reused under the same id).
  * The cancel watchdog applies the same identity check: a presumed-stopped
    terminal + stamp happen only for the worker generation it armed on.
  * Legacy records without a token keep today's stamp behavior (None == None).

Background: the watchdog already refused to close a `finished_at` entry,
but neither it nor the worker `finally` checked GENERATION identity, so a
late-exiting worker (or a watchdog firing after a fast retry) could mark a
fresh download terminal and get it reaped mid-flight by the cleanup loop.
"""

import queue as _queue
import threading
import time

import pytest

import grablytic_engine.downloader as dl_mod


@pytest.fixture
def _engine_env(tmp_path, monkeypatch):
    """Live engine state with a hook-blind wedging FakeYDL (gate-controlled)."""
    gate = threading.Event()

    ffmpeg = tmp_path / "ffmpeg"
    ffmpeg.write_text("#!/bin/sh\nexit 0\n")
    import os as _os
    import stat as _stat
    _os.chmod(str(ffmpeg), _os.stat(str(ffmpeg)).st_mode | _stat.S_IXUSR)

    import grablytic_engine.paths as _paths_mod
    saved_paths = dict(_paths_mod._paths)
    _paths_mod._paths.update({
        "data_dir": str(tmp_path), "output_dir": str(tmp_path),
        "cache_dir": str(tmp_path), "ffmpeg_path": str(ffmpeg),
        "aria2c_path": None, "deno_path": None, "nodejs_path": None,
        "po_token": None, "cookies_path": None, "ffmpeg_ld_path": None,
    })
    dl_mod._active_downloads.clear()
    dl_mod._pending_queue.clear()

    class FakeYDL:
        def __init__(self, opts):
            self.opts = opts
            self.hooks = []

        def add_progress_hook(self, fn):
            self.hooks.append(fn)

        def download(self, urls):
            gate.wait(timeout=30)  # wedge until the test releases

    monkeypatch.setattr(dl_mod, "YoutubeDL", FakeYDL)
    try:
        yield {"gate": gate}
    finally:
        gate.set()
        deadline = time.time() + 10
        while time.time() < deadline:
            live = [i for i in dl_mod._active_downloads.values()
                    if (i.get("thread") is not None
                        and getattr(i["thread"], "is_alive", lambda: False)())]
            if not live:
                break
            time.sleep(0.05)
        for t in [i.get("thread") for i in dl_mod._active_downloads.values()]:
            try:
                if t is not None and hasattr(t, "join"):
                    t.join(timeout=5)
            except Exception:
                pass
        dl_mod._active_downloads.clear()
        dl_mod._pending_queue.clear()
        _paths_mod._paths.clear()
        _paths_mod._paths.update(saved_paths)


def _wait_alive(download_id, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        info = dl_mod._active_downloads.get(download_id)
        th = info.get("thread") if info else None
        if th is not None and th.is_alive():
            return th
        time.sleep(0.02)
    raise AssertionError(f"worker for {download_id} never came alive")


def _drain(q):
    out = []
    if q is not None:
        try:
            while True:
                out.append(q.get_nowait())
        except _queue.Empty:
            pass
    return out


def test_admission_mints_unique_slot_tokens(_engine_env):
    dl_mod.start_download(url="https://x.test/t1", download_id="tok-1")
    _wait_alive("tok-1")
    token_a = dl_mod._active_downloads["tok-1"]["slot_token"]
    assert isinstance(token_a, str) and token_a

    # A second id gets a different token (per-admission identity).
    dl_mod.start_download(url="https://x.test/t2", download_id="tok-2")
    _wait_alive("tok-2")
    token_b = dl_mod._active_downloads["tok-2"]["slot_token"]
    assert isinstance(token_b, str) and token_b
    assert token_a != token_b


def test_stale_worker_finally_does_not_close_reused_slot(_engine_env):
    dl_mod.start_download(url="https://x.test/s1", download_id="slot-1")
    worker_a = _wait_alive("slot-1")
    old_res_q = dl_mod._active_downloads["slot-1"]["result_queue"]

    # Wedge, then request cancel (worker stays blocked; terminal pending).
    res = dl_mod.cancel_download("slot-1")
    assert res.get("cancelling") is True

    # Slot reuse under the same id (what admission does after a release):
    # wholesale replacement entry with its own token and fresh queues.
    fresh_res_q = _queue.Queue()
    with dl_mod._downloads_lock:
        dl_mod._active_downloads["slot-1"] = {
            "cancel_event": threading.Event(),
            "progress_queue": _queue.Queue(),
            "result_queue": fresh_res_q,
            "url": "https://x.test/s1-retry",
            "audio_only": False,
            "thread": None,
            "started_at": dl_mod._active_downloads["slot-1"]["started_at"],
            "slot_token": "token-generation-B",
        }

    # Stale worker A exits now: observes cancel, emits its terminal to ITS
    # queues, and runs its finally-block.
    _engine_env["gate"].set()
    worker_a.join(timeout=10)
    assert not worker_a.is_alive()

    # A's terminal went to A's own queue...
    old_terminal = _drain(old_res_q)
    assert len(old_terminal) == 1
    assert old_terminal[0].get("error_type") == "ERROR_CANCELLED"

    # ...and B's fresh entry is untouched: no stamp, no terminal.
    with dl_mod._downloads_lock:
        entry_b = dl_mod._active_downloads.get("slot-1")
    assert entry_b is not None
    assert entry_b.get("url") == "https://x.test/s1-retry"
    assert "finished_at" not in entry_b
    assert _drain(fresh_res_q) == []


def test_close_own_slot_unit_semantics():
    with dl_mod._downloads_lock:
        dl_mod._active_downloads["u-1"] = {"slot_token": "tok-A"}
        dl_mod._active_downloads["u-2"] = {"slot_token": "tok-B"}
        dl_mod._active_downloads["u-3"] = {}  # legacy record, no token
    try:
        assert dl_mod._close_own_slot("u-1", "tok-A") is True
        assert dl_mod._active_downloads["u-1"].get("finished_at") is not None
        # Wrong generation: refused, unstamped.
        assert dl_mod._close_own_slot("u-2", "tok-STALE") is False
        assert "finished_at" not in dl_mod._active_downloads["u-2"]
        # Legacy (no token anywhere): preserves today's stamp behavior.
        assert dl_mod._close_own_slot("u-3", None) is True
        assert dl_mod._active_downloads["u-3"].get("finished_at") is not None
        # Missing entry: refused, no crash.
        assert dl_mod._close_own_slot("u-nope", "tok-X") is False
    finally:
        with dl_mod._downloads_lock:
            for k in ("u-1", "u-2", "u-3"):
                dl_mod._active_downloads.pop(k, None)


def test_watchdog_does_not_close_reused_slot(_engine_env, monkeypatch):
    monkeypatch.setattr(dl_mod, "_CANCEL_WATCHDOG_SECONDS", 5.0)
    dl_mod.start_download(url="https://x.test/w1", download_id="wd-1")
    worker_a = _wait_alive("wd-1")
    assert worker_a.is_alive()

    # Arm the watchdog, but swap the slot inside join() — deterministically
    # reproducing "retry admitted between watchdog timeout and stamp".
    state = {}

    class SwapOnJoinThread:
        def join(self, timeout=None):
            fresh_q = _queue.Queue()
            with dl_mod._downloads_lock:
                dl_mod._active_downloads["wd-1"] = {
                    "cancel_event": threading.Event(),
                    "progress_queue": _queue.Queue(),
                    "result_queue": fresh_q,
                    "url": "https://x.test/w1-retry",
                    "audio_only": False,
                    "thread": None,
                    "started_at": dl_mod._active_downloads["wd-1"]["started_at"],
                    "slot_token": "token-generation-B",
                }
            state["fresh_q"] = fresh_q

        def is_alive(self):
            return True  # still wedged from the watchdog's view

    dl_mod._start_cancel_watchdog("wd-1", SwapOnJoinThread())
    deadline = time.time() + 5
    while time.time() < deadline:
        if "fresh_q" in state:
            break
        time.sleep(0.02)
    assert "fresh_q" in state
    # Let the watchdog finish its post-join stamp path.
    time.sleep(0.5)

    with dl_mod._downloads_lock:
        entry = dl_mod._active_downloads.get("wd-1")
    assert entry is not None
    assert entry.get("url") == "https://x.test/w1-retry"
    assert "finished_at" not in entry
    assert _drain(state["fresh_q"]) == []
