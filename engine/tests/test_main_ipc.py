"""JSON-RPC IPC contract tests for `python -m grablytic_engine`.

Drives main()'s stdin loop with canned requests (no subprocess, no
network): proves request/response envelopes, method dispatch, and the
error contract the Flutter side depends on.
"""

import io
import json
import sys

import pytest


def _main_mod():
    import importlib
    return importlib.import_module("grablytic_engine.__main__")


def _run_lines(monkeypatch, capsys, lines, argv=None):
    mod = _main_mod()
    monkeypatch.setattr(sys, "argv", ["grablytic_engine", *(argv or [])])
    monkeypatch.setattr(sys, "stdin", io.StringIO("\n".join(lines) + "\n"))
    mod.main()
    out, _ = capsys.readouterr()
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def _by_id(responses, req_id):
    return next(r for r in responses if r.get("id") == req_id)


@pytest.mark.unit
def test_paths_set_envelope(tmp_path, monkeypatch, capsys):
    resps = _run_lines(monkeypatch, capsys, [json.dumps({
        "id": "p1", "method": "paths/set",
        "params": {
            "data_dir": str(tmp_path), "output_dir": str(tmp_path),
            "cache_dir": str(tmp_path),
        },
    })])
    assert _by_id(resps, "p1") == {"id": "p1", "result": {"success": True}}


@pytest.mark.unit
def test_paths_set_forwards_nodejs_path(tmp_path, monkeypatch, capsys):
    """Regression test for FLAW E-R3: paths/set must forward nodejs_path."""
    from grablytic_engine.paths import get_paths
    node_bin = tmp_path / "node"
    node_bin.touch()
    node_bin.chmod(0o755)

    resps = _run_lines(monkeypatch, capsys, [json.dumps({
        "id": "p_node", "method": "paths/set",
        "params": {
            "data_dir": str(tmp_path), "output_dir": str(tmp_path),
            "cache_dir": str(tmp_path),
            "nodejs_path": str(node_bin),
        },
    })])
    assert _by_id(resps, "p_node") == {"id": "p_node", "result": {"success": True}}
    assert get_paths()["nodejs_path"] == str(node_bin.resolve())


@pytest.mark.unit
def test_download_queue_status_ipc_envelope(tmp_path, monkeypatch, capsys):
    """Regression test for FLAW E-R3: download/queue_status returns success envelope."""
    resps = _run_lines(monkeypatch, capsys, [
        json.dumps({"id": "s1", "method": "paths/set", "params": {
            "data_dir": str(tmp_path), "output_dir": str(tmp_path),
            "cache_dir": str(tmp_path)}}),
        json.dumps({"id": "q_stat", "method": "download/queue_status", "params": {}}),
    ])
    result = _by_id(resps, "q_stat")["result"]
    assert result["success"] is True
    assert "active" in result and isinstance(result["active"], list)
    assert "queued" in result and isinstance(result["queued"], list)
    assert "max_concurrent" in result and isinstance(result["max_concurrent"], int)


@pytest.mark.unit
def test_unknown_method_error_envelope(monkeypatch, capsys):
    resps = _run_lines(monkeypatch, capsys, [
        json.dumps({"id": "s1", "method": "paths/set", "params": {
            "data_dir": "/tmp/x", "output_dir": "/tmp/x",
            "cache_dir": "/tmp/x"}}),
        json.dumps({"id": "u9", "method": "frobnicate/do", "params": {}}),
    ])
    err = _by_id(resps, "u9")
    assert err["error"]["success"] is False
    assert err["error"]["error_type"] == "ERROR_UNKNOWN_METHOD"


@pytest.mark.unit
def test_dispatch_calls_module_function(monkeypatch, capsys):
    mod = _main_mod()
    seen = {}

    def fake_get_formats(url, config=None):
        seen["url"] = url
        return {"success": True, "formats": []}

    monkeypatch.setattr(mod, "get_formats", fake_get_formats)
    resps = _run_lines(monkeypatch, capsys, [
        json.dumps({"id": "s1", "method": "paths/set", "params": {
            "data_dir": "/tmp/x", "output_dir": "/tmp/x",
            "cache_dir": "/tmp/x"}}),
        json.dumps({"id": "f1", "method": "formats/get",
                    "params": {"url": "https://x.test/v"}}),
    ])
    assert seen["url"] == "https://x.test/v"
    assert _by_id(resps, "f1")["result"] == {"success": True, "formats": []}


