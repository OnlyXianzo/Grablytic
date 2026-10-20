"""Regression tests for the 2026-10-19 review pass.

Each test names the defect it locks down. The engine suite is the only
automated gate that runs on every push, so the regressions fixed here
need a test that fails without the fix.
"""

import json
import os
import tempfile
import threading
import time

import pytest

from grablytic_engine.persistent import is_sensitive_key, sanitize, scrub_text


# ── redaction: shared references, header secrets, benign keys ──────────


def test_shared_reference_is_not_reported_as_a_cycle():
    """A DAG is not a cycle. The old global `_seen` set blanked real values."""
    shared = {"a": 1}
    out = sanitize({"x": shared, "y": shared})
    assert out == {"x": {"a": 1}, "y": {"a": 1}}


def test_true_cycle_still_terminates():
    payload = {}
    payload["self"] = payload
    out = sanitize(payload)
    assert out["self"] == "***CYCLIC***"


def test_benign_keys_are_not_redacted():
    out = sanitize(
        {
            "author": "Some Channel",
            "author_id": "UC123",
            "authorization_status": "granted",
        }
    )
    assert out["author"] == "Some Channel"
    assert out["author_id"] == "UC123"
    assert out["authorization_status"] == "granted"


def test_secret_keys_are_redacted():
    out = sanitize(
        {
            "cookie": "SID=abc",
            "po_token": "xyz",
            "proxy": "socks5://u:p@h:1080",
            "yt_api_key": "k",
        }
    )
    assert out["cookie"] == "***REDACTED***"
    assert out["po_token"] == "***REDACTED***"
    assert out["proxy"] == "***REDACTED***"
    assert out["yt_api_key"] == "***REDACTED***"


@pytest.mark.parametrize(
    "text",
    [
        "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc",
        "Cookie: SID=0123456789",
        "Set-Cookie: SID=0123456789; Path=/",
        # gitleaks:allow — a fake header used to prove the redactor
        # catches `X-Api-Key` shaped values. It is a test fixture, not
        # a credential, and the scan must not flag it.
        "X-Api-Key: 0123456789abcdef",  # gitleaks:allow
    ],
)
def test_header_shaped_secrets_are_redacted(text):
    out = scrub_text(text)
    assert "***REDACTED***" in out
    for leak in ("eyJhbGciOiJIUzI1NiJ9", "0123456789"):
        assert leak not in out


def test_signed_url_query_is_redacted():
    out = scrub_text("https://cdn.example/v?id=1&sig=SUPERSECRETSIG")
    assert "SUPERSECRETSIG" not in out
    assert "id=1" in out


def test_is_sensitive_key_helper():
    assert is_sensitive_key("Cookie") is True
    assert is_sensitive_key("proxy_password") is True
    assert is_sensitive_key("author") is False
    assert is_sensitive_key("title") is False


# ── URL helpers ────────────────────────────────────────────────────────


def test_redact_url_drops_query_and_userinfo():
    from grablytic_engine.url_guard import redact_url

    out = redact_url("https://user:pw@cdn.example:8443/v/x.mp4?sig=SEKRIT&id=2")
    assert "SEKRIT" not in out
    assert "pw" not in out
    assert out.startswith("https://cdn.example:8443/v/x.mp4")


def test_redact_url_handles_non_urls():
    from grablytic_engine.url_guard import redact_url

    assert redact_url(None) == "<url>"
    assert redact_url("not-a-url").startswith("not-a-url")


@pytest.mark.parametrize(
    "url,expected",
    [
        ("https://www.youtube.com/watch?v=abc", True),
        ("https://m.youtube.com/watch?v=abc", True),
        ("https://youtu.be/abc", True),
        ("https://www.youtube-nocookie.com/embed/abc", True),
        ("https://notyoutube.com/watch?v=abc", False),
        ("https://evil.tld/?youtube.com", False),
        ("https://vimeo.com/12345", False),
        ("", False),
        (None, False),
    ],
)
def test_is_youtube_url_uses_host_allowlist(url, expected):
    from grablytic_engine.url_guard import is_youtube_url

    assert is_youtube_url(url) is expected


# ── hooks: error events are classified, not hardcoded recoverable ──────


