"""T0-2 exploit-proof tests: IPC-controlled paths must not hijack execution.

Attack primitives under test (see GRABLYTIC_TEARDOWN.md §4 + HQ tracking):
  (a) explicit binary (ffmpeg/aria2c/deno/node) accepted on bare `isfile`
      → arbitrary binary execution;
  (b) `dirname(explicit)` prepended to process PATH on a SUBSTRING check
      (`if pd not in existing_path`) → `/evil/dir` injection + shadowing of
      every later `shutil.which()` fallback;
  (c) IPC `data_dir/site-packages` inserted at `sys.path[0]` on bare `isdir`
      (symlinks followed) → module shadowing + import-time code execution.

Fail-closed expectations below. Legitimate flows (absolute + executable
explicit binaries, e.g. /opt, nix store, test tmp fakes) keep working —
location allowlists were deliberately REJECTED (they break those flows);
the injection *primitive* (PATH prepend of explicit dirs) is removed instead.
"""

import io
import json
import os
import stat
import sys

import pytest

from grablytic_engine.paths import set_paths, get_paths, _paths


# ── hygiene: set_paths mutates process-global PATH/LD_LIBRARY_PATH/ ──
# ── sys.path/_paths. Snapshot everything, restore after each test.   ──

@pytest.fixture
def _isolated(monkeypatch):
    saved_paths = dict(_paths)
    saved_syspath = list(sys.path)
    yield
    _paths.clear()
    _paths.update(saved_paths)
    sys.path[:] = saved_syspath
    # PATH / LD_LIBRARY_PATH restored automatically via monkeypatch below.


@pytest.fixture
def _clean_env(monkeypatch):
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)


def _mkexe(path):
    """Create a genuinely executable file (no mocks — real X_OK bit)."""
    p = str(path)
    with open(p, "w") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    assert os.access(p, os.X_OK)
    return p


def _path_components():
    return os.environ.get("PATH", "").split(os.pathsep)


# ── (b) PATH injection ────────────────────────────────────────────────

def test_evil_aria_dir_never_lands_on_path(tmp_path, monkeypatch, _isolated):
    evil = tmp_path / "evil"
    evil.mkdir()
    evil_bin = _mkexe(evil / "aria2c")
    data = tmp_path / "data"
    data.mkdir()
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    set_paths(data_dir=str(data), output_dir=str(data),
              ffmpeg_path=None, cache_dir=str(data),
              aria2c_path=evil_bin)
    assert str(evil) not in _path_components()


def test_explicit_binary_dirnames_never_prepended(tmp_path, monkeypatch, _isolated):
    dirs = {}
    kwargs = {}
    for key, name in (("ffmpeg_path", "ffmpeg"), ("aria2c_path", "aria2c"),
                      ("deno_path", "deno"), ("nodejs_path", "node")):
        d = tmp_path / f"{name}-dir"
        d.mkdir()
        kwargs[key] = _mkexe(d / name)
        dirs[key] = str(d)
    data = tmp_path / "data"
    data.mkdir()
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    set_paths(data_dir=str(data), output_dir=str(data),
              cache_dir=str(data), **kwargs)
    comps = _path_components()
    for key, d in dirs.items():
        assert d not in comps, key
    # Our own constructed bin dir is still present (bundled resolution intact).
    assert str(data / "bin") in comps


def test_substring_trap_does_not_skip_bin_dir(tmp_path, monkeypatch, _isolated):
    # Old code: `if pd not in existing_path` (substring on the JOINED string).
    # A pre-existing "<bin_dir>_evil" entry contains bin_dir as a substring,
    # so the legit bin dir was silently never prepended (shadowing preserved).
    data = tmp_path / "data"
    data.mkdir()
    bindir = str(data / "bin")
    monkeypatch.setenv("PATH", bindir + "_evil" + os.pathsep + "/usr/bin:/bin")
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    set_paths(data_dir=str(data), output_dir=str(data),
              ffmpeg_path=None, cache_dir=str(data))
    assert bindir in _path_components()


