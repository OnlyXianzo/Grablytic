"""FFmpeg gate hardening (item 7): a hung merge must not wedge the gate forever.

Red-first regression: hold the process-wide ``_ffmpeg_semaphore`` (simulating
a stuck native FFmpeg remux) and prove a second download's
``real_run_ffmpeg`` fails fast with a clear post-processing error instead of
blocking forever — and that the gate stays usable for the next download.
"""

import threading

import pytest


def _wrap_fake(monkeypatch, fake_run, timeout):
    """Wrap *fake_run* with the real serializer; return (dl_mod, yt_ffmpeg)."""
    import yt_dlp.postprocessor.ffmpeg as yt_ffmpeg
    import grablytic_engine.downloader as dl_mod

    fresh = threading.Semaphore(1)
    monkeypatch.setattr(dl_mod, "_ffmpeg_semaphore", fresh, raising=False)
    # raising=False: before the fix this knob does not exist yet (old code
    # ignores it and stays wedged -> red); after the fix the wrapper honors it.
    monkeypatch.setattr(dl_mod, "_FFMPEG_GATE_TIMEOUT", timeout, raising=False)
    monkeypatch.setattr(
        yt_ffmpeg.FFmpegPostProcessor, "real_run_ffmpeg", fake_run, raising=True
    )
    monkeypatch.setattr(dl_mod, "_ffmpeg_patched", False, raising=True)
    dl_mod._ensure_ffmpeg_serialized()
    assert dl_mod._ffmpeg_patched is True
    return dl_mod, yt_ffmpeg


@pytest.mark.unit
def test_stuck_ffmpeg_does_not_wedge_gate_forever(monkeypatch):
    """A stuck holder must not wedge every later download's post-processing."""
    calls: list = []

    def fake_run(self, *args, **kwargs):
        calls.append(1)
        return "merged-ok"

    dl_mod, yt_ffmpeg = _wrap_fake(monkeypatch, fake_run, timeout=0.3)
    gate = dl_mod._ffmpeg_semaphore

    # Simulate the hung merge holding the gate.
    assert gate.acquire(blocking=False), "fresh gate must be free"
    errors: list = []
    try:
        def waiter():
            try:
                yt_ffmpeg.FFmpegPostProcessor.real_run_ffmpeg(object())
            except Exception as exc:  # noqa: BLE001 — captured for assertions
                errors.append(exc)

        t = threading.Thread(target=waiter, daemon=True)
        t.start()
        t.join(timeout=5.0)
        assert not t.is_alive(), (
            "WEDGED: second download blocked forever behind a stuck FFmpeg "
            "merge (bare `with semaphore` has no timeout)"
        )
        assert errors, "waiter must surface an error instead of hanging"
        assert "ffmpeg" in str(errors[0]).lower(), (
            f"timeout error must identify FFmpeg post-processing: {errors[0]!r}"
        )
        # The timed-out waiter must never have run the inner merge ...
        assert calls == []
        # ... and must not have released the holder's slot (no global poison).
        assert not gate.acquire(blocking=False), (
            "waiter released a gate it never acquired"
        )
    finally:
        gate.release()

    # Gate reusable for the next download once the holder finishes.
    assert yt_ffmpeg.FFmpegPostProcessor.real_run_ffmpeg(object()) == "merged-ok"
    assert calls == [1]

    # Timeout surfaces as a retryable (recoverable) error via classify_error,
    # matching the file's error-shape conventions (ERROR_UNKNOWN + retry).
    from grablytic_engine.errors import classify_error

    ge = classify_error(errors[0])
    assert ge.recoverable is True


@pytest.mark.unit
def test_gate_released_when_merge_raises(monkeypatch):
    """An inner FFmpeg failure must not poison the gate for later downloads."""

    def boom(self, *args, **kwargs):
        raise RuntimeError("ffmpeg fake failure")

    dl_mod, yt_ffmpeg = _wrap_fake(monkeypatch, boom, timeout=2.0)
    gate = dl_mod._ffmpeg_semaphore

    with pytest.raises(RuntimeError, match="ffmpeg fake failure"):
        yt_ffmpeg.FFmpegPostProcessor.real_run_ffmpeg(object())
    # Gate free again despite the exception.
    assert gate.acquire(blocking=False), "gate poisoned by inner exception"
    gate.release()


@pytest.mark.unit
def test_gate_still_serializes_concurrent_merges(monkeypatch):
    """Timed acquire must preserve mutual exclusion (no parallel merges)."""
    overlap = {"active": 0, "max": 0}
    lock = threading.Lock()

    def slow_merge(self, *args, **kwargs):
        with lock:
            overlap["active"] += 1
            overlap["max"] = max(overlap["max"], overlap["active"])
        try:
            import time as _time

            _time.sleep(0.1)
            return "ok"
        finally:
            with lock:
                overlap["active"] -= 1

    dl_mod, yt_ffmpeg = _wrap_fake(monkeypatch, slow_merge, timeout=5.0)

    results: list = []

    def worker():
        results.append(yt_ffmpeg.FFmpegPostProcessor.real_run_ffmpeg(object()))

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10.0)
    assert all(not t.is_alive() for t in threads)
    assert sorted(results) == ["ok"] * 3
    assert overlap["max"] == 1, f"merges overlapped: {overlap}"