@pytest.mark.unit
def test_dispatch_calls_search(monkeypatch, capsys):
    mod = _main_mod()
    called = {}

    def fake_search(query, site="youtube", limit=20, config=None):
        called["query"] = query
        called["site"] = site
        called["limit"] = limit
        return {"success": True, "query": query, "count": 1, "entries": [{"title": "Test"}]}

    monkeypatch.setattr(mod, "search_query", fake_search)
    resps = _run_lines(monkeypatch, capsys, [
        json.dumps({"id": "s1", "method": "paths/set", "params": {
            "data_dir": "/tmp/x", "output_dir": "/tmp/x",
            "cache_dir": "/tmp/x"}}),
        json.dumps({"id": "q1", "method": "search/query",
                    "params": {"query": "rick astley", "site": "youtube", "limit": 10}}),
    ])
    assert called == {"query": "rick astley", "site": "youtube", "limit": 10}
    assert _by_id(resps, "q1")["result"]["count"] == 1


@pytest.mark.unit
def test_search_dispatch_wiring_is_callable_without_mock(monkeypatch, capsys):
    """Regression: search/query dispatch must bind the real function.

    Previously `from grablytic_engine import search` bound the submodule
    (module, not callable), so unmocked dispatch raised
    `TypeError: 'module' object is not callable` and surfaced as
    ERROR_INTERNAL. The old test masked this by monkeypatching
    `mod.search`. Empty query exercises the real function without
    network and must return ERROR_INVALID_PARAM, never ERROR_INTERNAL.
    """
    mod = _main_mod()
    assert callable(getattr(mod, "search_query", None))
    resps = _run_lines(monkeypatch, capsys, [
        json.dumps({"id": "s1", "method": "paths/set", "params": {
            "data_dir": "/tmp/x", "output_dir": "/tmp/x",
            "cache_dir": "/tmp/x"}}),
        json.dumps({"id": "q2", "method": "search/query",
                    "params": {"query": "", "site": "youtube", "limit": 10}}),
    ])
    resp = _by_id(resps, "q2")
    assert "result" in resp or "error" in resp
    payload = resp.get("result", resp.get("error"))
    assert payload["error_type"] == "ERROR_INVALID_PARAM"


@pytest.mark.unit
def test_malformed_line_does_not_kill_loop(monkeypatch, capsys):
    resps = _run_lines(monkeypatch, capsys, [
        "this is not json {{{",
        json.dumps({"id": "s1", "method": "paths/set", "params": {
            "data_dir": "/tmp/x", "output_dir": "/tmp/x",
            "cache_dir": "/tmp/x"}}),
    ])
    assert _by_id(resps, "s1")["result"] == {"success": True}


@pytest.mark.unit
def test_malformed_line_error_keeps_null_id(monkeypatch, capsys):
    """T1-8: even an unparseable line must produce an error envelope that
    keeps its (null) request ID — the client correlates every error by id,
    never a bare id-less failure."""
    resps = _run_lines(monkeypatch, capsys, [
        "this is not json {{{",
    ])
    assert len(resps) == 1
    assert resps[0]["id"] is None
    assert resps[0]["error"]["success"] is False
    assert resps[0]["error"]["error_type"] == "ERROR_INTERNAL"