def test_no_duplicate_bin_dir_on_repeat_calls(tmp_path, monkeypatch, _isolated):
    data = tmp_path / "data"
    data.mkdir()
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    kw = dict(data_dir=str(data), output_dir=str(data),
              ffmpeg_path=None, cache_dir=str(data))
    set_paths(**kw)
    set_paths(**kw)
    assert _path_components().count(str(data / "bin")) == 1


# ── (a) binary admission ──────────────────────────────────────────────

def test_relative_binary_path_rejected(tmp_path, monkeypatch, _isolated, _clean_env):
    data = tmp_path / "data"
    data.mkdir()
    set_paths(data_dir=str(data), output_dir=str(data),
              ffmpeg_path="bin/ffmpeg", cache_dir=str(data))
    assert get_paths()["ffmpeg_path"] != "bin/ffmpeg"


def test_non_executable_binary_rejected(tmp_path, monkeypatch, _isolated, _clean_env):
    data = tmp_path / "data"
    data.mkdir()
    plain = str(data / "ffmpeg")
    with open(plain, "w") as fh:
        fh.write("not executable")
    assert not os.access(plain, os.X_OK)
    set_paths(data_dir=str(data), output_dir=str(data),
              ffmpeg_path=plain, cache_dir=str(data))
    assert get_paths()["ffmpeg_path"] != plain


def test_symlink_to_non_executable_rejected(tmp_path, monkeypatch, _isolated, _clean_env):
    data = tmp_path / "data"
    data.mkdir()
    target = str(data / "real-file")
    with open(target, "w") as fh:
        fh.write("not executable")
    link = str(data / "ffmpeg-link")
    os.symlink(target, link)
    set_paths(data_dir=str(data), output_dir=str(data),
              ffmpeg_path=link, cache_dir=str(data))
    # Validation follows symlinks (as exec would): non-exec target rejected.
    assert get_paths()["ffmpeg_path"] != link


def test_absolute_executable_explicit_binary_accepted(tmp_path, monkeypatch, _isolated, _clean_env):
    # Legit custom-toolchain flow (/opt, nix store, side-loaded): absolute +
    # executable explicit paths keep working — no location allowlist.
    data = tmp_path / "data"
    data.mkdir()
    custom_dir = tmp_path / "custom"
    custom_dir.mkdir()
    custom = _mkexe(custom_dir / "ffmpeg")
    set_paths(data_dir=str(data), output_dir=str(data),
              ffmpeg_path=custom, cache_dir=str(data))
    assert get_paths()["ffmpeg_path"] == os.path.realpath(custom)


# ── data/output/cache confinement ─────────────────────────────────────

def test_relative_data_dir_fails_closed(tmp_path, monkeypatch, _isolated, _clean_env):
    before_path = os.environ.get("PATH", "")
    before_sys = list(sys.path)
    res = set_paths(data_dir="rel/data", output_dir=str(tmp_path),
                    ffmpeg_path=None, cache_dir=str(tmp_path))
    assert res["success"] is False
    assert os.environ.get("PATH", "") == before_path
    assert list(sys.path) == before_sys


# ── (c) sys.path insertion ────────────────────────────────────────────

def test_site_packages_symlink_escape_not_inserted(tmp_path, monkeypatch, _isolated, _clean_env):
    data = tmp_path / "data"
    data.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(str(outside), str(data / "site-packages"))
    set_paths(data_dir=str(data), output_dir=str(data),
              ffmpeg_path=None, cache_dir=str(data))
    # The escaped dir itself must not have been inserted at sys.path[0].
    assert str(outside) not in sys.path


def test_legit_site_packages_still_inserted(tmp_path, monkeypatch, _isolated, _clean_env):
    data = tmp_path / "data"
    sp = data / "site-packages"
    sp.mkdir(parents=True)
    assert str(sp) not in sys.path
    set_paths(data_dir=str(data), output_dir=str(data),
              ffmpeg_path=None, cache_dir=str(data))
    assert str(sp) in sys.path


# ── LD_LIBRARY_PATH ───────────────────────────────────────────────────

def test_ld_relative_dir_rejected(tmp_path, monkeypatch, _isolated):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "rel").mkdir()
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    set_paths(data_dir=str(tmp_path), output_dir=str(tmp_path),
              ffmpeg_path=None, cache_dir=str(tmp_path),
              ffmpeg_ld_path="rel")
    assert get_paths()["ffmpeg_ld_path"] is None