def test_progress_hook_error_event_is_classified():
    from grablytic_engine.hooks import build_progress_hook

    import queue as _queue

    q = _queue.Queue()
    hook = build_progress_hook(q, "dl-1", None)
    hook({"status": "error", "error": "This video is private"})
    payload = json.loads(q.get_nowait())
    assert payload["error_type"] == "ERROR_PRIVATE"
    assert payload["recoverable"] is True
    assert payload["suggests_vpn"] is False


def test_progress_hook_error_event_reports_unrecoverable():
    from grablytic_engine.hooks import build_progress_hook

    import queue as _queue

    q = _queue.Queue()
    hook = build_progress_hook(q, "dl-2", None)
    hook({"status": "error", "error": "This video has been removed"})
    payload = json.loads(q.get_nowait())
    assert payload["error_type"] == "ERROR_UNAVAILABLE"
    assert payload["recoverable"] is False


# ── resume: the .info.json sidecar is size-capped ──────────────────────


def test_resume_scan_skips_oversized_info_json():
    import grablytic_engine.resume as resume_mod

    with tempfile.TemporaryDirectory() as tmpdir:
        part = os.path.join(tmpdir, "big.part")
        open(part, "w").close()
        info = os.path.join(tmpdir, "big.info.json")
        with open(info, "w", encoding="utf-8") as f:
            f.write(json.dumps({"webpage_url": "https://example.com/x"}))
        # Blow past the cap.
        with open(info, "a", encoding="utf-8") as f:
            f.write(" " * (resume_mod._MAX_INFOJSON_BYTES + 1024))
        result = resume_mod.scan_resume_candidates(tmpdir)
        assert result["candidates"][0]["likely_url"] is None


def test_resume_scan_reads_normal_info_json():
    import grablytic_engine.resume as resume_mod

    with tempfile.TemporaryDirectory() as tmpdir:
        part = os.path.join(tmpdir, "ok.part")
        open(part, "w").close()
        with open(os.path.join(tmpdir, "ok.info.json"), "w", encoding="utf-8") as f:
            json.dump({"webpage_url": "https://example.com/video"}, f)
        result = resume_mod.scan_resume_candidates(tmpdir)
        assert result["candidates"][0]["likely_url"] == "https://example.com/video"


# ── IPC: the reader never blocks on the auto-report network call ───────


def test_auto_report_is_queued_not_run_inline(monkeypatch):
    import grablytic_engine.__main__ as main_mod

    calls = []
    started = threading.Event()
    release = threading.Event()

    def _fake_notify(exc, context=None, **kwargs):
        calls.append(context)
        started.set()
        release.wait(5)
        return {"status": "skipped"}

    import grablytic_engine.github_notifier as notifier

    monkeypatch.setattr(notifier, "notify_exception", _fake_notify)
    monkeypatch.setattr(main_mod, "_report_state", {"sent": 0, "last_monotonic": 0.0})
    monkeypatch.setattr(main_mod, "_report_pool", None)

    t0 = time.monotonic()
    accepted = main_mod._report_async(RuntimeError("boom"), "formats/get")
    elapsed = time.monotonic() - t0

    assert accepted is True
    # The caller returned immediately — the network call runs elsewhere.
    assert elapsed < 0.5
    assert started.wait(5)
    release.set()
    main_mod._shutdown_report_pool()


def test_auto_report_is_rate_limited(monkeypatch):
    import grablytic_engine.__main__ as main_mod

    monkeypatch.setattr(main_mod, "_report_state", {"sent": 0, "last_monotonic": 0.0})
    monkeypatch.setattr(main_mod, "_report_pool", None)
    monkeypatch.setattr(main_mod, "_deliver_report", lambda exc, method: None)
    try:
        assert main_mod._report_async(RuntimeError("a"), "m") is True
        # Second report inside the window is suppressed.
        assert main_mod._report_async(RuntimeError("b"), "m") is False
    finally:
        main_mod._shutdown_report_pool()


def test_auto_report_caps_reports_per_session(monkeypatch):
    import grablytic_engine.__main__ as main_mod

    monkeypatch.setattr(
        main_mod,
        "_report_state",
        {"sent": main_mod._REPORT_MAX_PER_SESSION, "last_monotonic": 0.0},
    )
    monkeypatch.setattr(main_mod, "_report_pool", None)
    assert main_mod._report_async(RuntimeError("a"), "m") is False


