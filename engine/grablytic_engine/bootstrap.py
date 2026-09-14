import os
import sys
import json
import time
import platform
import hashlib
import urllib.request
import zipfile
import tarfile
import shutil
import tempfile
import threading
import subprocess

from grablytic_engine.paths import get_paths, is_initialized
from grablytic_engine.logger import get_logger


log = get_logger("grablytic_engine.bootstrap")

GITHUB_REPOS = {
    "uv": "astral-sh/uv",
    "ffmpeg": "BtbN/FFmpeg-Builds",
    "aria2c": "asdo92/aria2-static-builds",
    "deno": "denoland/deno",
}

PLATFORM_TRIPLES = {
    "linux-x86_64": "x86_64-unknown-linux-gnu",
    "linux-aarch64": "aarch64-unknown-linux-gnu",
    "windows-x86_64": "x86_64-pc-windows-msvc",
    "macos-x86_64": "x86_64-apple-darwin",
    "macos-aarch64": "aarch64-apple-darwin",
    "android-arm64": "linux-aarch64",
    "android-x86_64": "linux-x86_64",
}

FFMPEG_PLATFORM_MAP = {
    "linux-x86_64": "linux64-gpl",
    "linux-aarch64": "linuxarm64-gpl",
    "windows-x86_64": "win64-gpl",
    "macos-x86_64": "macos64-gpl",
    "macos-aarch64": "macosarm64-gpl",
    "android-arm64": "linuxarm64-gpl",
    "android-x86_64": "linux64-gpl",
}


def _on_android_os() -> bool:
    """True on any Android Bionic Python (app, Termux, CI runners)."""
    return hasattr(sys, "getandroidapilevel")


def _is_termux() -> bool:
    """True inside a Termux user shell (behaves like Linux for toolchains)."""
    return "TERMUX_VERSION" in os.environ or os.environ.get("PREFIX", "").startswith(
        "/data/data/com.termux"
    )


def _is_android_app() -> bool:
    """True only inside the production Chaquopy app process.

    The `java.android` bridge exists solely in-app: Termux, desktop and CI
    Pythons raise ImportError. This replaces the ANDROID_DATA env sniff,
    which the OS sets for every app process including Termux shells.
    """
    try:
        from java.android import context  # type: ignore[import-not-found]
        return context is not None
    except Exception:
        return False


def _get_platform_key() -> str:
    if _on_android_os() and not _is_termux():
        os_name = "android"
    elif sys.platform.startswith("win"):
        os_name = "windows"
    elif sys.platform.startswith("linux"):
        os_name = "linux"
    elif sys.platform.startswith("darwin"):
        os_name = "macos"
    else:
        os_name = "unknown"

    machine = platform.machine().lower()
    if "arm64" in machine or "aarch64" in machine:
        arch = "arm64"
    elif "x86_64" in machine or "amd64" in machine:
        arch = "x86_64"
    elif "arm" in machine:
        arch = "arm"
    else:
        arch = "x86_64"

    return f"{os_name}-{arch}"


def _get_asset_substring(name: str, platform_key: str) -> str:
    if name == "ffmpeg":
        return FFMPEG_PLATFORM_MAP.get(platform_key, platform_key)
    if name == "aria2c":
        if "windows" in platform_key:
            return "windows-x86_64"
        if "arm64" in platform_key or "aarch64" in platform_key:
            return "aarch64"
        return "x86_64"
    return PLATFORM_TRIPLES.get(platform_key, platform_key)


def _calculate_sha256(filepath: str) -> str:
    sha256 = hashlib.sha256()
    try:
        with open(filepath, "rb") as f:
            while chunk := f.read(8192):
                sha256.update(chunk)
        return sha256.hexdigest()
    except Exception:
        return ""


def _get_yt_dlp_version() -> str:
    try:
        from yt_dlp import version as yt_dlp_version
        return yt_dlp_version.__version__
    except (ImportError, AttributeError):
        return "unknown"


def _write_progress(step: str, status: str):
    paths = get_paths()
    data_dir = paths.get("data_dir")
    if not data_dir:
        return
    progress_path = os.path.join(data_dir, "bootstrap_progress.json")
    try:
        with open(progress_path, "a") as f:
            f.write(json.dumps({"step": step, "status": status}) + "\n")
    except Exception:
        pass


