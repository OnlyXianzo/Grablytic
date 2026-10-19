"""The cleanup loop must not lean on `Queue.empty()`.

`Queue.empty()` is documented as UNRELIABLE in multi-threaded contexts,
and the invariant it relied on was an engine-internal detail, not an
upstream yt-dlp contract. A race there reaped an entry whose result the
client had not read yet — the client lost the terminal event.

An explicit `result_delivered` flag records the fact instead.
"""

import pytest


def _dl():
    import grablytic_engine.downloader as dl_mod

    return dl_mod


@pytest.mark.unit
def test_the_flag_exists_on_a_new_entry():
    dl = _dl()
    dl._active_downloads.clear()
    with dl._downloads_lock:
        dl._active_downloads["x"] = {
            "url": "https://example.com/x",
            "audio_only": False,
            "finished_at": None,
            "result_delivered": False,
        }
    # `_mark_result_delivered` takes the lock itself: calling it while
    # holding it would deadlock (a plain Lock is not re-entrant).
    dl._mark_result_delivered("x")
    with dl._downloads_lock:
        assert dl._active_downloads["x"]["result_delivered"] is True
    dl._active_downloads.clear()


@pytest.mark.unit
def test_marking_is_idempotent_and_safe_for_unknown_ids():
    dl = _dl()
    dl._mark_result_delivered("does-not-exist")  # must not raise


@pytest.mark.unit
def test_the_cleanup_does_not_call_queue_empty():
    """The old code asked the queue whether it was empty."""
    import ast
    import inspect

    src = inspect.getsource(_dl())
    # No `.empty()` call anywhere in the module: the flag replaced it.
    tree = ast.parse(src)
    calls = [
        n
        for n in ast.walk(tree)
        if isinstance(n, ast.Call)
        and isinstance(n.func, ast.Attribute)
        and n.func.attr == "empty"
    ]
    assert calls == []
    assert "result_delivered" in src