def test_shutdown_pool_cancels_and_drains_with_deadline():
    import grablytic_engine.__main__ as main_mod
    import concurrent.futures as futures

    pool = futures.ThreadPoolExecutor(max_workers=1)
    started = threading.Event()
    release = threading.Event()

    def _slow():
        started.set()
        release.wait(10)
        return 1

    running = pool.submit(_slow)
    queued = pool.submit(_slow)
    assert started.wait(5)
    tracked = {running, queued}
    for fut in tracked:
        fut.add_done_callback(tracked.discard)

    t0 = time.monotonic()
    main_mod._shutdown_ipc_pool(pool, tracked, drain_timeout=1.0)
    elapsed = time.monotonic() - t0
    release.set()
    # The drain honoured its deadline instead of waiting for the slow job.
    assert elapsed < 5.0


# ── downloader: the worker handle is published before start() ──────────


def test_thread_handle_is_published_before_start(monkeypatch):
    """A cancel that lands between register and start must see the thread."""
    import grablytic_engine.downloader as dl

    monkeypatch.setattr(dl, "_max_concurrent", 1)
    observed = {}

    real_thread_cls = dl.threading.Thread

    class _ProbeThread(real_thread_cls):  # type: ignore[misc,valid-type]
        def start(self):
            rec = dl._active_downloads.get(observed.get("download_id"))
            observed["thread_at_start"] = (
                rec.get("thread") if isinstance(rec, dict) else None
            )
            super().start()

    monkeypatch.setattr(dl.threading, "Thread", _ProbeThread)

    import queue as _queue

    entry = {
        "url": "https://example.com/v",
        "download_id": "probe-1",
        "config": {},
        "network_type": "wifi",
        "progress_queue": _queue.Queue(),
        "result_queue": _queue.Queue(),
        "cancel_event": threading.Event(),
        "event_callback": None,
    }
    observed["download_id"] = "probe-1"

    def _noop_download_thread(*args, **kwargs):
        time.sleep(0.05)

    monkeypatch.setattr(dl, "download_thread", _noop_download_thread)

    try:
        dl._spawn_thread(entry)
        assert observed.get("thread_at_start") is not None, (
            "the worker handle must be visible before start()"
        )
    finally:
        with dl._downloads_lock:
            dl._active_downloads.pop("probe-1", None)
        dl._index_remove("https://example.com/v", False, "probe-1")


# ── paths: the process-global env is replaced, not stacked ─────────────


def test_set_paths_replaces_its_own_path_entry(tmp_path, monkeypatch):
    import grablytic_engine.paths as paths_mod

    first = tmp_path / "one"
    second = tmp_path / "two"
    (first / "bin").mkdir(parents=True)
    (second / "bin").mkdir(parents=True)
    monkeypatch.setenv("PATH", "/usr/bin:/bin")

    paths_mod.set_paths(
        data_dir=str(first),
        output_dir=str(tmp_path / "out"),
        ffmpeg_path=None,
        cache_dir=str(tmp_path / "cache"),
    )
    assert os.environ["PATH"].split(os.pathsep)[0] == str(first / "bin")

    paths_mod.set_paths(
        data_dir=str(second),
        output_dir=str(tmp_path / "out"),
        ffmpeg_path=None,
        cache_dir=str(tmp_path / "cache"),
    )
    entries = os.environ["PATH"].split(os.pathsep)
    assert entries[0] == str(second / "bin")
    # The previous entry must be gone, not stacked underneath.
    assert str(first / "bin") not in entries


def test_child_env_does_not_mutate_the_process_environment(tmp_path):
    from grablytic_engine.paths import child_env

    before = os.environ.get("LD_LIBRARY_PATH", "")
    env = child_env({"A": "1"}, ld_dirs=[str(tmp_path)])
    assert env["A"] == "1"
    assert env["LD_LIBRARY_PATH"] == str(tmp_path)
    assert os.environ.get("LD_LIBRARY_PATH", "") == before


# ── traced_request: the preview is bounded before it is sanitized ──────


def test_preview_does_not_sanitize_the_whole_payload():
    from grablytic_engine.persistent import _preview

    big = {"k%d" % i: "v" * 100 for i in range(5000)}
    out = _preview(big, limit=500)
    assert len(out) <= 500
