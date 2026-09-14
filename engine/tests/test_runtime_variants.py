"""Release-variant coverage (Task 2: APK size / ABI split / runtime matrix).

Simulates each single-runtime APK flavor hermetically: the Gradle
`-PjsRuntime` filter decides which `.so` files ship, and everything
downstream is presence-based — so a variant APK is faithfully modeled by
bundling only that variant's binaries via set_paths() and asserting the
engine still resolves a working JS runtime.

Also pins the Gradle-side wiring as a cross-file contract (property name,
valid values, default, fetch-loop hookup, and the no-splits{} invariant
that Chaquopy requires).
"""

import os
import pathlib
import stat
import sys

import pytest

from grablytic_engine import paths as paths_mod
from grablytic_engine.paths import set_paths


@pytest.fixture(autouse=True)
def _clean_paths(monkeypatch):
    saved = dict(paths_mod._paths)
    monkeypatch.delenv("LD_LIBRARY_PATH", raising=False)
    monkeypatch.delenv("NODE_PATH", raising=False)
    monkeypatch.delenv("DENO_PATH", raising=False)
    paths_mod._paths.update({
        "data_dir": None, "output_dir": None, "ffmpeg_path": None,
        "ffmpeg_ld_path": None, "cache_dir": None, "cookies_path": None,
        "aria2c_path": None, "deno_path": None, "nodejs_path": None,
        "po_token": None,
    })
    yield
    paths_mod._paths.update(saved)


def _boot():
    import importlib
    return importlib.import_module("grablytic_engine.bootstrap")


def _fake_exe(tmp_path, name, version_line):
    exe = tmp_path / name
    exe.write_text(f"#!/bin/sh\necho '{version_line}'\n")
    exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return str(exe)


def _ld_dir(tmp_path):
    d = tmp_path / "usr" / "lib"
    d.mkdir(parents=True)
    return str(d)


def _android_no_network(monkeypatch):
    boot = _boot()
    import shutil
    monkeypatch.setattr(boot, "_is_android_app", lambda: True)
    monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
    monkeypatch.setattr(
        boot, "_resolve_latest_release",
        lambda repo: (_ for _ in ()).throw(AssertionError("network used!")),
    )
    return boot


class TestSingleRuntimeVariants:
    @pytest.mark.unit
    def test_node_only_variant_resolves_node(self, tmp_path, monkeypatch):
        """Simulates the arm64+Node APK: only libnode.so bundled."""
        boot = _android_no_network(monkeypatch)
        ffmpeg = _fake_exe(tmp_path, "libffmpeg.so", "ffmpeg version n7.1-test")
        node = _fake_exe(tmp_path, "libnode.so", "v25.3.0")
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=ffmpeg, cache_dir=str(tmp_path),
            nodejs_path=node, ffmpeg_ld_path=_ld_dir(tmp_path),
        )
        res = boot.bootstrap()
        assert res["success"] is True
        assert res["node_ok"] is True
        assert res["deno_ok"] is False
        assert res["js_runtime"] == "node"

    @pytest.mark.unit
    def test_deno_only_variant_resolves_deno(self, tmp_path, monkeypatch):
        """Simulates the arm64+Deno APK: only libdeno.so bundled."""
        boot = _android_no_network(monkeypatch)
        ffmpeg = _fake_exe(tmp_path, "libffmpeg.so", "ffmpeg version n7.1-test")
        deno = _fake_exe(tmp_path, "libdeno.so", "deno 2.7.7")
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=ffmpeg, cache_dir=str(tmp_path),
            deno_path=deno, ffmpeg_ld_path=_ld_dir(tmp_path),
        )
        res = boot.bootstrap()
        assert res["success"] is True
        assert res["deno_ok"] is True
        assert res["node_ok"] is False
        assert res["js_runtime"] == "deno"

    @pytest.mark.unit
    def test_opts_builder_node_only_selects_node(self, tmp_path, monkeypatch):
        """Desktop line 461 branch: deno absent, node present → node configured."""
        import shutil
        from grablytic_engine.opts_builder import build_ydl_opts
        monkeypatch.delitem(sys.modules, "java.android", raising=False)
        monkeypatch.setattr(shutil, "which", lambda *a, **k: None)
        node = tmp_path / "node"
        node.touch()
        os.chmod(node, 0o755)
        set_paths(
            data_dir=str(tmp_path), output_dir=str(tmp_path),
            ffmpeg_path=str(tmp_path / "ffmpeg"), cache_dir=str(tmp_path),
            nodejs_path=str(node),
        )
        opts = build_ydl_opts()
        assert opts["js_runtimes"] == {"node": {"path": str(node)}}
        assert opts["remote_components"] == ["ejs:github"]


class TestGradleVariantContract:
    @staticmethod
    def _read(name):
        root = pathlib.Path(__file__).resolve().parents[2]
        return (root / "android" / "app" / name).read_text()

    @pytest.mark.unit
    def test_jsruntime_property_wired(self):
        pkg = self._read("packages.gradle.kts")
        # Property read + closed value set + default preserving today's behavior.
        assert 'findProperty("jsRuntime")' in pkg
        assert 'setOf("deno", "node", "both")' in pkg
        assert '"both" else' in pkg or "'both'" in pkg or '"both"' in pkg
        # The filter must feed the actual fetch loop AND the offline warm check,
        # not just be defined and unused.
        assert "for ((pkg, version) in activePackageVersions)" in pkg
        assert pkg.count("activePackageVersions") >= 3

    @pytest.mark.unit
    def test_abi_mechanism_intact_no_splits(self):
        pkg = self._read("packages.gradle.kts")
        app = self._read("build.gradle.kts")
        # -PtargetAbi mechanism untouched in both files.
        assert 'findProperty("targetAbi")' in pkg
        assert 'findProperty("targetAbi")' in app
        # splits{}/flavor ABI blocks would hard-fail (or silently no-op on) the
        # build against Chaquopy's abiFilters (verified Phase 1): guard the
        # decision against regression. Match real DSL blocks, not prose mentions.
        import re
        code_lines = [ln for ln in app.splitlines()
                      if not ln.strip().startswith("//")]
        code = "\n".join(code_lines)
        assert re.search(r"(?m)^\s*splits\s*\{", code) is None
        assert re.search(r"(?m)^\s*productFlavors\s*\{", code) is None
