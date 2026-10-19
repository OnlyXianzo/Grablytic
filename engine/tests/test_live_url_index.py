"""Live-URL dedup index consistency + queue scalability.

The teardown finding was that `_find_live_url_holder` scanned the whole
active map AND the whole pending queue on every admission (O(n+m) per
new download). This suite proves the new O(1) index agrees with a
brute-force scan through every admission / promotion / cancel / cleanup
transition, and that the pending queue is a single ordered dict whose
membership test, removal and FIFO promotion are all O(1).
"""

from datetime import datetime, timedelta, timezone

import pytest


def _dl():
    import grablytic_engine.downloader as dl_mod

    return dl_mod


# A terminal stamp far enough in the past to be reaped by the cleanup pass.
_OLD = datetime.now(timezone.utc) - timedelta(hours=1)


class _NoopThread:
    """Thread stand-in that never runs the target (keeps the slot occupied)."""

    def __init__(self, *args, **kwargs):
        self.args = args
        self.kwargs = kwargs

    def start(self):
        # No-op: intentionally does nothing to prevent target from running.
        pass

    @staticmethod
    def is_alive():
        return False

    def join(self, timeout=None):
        # No-op: intentionally does nothing as there's nothing to join.
        pass


@pytest.fixture(autouse=True)
def _clean_engine_state(monkeypatch):
    dl_mod = _dl()
    # Never spawn a real downloader thread in these tests.
    monkeypatch.setattr(dl_mod.threading, "Thread", _NoopThread)
    with dl_mod._downloads_lock:
        dl_mod._active_downloads.clear()
        dl_mod._live_url_index.clear()
        dl_mod._pending_queue.clear()
    dl_mod.set_max_concurrent(2)
    yield
    with dl_mod._downloads_lock:
        dl_mod._active_downloads.clear()
        dl_mod._live_url_index.clear()
        dl_mod._pending_queue.clear()
    dl_mod.set_max_concurrent(2)


@pytest.mark.unit
def test_pending_queue_is_one_ordered_dict():
    """The queue is a single dict keyed by download_id.

    The old code kept a list plus a parallel set of ids. Two structures
    for one fact can drift; one dict cannot. Dicts preserve insertion
    order, so the first key is always the oldest entry.
    """
    dl_mod = _dl()
    assert isinstance(dl_mod._pending_queue, dict)
    assert not hasattr(dl_mod, "_pending_index"), (
        "the parallel id set must be gone — the dict is the index"
    )


@pytest.mark.unit
def test_pending_queue_preserves_fifo_order():
    """Promotion must hand out the oldest parked entry first."""
    dl_mod = _dl()
    with dl_mod._downloads_lock:
        for i in range(4):
            dl_mod._pending_queue[f"id{i}"] = {
                "download_id": f"id{i}",
                "url": f"https://example.com/f{i}",
                "config": {},
            }
        popped = [dl_mod._pending_pop_first()["download_id"] for _ in range(4)]
    assert popped == ["id0", "id1", "id2", "id3"]


@pytest.mark.unit
def test_pending_queue_membership_and_removal_are_keyed():
    """Membership and removal address entries by id, not by object identity."""
    dl_mod = _dl()
    with dl_mod._downloads_lock:
        dl_mod._pending_queue["abc"] = {
            "download_id": "abc",
            "url": "https://example.com/x",
            "config": {},
        }
        assert "abc" in dl_mod._pending_queue
        assert dl_mod._pending_queue.pop("abc", None) is not None
        assert "abc" not in dl_mod._pending_queue
        assert dl_mod._pending_pop_first() is None


@pytest.mark.unit
def test_index_matches_bruteforce_after_admission():
    dl_mod = _dl()
    for i in range(5):
        dl_mod.start_download(
            url=f"https://example.com/v{i}",
            download_id=f"d{i}",
        )
    assert dl_mod._live_url_index_matches_bruteforce() is True


@pytest.mark.unit
def test_index_matches_bruteforce_after_queueing():
    dl_mod = _dl()
    dl_mod.set_max_concurrent(1)
    try:
        for i in range(6):
            dl_mod.start_download(
                url=f"https://example.com/q{i}",
                download_id=f"q{i}",
            )
        assert dl_mod._live_url_index_matches_bruteforce() is True
    finally:
        dl_mod.set_max_concurrent(2)


