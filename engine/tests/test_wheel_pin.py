"""Finding #18: the yt-dlp pin is a digest, not just a version.

The wheel constant, the desktop requirements pin, the Chaquopy pin and the
host-side `EngineContract.ytDlpVersion` all describe the same release. If
they drift, the build installs one version and the docs/tests claim
another — which is exactly how an unverified package slips in.
"""

import hashlib
import importlib
import os

from grablytic_engine import wheel_pin

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
        return handle.read()


def test_pin_constants_are_consistent():
    assert (
        wheel_pin.PINNED_WHEEL == f"yt_dlp-{wheel_pin.PINNED_VERSION}-py3-none-any.whl"
    )
    assert len(wheel_pin.PINNED_SHA256) == 64
    int(wheel_pin.PINNED_SHA256, 16)  # hex, not a placeholder
    assert wheel_pin.requirement_line() == (
        f"yt-dlp=={wheel_pin.PINNED_VERSION} --hash=sha256:{wheel_pin.PINNED_SHA256}"
    )


def test_requirements_file_pins_the_same_version():
    text = _read("engine/requirements.txt")
    pins = [
        line.strip()
        for line in text.splitlines()
        if line.strip().startswith("yt-dlp==")
    ]
    assert pins, "engine/requirements.txt must pin yt-dlp exactly"
    assert pins[0].split("#")[0].strip() == f"yt-dlp=={wheel_pin.PINNED_VERSION}"


def test_android_pin_matches():
    gradle = _read(os.path.join("android", "app", "build.gradle.kts"))
    assert f'install("yt-dlp=={wheel_pin.PINNED_VERSION}")' in gradle


def test_dart_contract_matches():
    dart = _read(os.path.join("lib", "core", "engine", "engine_contract.dart"))
    assert (
        f"ytDlpVersion = '{wheel_pin.PINNED_VERSION}'" in dart
        or f'ytDlpVersion = "{wheel_pin.PINNED_VERSION}"' in dart
    )


def test_verify_wheel_accepts_only_the_pinned_digest(tmp_path):
    good = tmp_path / wheel_pin.PINNED_WHEEL
    good.write_bytes(b"wheel bytes")

    # A file whose digest we do not know is never accepted.
    assert wheel_pin.verify_wheel(str(good)) is False

    # Pretend the file is the pinned artefact by pinning ITS digest.
    original = wheel_pin.PINNED_SHA256
    try:
        wheel_pin.PINNED_SHA256 = hashlib.sha256(b"wheel bytes").hexdigest()
        assert wheel_pin.verify_wheel(str(good)) is True
        good.write_bytes(b"tampered")
        assert wheel_pin.verify_wheel(str(good)) is False
    finally:
        wheel_pin.PINNED_SHA256 = original


def test_missing_file_is_a_failure_not_a_crash(tmp_path):
    assert wheel_pin.verify_wheel(str(tmp_path / "absent.whl")) is False


def test_install_refuses_unverified_bytes(monkeypatch, tmp_path):
    """The installer must not fall back to an unpinned `pip install`."""
    bootstrap = importlib.import_module("grablytic_engine.bootstrap")

    ran = []

    def _no_download(dest_dir, timeout=60.0):
        return None

    monkeypatch.setattr(wheel_pin, "download_verified_wheel", _no_download)
    monkeypatch.setattr(
        bootstrap.subprocess,
        "run",
        lambda *a, **k: ran.append(a)
        or (_ for _ in ()).throw(AssertionError("uv ran")),
    )

    assert bootstrap._install_yt_dlp_via_uv("/usr/bin/uv", str(tmp_path)) is False
    assert ran == []


def test_install_uses_the_verified_wheel(monkeypatch, tmp_path):
    bootstrap = importlib.import_module("grablytic_engine.bootstrap")

    verified = tmp_path / wheel_pin.PINNED_WHEEL
    verified.write_bytes(b"x")
    calls = []

    monkeypatch.setattr(
        wheel_pin,
        "download_verified_wheel",
        lambda dest_dir, timeout=60.0: str(verified),
    )

    class _Ok:
        returncode = 0

    def _run(args, **kwargs):
        calls.append(args)
        return _Ok()

    monkeypatch.setattr(bootstrap.subprocess, "run", _run)

    assert bootstrap._install_yt_dlp_via_uv("/usr/bin/uv", str(tmp_path)) is True
    assert calls == [["/usr/bin/uv", "pip", "install", str(verified)]]
