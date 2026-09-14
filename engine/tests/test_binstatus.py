"""Stronger binary installed-state mechanism + advisory version floor."""

import os
import stat

import pytest

from grablytic_engine import paths as paths_mod
from grablytic_engine.paths import set_paths


def _boot():
    import importlib
    return importlib.import_module("grablytic_engine.bootstrap")


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


def _fake_exe(path, version_line):
    path.write_text(f"#!/bin/sh\necho '{version_line}'\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(path)


def _by_name(res, name):
    return next(b for b in res["binaries"] if b["name"] == name)


class TestBinariesList:
    @pytest.mark.unit
    def test_binaries_present_with_provenance(self, tmp_path, monkeypatch):
        import shutil
        boot = _boot()
        monkeypatch.setattr(boot, "_is_android_app", lambda: True)
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        monkeypatch.setattr(
            boot, "_resolve_latest_release",
            lambda repo: (_ for _ in ()).throw(AssertionError("network used!")),
        )
        ffmpeg = _fake_exe(tmp_path / "libffmpeg.so", "ffmpeg version n7.1")
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=ffmpeg, cache_dir=str(tmp_path),
        )
        res = boot.bootstrap()
        assert res["success"] is True
        assert {b["name"] for b in res["binaries"]} == \
            {"yt-dlp", "ffmpeg", "aria2c", "quickjs", "deno", "node"}
        for b in res["binaries"]:
            assert set(b) == {"name", "ok", "source", "version", "detail"}
        # .so executable resolves as the bundled jniLibs binary.
        assert _by_name(res, "ffmpeg")["source"] == "bundled"
        # aria2c has no Android channel: unsupported, never "missing".
        aria = _by_name(res, "aria2c")
        assert aria["ok"] is False
        assert aria["source"] == "unsupported"
        assert "native downloader" in aria["detail"]
        # quickjs without the wheel: missing with an actionable hint.
        qjs = _by_name(res, "quickjs")
        assert qjs["source"] == "missing"
        assert "Deno" in qjs["detail"]

    @pytest.mark.unit
    def test_broken_binary_fails_closed(self, tmp_path, monkeypatch):
        """When an executable fails probe (e.g. missing DT_NEEDED library / rc!=0),
        bootstrap must report ok=False, missing source, and log diagnostic detail."""
        import shutil
        boot = _boot()
        monkeypatch.setattr(boot, "_is_android_app", lambda: True)
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        monkeypatch.setattr(
            boot, "_resolve_latest_release",
            lambda repo: (_ for _ in ()).throw(AssertionError("network used!")),
        )
        broken_path = tmp_path / "libffmpeg.so"
        broken_path.write_text(
            "#!/bin/sh\n"
            "echo 'CANNOT LINK EXECUTABLE: library \"libexpat.so.1\" not found' >&2\n"
            "exit 1\n"
        )
        broken_path.chmod(broken_path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=str(broken_path), cache_dir=str(tmp_path),
        )
        res = boot.bootstrap()
        assert res["success"] is True
        assert res["ffmpeg_ok"] is False
        assert "ffmpeg" in res["update_components"]
        ffmpeg = _by_name(res, "ffmpeg")
        assert ffmpeg["ok"] is False
        assert ffmpeg["source"] == "missing"
        assert ffmpeg["version"] is None
        assert "probe rc=1" in ffmpeg["detail"]
        assert "libexpat.so.1" in ffmpeg["detail"]

    @pytest.mark.unit
    def test_ffmpeg_probe_uses_single_dash_version(self, tmp_path, monkeypatch):
        """Probe invokes single-dash '-version' (yt-dlp's own convention).
        Both dash forms work on real FFmpeg (verified empirically); the
        single-dash form is kept for consistency, and this test pins it."""
        import shutil
        boot = _boot()
        monkeypatch.setattr(boot, "_is_android_app", lambda: True)
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        monkeypatch.setattr(
            boot, "_resolve_latest_release",
            lambda repo: (_ for _ in ()).throw(AssertionError("network used!")),
        )
        ffmpeg_script = tmp_path / "libffmpeg.so"
        ffmpeg_script.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = \"-version\" ]; then\n"
            "  echo 'ffmpeg version 7.0.1 Copyright (c) 2000-2024'\n"
            "  exit 0\n"
            "else\n"
            "  echo \"Unrecognized option '$1'\" >&2\n"
            "  exit 8\n"
            "fi\n"
        )
        ffmpeg_script.chmod(ffmpeg_script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=str(ffmpeg_script), cache_dir=str(tmp_path),
        )
        res = boot.bootstrap()
        assert res["success"] is True
        assert res["ffmpeg_ok"] is True
        assert "ffmpeg" not in res["update_components"]
        ffmpeg = _by_name(res, "ffmpeg")
        assert ffmpeg["ok"] is True
        assert ffmpeg["source"] == "bundled"
        assert "7.0.1" in (ffmpeg["version"] or "")

    @pytest.mark.unit

    def test_downloaded_and_system_sources(self, tmp_path, monkeypatch):
        import shutil
        boot = _boot()
        monkeypatch.setattr(boot, "_is_android_app", lambda: False)
        bindir = tmp_path / "bin"
        bindir.mkdir()
        ffmpeg = _fake_exe(bindir / "ffmpeg", "ffmpeg version sys")
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        monkeypatch.setattr(
            boot, "_resolve_latest_release",
            lambda repo: (_ for _ in ()).throw(AssertionError("network used!")),
        )
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=ffmpeg, cache_dir=str(tmp_path),
        )
        res = boot.bootstrap()
        assert _by_name(res, "ffmpeg")["source"] == "downloaded"

        sysbin = _fake_exe(tmp_path / "ffmpeg-sys", "ffmpeg version s")
        monkeypatch.setattr(shutil, "which", lambda *a, **k: sysbin)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=sysbin, cache_dir=str(tmp_path),
        )
        res = boot.bootstrap()
        assert _by_name(res, "ffmpeg")["source"] == "system"

    @pytest.mark.unit
    def test_legacy_keys_untouched(self, tmp_path, monkeypatch):
        import shutil
        boot = _boot()
        monkeypatch.setattr(boot, "_is_android_app", lambda: False)
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        monkeypatch.setattr(
            boot, "_resolve_latest_release",
            lambda repo: (_ for _ in ()).throw(AssertionError("network used!")),
        )
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=None, cache_dir=str(tmp_path),
        )
        res = boot.bootstrap()
        assert res["contract_version"] == "1.0"
        assert "ffmpeg_ok" in res and "quickjs_ok" in res


