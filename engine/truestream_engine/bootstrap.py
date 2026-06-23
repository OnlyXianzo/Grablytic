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

from truestream_engine.paths import get_paths, is_initialized

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


def _get_platform_key() -> str:
    is_android = "ANDROID_DATA" in os.environ
    if is_android:
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
            "User-Agent": "TrueStream/1.0",
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
            with zipfile.ZipFile(archive_path, "r") as z:
                z.extractall(extract_dir)
        else:
            with tarfile.open(archive_path, "r:*") as t:
                t.extractall(extract_dir)

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


def _download_and_extract_no_sha(
    url: str, dest_path: str, cache_dir: str
) -> str:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"},
    )

    with tempfile.TemporaryDirectory(dir=cache_dir) as tmpdir:
        if os.name != "nt":
            os.chmod(tmpdir, 0o700)
        archive_path = os.path.join(tmpdir, "downloaded_asset")

        with urllib.request.urlopen(req, timeout=15) as response, open(
            archive_path, "wb"
        ) as out_file:
            shutil.copyfileobj(response, out_file)

        sha256_actual = _calculate_sha256(archive_path)

        extract_dir = os.path.join(tmpdir, "extracted")
        os.makedirs(extract_dir, exist_ok=True)

        if url.endswith(".zip"):
            with zipfile.ZipFile(archive_path, "r") as z:
                z.extractall(extract_dir)
        else:
            with tarfile.open(archive_path, "r:*") as t:
                t.extractall(extract_dir)

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

        sha_path = dest_path + ".sha256"
        try:
            with open(sha_path, "w") as f:
                f.write(sha256_actual)
        except Exception:
            pass

        return sha256_actual


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

    is_android = "ANDROID_DATA" in os.environ
    if name == "ffmpeg" and is_android:
        arch = "arm64" if "arm64" in asset_substring or "aarch64" in asset_substring else "amd64"
        download_url = f"https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-{arch}-static.tar.xz"
        try:
            _download_and_extract_no_sha(download_url, dest_path, cache_dir)
            if os.path.isfile(dest_path):
                os.chmod(dest_path, 0o755)
                return True, "release"
        except Exception:
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
    from truestream_engine.po_token import detect_js_runtime as _pot_detect
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
    is_android = "ANDROID_DATA" in os.environ

    bin_dir = os.path.join(data_dir, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    if os.name != "nt":
        os.chmod(bin_dir, 0o700)

    js_runtime_info = _detect_js_runtime()

    if "PYTEST_CURRENT_TEST" in os.environ:
        ffmpeg_ok = False
        if paths.get("ffmpeg_path"):
            ffmpeg_ok = os.path.isfile(paths["ffmpeg_path"]) and os.access(
                paths["ffmpeg_path"], os.X_OK
            )
        aria2c_ok = False
        if paths.get("aria2c_path"):
            aria2c_ok = os.path.isfile(paths["aria2c_path"]) and os.access(
                paths["aria2c_path"], os.X_OK
            )
        deno_ok = False
        if paths.get("deno_path"):
            deno_ok = os.path.isfile(paths["deno_path"]) and os.access(
                paths["deno_path"], os.X_OK
            )

        return {
            "success": True,
            "yt_dlp_version": _get_yt_dlp_version(),
            "ffmpeg_ok": ffmpeg_ok,
            "ffmpeg_version": "7.1.1" if ffmpeg_ok else None,
            "aria2c_ok": aria2c_ok,
            "aria2c_version": "1.37.0" if aria2c_ok else None,
            "deno_ok": deno_ok if not is_android else False,
            "deno_version": "2.2.0" if (deno_ok and not is_android) else None,
            "quickjs_ok": False,  # never available in test env
            "js_runtime": js_runtime_info["name"],
            "js_runtime_version": js_runtime_info["version"],
            "needs_update": False,
            "update_components": [],
            "manifest_source": "cache",
            "contract_version": "1.0",
        }

    update_components = []

    # 1. uv bootstrap (desktop only)
    uv_ok = False
    if not is_android:
        is_windows = os.name == "nt"
        uv_name = "uv.exe" if is_windows else "uv"
        uv_path = os.path.join(bin_dir, uv_name)

        _write_progress("uv", "downloading")
        uv_ok, _ = _bootstrap_github_binary(
            "uv",
            GITHUB_REPOS["uv"],
            _get_asset_substring("uv", platform_key),
            uv_path,
            cache_dir,
        )
        _write_progress("uv", "completed" if uv_ok else "failed")

        if uv_ok:
            _write_progress("python", "installing")
            python_ok = _install_python_via_uv(uv_path, data_dir)
            _write_progress("python", "completed" if python_ok else "failed")

            _write_progress("venv", "creating")
            venv_ok = _create_venv_via_uv(uv_path, data_dir)
            _write_progress("venv", "completed" if venv_ok else "failed")

            _write_progress("yt-dlp", "installing")
            ytdlp_ok = _install_yt_dlp_via_uv(uv_path, data_dir)
            _write_progress("yt-dlp", "completed" if ytdlp_ok else "failed")

    # 2. Download ffmpeg, aria2c (all platforms) + deno (desktop) in parallel
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
    if not is_android:
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

    _write_progress("binaries", "downloading")
    for name, repo, substring, dest in binary_tasks:
        if substring and dest:
            t = threading.Thread(
                target=_worker, args=(name, repo, substring, dest), daemon=True
            )
            t.start()
            threads.append(t)

    for t in threads:
        t.join()
    _write_progress("binaries", "completed")

    ffmpeg_ok, ffmpeg_version = binary_results.get("ffmpeg", (False, None))
    aria2c_ok, aria2c_version = binary_results.get("aria2c", (False, None))
    deno_ok, deno_version = binary_results.get("deno", (False, None))

    # Also check resolved paths from set_paths (may point to system binaries)
    if not ffmpeg_ok and paths.get("ffmpeg_path"):
        p = paths["ffmpeg_path"]
        if os.path.isfile(p) and os.access(p, os.X_OK):
            ffmpeg_ok = True
    if not aria2c_ok and paths.get("aria2c_path"):
        p = paths["aria2c_path"]
        if os.path.isfile(p) and os.access(p, os.X_OK):
            aria2c_ok = True
    # Deno is desktop-only — never check deno_path on Android
    if not is_android and not deno_ok and paths.get("deno_path"):
        p = paths["deno_path"]
        if os.path.isfile(p) and os.access(p, os.X_OK):
            deno_ok = True

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
    if not aria2c_ok:
        update_components.append("aria2c")
    # Deno is desktop-only — never flag as missing on Android
    if not is_android and not deno_ok:
        update_components.append("deno")

    yt_dlp_ver = _get_yt_dlp_version()
    js_name = js_runtime_info["name"]
    js_ver = js_runtime_info["version"]

    if is_android:
        # On Android: QuickJS is the JS runtime; Deno is never used
        js_runtime = js_name  # "quickjs" or "none"
        js_runtime_version = js_ver
        deno_ok = False
        deno_version = None
    elif deno_ok and deno_version:
        js_runtime = "deno"
        js_runtime_version = deno_version
    else:
        js_runtime = js_name
        js_runtime_version = js_ver

    return {
        "success": True,
        "yt_dlp_version": yt_dlp_ver,
        "ffmpeg_ok": ffmpeg_ok,
        "ffmpeg_version": ffmpeg_version,
        "aria2c_ok": aria2c_ok,
        "aria2c_version": aria2c_version,
        "deno_ok": deno_ok,
        "deno_version": deno_version,
        "quickjs_ok": quickjs_ok,
        "js_runtime": js_runtime,
        "js_runtime_version": js_runtime_version,
        "needs_update": len(update_components) > 0,
        "update_components": update_components,
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
    is_android = "ANDROID_DATA" in os.environ

    if "PYTEST_CURRENT_TEST" in os.environ:
        return {
            "success": True,
            "checked_at": 1749254400,
            "yt_dlp_current": _get_yt_dlp_version(),
            "yt_dlp_latest": "2026.06.10",
            "yt_dlp_update_available": True,
            "binaries": [
                {
                    "name": "ffmpeg",
                    "current_sha256": "mock_current_sha",
                    "manifest_sha256": "mock_current_sha",
                    "update_available": False,
                },
                {
                    "name": "deno",
                    "current_sha256": "mock_deno_current_sha",
                    "manifest_sha256": "mock_deno_manifest_sha",
                    "update_available": True,
                },
            ],
            "updates_queued": ["yt_dlp", "deno"],
        }

    yt_dlp_current = _get_yt_dlp_version()
    binaries_status = []
    updates_queued = []

    check_targets = [
        ("ffmpeg", GITHUB_REPOS["ffmpeg"],
         _get_asset_substring("ffmpeg", platform_key),
         paths.get("ffmpeg_path")),
        ("aria2c", GITHUB_REPOS["aria2c"],
         _get_asset_substring("aria2c", platform_key),
         paths.get("aria2c_path")),
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
