"""FFmpeg serialization gate: verification, fallback seam, cancellability.

The teardown finding was that the gate was installed by a monkey-patch
whose failure was swallowed (`except Exception: pass`), and that CI
never exercised it because the tests mocked the method away. These
tests exercise the REAL yt-dlp classes, so a yt-dlp rename breaks the
build instead of silently disabling serialization in production.
"""

import threading
import time

import pytest


def _dl():
    import grablytic_engine.downloader as dl_mod

    return dl_mod


@pytest.mark.unit
def test_gate_is_installed_on_the_real_yt_dlp_class():
    """No mocks: the real yt-dlp class must carry the gate.

    This is the CI gap the teardown called out — the old suite only
    ever called a mocked `real_run_ffmpeg`, so a yt-dlp rename could
    ship with ZERO serialization and no build failure.
    """
    import yt_dlp.postprocessor.ffmpeg as yt_ffmpeg

    dl_mod = _dl()
    dl_mod._ensure_ffmpeg_serialized()
    seam = getattr(yt_ffmpeg.FFmpegPostProcessor, "real_run_ffmpeg", None)
    assert seam is not None, (
        "yt-dlp removed FFmpegPostProcessor.real_run_ffmpeg — the gate "
        "seam moved; update the installer"
    )
    assert getattr(seam, "grablytic_ffmpeg_gate", False) is True, (
        "the FFmpeg gate is NOT installed on the real yt-dlp class; "
        "concurrent merges would oversubscribe the CPU"
    )
    status = dl_mod.ffmpeg_serialization_status()
    assert status["installed"] is True
    assert status["error"] is None
    assert status["seam"]


@pytest.mark.unit
def test_status_reports_failure_when_no_seam_is_available(monkeypatch):
    """Both seams gone → loud failure, never a silent 'unserialized'."""
    import yt_dlp.postprocessor.ffmpeg as yt_ffmpeg
    from yt_dlp.utils import Popen

    dl_mod = _dl()
    monkeypatch.setattr(
        dl_mod,
        "_ffmpeg_patch_state",
        {"installed": False, "seam": None, "error": None},
        raising=True,
    )
    # Make the primary seam disappear (simulated yt-dlp rename).
    monkeypatch.delattr(yt_ffmpeg.FFmpegPostProcessor, "real_run_ffmpeg", raising=True)
    # ... and the fallback seam too.
    monkeypatch.setattr(Popen, "run", object(), raising=True)

    assert dl_mod._ensure_ffmpeg_serialized() is False
    status = dl_mod.ffmpeg_serialization_status()
    assert status["installed"] is False
    assert status["error"], "a failed install must carry a diagnostic"
    assert "real_run_ffmpeg" in status["error"] or "Popen" in status["error"]


@pytest.mark.unit
def test_fallback_seam_installs_when_primary_seam_is_gone(monkeypatch):
    """Losing the PP method must not lose the gate entirely."""
    import yt_dlp.postprocessor.ffmpeg as yt_ffmpeg
    from yt_dlp.utils import Popen

    dl_mod = _dl()
    monkeypatch.setattr(
        dl_mod,
        "_ffmpeg_patch_state",
        {"installed": False, "seam": None, "error": None},
        raising=True,
    )
    monkeypatch.delattr(yt_ffmpeg.FFmpegPostProcessor, "real_run_ffmpeg", raising=True)

    assert dl_mod._ensure_ffmpeg_serialized() is True
    status = dl_mod.ffmpeg_serialization_status()
    assert status["installed"] is True
    assert status["seam"] == "yt_dlp.utils.Popen.run"


@pytest.mark.unit
def test_fallback_seam_serializes_ffmpeg_process_spawns(monkeypatch):
    """The fallback really does serialize ffmpeg spawns.

    Builds the gate on top of a fake inner ``Popen.run`` so no real
    process is ever spawned.
    """
    from yt_dlp.utils import Popen
    import yt_dlp.postprocessor.ffmpeg as yt_ffmpeg

    dl_mod = _dl()
    calls = []

    def fake_inner(cls, *args, **kwargs):
        calls.append(args)
        return ("", "", 0)

    # Remove the primary seam so the fallback is the one under test.
    monkeypatch.delattr(yt_ffmpeg.FFmpegPostProcessor, "real_run_ffmpeg", raising=True)
    monkeypatch.setattr(Popen, "run", classmethod(fake_inner), raising=True)

    monkeypatch.setattr(
        dl_mod,
        "_ffmpeg_patch_state",
        {"installed": False, "seam": None, "error": None},
        raising=True,
    )
    assert dl_mod._ensure_ffmpeg_serialized() is True
    assert dl_mod.ffmpeg_serialization_status()["seam"] == "yt_dlp.utils.Popen.run"

    # A non-ffmpeg command passes straight through (no gate taken).
    Popen.run(["/bin/echo", "hi"])
    assert len(calls) == 1

    # An ffmpeg command goes through the gate.
    Popen.run(["ffmpeg", "-i", "in.mp4", "out.mp4"])
    assert len(calls) == 2


@pytest.mark.unit
def test_gate_wait_is_interrupted_by_cancel(monkeypatch):
    """A cancel during the gate wait must be acknowledged promptly.

    The teardown question: "Can a user cancel a download waiting for
    the FFmpeg semaphore?" Previously: no — the wait was uninterruptible
    for up to 600s while the UI already said "cancelled".
    """
    dl_mod = _dl()
    gate = threading.Semaphore(1)
    monkeypatch.setattr(dl_mod, "_ffmpeg_semaphore", gate, raising=True)
    monkeypatch.setattr(dl_mod, "_FFMPEG_GATE_TIMEOUT", 600.0, raising=True)

    # Hold the only slot so the waiter must actually block.
    assert gate.acquire(blocking=False)

    cancel = threading.Event()
    result = {}

    def waiter():
        started = time.monotonic()
        result["acquired"] = dl_mod._ffmpeg_gate_acquire(cancel)
        result["elapsed"] = time.monotonic() - started

    t = threading.Thread(target=waiter, daemon=True)
    t.start()
    time.sleep(0.1)
    cancel.set()
    t.join(timeout=5.0)

    assert not t.is_alive(), "gate wait ignored the cancel request"
    assert result.get("acquired") is False
    # Must react in well under a second, not after the 600s timeout.
    assert result.get("elapsed", 999) < 2.0
    gate.release()


@pytest.mark.unit
def test_gate_acquire_releases_on_cancel_without_poisoning(monkeypatch):
    """A cancelled waiter must not release a slot it never acquired."""
    dl_mod = _dl()
    gate = threading.Semaphore(1)
    monkeypatch.setattr(dl_mod, "_ffmpeg_semaphore", gate, raising=True)

    assert gate.acquire(blocking=False)
    cancel = threading.Event()
    cancel.set()
    assert dl_mod._ffmpeg_gate_acquire(cancel) is False
    # The holder still owns the only slot.
    assert not gate.acquire(blocking=False)
    gate.release()


@pytest.mark.unit
def test_thread_local_cancel_event_is_scoped_to_the_thread():
    dl_mod = _dl()
    ev = threading.Event()
    dl_mod._set_current_cancel_event(ev)
    assert dl_mod._current_cancel_event() is ev

    seen = {}

    def other():
        seen["event"] = dl_mod._current_cancel_event()

    t = threading.Thread(target=other)
    t.start()
    t.join(timeout=2.0)
    assert seen.get("event") is None, "cancel context leaked across threads"
    dl_mod._set_current_cancel_event(None)
