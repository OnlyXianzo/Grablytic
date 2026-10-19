"""The cancel watchdog must be a BOUNDED pool, not a thread per cancel.

The teardown finding: every cancelled download spawned its own daemon
thread that then blocked in `join()` for up to 120 seconds. Cancelling
200 downloads meant 200 live threads — an unbounded thread-per-event
leak, and a real memory/fd cost on a phone.

These tests pin the pool shape: fixed size, one job per download id, the
deadline stamped at cancel time (not at dequeue time), and a worker
generation that retires cleanly on shutdown.
"""

import threading
import time

import pytest


def _dl():
    import grablytic_engine.downloader as dl_mod

    return dl_mod


class _AlwaysAliveThread:
    """A worker stand-in that never exits — the wedge case."""

    def __init__(self):
        self.joined_with = None

    def join(self, timeout=None):
        self.joined_with = timeout

    def is_alive(self):
        return True


class _DeadThread:
    """A worker that already exited — its own terminal stands."""

    def __init__(self):
        self.joined_with = None

    def join(self, timeout=None):
        self.joined_with = timeout

    def is_alive(self):
        return False


@pytest.fixture
def _clean_pool():
    dl = _dl()
    dl.stop_watchdog_pool()
    with dl._watchdog_pool_lock:
        dl._watchdog_active_ids.clear()
    yield dl
    dl.stop_watchdog_pool()
    with dl._watchdog_pool_lock:
        dl._watchdog_active_ids.clear()


def _drain(dl):
    """Remove and return every queued watchdog job."""
    jobs = []
    while True:
        try:
            job = dl._watchdog_queue.get_nowait()
        except Exception:
            break
        jobs.append(job)
        try:
            dl._watchdog_queue.task_done()
        except Exception:
            pass
    return jobs


@pytest.mark.unit
def test_pool_size_is_fixed_and_small(_clean_pool):
    """A bounded pool: the size is a constant, not a function of cancels."""
    dl = _clean_pool
    assert dl._WATCHDOG_POOL_SIZE == 4
    assert dl._WATCHDOG_POOL_SIZE < 16


@pytest.mark.unit
def test_many_cancels_do_not_spawn_many_threads(_clean_pool):
    """50 cancels must not create 50 watchdog threads."""
    dl = _clean_pool
    before = {t.name for t in threading.enumerate() if "cancel-watchdog" in t.name}
    for i in range(50):
        dl._start_cancel_watchdog(f"dl{i}", _AlwaysAliveThread())
    time.sleep(0.3)
    after = {t.name for t in threading.enumerate() if "cancel-watchdog" in t.name}
    assert len(after - before) <= dl._WATCHDOG_POOL_SIZE
    _drain(dl)


@pytest.mark.unit
def test_one_job_per_download_id(_clean_pool):
    """A second cancel of the same id must not enqueue a second job."""
    dl = _clean_pool
    dl._start_cancel_watchdog("dup", _AlwaysAliveThread())
    dl._start_cancel_watchdog("dup", _AlwaysAliveThread())
    jobs = _drain(dl)
    assert len(jobs) == 1
    assert jobs[0]["download_id"] == "dup"


@pytest.mark.unit
def test_deadline_is_stamped_at_cancel_time(_clean_pool):
    """The wait window is measured from the cancel, not from the dequeue."""
    dl = _clean_pool
    before = time.monotonic()
    dl._start_cancel_watchdog("stamped", _AlwaysAliveThread())
    jobs = _drain(dl)
    after = time.monotonic()
    deadline = jobs[0]["deadline"]
    assert before + dl._CANCEL_WATCHDOG_SECONDS - 1 <= deadline
    assert deadline <= after + dl._CANCEL_WATCHDOG_SECONDS + 1


@pytest.mark.unit
def test_job_presumes_stopped_and_releases_the_slot(_clean_pool):
    """A wedged worker gets a terminal and its slot is freed."""
    dl = _clean_pool
    dl._active_downloads["wedged"] = {
        "url": "https://example.com/w",
        "audio_only": False,
        "finished_at": None,
        "slot_token": "tok-wedged",
        "thread": _AlwaysAliveThread(),
        "event_callback": None,
        "result_queue": None,
    }
    dl._run_watchdog_job(
        {
            "download_id": "wedged",
            "thread": dl._active_downloads["wedged"]["thread"],
            "deadline": time.monotonic() - 1,  # already expired
        }
    )
    assert dl._active_downloads["wedged"].get("finished_at") is not None
    dl._active_downloads.pop("wedged", None)


@pytest.mark.unit
def test_exited_worker_leaves_the_slot_alone(_clean_pool):
    """A worker that exited on its own keeps its own terminal."""
    dl = _clean_pool
    dl._active_downloads["exited"] = {
        "url": "https://example.com/e",
        "audio_only": False,
        "finished_at": None,
        "slot_token": "tok-exited",
        "thread": _DeadThread(),
        "event_callback": None,
        "result_queue": None,
    }
    dl._run_watchdog_job(
        {
            "download_id": "exited",
            "thread": dl._active_downloads["exited"]["thread"],
            "deadline": time.monotonic() - 1,
        }
    )
    assert dl._active_downloads["exited"].get("finished_at") is None
    dl._active_downloads.pop("exited", None)


@pytest.mark.unit
def test_stopping_the_pool_retires_its_workers(_clean_pool):
    """After a stop, no watchdog worker thread is left running."""
    dl = _clean_pool
    dl._start_cancel_watchdog("stopme", _AlwaysAliveThread())
    time.sleep(0.3)
    dl.stop_watchdog_pool()
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        alive = [
            t
            for t in threading.enumerate()
            if "cancel-watchdog" in t.name and t.is_alive()
        ]
        if not alive:
            break
        time.sleep(0.1)
    alive = [
        t for t in threading.enumerate() if "cancel-watchdog" in t.name and t.is_alive()
    ]
    assert alive == []
    _drain(dl)