@pytest.mark.unit
def test_5_concurrent_downloads_stdout_never_interleaved(monkeypatch):
    """T1-7 / HQ1: Prove that under 5 concurrent downloads and simultaneous
    main-thread responses, _stdout_lock guarantees zero interleaved or
    corrupted JSON lines reach stdout.
    """
    import queue as _q
    import threading
    import time
    mod = _main_mod()

    assert hasattr(mod, "_stdout_lock"), "Missing _stdout_lock in __main__.py!"

    # Thread-safe buffer capturing stdout chunks
    buffer_lock = threading.Lock()
    captured_chunks = []

    class _MockStdout:
        def write(self, s):
            with buffer_lock:
                captured_chunks.append(s)

        def flush(self):
            pass

    monkeypatch.setattr(sys, "stdout", _MockStdout())

    # Setup 5 concurrent active downloads in downloader
    from grablytic_engine.downloader import _active_downloads, _downloads_lock
    _active_downloads.clear()

    download_ids = [f"dl-concurrent-{i}" for i in range(5)]
    queues = []

    with _downloads_lock:
        for did in download_ids:
            prog_q = _q.Queue()
            res_q = _q.Queue()
            queues.append((prog_q, res_q))
            _active_downloads[did] = {
                "progress_queue": prog_q,
                "result_queue": res_q,
                "url": f"https://example.com/{did}",
                "cancel_event": threading.Event(),
            }

    stop_event = threading.Event()

    # 5 producer threads pushing progress events at high frequency
    def _producer(did, prog_q, count=200):
        for seq in range(count):
            if stop_event.is_set():
                break
            payload = json.dumps({
                "type": "event",
                "event": "downloading",
                "download_id": did,
                "sequence": seq,
                "payload": "X" * 100,  # Long payload increases interleaving probability
            })
            prog_q.put(payload)

    # 1 thread simultaneously emitting responses via _write_stdout_line
    def _response_writer(count=200):
        for seq in range(count):
            if stop_event.is_set():
                break
            res = json.dumps({
                "id": f"req-{seq}",
                "result": {"status": "ok", "padding": "Y" * 120},
            })
            mod._write_stdout_line(res)

    # 1 thread draining queues via mod._write_stdout_line (simulating poll_queues loop)
    def _poll_drain():
        while not stop_event.is_set():
            for did in download_ids:
                with _downloads_lock:
                    info = _active_downloads.get(did, {})
                    pq = info.get("progress_queue")
                if pq:
                    while not pq.empty():
                        try:
                            ev = pq.get_nowait()
                            mod._write_stdout_line(ev)
                        except Exception:
                            break
            time.sleep(0.001)

    threads = []
    # Start 5 concurrent producers
    for did, (pq, rq) in zip(download_ids, queues):
        t = threading.Thread(target=_producer, args=(did, pq, 150))
        threads.append(t)

    # Start response writer
    resp_thread = threading.Thread(target=_response_writer, args=(150,))
    threads.append(resp_thread)

    # Start poll drain thread
    poll_thread = threading.Thread(target=_poll_drain)
    threads.append(poll_thread)

    for t in threads:
        t.start()

    # Wait for producers and response writer to finish
    for t in threads[:-1]:
        t.join(timeout=10)

    # Allow poll thread a moment to drain remaining items
    time.sleep(0.2)
    stop_event.set()
    poll_thread.join(timeout=5)

    with _downloads_lock:
        _active_downloads.clear()

    # Verify that captured output consists of 100% valid JSON lines
    full_output = "".join(captured_chunks)
    lines = [line.strip() for line in full_output.splitlines() if line.strip()]

    assert len(lines) > 500, f"Expected >500 lines, got {len(lines)}"

    # Crucial assertion: Every single line must parse cleanly without JSONDecodeError!
    for idx, line in enumerate(lines):
        try:
            parsed = json.loads(line)
            assert isinstance(parsed, dict)
        except json.JSONDecodeError as exc:
            pytest.fail(
                f"Interleaved/corrupted JSON line detected at line {idx}: {line!r}\nError: {exc}"
            )



@pytest.mark.unit
def test_method_log_params_sanitized(monkeypatch, capsys):
    """Engine request log must not carry raw proxy/token secrets (Batch 2).

    RED before fix: __main__ logs extra={"params": params} verbatim, so
    proxy passwords, po_tokens and signed-URL sigs hit disk/GitHub.
    """
    mod = _main_mod()
    seen = {}

    class FakeLog:
        def info(self, msg, extra=None):
            seen.setdefault("infos", []).append((msg, extra))

        def log_exception(self, *a, **k):
            pass

        def debug(self, *a, **k):
            pass

    def fake_get_formats(url, config=None):
        return {"success": True, "formats": []}

    monkeypatch.setattr(mod, "log", FakeLog())
    monkeypatch.setattr(mod, "get_formats", fake_get_formats)
    _run_lines(monkeypatch, capsys, [
        json.dumps({"id": "s1", "method": "paths/set", "params": {
            "data_dir": "/tmp/x", "output_dir": "/tmp/x",
            "cache_dir": "/tmp/x"}}),
        json.dumps({"id": "f1", "method": "formats/get", "params": {
            "url": "https://vid.test/watch?v=1&sig=S3CR3T",
            "config": {"proxy": "http://user:p4ssw0rd@proxy.test:8080",
                       "po_token": "POSECRET"}}}),
    ])
    blob = json.dumps(seen.get("infos", []))
    assert "S3CR3T" not in blob
    assert "p4ssw0rd" not in blob
    assert "POSECRET" not in blob