class TestVersionFloor:
    @pytest.mark.unit
    def test_below_floor(self):
        boot = _boot()
        assert boot._is_version_below("2024.07.01", "2025.11.12") is True
        assert boot._is_version_below("2025.11.11", "2025.11.12") is True

    @pytest.mark.unit
    def test_at_or_above_floor(self):
        boot = _boot()
        assert boot._is_version_below("2025.11.12", "2025.11.12") is False
        assert boot._is_version_below("2026.08.19", "2025.11.12") is False

    @pytest.mark.unit
    def test_unparseable_never_bricks(self):
        boot = _boot()
        assert boot._is_version_below("unknown", "2025.11.12") is False
        assert boot._is_version_below("", "2025.11.12") is False
        assert boot._is_version_below(None, "2025.11.12") is False


class TestTmplConfine:
    @pytest.mark.unit
    def test_good_templates_pass(self):
        from grablytic_engine.opts_builder import _is_safe_outtmpl
        assert _is_safe_outtmpl("%(uploader)s - %(title)s.%(ext)s") is True
        assert _is_safe_outtmpl("%(uploader)s/%(title)s.%(ext)s") is True

    @pytest.mark.unit
    def test_escape_attempts_rejected(self):
        from grablytic_engine.opts_builder import _is_safe_outtmpl
        assert _is_safe_outtmpl("/etc/cron.d/%(title)s") is False
        assert _is_safe_outtmpl("C:\\Windows\\%(title)s") is False
        assert _is_safe_outtmpl("../../%(title)s") is False
        assert _is_safe_outtmpl("a/b/../../c") is False
        assert _is_safe_outtmpl("") is False
        assert _is_safe_outtmpl(None) is False
        assert _is_safe_outtmpl("x" * 257) is False
        assert _is_safe_outtmpl("a\x00b") is False

    @pytest.mark.unit
    def test_builder_falls_back_to_default(self):
        from grablytic_engine.opts_builder import build_ydl_opts
        from grablytic_engine.config import DEFAULT_CFG
        opts = build_ydl_opts(config={"output_tmpl": "/abs/evil"})
        assert opts["outtmpl"] == {"default": DEFAULT_CFG["output_tmpl"]}
        opts = build_ydl_opts(config={"output_tmpl": "%(title)s.%(ext)s"})
        assert opts["outtmpl"] == {"default": "%(title)s.%(ext)s"}
