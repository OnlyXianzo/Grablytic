"""A retry backoff must NOT hold the concurrency slot.

The teardown finding: a transient failure slept 5s (then 15s) inside the
already-admitted slot, so the engine sat idle with N-1 usable slots for
the whole backoff window. The slot is now released for the duration of
the sleep and re-acquired afterwards — without barging past a live
download.
"""

import threading

import pytest

# Captured BEFORE the fixture patches `threading.Thread`: the tests below
# need REAL threads to exercise the blocking wait.
_REAL_THREAD = threading.Thread


def _dl():
    import grablytic_engine.downloader as dl_mod

    return dl_mod


class _NoopThread:
    def __init__(self, *args, **kwargs):
        pass

    def start(self):
        pass

    def is_alive(self):
        return False

    def join(self, timeout=None):
        pass


@pytest.fixture(autouse=True)
def _clean_engine_state(monkeypatch):
    dl = _dl()
    monkeypatch.setattr(dl.threading, "Thread", _NoopThread)
    with dl._downloads_lock:
        dl._active_downloads.clear()
        dl._live_url_index.clear()
        dl._pending_queue.clear()
    dl.set_max_concurrent(2)
    yield
    with dl._downloads_lock:
        dl._active_downloads.clear()
        dl._live_url_index.clear()
        dl._pending_queue.clear()
    dl.set_max_concurrent(2)


@pytest.mark.unit
def test_backoff_releases_the_slot_during_the_sleep(monkeypatch):
    """The slot is handed back while the download sleeps."""
    dl = _dl()
    observed = {}

    def fake_sleep(seconds):
        observed["delay"] = seconds
        observed["running_during_sleep"] = dl._running_count()

    monkeypatch.setattr(dl.time, "sleep", fake_sleep)
    dl.start_download(url="https://example.com/a", download_id="a")
    assert dl._running_count() == 1

    dl._begin_backoff("a", 5.0, None)

    assert observed["delay"] == 5.0
    assert observed["running_during_sleep"] == 0
    # After the backoff the slot is held again.
    assert dl._running_count() == 1


@pytest.mark.unit
def test_backoff_sleeps_the_documented_policy(monkeypatch):
    """The 5s/15s policy stays observable (and is not silently changed)."""
    dl = _dl()
    delays = []
    monkeypatch.setattr(dl.time, "sleep", lambda s: delays.append(s))
    dl.start_download(url="https://example.com/b", download_id="b")
    dl._begin_backoff("b", dl._RETRY_BACKOFF_SECONDS[0], None)
    dl._begin_backoff("b", dl._RETRY_BACKOFF_SECONDS[1], None)
    assert delays == [5.0, 15.0]


@pytest.mark.unit
def test_backoff_promotes_a_queued_download(monkeypatch):
    """A waiting download starts while the failing one backs off."""
    dl = _dl()
    monkeypatch.setattr(dl.time, "sleep", lambda s: None)
    dl.set_max_concurrent(1)
    try:
        dl.start_download(url="https://example.com/a", download_id="a")
        dl.start_download(url="https://example.com/b", download_id="b")
        assert "b" in dl._pending_queue

        cancel = threading.Event()
        cancel.set()  # do not wait for a slot on the way back in
        dl._begin_backoff("a", 5.0, cancel)

        assert "b" not in dl._pending_queue
        assert "b" in dl._active_downloads
    finally:
        dl.set_max_concurrent(2)


@pytest.mark.unit
def test_backoff_does_not_barge_past_a_live_download(monkeypatch):
    """The retry waits for a free slot instead of stealing one."""
    dl = _dl()
    monkeypatch.setattr(dl.time, "sleep", lambda s: None)
    dl.set_max_concurrent(1)
    try:
        dl.start_download(url="https://example.com/a", download_id="a")
        # A second live download takes the only slot.
        with dl._downloads_lock:
            dl._active_downloads["z"] = {
                "url": "https://example.com/z",
                "audio_only": False,
                "finished_at": None,
            }
        done = threading.Event()

        def _backoff():
            dl._begin_backoff("a", 0.0, None)
            done.set()

        t = _REAL_THREAD(target=_backoff, daemon=True)
        t.start()
        assert not done.wait(1.0), "the retry resumed while the slot was taken"

        # Free the slot: the retry may now resume.
        with dl._downloads_lock:
            dl._active_downloads.pop("z", None)
        dl._notify_slot_change()
        assert done.wait(3.0)
    finally:
        dl.set_max_concurrent(2)


@pytest.mark.unit
def test_backoff_is_cancelled_by_a_cancel_event(monkeypatch):
    """A cancel during the backoff stops the wait immediately."""
    dl = _dl()
    monkeypatch.setattr(dl.time, "sleep", lambda s: None)
    dl.set_max_concurrent(1)
    try:
        dl.start_download(url="https://example.com/a", download_id="a")
        with dl._downloads_lock:
            dl._active_downloads["z"] = {
                "url": "https://example.com/z",
                "audio_only": False,
                "finished_at": None,
            }
        cancel = threading.Event()
        cancel.set()
        done = threading.Event()

        def _backoff():
            dl._begin_backoff("a", 0.0, cancel)
            done.set()

        t = _REAL_THREAD(target=_backoff, daemon=True)
        t.start()
        assert done.wait(3.0), "a cancelled backoff must not wait for a slot"
    finally:
        dl.set_max_concurrent(2)
