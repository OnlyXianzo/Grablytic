"""T1-3 engine honesty tests: cancel must not claim completion prematurely.

Contract under test (see GRABLYTIC_TEARDOWN.md T1-3 + arjun.md T1-3 statement):
  * queued dequeue / pre-spawn / already-terminal entry → terminal
    `{success: True, cancelled: True}` (nothing remains running — honest).
  * LIVE worker thread → `{success: True, cancelled: False, cancelling: True}`
    + watchdog; the terminal `cancelled` arrives later via the normal channel
    (worker exit) or the watchdog (wedged worker, presumed-stopped).
  * NOT_FOUND shape unchanged.

All workers here are REAL threads (never test doubles without is_alive —
doubles take the legacy terminal path by design) running download_thread
against a blocking FakeYDL (hook-blind wedge: no progress callbacks ever).
"""

import queue as _queue
import threading
import time

import pytest

import grablytic_engine.downloader as dl_mod


@pytest.fixture
def _engine_env(tmp_path, monkeypatch):
    """Minimal live engine state: real dirs, executable fake ffmpeg.

    FakeYDL blocks on `gate` until the test releases it — a true hook-blind
    wedge: cooperative cancel can never observe it.
    """
    gate = threading.Event()
    calls = {"downloads": 0}

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
            calls["downloads"] += 1
            gate.wait(timeout=30)  # wedge: no hooks fire while blocked

    monkeypatch.setattr(dl_mod, "YoutubeDL", FakeYDL)
    try:
        yield {"gate": gate, "calls": calls}
    finally:
        gate.set()
        # Release + reap any live workers so no thread/expired entry leaks
        # into later tests (daemon threads would survive; map entries would).
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


def _drain_result(download_id):
    info = dl_mod._active_downloads.get(download_id)
    res_q = info.get("result_queue") if info else None
    out = []
    if res_q is not None:
        try:
            while True:
                out.append(res_q.get_nowait())
        except _queue.Empty:
            pass
    return out


def test_cancel_inflight_returns_cancelling_not_cancelled(_engine_env):
    r = dl_mod.start_download(url="https://x.test/1", download_id="hon-1")
    assert r["success"] is True
    worker = _wait_alive("hon-1")

    res = dl_mod.cancel_download("hon-1")
    assert res["success"] is True
    assert res.get("cancelling") is True
    assert res.get("cancelled") is not True  # THE fix: no premature claim

    # Worker still blocked; no terminal may have been delivered yet.
    assert worker.is_alive()
    assert _drain_result("hon-1") == []

    # Release the wedge: the worker observes cancel and emits the terminal.
    _engine_env["gate"].set()
    worker.join(timeout=10)
    terminal = _drain_result("hon-1")
    assert len(terminal) == 1
    assert terminal[0].get("error_type") == "ERROR_CANCELLED"


def test_watchdog_frees_wedged_worker_and_slot(_engine_env, monkeypatch):
    monkeypatch.setattr(dl_mod, "_CANCEL_WATCHDOG_SECONDS", 0.05)
    r = dl_mod.start_download(url="https://x.test/2", download_id="hon-2")
    assert r["success"] is True
    _wait_alive("hon-2")

    res = dl_mod.cancel_download("hon-2")
    assert res.get("cancelling") is True

    # Watchdog fires: presumed-stopped terminal + slot freed for reuse.
    deadline = time.time() + 5
    terminal = []
    while time.time() < deadline and not terminal:
        terminal = _drain_result("hon-2")
        time.sleep(0.05)
    assert len(terminal) == 1
    assert terminal[0].get("error_type") == "ERROR_CANCELLED"
    assert "presumed stopped" in terminal[0].get("error_message", "")

    info = dl_mod._active_downloads.get("hon-2")
    assert info is not None and info.get("finished_at") is not None
    # Same-id redownload admitted (slot genuinely freed, not stranded).
    r2 = dl_mod.start_download(url="https://x.test/2b", download_id="hon-2")
    assert r2["success"] is True, r2


def test_cancel_without_live_worker_stays_terminal(_engine_env):
    # Thread-double entries (no is_alive, e.g. _NoopThread fixtures) and
    # pre-spawn entries keep the legacy terminal shape (T1-2 pins this).
    dl_mod._active_downloads["hon-3"] = {
        "cancel_event": threading.Event(),
        "progress_queue": _queue.Queue(),
        "result_queue": _queue.Queue(),
        "url": "https://x.test/3",
        "thread": None,
    }
    try:
        res = dl_mod.cancel_download("hon-3")
        assert res["success"] is True
        assert res.get("cancelled") is True
    finally:
        dl_mod._active_downloads.pop("hon-3", None)


def test_cancel_unknown_id_still_not_found(_engine_env):
    res = dl_mod.cancel_download("hon-nope")
    assert res["success"] is False
    assert res.get("error_type") == "ERROR_DOWNLOAD_NOT_FOUND"