def _github_api(url: str) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Grablytic/1.0",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _resolve_latest_release(repo: str) -> dict:
    return _github_api(f"https://api.github.com/repos/{repo}/releases/latest")


def _find_asset(assets: list, substring: str) -> str | None:
    for a in assets:
        if substring in a["name"]:
            return a["browser_download_url"]
    return None


def _find_checksum_url(assets: list, archive_name: str) -> str | None:
    for suffix in (".sha256", ".sha256sum"):
        target = archive_name + suffix
        for a in assets:
            if a["name"] == target:
                return a["browser_download_url"]
    for a in assets:
        name = a["name"]
        if "SHA256" in name.upper() and archive_name.split(".")[0] in name:
            return a["browser_download_url"]
    for a in assets:
        if a["name"] in ("checksums.sha256", "checksums.txt", "SHA256SUMS"):
            return a["browser_download_url"]
    return None


def _parse_sha256_file(content: str) -> dict[str, str]:
    result = {}
    for line in content.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        parts = line.replace(" *", "  ").split("  ")
        if len(parts) == 2:
            result[parts[1].lstrip("./")] = parts[0]
    return result


def _extract_version_from_tag(tag: str) -> str:
    v = tag.lstrip("v")
    if v.startswith("release-"):
        v = v[len("release-"):]
    return v


def _is_version_below(have: str | None, floor: str) -> bool:
    """True when dotted version *have* is older than *floor*.

    Non-parseable values ("unknown", dates, suffixed builds) return False —
    an advisory must never brick on a version string it cannot read.
    """
    def _parts(v: str) -> list[int] | None:
        try:
            chunks = []
            for piece in v.strip().split("."):
                digits = "".join(c for c in piece if c.isdigit())
                if not digits:
                    return None
                chunks.append(int(digits))
            return chunks or None
        except Exception:
            return None

    if not have:
        return False
    hp, fp = _parts(have), _parts(floor)
    if hp is None or fp is None:
        return False
    width = max(len(hp), len(fp))
    hp += [0] * (width - len(hp))
    fp += [0] * (width - len(fp))
    return hp < fp


def _is_within_directory(base: str, target: str) -> bool:
    """True iff realpath(target) stays inside realpath(base)."""
    try:
        return os.path.commonpath(
            [os.path.realpath(base), os.path.realpath(target)]
        ) == os.path.realpath(base)
    except Exception:
        return False


def _reject_unsafe_name(name: str) -> str | None:
    """Return a clean relative member name, or None to skip the member.

    Rejects absolute paths (POSIX + Windows drive/UNC), null bytes, and
    anything escaping via `..` after separator normalization. zipfile has no
    `filter=` parameter, so this manual gate is mandatory.
    """
    if not name or "\x00" in name:
        return None
    text = name.replace("\\", "/")
    # Absolute POSIX, Windows drive (C:/, C:), UNC/host shares.
    if text.startswith(("/", "~")):
        return None
    if len(text) >= 2 and text[1] == ":":
        return None
    if text.startswith("//"):
        return None
    cleaned = os.path.normpath(text)
    if cleaned in (".", "") or cleaned.startswith(".."):
        return None
    return cleaned


def _safe_extract_zip(archive_path: str, extract_dir: str) -> None:
    with zipfile.ZipFile(archive_path, "r") as z:
        for member in z.infolist():
            clean = _reject_unsafe_name(member.filename)
            if clean is None:
                raise ValueError(
                    f"Security Violation: unsafe zip member {member.filename!r}"
                )
            target = os.path.join(extract_dir, clean)
            if not _is_within_directory(extract_dir, target):
                raise ValueError(
                    f"Security Violation: Zip Slip detected in {member.filename!r}"
                )
            if member.is_dir():
                os.makedirs(target, exist_ok=True)
            else:
                os.makedirs(os.path.dirname(target) or extract_dir, exist_ok=True)
                with z.open(member, "r") as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)


def _safe_extract_tar(archive_path: str, extract_dir: str) -> None:
    # Toolchain archives only ever need regular files and directories:
    # symlinks, hardlinks, devices and fifos are rejected outright.
    with tarfile.open(archive_path, "r:*") as t:
        members = t.getmembers()
        for m in members:
            if m.issym() or m.islnk() or m.ischr() or m.isblk() or m.isfifo():
                raise ValueError(
                    f"Security Violation: non-regular tar member {m.name!r}"
                )
            clean = _reject_unsafe_name(m.name)
            if clean is None or not _is_within_directory(
                extract_dir, os.path.join(extract_dir, clean)
            ):
                raise ValueError(
                    f"Security Violation: Tar Slip detected in {m.name!r}"
                )
        if hasattr(tarfile, "data_filter"):
            t.extractall(extract_dir, filter="data")
        else:
            # Python < 3.11.4 has no extraction filter: the manual gate above
            # already validated every member, so this is fail-closed, never
            # silently trusted.
            t.extractall(extract_dir)


