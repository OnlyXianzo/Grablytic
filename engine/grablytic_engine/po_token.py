"""PO-Token helpers + JS execution trust boundary (read before extending).

What IS gated here: the two local stub scripts below (`verify_js_code`
SHA-256 allowlist). Both stubs are inert by design — they return null and
the download falls back to no token. The gate proves "this exact stub ran",
nothing more.

The local stub allowlist does not cover the real YouTube challenge solver.
Whenever `_configure_js_runtime` selects a runtime it also sets
`remote_components=["ejs:github"]`, so yt-dlp fetches the EJS solver bundle
(LIB+CORE) from github.com/yt-dlp/ejs releases and executes it (plus
YouTube-player JS as input data) in deno/node. That code never passes through
`verify_js_code`. Its integrity gate is yt-dlp's own check in
`yt_dlp/extractor/youtube/jsc/_builtin/ejs.py`: a pinned SCRIPT_VERSION plus
a SHA3-512 hash per script variant (cache purged on mismatch), with
deliberate dev-only bypasses (`youtube-ejs:dev/repo/script_version`
extractor args — not set here). Deno runs the solver with no
`--allow-*` flags (default-deny); Node's permission model is explicitly not
a security boundary for malicious code (nodejs.org/api/permissions).

Vendoring the EJS bundle and auditing `youtube-ejs` extractor-argument
reachability are separate hardening work; the local stub allowlist is not a
substitute for either.
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

# Deno's default-deny flag set, mirroring yt-dlp's own invocation
# (yt_dlp/extractor/youtube/jsc/_builtin/deno.py `_DENO_BASE_OPTIONS`).
# `--no-remote` blocks remote module imports, `--no-config` ignores
# deno.json, `--no-prompt` keeps the runtime non-interactive, and
# `--node-modules-dir=none` stops it from touching node_modules.
_DENO_RUN_FLAGS = (
    "--ext=js",
    "--no-code-cache",
    "--no-prompt",
    "--no-remote",
    "--no-lock",
    "--node-modules-dir=none",
    "--no-config",
)

# Both allowlisted stubs always return None, so running `deno eval` for each
# YouTube download would add latency and battery use without producing a token.
# Generation fast-paths to None until a real solver is explicitly allowlisted
# and enabled. Callers can still fall back to a user-supplied `paths["po_token"]`.
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
    # Fast-path: no real solver configured — return None WITHOUT
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
    # Fast-path: the allowlisted stub is inert (always None).
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
    # Fast-path: the allowlisted stub is inert (always None) — skip
    # the `deno eval` spawn entirely. The machinery below stays intact for
    # a future real solver (see PO_TOKEN_SOLVER_ENABLED).
    if not PO_TOKEN_SOLVER_ENABLED:
        return None
    # `deno eval` runs with ALL permissions enabled by default
    # (docs.deno.com -> runtime/manual/tools/eval). The old comment
    # claimed the opposite, so the harness would have handed a solver
    # script full file / network / env access.
    #
    # `deno run` is DEFAULT-DENY: the script starts with no permissions at
    # all, so no allow-list is needed and a permission bug in Deno's
    # `--deny-*` handling (CVE-2025-48888: a contradictory global allow+deny
    # can let the allow win) cannot help us — we never allow anything.
    # The flag set mirrors yt-dlp's own Deno invocation
    # (yt_dlp/extractor/youtube/jsc/_builtin/deno.py).
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
            # The script is piped on stdin; `--` separates Deno's own
            # flags from the script's arguments.
            [deno_path, "run", *_DENO_RUN_FLAGS, "-", "--", url],
            input=DENO_STUB_SCRIPT,
            capture_output=True, text=True, timeout=10,
        )
        if res.returncode == 0 and res.stdout.strip():
            data = json.loads(res.stdout.strip())
            return data.get("token")
    except Exception as exc:
        log.warn(f"Deno PO token generation failed: {exc}")
        return None
    return None
