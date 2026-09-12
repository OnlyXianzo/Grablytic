"""Bundled native packages (ffmpeg/deno jniLibs) — paths, env, bootstrap.

All tests are hermetic: tmp_path dirs, fake `--version` shell scripts, and
( for Android flows) a hard failure if any network download is attempted.
"""

import os
import stat

import pytest

from truestream_engine import paths as paths_mod
from truestream_engine.paths import get_paths, set_paths


def _boot():
    """The bootstrap *module* (the package also exports a `bootstrap`
    function that shadows it on attribute access)."""
    import importlib
    return importlib.import_module("truestream_engine.bootstrap")


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    paths_mod._paths.update({
        "data_dir": None, "output_dir": None, "ffmpeg_path": None,
        "ffmpeg_ld_path": None, "cache_dir": None, "cookies_path": None,
        "aria2c_path": None, "deno_path": None, "po_token": None,
    })
    yield
    paths_mod._paths.update({
        "data_dir": None, "output_dir": None, "ffmpeg_path": None,
        "ffmpeg_ld_path": None, "cache_dir": None, "cookies_path": None,
        "aria2c_path": None, "deno_path": None, "po_token": None,
    })


def _fake_exe(tmp_path, name, version_line):
    exe = tmp_path / name
    exe.write_text(f"#!/bin/sh\necho '{version_line}'\n")
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(exe)


def _ld_dir(tmp_path):
    d = tmp_path / "usr" / "lib"
    d.mkdir(parents=True)
    return str(d)


class TestLdPath:
    @pytest.mark.unit
    def test_multi_dir_ld_path_preserves_order(self, tmp_path, monkeypatch):
        import os
        a = tmp_path / "a" / "usr" / "lib"
        b = tmp_path / "b" / "usr" / "lib"
        a.mkdir(parents=True)
        b.mkdir(parents=True)
        monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
            ffmpeg_ld_path=f"{a}{os.pathsep}{b}",
        )
        assert get_paths()["ffmpeg_ld_path"] == str(a)
        head = os.environ["LD_LIBRARY_PATH"].split(os.pathsep)[:2]
        assert head == [str(a), str(b)]

    def test_multi_dir_skips_missing(self, tmp_path, monkeypatch):
        import os
        good = tmp_path / "good"
        good.mkdir()
        monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
            ffmpeg_ld_path=f"{tmp_path}/nope{os.pathsep}{good}",
        )
        assert get_paths()["ffmpeg_ld_path"] == str(good)
        assert str(good) in os.environ["LD_LIBRARY_PATH"].split(os.pathsep)
        assert f"{tmp_path}/nope" not in os.environ["LD_LIBRARY_PATH"]

    def test_stores_ld_path_and_prepends_env(self, tmp_path):
        ld = _ld_dir(tmp_path)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
            ffmpeg_ld_path=ld,
        )
        assert get_paths()["ffmpeg_ld_path"] == ld
        assert os.environ["LD_LIBRARY_PATH"].split(os.pathsep)[0] == ld

    @pytest.mark.unit
    def test_no_duplicate_on_repeat_calls(self, tmp_path):
        ld = _ld_dir(tmp_path)
        kwargs = dict(data_dir=str(tmp_path), output_dir=str(tmp_path),
                      ffmpeg_path=None, cache_dir=str(tmp_path),
                      ffmpeg_ld_path=ld)
        set_paths(**kwargs)
        set_paths(**kwargs)
        parts = os.environ["LD_LIBRARY_PATH"].split(os.pathsep)
        assert parts.count(ld) == 1

    @pytest.mark.unit
    def test_missing_dir_ignored(self, tmp_path):
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
            ffmpeg_ld_path=str(tmp_path / "does-not-exist"),
        )
        assert get_paths()["ffmpeg_ld_path"] is None
        assert "LD_LIBRARY_PATH" not in os.environ

    @pytest.mark.unit
    def test_none_is_noop(self, tmp_path):
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
        )
        assert get_paths()["ffmpeg_ld_path"] is None
        assert "LD_LIBRARY_PATH" not in os.environ


