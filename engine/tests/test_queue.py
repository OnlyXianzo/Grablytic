"""Download queue / concurrency limit (Milestone 1, TDD repro).

Expected behavior (Verified Approach):
- Default max 2 concurrent, configurable 1-5 (clamped).
- start_download admits when under limit, queues (FIFO) when at limit.
- Promotion when a slot frees up.
- Duplicate active/queued id rejected (prevents redownload-while-active collision).
- Queued cancel dequeues without spawning a thread.
"""

import queue as _queue

import grablytic_engine.downloader as dl_mod


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


def test_register_before_start_race(monkeypatch):
    """T1-1: Prove that _active_downloads is populated BEFORE t.start() runs.
    
    A fast cancel issued during t.start() must find the download in
    _active_downloads and succeed, rather than hitting NOT_FOUND.
    """
    _reset()
    seen_in_active_during_start = []
    cancel_result_during_start = []

    class _VerifyingThread:
        def __init__(self, *args, **kwargs):
            self.download_id = kwargs.get("args", (None, None))[1]

        def start(self):
            # Inside start(), the download MUST already be registered in _active_downloads
            with dl_mod._downloads_lock:
                registered = self.download_id in dl_mod._active_downloads
                seen_in_active_during_start.append(registered)
            # A fast cancel issued in this exact window must find it
            res = dl_mod.cancel_download(self.download_id)
            cancel_result_during_start.append(res)

    monkeypatch.setattr(dl_mod.threading, "Thread", _VerifyingThread)
    r = dl_mod.start_download(url="https://x.test/1", download_id="race-1")
    try:
        assert r["success"] is True
        assert len(seen_in_active_during_start) == 1
        assert seen_in_active_during_start[0] is True, (
            "Registration happened after start()! Classic register-after-start race."
        )
        assert len(cancel_result_during_start) == 1
        assert cancel_result_during_start[0]["success"] is True
        assert cancel_result_during_start[0].get("error_type") != "ERROR_DOWNLOAD_NOT_FOUND"
    finally:
        dl_mod._active_downloads.pop("race-1", None)


def test_pump_queue_cancel_loss_window_terminal_cancelled(monkeypatch):
    """T1-2 / HQ2: Prove that cancelling between pop and spawn in _pump_queue
    results in a terminal 'cancelled' event delivered to the caller, and
    no phantom download thread is spawned.
    """
    import json
    _reset()
    events_received = []

    class _Callback:
        def onEvent(self, event_json):
            events_received.append(json.loads(event_json))

    cb_obj = _Callback()

    threads_spawned = []
    real_spawn_thread = dl_mod._spawn_thread

    def _intercept_spawn(entry):
        if entry["download_id"] == "q-loss-3":
            # Cancel issued right after pop in _pump_queue, before thread spawn
            res = dl_mod.cancel_download("q-loss-3")
            assert res["success"] is True
            assert res.get("cancelled") is True
            assert res.get("error_type") != "ERROR_DOWNLOAD_NOT_FOUND"
        t = real_spawn_thread(entry)
        if t is not None:
            threads_spawned.append(entry["download_id"])
        return t

    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    monkeypatch.setattr(dl_mod, "_spawn_thread", _intercept_spawn)

    # 1. Fill slots
    dl_mod.start_download(url="https://x.test/1", download_id="q-loss-1")
    dl_mod.start_download(url="https://x.test/2", download_id="q-loss-2")

    # 2. Queue the 3rd item with event_callback
    q = dl_mod.start_download(
        url="https://x.test/3",
        download_id="q-loss-3",
        event_callback=cb_obj,
    )
    assert q.get("queued") is True
    assert any(ev.get("event") == "queued" for ev in events_received)

    try:
        # 3. Free a slot and trigger _pump_queue()
        import datetime
        dl_mod._active_downloads["q-loss-1"]["finished_at"] = (
            datetime.datetime.now(datetime.timezone.utc)
        )
        dl_mod._pump_queue()

        # 4. Verify the terminal event received by the caller
        terminal_events = [ev for ev in events_received if ev.get("event") == "cancelled"]
        assert len(terminal_events) == 1, f"Expected terminal 'cancelled' event, got: {events_received}"
        term = terminal_events[0]
        assert term["download_id"] == "q-loss-3"
        assert term["error_type"] == "ERROR_CANCELLED"
        assert "cancelled by user" in term.get("error_message", "").lower()

        # 5. Prove no phantom thread was spawned for q-loss-3
        assert "q-loss-3" not in threads_spawned
    finally:
        for did in ("q-loss-1", "q-loss-2", "q-loss-3"):
            dl_mod._active_downloads.pop(did, None)
        dl_mod._pending_queue.clear()




def _cleanup(*ids):
    for did in ids:
        dl_mod._active_downloads.pop(did, None)
    dl_mod._pending_queue.clear()