def _download_and_extract_binary(
    url: str, sha256_expected: str | None, dest_path: str, temp_dir_root: str
):
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"},
    )

    with tempfile.TemporaryDirectory(dir=temp_dir_root) as tmpdir:
        if os.name != "nt":
            os.chmod(tmpdir, 0o700)
        archive_path = os.path.join(tmpdir, "downloaded_asset")

        with urllib.request.urlopen(req, timeout=15) as response, open(
            archive_path, "wb"
        ) as out_file:
            shutil.copyfileobj(response, out_file)

        sha256_actual = _calculate_sha256(archive_path)
        if sha256_expected is not None and sha256_actual != sha256_expected:
            raise ValueError(
                f"Checksum mismatch for {url}: expected {sha256_expected}, got {sha256_actual}"
            )

        extract_dir = os.path.join(tmpdir, "extracted")
        os.makedirs(extract_dir, exist_ok=True)

        if url.endswith(".zip"):
            _safe_extract_zip(archive_path, extract_dir)
        else:
            _safe_extract_tar(archive_path, extract_dir)

        binary_name = os.path.basename(dest_path).lower()
        found_binary = None
        for root, _, files in os.walk(extract_dir):
            for file in files:
                if file.lower() == binary_name:
                    found_binary = os.path.join(root, file)
                    break
            if found_binary:
                break

        if not found_binary:
            base_bin_name = binary_name.split(".")[0]
            for root, _, files in os.walk(extract_dir):
                for file in files:
                    if base_bin_name in file.lower():
                        found_binary = os.path.join(root, file)
                        break
                if found_binary:
                    break

        if not found_binary:
            raise FileNotFoundError(
                f"Could not find binary {binary_name} in extracted archive"
            )

        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        if os.path.exists(dest_path):
            os.remove(dest_path)
        shutil.move(found_binary, dest_path)

        if os.name != "nt" and os.path.isfile(dest_path):
            os.chmod(dest_path, 0o755)


def _probe_report(bin_path: str, timeout: int = 8) -> dict:
    """Best-effort `--version` probe with full diagnostics.

    Returns {"ok", "version", "returncode", "output"} where output is the
    first 300 chars of stdout+stderr. The output is the decisive artifact
    when a bundled binary refuses to run on-device (linker errors,
    permission denials) — version alone ("None") says nothing. Never raises.
    """
    report: dict = {"ok": False, "version": None, "returncode": None,
                    "output": ""}
    try:
        bin_name = os.path.basename(bin_path).lower()
        # FFmpeg and FFprobe CLI syntax requires '-version' (single hyphen).
        # Passing GNU-style '--version' causes unrecognized option and exit code 8.
        version_arg = "-version" if ("ffmpeg" in bin_name or "ffprobe" in bin_name) else "--version"
        proc = subprocess.run(
            [bin_path, version_arg],
            capture_output=True, text=True, timeout=timeout,
        )
        report["returncode"] = proc.returncode
        out = ((proc.stdout or "") + "\n" + (proc.stderr or "")).strip()
        report["output"] = out[:2000]
        if proc.returncode == 0 and proc.stdout:
            first = proc.stdout.splitlines()[0].strip()[:120] or None
            report["version"] = first
            report["ok"] = first is not None
    except Exception as exc:
        report["output"] = f"probe raised {type(exc).__name__}: {exc}"[:300]
    return report


def _probe_bin_version(bin_path: str, timeout: int = 8) -> str | None:
    """Best-effort `--version` probe. Returns the first line, else None.

    Used on Android where binaries come from bundled jniLibs (no release tag
    to read a version from). Never raises.
    """
    return _probe_report(bin_path, timeout=timeout)["version"]


