"""Hash pin for the one third-party package the engine executes.

#18: `yt-dlp` was pinned to a VERSION but not to a HASH. A version pin
answers "which upstream release did we test"; it does not answer "is this
byte-for-byte that release". A compromised PyPI account, a hijacked
mirror, or a TLS-terminating proxy can serve a different wheel under the
same version number, and `uv pip install -r requirements.txt` would
install it — inside the same process that holds the user's cookies,
proxy credentials and download URLs.

So the wheel is fetched by this module, hashed, and only then handed to
uv. The digest is the trust anchor, not the version string.

The constant is kept in step with:
  * `engine/requirements.txt` (desktop pin),
  * `android/app/build.gradle.kts` (Chaquopy pin),
  * `EngineContract.ytDlpVersion` (host-side pin).

`test_wheel_pin.py` fails if they drift apart.
"""

from __future__ import annotations

import hashlib
import json
import os
import urllib.request

#: The release the engine is built and tested against.
PINNED_VERSION = "2026.8.19"

#: The exact artefact we accept (`py3-none-any` — there is one wheel for
#: every platform, which is why an sdist is never installed).
PINNED_WHEEL = "yt_dlp-2026.8.19-py3-none-any.whl"

#: SHA-256 of that wheel, from the PyPI JSON API at pin time.
PINNED_SHA256 = "1d57897e94c6665a0a6f9bc54b34e584284e32c034ffab3a7df25d8f7b24eedf"

PYPI_JSON_URL = "https://pypi.org/pypi/yt-dlp/{version}/json"

CHUNK = 1 << 20


def requirement_line() -> str:
    """The hashed requirement, as it would appear in a requirements file."""
    return f"yt-dlp=={PINNED_VERSION} --hash=sha256:{PINNED_SHA256}"


def sha256_of(path: str) -> str:
    """Digest of a file, streamed so a large wheel never sits in RAM."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_wheel(path: str) -> bool:
    """True only for the exact pinned artefact.

    A missing file is a failure, not an exception: callers treat "not the
    pinned bytes" and "not there" the same way, and an install must never
    proceed on either.
    """
    try:
        return sha256_of(path) == PINNED_SHA256
    except OSError:
        return False


def wheel_url(timeout: float = 15.0) -> str | None:
    """Resolve the pinned wheel's download URL from the PyPI JSON API.

    The URL is read from the same response that carries the digest, so a
    mirror that lies about the URL is caught by `verify_wheel` rather
    than trusted.
    """
    request = urllib.request.Request(
        PYPI_JSON_URL.format(version=PINNED_VERSION),
        headers={"Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
        payload = json.load(response)
    for item in payload.get("urls", []):
        if item.get("filename") == PINNED_WHEEL:
            url = item.get("url")
            return url if isinstance(url, str) else None
    return None


def download_verified_wheel(dest_dir: str, timeout: float = 60.0) -> str | None:
    """Fetch the pinned wheel into `dest_dir`, or return None.

    Returns the local path only when the bytes hash to `PINNED_SHA256`.
    A mismatch deletes the download and returns None: there is no path
    from here to "install it anyway".
    """
    url = wheel_url(timeout=min(timeout, 30.0))
    if not url:
        return None
    os.makedirs(dest_dir, exist_ok=True)
    target = os.path.join(dest_dir, PINNED_WHEEL)
    partial = f"{target}.part"
    request = urllib.request.Request(url, headers={"User-Agent": "Grablytic"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310
            with open(partial, "wb") as out:
                for chunk in iter(lambda: response.read(CHUNK), b""):
                    out.write(chunk)
        if not verify_wheel(partial):
            try:
                os.remove(partial)
            except OSError:
                pass
            return None
        os.replace(partial, target)
        return target
    except Exception:
        try:
            os.remove(partial)
        except OSError:
            pass
        return None