class TestUrlDedup:
    """T1-5: same URL under N different IDs must not download N times."""

    def test_duplicate_url_while_active_rejected(self, monkeypatch):
        _reset()
        monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
        try:
            r1 = dl_mod.start_download(url="https://x.test/dup", download_id="dup-1")
            assert r1["success"] is True
            r2 = dl_mod.start_download(url="https://x.test/dup", download_id="dup-2")
            assert r2["success"] is False
            assert r2["error_type"] == "ERROR_DUPLICATE_URL"
            assert r2.get("existing_download_id") == "dup-1"
            # First download unaffected.
            assert "dup-1" in dl_mod._active_downloads
            assert "dup-2" not in dl_mod._active_downloads
        finally:
            _cleanup("dup-1", "dup-2")

    def test_duplicate_url_while_queued_rejected(self, monkeypatch):
        _reset()
        monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
        try:
            dl_mod.start_download(url="https://x.test/a", download_id="dq-1")
            dl_mod.start_download(url="https://x.test/b", download_id="dq-2")
            q = dl_mod.start_download(url="https://x.test/c", download_id="dq-3")
            assert q.get("queued") is True
            r = dl_mod.start_download(url="https://x.test/c", download_id="dq-4")
            assert r["success"] is False
            assert r["error_type"] == "ERROR_DUPLICATE_URL"
            assert r.get("existing_download_id") == "dq-3"
        finally:
            _cleanup("dq-1", "dq-2", "dq-3", "dq-4")

    def test_same_url_audio_extract_allowed_alongside_video(self, monkeypatch):
        _reset()
        monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
        try:
            r1 = dl_mod.start_download(url="https://x.test/m", download_id="m-vid")
            assert r1["success"] is True
            # Extract-audio re-fetch is an explicit user action producing a
            # different artifact — must not be blocked as a duplicate.
            r2 = dl_mod.start_download(
                url="https://x.test/m", download_id="m-aud",
                config={"audio_only": True},
            )
            assert r2["success"] is True, r2
        finally:
            _cleanup("m-vid", "m-aud")

    def test_same_url_readmitted_after_finish(self, monkeypatch):
        _reset()
        monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
        import datetime
        try:
            r1 = dl_mod.start_download(url="https://x.test/r", download_id="re-1")
            assert r1["success"] is True
            # Terminal entries awaiting cleanup must not block re-download.
            dl_mod._active_downloads["re-1"]["finished_at"] = (
                datetime.datetime.now(datetime.timezone.utc)
            )
            r2 = dl_mod.start_download(url="https://x.test/r", download_id="re-2")
            assert r2["success"] is True, r2
        finally:
            _cleanup("re-1", "re-2")


def test_progress_queues_are_bounded(monkeypatch):
    """E2 regression: admission queues must carry maxsize so drop-oldest
    engages; unbounded queues retained tens of thousands of ticks (OOM)."""
    from grablytic_engine.hooks import _QUEUE_MAXSIZE
    _reset()
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    try:
        r = dl_mod.start_download(url="https://x.test/b", download_id="b-1")
        assert r["success"] is True
        entry = dl_mod._active_downloads["b-1"]
        assert entry["progress_queue"].maxsize == _QUEUE_MAXSIZE
        assert entry["result_queue"].maxsize == _QUEUE_MAXSIZE
    finally:
        _cleanup("b-1")


def test_ydlogger_output_files_capped_and_deduped():
    """E2 regression: output_files can never grow without bound and
    duplicate log lines must not rescan an O(n) list."""
    from grablytic_engine.downloader import YDLogger
    yd = YDLogger()
    yd._extract_path('[download] Destination: /tmp/a.mp4')
    yd._extract_path('[download] Destination: /tmp/a.mp4')
    assert yd.output_files == ['/tmp/a.mp4']
    for i in range(yd.MAX_OUTPUT_FILES + 100):
        yd._extract_path(f'[download] Destination: /tmp/f{i}.mp4')
    assert len(yd.output_files) <= yd.MAX_OUTPUT_FILES


def test_close_own_slot_is_idempotent(monkeypatch):
    """Watchdog close followed by late worker finally must not double-pump."""
    _reset()
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    try:
        dl_mod.start_download(url="https://x.test/i", download_id="i-1")
        token = dl_mod._active_downloads["i-1"].get("slot_token")
        assert dl_mod._close_own_slot("i-1", token) is True
        assert dl_mod._close_own_slot("i-1", token) is False
        assert dl_mod._close_own_slot("i-1", "wrong-token") is False
    finally:
        _cleanup("i-1")