def _bootstrap_github_binary(
    name: str,
    repo: str,
    asset_substring: str,
    dest_path: str | None,
    cache_dir: str,
) -> tuple[bool, str | None]:
    if not dest_path:
        return False, None

    if os.path.isfile(dest_path) and os.access(dest_path, os.X_OK):
        return True, None

    is_android = _is_android_app()
    if is_android:
        # Bundled jniLibs binaries (libffmpeg.so / libdeno.so) are the ONLY
        # files the OS will execute on targetSdk > 28. Toolchain binaries
        # downloaded here could never run — and fetching them unverified (the
        # old John Van Sickle branch) was a security hole. Fail closed: the
        # resolved-path fallback below reports bundled binaries as ok.
        log.info(f"Bootstrap {name}: skipped download on Android (bundled jniLibs)")
        return False, None

    # Check if binary is available on system PATH (e.g. /usr/bin/ffmpeg)
    system_bin = shutil.which(name)
    if system_bin and os.path.isfile(system_bin) and os.access(system_bin, os.X_OK):
        return True, None

    try:
        release = _resolve_latest_release(repo)
        assets = release.get("assets", [])
        version_str = _extract_version_from_tag(release.get("tag_name", ""))

        download_url = _find_asset(assets, asset_substring)
        if not download_url:
            return False, None

        archive_name = download_url.split("/")[-1].split("?")[0]

        expected_sha = None
        sha_url = _find_checksum_url(assets, archive_name)
        if sha_url:
            try:
                req = urllib.request.Request(
                    sha_url,
                    headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"},
                )
                with urllib.request.urlopen(req, timeout=10) as resp:
                    sha_content = resp.read().decode("utf-8")
                sha_map = _parse_sha256_file(sha_content)
                bare = archive_name.lstrip("./")
                expected_sha = (
                    sha_map.get(archive_name)
                    or sha_map.get(bare)
                    or sha_map.get(f"./{archive_name}")
                    or sha_map.get(f"*{archive_name}")
                )
            except Exception:
                pass

        if not expected_sha:
            raise ValueError(f"No expected SHA-256 checksum found for {archive_name}")

        _download_and_extract_binary(
            download_url, expected_sha, dest_path, cache_dir
        )

        if os.path.isfile(dest_path):
            return True, version_str

        return False, None
    except Exception:
        return False, None


def _install_python_via_uv(uv_bin: str, data_dir: str) -> bool:
    try:
        subprocess.run(
            [uv_bin, "python", "install"],
            check=True,
            timeout=120,
            capture_output=True,
        )
        return True
    except Exception:
        return False


def _create_venv_via_uv(uv_bin: str, data_dir: str) -> bool:
    venv_path = os.path.join(data_dir, "pyvenv")
    try:
        subprocess.run(
            [uv_bin, "venv", venv_path, "--python", "3.11"],
            check=True,
            timeout=30,
            capture_output=True,
        )
        return True
    except Exception:
        return False


def _install_yt_dlp_via_uv(uv_bin: str, data_dir: str) -> bool:
    engine_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    req_path = os.path.join(engine_dir, "requirements.txt")
    if not os.path.isfile(req_path):
        req_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "requirements.txt")
    if not os.path.isfile(req_path):
        return False
    try:
        subprocess.run(
            [uv_bin, "pip", "install", "-r", req_path],
            check=True,
            timeout=120,
            capture_output=True,
        )
        return True
    except Exception:
        return False


def _detect_js_runtime() -> dict:
    from grablytic_engine.po_token import detect_js_runtime as _pot_detect
    return _pot_detect()


