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

    monkeypatch.setattr(mod, "search", fake_search)
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
def test_malformed_line_does_not_kill_loop(monkeypatch, capsys):
    resps = _run_lines(monkeypatch, capsys, [
        "this is not json {{{",
        json.dumps({"id": "s1", "method": "paths/set", "params": {
            "data_dir": "/tmp/x", "output_dir": "/tmp/x",
            "cache_dir": "/tmp/x"}}),
    ])
    assert _by_id(resps, "s1")["result"] == {"success": True}