class TestProbe:
    @pytest.mark.unit
    def test_probe_returns_first_line(self, tmp_path):
        from truestream_engine.bootstrap import _probe_bin_version
        exe = _fake_exe(tmp_path, "ffmpeg", "ffmpeg version n7.1-test")
        assert _probe_bin_version(exe) == "ffmpeg version n7.1-test"

    @pytest.mark.unit
    def test_probe_missing_returns_none(self, tmp_path):
        from truestream_engine.bootstrap import _probe_bin_version
        assert _probe_bin_version(str(tmp_path / "nope")) is None


class TestAndroidBootstrap:
    @pytest.mark.unit
    def test_android_never_downloads(self, tmp_path, monkeypatch):
        """Fail closed in-app: no toolchain fetch, even unverified."""
        boot = _boot()
        # Simulate the production Chaquopy app (java bridge present).
        monkeypatch.setattr(boot, "_is_android_app", lambda: True)
        monkeypatch.setattr(
            boot, "_resolve_latest_release",
            lambda repo: (_ for _ in ()).throw(AssertionError("network used!")),
        )
        ok, ver = boot._bootstrap_github_binary(
            "ffmpeg", boot.GITHUB_REPOS["ffmpeg"], "linuxarm64-gpl",
            str(tmp_path / "bin" / "ffmpeg"), str(tmp_path),
        )
        assert (ok, ver) == (False, None)

    @pytest.mark.unit
    def test_android_env_alone_does_not_trigger_app_branch(
        self, tmp_path, monkeypatch
    ):
        """ANDROID_DATA without the java bridge (Termux/CI) is NOT the app."""
        boot = _boot()
        assert boot._is_android_app() is False

    @pytest.mark.unit
    def test_android_bootstrap_uses_bundled_sos(self, tmp_path, monkeypatch):
        import shutil
        boot = _boot()
        monkeypatch.setattr(boot, "_is_android_app", lambda: True)
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        monkeypatch.setattr(
            boot, "_resolve_latest_release",
            lambda repo: (_ for _ in ()).throw(AssertionError("network used!")),
        )
        ffmpeg = _fake_exe(tmp_path, "libffmpeg.so", "ffmpeg version n7.1-test")
        deno = _fake_exe(tmp_path, "libdeno.so", "deno 2.7.7")
        ld = _ld_dir(tmp_path)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=ffmpeg, cache_dir=str(tmp_path),
            deno_path=deno, ffmpeg_ld_path=ld,
        )
        res = boot.bootstrap()
        assert res["success"] is True
        assert res["ffmpeg_ok"] is True
        assert res["ffmpeg_version"] == "ffmpeg version n7.1-test"
        assert res["deno_ok"] is True
        assert res["js_runtime"] == "deno"
        # aria2c uses compiled/pinned version only: never flagged for dynamic updates.
        assert "aria2c" not in res["update_components"]

    @pytest.mark.unit
    def test_android_bootstrap_missing_bins_reported(self, tmp_path, monkeypatch):
        import shutil
        boot = _boot()
        monkeypatch.setattr(boot, "_is_android_app", lambda: True)
        # Hide system binaries: nothing bundled, nothing on PATH.
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
        )
        res = boot.bootstrap()
        assert res["success"] is True
        assert res["ffmpeg_ok"] is False
        assert "ffmpeg" in res["update_components"]


class TestDenoJsRuntimeFromSo:
    @pytest.mark.unit
    def test_native_lib_deno_path_accepted(self, tmp_path):
        from truestream_engine.opts_builder import _configure_js_runtime
        deno = _fake_exe(tmp_path, "libdeno.so", "deno 2.7.7")
        # detect_js_runtime() resolves deno from the global paths store.
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
            deno_path=deno,
        )
        opts: dict = {}
        _configure_js_runtime(opts, get_paths())
        assert opts["js_runtimes"] == {"deno": {"path": deno}}
        assert opts["remote_components"] == ["ejs:github"]

    @pytest.mark.unit
    def test_paths_store_wins_over_env_and_which(self, tmp_path, monkeypatch):
        from truestream_engine import po_token as pot

        deno = _fake_exe(tmp_path, "libdeno.so", '{"token": "T123"}')
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
            deno_path=deno,
        )
        # Bogus env/which must not shadow the engine paths store.
        monkeypatch.setenv("DENO_PATH", "/nonexistent/deno")
        monkeypatch.setattr(pot.shutil, "which", lambda *a, **k: None)
        assert pot.generate_po_token("https://youtube.com/watch?v=abc") == "T123"