def test_queued_promotion_is_pollable_on_desktop(monkeypatch):
    """Desktop (no callback) must observe promoted_from_queue in its
    progress queue; previously only the callback path emitted it."""
    import json as _json
    _reset()
    dl_mod.set_max_concurrent(1)
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    try:
        r1 = dl_mod.start_download(url="https://x.test/p1", download_id="pr-1")
        assert r1["success"] is True
        r2 = dl_mod.start_download(url="https://x.test/p2", download_id="pr-2")
        assert r2.get("queued") is True
        token = dl_mod._active_downloads["pr-1"].get("slot_token")
        assert dl_mod._close_own_slot("pr-1", token) is True
        dl_mod._pump_queue()
        prog_q = dl_mod._active_downloads["pr-2"]["progress_queue"]
        found = False
        while not prog_q.empty():
            ev = _json.loads(prog_q.get_nowait())
            if ev.get("promoted_from_queue") is True and ev.get("download_id") == "pr-2":
                found = True
        assert found, "promotion event missing from desktop progress queue"
    finally:
        dl_mod.set_max_concurrent(2)
        _cleanup("pr-1", "pr-2")


def test_pending_queue_rejects_when_full(monkeypatch):
    """FLAW E-R1: start_download must reject with ERROR_QUEUE_FULL when queue cap reached."""
    _reset()
    dl_mod.set_max_concurrent(1)
    monkeypatch.setattr(dl_mod, "_MAX_PENDING_QUEUE", 3)
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    ids = ["act-0", "q-0", "q-1", "q-2", "overflow-1"]
    try:
        r_act = dl_mod.start_download(url="https://x.test/act", download_id="act-0")
        assert r_act["success"] is True
        for i in range(3):
            r = dl_mod.start_download(url=f"https://x.test/q{i}", download_id=f"q-{i}")
            assert r["success"] is True
            assert r.get("queued") is True

        assert len(dl_mod._pending_queue) == 3

        # 4th pending item must be rejected
        r_overflow = dl_mod.start_download(url="https://x.test/overflow", download_id="overflow-1")
        assert r_overflow["success"] is False
        assert r_overflow["error_type"] == "ERROR_QUEUE_FULL"
        assert r_overflow["queue_size"] == 3
        assert r_overflow["max_queue_size"] == 3
        assert len(dl_mod._pending_queue) == 3
        assert "overflow-1" not in dl_mod._active_downloads
        assert not any(e["download_id"] == "overflow-1" for e in dl_mod._pending_queue)
    finally:
        dl_mod.set_max_concurrent(2)
        _cleanup(*ids)


def test_queue_rejection_allocates_no_resources(monkeypatch):
    """FLAW E-R1: Rejected downloads must not allocate Queues or Events."""
    import queue as _q
    _reset()
    dl_mod.set_max_concurrent(1)
    monkeypatch.setattr(dl_mod, "_MAX_PENDING_QUEUE", 1)
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)

    alloc_count = [0]
    orig_queue = _q.Queue

    def _counting_queue(*args, **kwargs):
        alloc_count[0] += 1
        return orig_queue(*args, **kwargs)

    monkeypatch.setattr(dl_mod._queue, "Queue", _counting_queue)

    ids = ["act-res", "q-res", "overflow-res"]
    try:
        dl_mod.start_download(url="https://x.test/act-res", download_id="act-res")
        dl_mod.start_download(url="https://x.test/q-res", download_id="q-res")
        before_count = alloc_count[0]

        res = dl_mod.start_download(url="https://x.test/overflow-res", download_id="overflow-res")
        assert res["success"] is False
        assert res["error_type"] == "ERROR_QUEUE_FULL"
        # Zero queue allocations for rejected admission
        assert alloc_count[0] == before_count
    finally:
        dl_mod.set_max_concurrent(2)
        _cleanup(*ids)


def test_queue_promotion_unblocks_after_queue_full(monkeypatch):
    """FLAW E-R1: Releasing slot unblocks queue and allows new admissions."""
    _reset()
    dl_mod.set_max_concurrent(1)
    monkeypatch.setattr(dl_mod, "_MAX_PENDING_QUEUE", 1)
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)

    ids = ["act-p", "q-p", "new-p"]
    try:
        dl_mod.start_download(url="https://x.test/act-p", download_id="act-p")
        dl_mod.start_download(url="https://x.test/q-p", download_id="q-p")

        # Full now
        r_blocked = dl_mod.start_download(url="https://x.test/block", download_id="block")
        assert r_blocked["success"] is False
        assert r_blocked["error_type"] == "ERROR_QUEUE_FULL"

        # Release act-p
        token = dl_mod._active_downloads["act-p"].get("slot_token")
        assert dl_mod._close_own_slot("act-p", token) is True
        dl_mod._pump_queue()

        # q-p is now active, pending queue has space
        assert len(dl_mod._pending_queue) == 0
        r_new = dl_mod.start_download(url="https://x.test/new-p", download_id="new-p")
        assert r_new["success"] is True
        assert r_new.get("queued") is True
        assert len(dl_mod._pending_queue) == 1
    finally:
        dl_mod.set_max_concurrent(2)
        _cleanup(*ids, "block")

