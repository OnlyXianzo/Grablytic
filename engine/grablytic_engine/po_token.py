"""PO-Token helpers + JS execution trust boundary (read before extending).

What IS gated here: the two local stub scripts below (`verify_js_code`
SHA-256 allowlist). Both stubs are inert by design — they return null and
the download falls back to no token. The gate proves "this exact stub ran",
nothing more.

What is NOT gated here (HQ5 answer): the real YouTube challenge solver.
Whenever `_configure_js_runtime` selects a runtime it also sets
`remote_components=["ejs:github"]`, so yt-dlp fetches the EJS solver bundle
(LIB+CORE) from github.com/yt-dlp/ejs releases and executes it (plus
YouTube-player JS as input data) in deno/node. That code NEVER passes
through `verify_js_code`. Its integrity gate is yt-dlp's OWN check in
`yt_dlp/extractor/youtube/jsc/_builtin/ejs.py`: pinned SCRIPT_VERSION plus
a SHA3-512 hash pin per script variant (cache purged on mismatch), with
deliberate dev-only bypasses (`youtube-ejs:dev/repo/script_version`
extractor args — we never set those). Deno runs the solver with no
`--allow-*` flags (default-deny); Node's permission model is explicitly NOT
a security boundary for malicious code (nodejs.org/api/permissions).

Do NOT cite this module's allowlist as covering the EJS path (that was the
T0-6 "theater" finding). Follow-ups, not this push: preferring a vendored
`yt-dlp-ejs` package over the network fetch; auditing `youtube-ejs` arg
reachability through our extractor-args plumbing.
"""

import os
import shutil
import hashlib

from grablytic_engine.logger import get_logger


log = get_logger("grablytic_engine.po_token")

# SHA-256 allowlist of the two inert local stub scripts (NOT the EJS solver).
QUICKJS_STUB_SCRIPT = """
            // PO Token generation — YouTube's PoToken.generate()
            // This requires the actual YouTube challenge script loaded at runtime
            // For the stub: return None and fall back to android client
            null
        """

DENO_STUB_SCRIPT = """
        const url = Deno.args[0];
        // PO Token generation stub — returns null, falls back to no token
        console.log(JSON.stringify({ token: null }));
        """

APPROVED_JS_HASHES = {
    hashlib.sha256(QUICKJS_STUB_SCRIPT.encode("utf-8")).hexdigest(),
    hashlib.sha256(DENO_STUB_SCRIPT.encode("utf-8")).hexdigest(),
}

# Item 4 (phantom PO-token) gate: both allowlisted stubs above are inert by
# design — they can only ever yield None. Spawning `deno eval` (a full
# subprocess, up to 10s timeout) on every YouTube download to compute a
# guaranteed-None token is pure latency/battery waste, so generation
# fast-paths to None until a REAL solver lands. Landing one means: add its
# script to APPROVED_JS_HASHES, implement it below, and flip this flag.
# The spawn machinery is gated, not deleted. Callers already fall back to
# a user-supplied `paths["po_token"]` when this returns None.
PO_TOKEN_SOLVER_ENABLED = False


def verify_js_code(code: str) -> None:
    """Allowlist check for the two local stub scripts ONLY.

    Raises ValueError unless `code` is byte-identical to an approved stub.
    This says nothing about the EJS remote solver (see module docstring).
    """
    code_hash = hashlib.sha256(code.encode("utf-8")).hexdigest()
    if code_hash not in APPROVED_JS_HASHES:
        raise ValueError("Security Violation: Attempted evaluation of untrusted JavaScript code.")


def detect_js_runtime() -> dict:
    """Detect available JS runtime. Returns {'name': str, 'version': str | None}."""
    # 1. QuickJS (python-quickjs binding — preferred on Android)
    try:
        import quickjs  # type: ignore[import-untyped]
        return {"name": "quickjs", "version": getattr(quickjs, "__version__", "0.8.0")}
    except ImportError:
        pass

    # 2. Deno (preferred — check paths module first, then env/PATH)
    deno_path = None
    try:
        from grablytic_engine.paths import get_paths
        deno_path = get_paths().get("deno_path")
    except Exception:
        pass
    if not deno_path:
        deno_path = os.environ.get("DENO_PATH") or shutil.which("deno")
    if deno_path:
        import subprocess
        try:
            res = subprocess.run(
                [deno_path, "--version"], capture_output=True, text=True, timeout=2
            )
            if res.returncode == 0:
                ver = res.stdout.splitlines()[0].replace("deno", "").strip()
                return {"name": "deno", "version": ver}
        except Exception:
            return {"name": "deno", "version": "unknown"}
        return {"name": "deno", "version": "unknown"}

    return {"name": "none", "version": None}


def js_runtime_available() -> bool:
    """Check whether a JS runtime that can handle YouTube nsig challenges is available."""
    runtime = detect_js_runtime()
    return runtime["name"] in ("quickjs", "deno")


def generate_po_token(url: str) -> str | None:
    # Item 4 fast-path: no real solver configured — return None WITHOUT
    # probing for a runtime (detect_js_runtime itself can spawn
    # `deno --version`) and WITHOUT spawning `deno eval`.
    if not PO_TOKEN_SOLVER_ENABLED:
        return None
    runtime = detect_js_runtime()
    name = runtime["name"]

    if name == "quickjs":
        return _generate_with_quickjs(url)
    if name == "deno":
        return _generate_with_deno(url)
    return None


def _generate_with_quickjs(url: str) -> str | None:
    """Generate PO Token via python-quickjs binding."""
    # Item 4 fast-path: the allowlisted stub is inert (always None).
    if not PO_TOKEN_SOLVER_ENABLED:
        return None
    try:
        import quickjs  # type: ignore[import-untyped]
        ctx = quickjs.Context()
        verify_js_code(QUICKJS_STUB_SCRIPT)
        result = ctx.eval(QUICKJS_STUB_SCRIPT)
        return str(result) if result else None
    except Exception:
        return None


def _generate_with_deno(url: str) -> str | None:
    """Generate PO Token via Deno subprocess."""
    # Item 4 fast-path: the allowlisted stub is inert (always None) — skip
    # the `deno eval` spawn entirely. The machinery below stays intact for
    # a future real solver (see PO_TOKEN_SOLVER_ENABLED).
    if not PO_TOKEN_SOLVER_ENABLED:
        return None
    # NOTE: intentionally plain `deno eval` with no permission flags.
    # `--no-read/--no-write/--no-env` are not valid Deno flags (negation is
    # `--deny-*`, and `deno eval` runs with implicit full permissions by
    # design) — passing them would only break flag parsing. yt-dlp itself
    # invokes `deno run -`, never `deno eval`; this harness executes our own
    # allowlisted stub only.
    from grablytic_engine.paths import get_paths
    deno_path = (
        get_paths().get("deno_path")
        or os.environ.get("DENO_PATH")
        or shutil.which("deno")
    )
    if not deno_path or not os.path.isfile(deno_path):
        return None
    try:
        import subprocess, json
        verify_js_code(DENO_STUB_SCRIPT)
        res = subprocess.run(
            [deno_path, "eval", DENO_STUB_SCRIPT, "--", url],
            capture_output=True, text=True, timeout=10,
        )
        if res.returncode == 0 and res.stdout.strip():
            data = json.loads(res.stdout.strip())
            return data.get("token")
    except Exception as exc:
        log.warn(f"Deno PO token generation failed: {exc}")
        return None
    return None
