"""BRUTAL-2b: concurrent manifest writers must not lose each other's keys.

_record_binary_sha / _record_archive_sha are load-modify-save cycles. Two
threads interleaving load() -> save() lose one update (last-writer-wins).
The fix serializes the whole cycle on a module lock.
"""

import importlib as _importlib
import threading
import time

# NOTE: `grablytic_engine/__init__.py` rebinds the `bootstrap` attribute to
# the bootstrap() function, so plain `import ...bootstrap as x` yields the
# function. import_module returns the real submodule.
boot_mod = _importlib.import_module("grablytic_engine.bootstrap")
from grablytic_engine.bootstrap import (
    _load_manifest,
    _record_archive_sha,
    _record_binary_sha,
)


def _mkbin(tmp_path, name, payload):
    p = tmp_path / name
    p.write_bytes(payload)
    return str(p)


def _run_interleaved(fn_a, fn_b):
    """Force fn_b's load to land inside fn_a's load->save window.

    The first thread signals once inside the (slowed) load; the second
    starts only then, so without serialization both read the same base
    and the second save clobbers the first. Deterministic both ways.
    """
    entered = threading.Event()
    real_load = boot_mod._load_manifest

    def slow_load(cache_dir):
        entered.set()
        time.sleep(0.3)
        return real_load(cache_dir)

    return entered, slow_load, fn_a, fn_b


def test_concurrent_binary_sha_records_keep_both_keys(tmp_path, monkeypatch):
    a = _mkbin(tmp_path, "ffmpeg", b"A" * 64)
    b = _mkbin(tmp_path, "deno", b"B" * 64)
    entered, slow_load, _, _ = _run_interleaved(None, None)
    monkeypatch.setattr(boot_mod, "_load_manifest", slow_load)

    ta = threading.Thread(target=_record_binary_sha, args=(str(tmp_path), a))
    ta.start()
    assert entered.wait(timeout=10)
    tb = threading.Thread(target=_record_binary_sha, args=(str(tmp_path), b))
    tb.start()
    ta.join(timeout=10)
    tb.join(timeout=10)

    manifest = _load_manifest(str(tmp_path))
    import os as _os
    assert _os.path.realpath(a) in manifest
    assert _os.path.realpath(b) in manifest


def test_concurrent_archive_sha_records_keep_both_keys(tmp_path, monkeypatch):
    entered, slow_load, _, _ = _run_interleaved(None, None)
    monkeypatch.setattr(boot_mod, "_load_manifest", slow_load)

    ta = threading.Thread(
        target=_record_archive_sha,
        args=(str(tmp_path), "ffmpeg", "ffmpeg-1.zip", "aa" * 32),
    )
    ta.start()
    assert entered.wait(timeout=10)
    tb = threading.Thread(
        target=_record_archive_sha,
        args=(str(tmp_path), "deno", "deno-2.zip", "bb" * 32),
    )
    tb.start()
    ta.join(timeout=10)
    tb.join(timeout=10)

    manifest = _load_manifest(str(tmp_path))
    assert manifest["archive:ffmpeg"]["archive_sha256"] == "aa" * 32
    assert manifest["archive:deno"]["archive_sha256"] == "bb" * 32
