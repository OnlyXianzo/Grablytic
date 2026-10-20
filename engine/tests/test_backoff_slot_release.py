"""Retry backoff: the slot is released for work but reserved for the retry.

The first teardown finding was that a transient failure slept 5s (then
15s) inside the already-admitted slot, so the engine sat idle with N-1
usable slots for the whole backoff window. The slot is therefore not
held as a *working* slot during the sleep.

The second, subtler finding is the one these tests now pin down: if the
released slot is simply handed to the next queued entry, then in a deep
queue every completion can refill it before the retry wakes, and the
retry waits for ever — a hang with no timeout, because `_MAX_AUTO_RETRIES`
counts attempts, not time. So the slot is a RESERVATION: `_running_count()`
stops counting the sleeper, `_backoff_reservations()` still does, and no
admission path may spend a reserved slot.
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
        """No initialization is needed for this test double."""

    def start(self):
        """Do not execute the thread target in these tests."""

    @staticmethod
    def is_alive():
        return False

    def join(self, timeout=None):
        """The no-op thread has nothing to join."""


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
def test_backoff_reserves_the_slot_against_the_queue(monkeypatch):
    """The queue may not take the slot a retrying download is coming back to.

    At the only slot, promoting "b" during the backoff means "a" has to
    wait for "b" to finish and then for whatever the queue promotes next;
    with a deep backlog that never ends. "b" stays parked instead.
    """
    dl = _dl()
    observed = {}

    def fake_sleep(seconds):
        observed["running"] = dl._running_count()
        observed["reserved"] = dl._backoff_reservations()
        dl._pump_queue()  # the pump runs on every terminal transition
        observed["b_still_parked"] = "b" in dl._pending_queue

    monkeypatch.setattr(dl.time, "sleep", fake_sleep)
    dl.set_max_concurrent(1)
    try:
        dl.start_download(url="https://example.com/a", download_id="a")
        dl.start_download(url="https://example.com/b", download_id="b")
        assert "b" in dl._pending_queue

        cancel = threading.Event()
        cancel.set()  # do not wait for a slot on the way back in
        dl._begin_backoff("a", 5.0, cancel)

        # The sleeper does not consume a working slot ...
        assert observed["running"] == 0
        # ... but the budget still accounts for it ...
        assert observed["reserved"] == 1
        # ... so the pump cannot spend that slot on the queue.
        assert observed["b_still_parked"] is True
        assert "b" in dl._pending_queue
        assert "b" not in dl._active_downloads
        # The retry itself is back in the slot after waking.
        assert dl._running_count() == 1
    finally:
        dl.set_max_concurrent(2)


@pytest.mark.unit
def test_backoff_keeps_one_slot_free_at_higher_limits(monkeypatch):
    """Reservations subtract from the limit; they do not freeze the queue."""
    dl = _dl()
    monkeypatch.setattr(dl.time, "sleep", lambda s: None)
    dl.set_max_concurrent(2)
    try:
        dl.start_download(url="https://example.com/a", download_id="a")
        dl.start_download(url="https://example.com/b", download_id="b")
        dl.start_download(url="https://example.com/c", download_id="c")
        # Two slots, so a and b are admitted and only c is parked.
        assert dl._running_count() == 2
        assert set(dl._pending_queue) == {"c"}

        with dl._downloads_lock:
            dl._active_downloads["a"]["backing_off"] = True
        dl._pump_queue()

        # 1 running (b) + 1 reserved (a) == the limit: c must not start.
        assert set(dl._pending_queue) == {"c"}

        # When b finishes, a's reservation becomes a running slot and the
        # engine is full again — c is admitted only after that.
        with dl._downloads_lock:
            dl._active_downloads["b"]["finished_at"] = 1
            dl._active_downloads["a"]["backing_off"] = False
        dl._pump_queue()
        assert dl._running_count() == 2
        assert set(dl._pending_queue) == set()
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


def test_expired_slot_wait_does_not_proceed(monkeypatch):
    """A retry that never gets capacity must not run anyway.

    Lowering the limit mid-backoff used to let every sleeper resume when
    its 300 s deadline expired, so N downloads ran against a limit of 1.
    The wait now reports failure and the caller ends the attempt.
    """
    dl = _dl()
    monkeypatch.setattr(dl.time, "sleep", lambda s: None)
    monkeypatch.setattr(dl, "_MAX_BACKOFF_SLOT_WAIT_S", -1.0)
    dl.set_max_concurrent(1)
    try:
        dl.start_download(url="https://example.com/a", download_id="a")
        with dl._downloads_lock:
            dl._active_downloads["z"] = {
                "url": "https://example.com/z",
                "audio_only": False,
                "finished_at": None,
            }
        assert dl._begin_backoff("a", 0.0, None) is False
        with dl._downloads_lock:
            assert dl._active_downloads["a"].get("backoff_slot_wait_expired") is True
            # The reservation is released either way, so the queue is not
            # permanently short a slot.
            assert dl._active_downloads["a"].get("backing_off") is False
    finally:
        dl.set_max_concurrent(2)


def test_expired_slot_wait_fails_the_retry(monkeypatch):
    """_maybe_retry_transient declines when the backoff finds no slot."""
    dl = _dl()
    monkeypatch.setattr(dl, "_begin_backoff", lambda *a, **k: False)
    err = dl.GrablyticError("ERROR_NETWORK", "boom")
    assert dl._maybe_retry_transient(err, 1, None, "id") is False