def bootstrap() -> dict:
    if not is_initialized():
        return {
            "success": False,
            "error_type": "ERROR_BOOTSTRAP_FAILED",
            "error_message": "paths/set not called before bootstrap",
        }

    paths = get_paths()
    data_dir = paths["data_dir"]
    cache_dir = paths["cache_dir"]
    platform_key = _get_platform_key()
    is_android = _is_android_app()

    bin_dir = os.path.join(data_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    if os.name != "nt":
        os.chmod(bin_dir, 0o700)

    js_runtime_info = _detect_js_runtime()

    update_components = []

    # 1. uv bootstrap (desktop only)
    uv_ok = False
    if not is_android:
        is_windows = os.name == "nt"
        uv_name = "uv.exe" if is_windows else "uv"
        uv_path = os.path.join(bin_dir, uv_name)

        log.info("Bootstrap uv: downloading")
        uv_ok, _ = _bootstrap_github_binary(
            "uv",
            GITHUB_REPOS["uv"],
            _get_asset_substring("uv", platform_key),
            uv_path,
            cache_dir,
        )
        log.info(f"Bootstrap uv: {'completed' if uv_ok else 'failed'}")

        if uv_ok:
            log.info("Bootstrap python: installing")
            python_ok = _install_python_via_uv(uv_path, data_dir)
            log.info(f"Bootstrap python: {'completed' if python_ok else 'failed'}")

            log.info("Bootstrap venv: creating")
            venv_ok = _create_venv_via_uv(uv_path, data_dir)
            log.info(f"Bootstrap venv: {'completed' if venv_ok else 'failed'}")

            log.info("Bootstrap yt-dlp: installing")
            ytdlp_ok = _install_yt_dlp_via_uv(uv_path, data_dir)
            log.info(f"Bootstrap yt-dlp: {'completed' if ytdlp_ok else 'failed'}")

    # 2. Download ffmpeg, aria2c (all platforms) + deno (desktop) in parallel.
    # On Android every download is skipped inside _bootstrap_github_binary:
    # bundled jniLibs binaries are the only executable files on targetSdk > 28,
    # so the resolved-path fallback below is the source of truth there.
    binary_tasks = [
        (
            "ffmpeg",
            GITHUB_REPOS["ffmpeg"],
            _get_asset_substring("ffmpeg", platform_key),
            paths.get("ffmpeg_path"),
        ),
        (
            "aria2c",
            GITHUB_REPOS["aria2c"],
            _get_asset_substring("aria2c", platform_key),
            paths.get("aria2c_path"),
        ),
    ]
    binary_tasks.append(
        (
            "deno",
            GITHUB_REPOS["deno"],
            _get_asset_substring("deno", platform_key),
            paths.get("deno_path"),
        )
    )

    binary_results = {}
    threads = []
    lock = threading.Lock()

    def _worker(name, repo, substring, dest):
        ok, ver = _bootstrap_github_binary(
            name, repo, substring, dest, cache_dir
        )
        with lock:
            binary_results[name] = (ok, ver)

    log.info("Bootstrap binaries: downloading")
    for name, repo, substring, dest in binary_tasks:
        log.info(f"Downloading {name} from {repo}")
        if substring and dest:
            t = threading.Thread(
                target=_worker, args=(name, repo, substring, dest), daemon=True
            )
            t.start()
            threads.append(t)

    for t in threads:
        t.join()
    log.info("Bootstrap binaries: completed")

    ffmpeg_ok, ffmpeg_version = binary_results.get("ffmpeg", (False, None))
    aria2c_ok, aria2c_version = binary_results.get("aria2c", (False, None))
    deno_ok, deno_version = binary_results.get("deno", (False, None))

    # Also check resolved paths from set_paths (bundled jniLibs .so files on
    # Android, system binaries elsewhere). Versions are probed live since
    # bundled binaries carry no release tag. Probe REPORTS (not just
    # versions) are kept: when a bundled binary refuses to run on-device,
    # the returncode/output below is the entire diagnosis.
    probe_reports: dict[str, dict] = {}

    def _probe_if_needed(name: str, path: str | None) -> tuple[bool, str | None]:
        if not path or not os.path.isfile(path):
            return False, None
        if name in probe_reports:
            rep = probe_reports[name]
        else:
            rep = _probe_report(path)
            probe_reports[name] = rep
            if not rep["ok"]:
                log.warn(
                    f"Probe {name} ({path}) failed "
                    f"rc={rep['returncode']}: {rep['output']}"
                )
        return rep["ok"], rep["version"]

    def _eval_binary(
        name: str,
        path: str | None,
        current_ok: bool,
        current_ver: str | None,
    ) -> tuple[bool, str | None]:
        if not path or not os.path.isfile(path) or not os.access(path, os.X_OK):
            return False, None
        # Always probe live: file presence does not guarantee dynamic linker
        # resolution or ABI compatibility. Fail closed on probe failure.
        probe_ok, probe_ver = _probe_if_needed(name, path)
        if not probe_ok:
            return False, None
        return True, probe_ver or current_ver

    ffmpeg_ok, ffmpeg_version = _eval_binary(
        "ffmpeg", paths.get("ffmpeg_path"), ffmpeg_ok, ffmpeg_version
    )
    aria2c_ok, aria2c_version = _eval_binary(
        "aria2c", paths.get("aria2c_path"), aria2c_ok, aria2c_version
    )
    deno_ok, deno_version = _eval_binary(
        "deno", paths.get("deno_path"), deno_ok, deno_version
    )
    node_ok, node_version = _eval_binary(
        "node", paths.get("nodejs_path"), False, None
    )

    # One line proving the child-process environment yt-dlp will inherit.
    # If a bundled .so later fails to spawn, compare: missing/wrong
    # LD_LIBRARY_PATH here means the usr/lib tree never arrived.
    log.info(
        f"Exec env: LD_LIBRARY_PATH={os.environ.get('LD_LIBRARY_PATH')} "
        f"ffmpeg_ld_path={paths.get('ffmpeg_ld_path')}"
    )
    # Disk snapshot: ENOSPC is a top-3 download failure cause and is
    # otherwise invisible until a write fails mid-transfer.
    for label, d in (("data", data_dir), ("cache", cache_dir),
                     ("output", paths.get("output_dir") or data_dir)):
        try:
            usage = shutil.disk_usage(d)
            log.info(
                f"Disk {label} ({d}): "
                f"{usage.free // (1024 * 1024)}MB free of "
                f"{usage.total // (1024 * 1024)}MB"
            )
        except Exception:
            pass

    # QuickJS availability (Android JS runtime)
    quickjs_ok = False
    if is_android:
        try:
            import quickjs  # type: ignore[import-untyped]
            quickjs_ok = True
        except ImportError:
            pass

    if not ffmpeg_ok:
        update_components.append("ffmpeg")
    if not deno_ok and not is_android:
        update_components.append("deno")

    yt_dlp_ver = _get_yt_dlp_version()
    js_name = js_runtime_info["name"]
    js_ver = js_runtime_info["version"]

    if deno_ok and deno_version:
        js_runtime = "deno"
        js_runtime_version = deno_version
    elif is_android and node_ok:
        # Android prefers the bundled Node (Deno's shared-lib deps don't
        # ship); version may still be None when only presence is known.
        js_runtime = "node"
        js_runtime_version = node_version
    else:
        js_runtime = js_name
        js_runtime_version = js_ver

    # Stronger installed-state mechanism (SEC sweep): per-binary records
    # with provenance instead of scattered booleans. Sources are inferred
    # locally — no IPC change: `.so` executables only exist as bundled
    # jniLibs; data_dir/bin holds our downloads; a shutil.which match means
    # system. Additive: legacy keys below are untouched.
    def _source(name: str, ok: bool, path: str | None) -> str:
        if not ok or not path:
            if name == "aria2c" and is_android:
                return "unsupported"
            return "missing"
        if path.endswith(".so"):
            return "bundled"
        bin_dir = os.path.join(data_dir, "bin")
        if path == bin_dir or path.startswith(bin_dir + os.sep):
            return "downloaded"
        try:
            if shutil.which(os.path.basename(path)) == path:
                return "system"
        except Exception:
            pass
        return "resolved"

    def _probe_detail(name: str, path: str | None) -> str | None:
        """Path plus failed-probe diagnostics (the on-device exec verdict)."""
        rep = probe_reports.get(name)
        if rep is not None and not rep["ok"]:
            return (f"{path} :: probe rc={rep['returncode']}: "
                    f"{rep['output'][:160]}")
        return path

    binaries = [
        {
            "name": "yt-dlp",
            "ok": yt_dlp_ver != "unknown",
            "source": "runtime",
            "version": yt_dlp_ver,
            "detail": "Python package",
        },
        {
            "name": "ffmpeg",
            "ok": ffmpeg_ok,
            "source": _source("ffmpeg", ffmpeg_ok, paths.get("ffmpeg_path")),
            "version": ffmpeg_version,
            "detail": _probe_detail("ffmpeg", paths.get("ffmpeg_path")),
        },
        {
            "name": "aria2c",
            "ok": aria2c_ok,
            "source": _source("aria2c", aria2c_ok, paths.get("aria2c_path")),
            "version": aria2c_version,
            "detail": (
                "No Android distribution channel; the native downloader "
                "handles all traffic"
                if (not aria2c_ok and is_android)
                else paths.get("aria2c_path")
            ),
        },
        {
            "name": "quickjs",
            "ok": quickjs_ok,
            "source": "runtime" if quickjs_ok else "missing",
            "version": None,
            "detail": (
                "python-quickjs binding"
                if quickjs_ok
                else ("No Chaquopy wheel on Android; Deno is primary"
                      if is_android else "pip install python-quickjs")
            ),
        },
        {
            "name": "deno",
            "ok": deno_ok,
            "source": _source("deno", deno_ok, paths.get("deno_path")),
            "version": deno_version,
            "detail": _probe_detail("deno", paths.get("deno_path")),
        },
        {
            "name": "node",
            "ok": node_ok,
            "source": _source("node", node_ok, paths.get("nodejs_path")),
            "version": node_version,
            "detail": _probe_detail("node", paths.get("nodejs_path")),
        },
    ]

    # SEC-05 (partial): advisory floor — yt-dlp below the EJS generation is
    # known-vulnerable (e.g. CVE-2024-38519 class <2024.07.01). Advisory
    # only (never blocking): the UI banners it, the user updates.
    yt_dlp_outdated = _is_version_below(yt_dlp_ver, "2025.11.12")

    log.info(
        f"Bootstrap completed — ffmpeg={'ok' if ffmpeg_ok else 'fail'} "
        f"aria2c={'ok' if aria2c_ok else 'fail'} "
        f"deno={'ok' if deno_ok else 'fail'} "
        f"quickjs={'ok' if quickjs_ok else 'fail'} "
        f"update_needed={len(update_components) > 0}"
    )

    return {
        "success": True,
        "yt_dlp_version": yt_dlp_ver,
        "yt_dlp_outdated": yt_dlp_outdated,
        "ffmpeg_ok": ffmpeg_ok,
        "ffmpeg_version": ffmpeg_version,
        "aria2c_ok": aria2c_ok,
        "aria2c_version": aria2c_version,
        "deno_ok": deno_ok,
        "deno_version": deno_version,
        "node_ok": node_ok,
        "node_version": node_version,
        "quickjs_ok": quickjs_ok,
        "js_runtime": js_runtime,
        "js_runtime_version": js_runtime_version,
        "needs_update": len(update_components) > 0,
        "update_components": update_components,
        "binaries": binaries,
        "contract_version": "1.0",
    }


def update_check() -> dict:
    if not is_initialized():
        return {
            "success": False,
            "error_type": "ERROR_BOOTSTRAP_FAILED",
            "error_message": "paths/set not called before update_check",
        }

    paths = get_paths()
    platform_key = _get_platform_key()
    is_android = _is_android_app()

    yt_dlp_current = _get_yt_dlp_version()
    binaries_status = []
    updates_queued = []

    check_targets = [
        ("ffmpeg", GITHUB_REPOS["ffmpeg"],
         _get_asset_substring("ffmpeg", platform_key),
         paths.get("ffmpeg_path")),
    ]
    if not is_android:
        check_targets.append(("deno", GITHUB_REPOS["deno"],
                              _get_asset_substring("deno", platform_key),
                              paths.get("deno_path")))

    for name, repo, asset_sub, bin_path in check_targets:
        current_sha = ""
        if bin_path and os.path.exists(bin_path):
            current_sha = _calculate_sha256(bin_path)

        latest_sha = ""
        update_available = False
        try:
            release = _resolve_latest_release(repo)
            assets = release.get("assets", [])
            download_url = _find_asset(assets, asset_sub)
            if download_url:
                archive_name = download_url.split("/")[-1].split("?")[0]
                sha_url = _find_checksum_url(assets, archive_name)
                if sha_url:
                    req = urllib.request.Request(
                        sha_url,
                        headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"},
                    )
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        sha_content = resp.read().decode("utf-8")
                    sha_map = _parse_sha256_file(sha_content)
                    latest_sha = sha_map.get(archive_name, "") or sha_map.get(
                        f"./{archive_name}", ""
                    ) or sha_map.get(f"*{archive_name}", "")
        except Exception:
            pass

        if current_sha and latest_sha and current_sha != latest_sha:
            update_available = True

        binaries_status.append({
            "name": name,
            "current_sha256": current_sha,
            "manifest_sha256": latest_sha,
            "update_available": update_available,
        })
        if update_available:
            updates_queued.append(name)

    return {
        "success": True,
        "checked_at": int(time.time()),
        "yt_dlp_current": yt_dlp_current,
        "yt_dlp_latest": yt_dlp_current,
        "yt_dlp_update_available": False,
        "binaries": binaries_status,
        "updates_queued": updates_queued,
    }