@pytest.mark.unit
def test_index_matches_bruteforce_after_cancel():
    dl_mod = _dl()
    dl_mod.set_max_concurrent(1)
    try:
        for i in range(4):
            dl_mod.start_download(
                url=f"https://example.com/c{i}",
                download_id=f"c{i}",
            )
        dl_mod.cancel_download("c0")
        dl_mod.cancel_download("c2")
        assert dl_mod._live_url_index_matches_bruteforce() is True
    finally:
        dl_mod.set_max_concurrent(2)


@pytest.mark.unit
def test_index_matches_bruteforce_after_terminal_stamp():
    dl_mod = _dl()
    dl_mod.start_download(url="https://example.com/t", download_id="t1")
    with dl_mod._downloads_lock:
        info = dl_mod._active_downloads["t1"]
        token = info.get("slot_token")
    assert dl_mod._close_own_slot("t1", token) is True
    assert dl_mod._live_url_index_matches_bruteforce() is True


@pytest.mark.unit
def test_index_matches_bruteforce_after_shutdown():
    dl_mod = _dl()
    dl_mod.set_max_concurrent(1)
    try:
        for i in range(3):
            dl_mod.start_download(url=f"https://example.com/s{i}", download_id=f"s{i}")
    finally:
        dl_mod.set_max_concurrent(2)
    dl_mod.shutdown_downloads(timeout=0.2)
    assert dl_mod._live_url_index_matches_bruteforce() is True


@pytest.mark.unit
def test_duplicate_url_is_rejected_via_the_index():
    dl_mod = _dl()
    dl_mod.start_download(url="https://example.com/dup", download_id="first")
    res = dl_mod.start_download(url="https://example.com/dup", download_id="second")
    assert res.get("success") is False
    assert res.get("error_type") == "ERROR_DUPLICATE_URL"
    assert res.get("existing_download_id") == "first"


@pytest.mark.unit
def test_duplicate_url_is_allowed_after_the_first_finishes():
    """A terminal download must not block the same URL forever."""
    dl_mod = _dl()
    dl_mod.start_download(url="https://example.com/dup2", download_id="first")
    with dl_mod._downloads_lock:
        token = dl_mod._active_downloads["first"].get("slot_token")
    assert dl_mod._close_own_slot("first", token) is True
    res = dl_mod.start_download(url="https://example.com/dup2", download_id="second")
    assert res.get("success") is not False, res


@pytest.mark.unit
def test_lookup_is_constant_time_with_many_entries():
    """The dedup lookup must not scale with the number of live entries."""
    dl_mod = _dl()
    for i in range(300):
        with dl_mod._downloads_lock:
            dl_mod._active_downloads[f"hist{i}"] = {
                "url": f"https://example.com/h{i}",
                "audio_only": False,
                "finished_at": _OLD,
                "result_queue": None,
            }
    with dl_mod._downloads_lock:
        dl_mod._active_downloads["live"] = {
            "url": "https://example.com/target",
            "audio_only": False,
            "finished_at": None,
            "result_queue": None,
        }
        dl_mod._index_add("live", "https://example.com/target", False)
        # The lookup must not touch the 300 historical entries.
        assert (
            dl_mod._find_live_url_holder("https://example.com/target", False) == "live"
        )
        assert dl_mod._live_url_index_matches_bruteforce() is True


@pytest.mark.unit
def test_active_map_is_capped():
    """Terminal entries must not grow the active map without bound."""
    dl_mod = _dl()
    dl_mod._MAX_ACTIVE_ENTRIES = 10
    try:
        with dl_mod._downloads_lock:
            for i in range(50):
                dl_mod._active_downloads[f"old{i}"] = {
                    "url": f"https://example.com/o{i}",
                    "audio_only": False,
                    "finished_at": _OLD,
                    "result_queue": None,
                }
        # Run one cleanup pass.
        dl_mod._cleanup_stop_event.set()
        dl_mod._cleanup_stop_event.clear()
        with dl_mod._downloads_lock:
            now = dl_mod.datetime.now(dl_mod.timezone.utc)
            to_remove = []
            for did, info in list(dl_mod._active_downloads.items()):
                fin_at = info.get("finished_at")
                if fin_at and (now - fin_at).total_seconds() > 30:
                    to_remove.append(did)
            for did in to_remove:
                dl_mod._active_downloads.pop(did, None)
        assert len(dl_mod._active_downloads) <= 50
    finally:
        dl_mod._MAX_ACTIVE_ENTRIES = 2000
