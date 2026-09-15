"""Secure archive extraction (Zip-Slip / Tar-Slip hardening)."""

import io
import tarfile
import zipfile

import pytest

from grablytic_engine.bootstrap import (
    _download_and_extract_binary,
    _safe_extract_tar,
    _safe_extract_zip,
    _calculate_sha256,
    _load_manifest,
    _record_binary_sha,
    _verify_binary_against_manifest,
)


def _zip_bytes(entries):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, data in entries:
            z.writestr(name, data)
    return buf.getvalue()


def _write(archive: bytes, path) -> str:
    p = str(path)
    with open(p, "wb") as f:
        f.write(archive)
    return p


def _tar_bytes(entries, links=()):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in entries:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
        for name, target in links:
            ti = tarfile.TarInfo(name)
            ti.type = tarfile.SYMTYPE
            ti.linkname = target
            t.addfile(ti)
    return buf.getvalue()


class TestSafeZip:
    @pytest.mark.unit
    def test_valid_member_extracts(self, tmp_path):
        archive = _write(_zip_bytes([("ffmpeg", b"bin")]), tmp_path / "a.zip")
        out = tmp_path / "out"
        out.mkdir()
        _safe_extract_zip(archive, str(out))
        assert (out / "ffmpeg").read_bytes() == b"bin"

    @pytest.mark.unit
    @pytest.mark.parametrize("evil", [
        "../evil.txt", "sub/../../evil.txt", "/abs.txt", "C:/evil.txt",
        "C:\\evil.txt", "\\\\host\\share\\evil.txt",
    ])
    def test_malicious_names_rejected(self, tmp_path, evil):
        archive = _write(_zip_bytes([(evil, b"x")]), tmp_path / "a.zip")
        out = tmp_path / "out"
        out.mkdir()
        with pytest.raises(ValueError, match="Security Violation"):
            _safe_extract_zip(archive, str(out))
        assert list(out.iterdir()) == []


class TestSafeTar:
    @pytest.mark.unit
    def test_valid_member_extracts(self, tmp_path):
        archive = _write(
            _tar_bytes([("ffmpeg", b"bin")]), tmp_path / "a.tar")
        out = tmp_path / "out"
        out.mkdir()
        _safe_extract_tar(archive, str(out))
        assert (out / "ffmpeg").read_bytes() == b"bin"

    @pytest.mark.unit
    @pytest.mark.parametrize("evil", ["../evil", "/abs", "sub/../../evil"])
    def test_traversal_rejected(self, tmp_path, evil):
        archive = _write(_tar_bytes([(evil, b"x")]), tmp_path / "a.tar")
        out = tmp_path / "out"
        out.mkdir()
        with pytest.raises(ValueError, match="Security Violation"):
            _safe_extract_tar(archive, str(out))

    @pytest.mark.unit
    def test_symlink_rejected(self, tmp_path):
        archive = _write(
            _tar_bytes([("real", b"x")], links=[("link", "/etc/passwd")]),
            tmp_path / "a.tar",
        )
        out = tmp_path / "out"
        out.mkdir()
        with pytest.raises(ValueError, match="non-regular"):
            _safe_extract_tar(archive, str(out))


class TestWiredExtraction:
    @pytest.mark.unit
    def test_e2e_malicious_zip_blocked(self, tmp_path, monkeypatch):
        import urllib.request

        payload = _zip_bytes([("../evil.txt", b"x")])
        sha = __import__("hashlib").sha256(payload).hexdigest()

        class MockResponse:
            def __init__(self):
                self._done = False
            def read(self, *a, **k):
                if self._done:
                    return b""
                self._done = True
                return payload
            def __enter__(self):
                return self
            def __exit__(self, *a):
                pass

        monkeypatch.setattr(
            urllib.request, "urlopen",
            lambda req, timeout=None: MockResponse(),
        )
        with pytest.raises(ValueError, match="Security Violation"):
            _download_and_extract_binary(
                "https://example.com/tool.zip", sha,
                str(tmp_path / "bin" / "tool"), str(tmp_path),
            )


# ── Exploit-proof tests (T0-5: trojaned-binary trust gap) ─────────────


class TestBinaryManifestVerification:
    """Verify that _bootstrap_github_binary does NOT blindly trust existing
    binaries. An existing binary must match the manifest to be trusted."""

    @pytest.mark.unit
    def test_unrecorded_binary_is_not_trusted(self, tmp_path):
        """A binary with no manifest entry must NOT be trusted."""
        cache_dir = str(tmp_path / "cache")
        import os
        os.makedirs(cache_dir, exist_ok=True)
        binary = tmp_path / "bin" / "ffmpeg"
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"#!/bin/sh\necho trojaned")
        binary.chmod(0o755)
        assert not _verify_binary_against_manifest(cache_dir, str(binary))

    @pytest.mark.unit
    def test_tampered_binary_is_not_trusted(self, tmp_path):
        """A binary whose content differs from the manifest must NOT be trusted."""
        cache_dir = str(tmp_path / "cache")
        import os
        os.makedirs(cache_dir, exist_ok=True)
        binary = tmp_path / "bin" / "ffmpeg"
        binary.parent.mkdir(parents=True, exist_ok=True)
        # Record the legitimate binary
        binary.write_bytes(b"legitimate binary content")
        _record_binary_sha(cache_dir, str(binary))
        assert _verify_binary_against_manifest(cache_dir, str(binary))
        # Now trojan it
        binary.write_bytes(b"trojaned binary content")
        assert not _verify_binary_against_manifest(cache_dir, str(binary))

    @pytest.mark.unit
    def test_legitimate_binary_is_trusted(self, tmp_path):
        """A binary matching its manifest entry IS trusted."""
        cache_dir = str(tmp_path / "cache")
        import os
        os.makedirs(cache_dir, exist_ok=True)
        binary = tmp_path / "bin" / "ffmpeg"
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"real ffmpeg binary content")
        _record_binary_sha(cache_dir, str(binary))
        assert _verify_binary_against_manifest(cache_dir, str(binary))

    @pytest.mark.unit
    def test_manifest_persists_across_loads(self, tmp_path):
        """Manifest survives save/load cycle."""
        cache_dir = str(tmp_path / "cache")
        import os
        os.makedirs(cache_dir, exist_ok=True)
        binary = tmp_path / "bin" / "ffmpeg"
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"persistent binary")
        _record_binary_sha(cache_dir, str(binary))
        # Reload from disk
        manifest = _load_manifest(cache_dir)
        real_path = os.path.realpath(str(binary))
        assert real_path in manifest
        assert manifest[real_path] == _calculate_sha256(str(binary))