# ── use-site gates (opts_builder) ─────────────────────────────────────

def _wire_paths(monkeypatch, **overrides):
    monkeypatch.setattr("shutil.which", lambda *a, **k: None)
    saved = dict(_paths)
    _paths.update({
        "data_dir": "/tmp/data", "output_dir": "/tmp/output",
        "ffmpeg_path": None, "aria2c_path": None, "deno_path": None,
        "nodejs_path": None, "po_token": None, "cache_dir": "/tmp/cache",
        "cookies_path": None, "ffmpeg_ld_path": None,
        "update_channel": "stable",
    })
    _paths.update(overrides)
    return saved


def test_non_executable_aria_not_wired(tmp_path, monkeypatch, _isolated):
    from grablytic_engine.opts_builder import build_ydl_opts
    dummy = str(tmp_path / "aria2c")
    with open(dummy, "w") as fh:
        fh.write("not executable")
    saved = _wire_paths(monkeypatch, aria2c_path=dummy)
    try:
        opts = build_ydl_opts(config={"aria2c_enabled": True})
        assert "external_downloader" not in opts
    finally:
        _paths.clear()
        _paths.update(saved)


def test_executable_aria_wired_by_absolute_path(tmp_path, monkeypatch, _isolated):
    from grablytic_engine.opts_builder import build_ydl_opts
    dummy = _mkexe(tmp_path / "aria2c")
    saved = _wire_paths(monkeypatch, aria2c_path=dummy)
    try:
        opts = build_ydl_opts(config={"aria2c_enabled": True})
        # Absolute pin: yt-dlp execs this exact file (basename→class lookup
        # still resolves Aria2cFD); no PATH lookup involved.
        assert opts["external_downloader"]["default"] == dummy
    finally:
        _paths.clear()
        _paths.update(saved)


def test_non_executable_ffmpeg_location_absent(tmp_path, monkeypatch, _isolated):
    from grablytic_engine.opts_builder import build_ydl_opts
    dummy = str(tmp_path / "ffmpeg")
    with open(dummy, "w") as fh:
        fh.write("not executable")
    saved = _wire_paths(monkeypatch, ffmpeg_path=dummy)
    try:
        opts = build_ydl_opts()
        assert opts.get("ffmpeg_location") != dummy
    finally:
        _paths.clear()
        _paths.update(saved)


def test_non_executable_deno_runtime_ignored(tmp_path, monkeypatch, _isolated):
    import sys as _sys
    from grablytic_engine.opts_builder import build_ydl_opts
    _sys.modules.pop("java.android", None)
    dummy = str(tmp_path / "deno")
    with open(dummy, "w") as fh:
        fh.write("not executable")
    saved = _wire_paths(monkeypatch, deno_path=dummy)
    try:
        opts = build_ydl_opts()
        runtimes = opts.get("js_runtimes", {})
        assert runtimes.get("deno", {}).get("path") != dummy
    finally:
        _paths.clear()
        _paths.update(saved)


# ── IPC envelope forwards fail-closed result ──────────────────────────

def test_ipc_paths_set_forwards_failure(monkeypatch, _isolated):
    import sys as _sys
    import importlib
    mod = importlib.import_module("grablytic_engine.__main__")
    monkeypatch.setattr(_sys, "argv", ["grablytic_engine"])
    monkeypatch.setattr(_sys, "stdin", io.StringIO(json.dumps({
        "id": "evil1", "method": "paths/set",
        "params": {"data_dir": "rel/evil", "output_dir": "/tmp/x",
                   "cache_dir": "/tmp/x"},
    }) + "\n"))
    out = io.StringIO()
    monkeypatch.setattr(_sys, "stdout", out)
    mod.main()
    # Select by id: background engine threads may interleave their own JSON
    # lines on stdout (the T1-7 hazard) — never assume resps[0] is ours, and
    # skip non-JSON print noise defensively.
    answer = None
    for line in out.getvalue().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("id") == "evil1":
            answer = obj
            break
    assert answer is not None
    assert answer["error"]["success"] is False
