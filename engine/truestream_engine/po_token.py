import os
import shutil


def detect_js_runtime() -> dict:
    """Detect available JS runtime. Returns {'name': str, 'version': str | None}."""
    # 1. QuickJS (python-quickjs binding — preferred on Android)
    try:
        import quickjs  # type: ignore[import-untyped]
        return {"name": "quickjs", "version": getattr(quickjs, "__version__", "0.8.0")}
    except ImportError:
        pass

    # 2. Deno (preferred on desktop)
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
    runtime = detect_js_runtime()
    name = runtime["name"]

    if name == "quickjs":
        return _generate_with_quickjs(url)
    if name == "deno":
        return _generate_with_deno(url)
    return None


def _generate_with_quickjs(url: str) -> str | None:
    """Generate PO Token via python-quickjs binding."""
    try:
        import quickjs  # type: ignore[import-untyped]
        ctx = quickjs.Context()
        result = ctx.eval("""
            // PO Token generation — YouTube's PoToken.generate()
            // This requires the actual YouTube challenge script loaded at runtime
            // For the stub: return None and fall back to android client
            null
        """)
        return str(result) if result else None
    except Exception:
        return None


def _generate_with_deno(url: str) -> str | None:
    """Generate PO Token via Deno subprocess."""
    deno_path = os.environ.get("DENO_PATH") or shutil.which("deno")
    if not deno_path:
        return None
    try:
        import subprocess, json
        script = f"""
        const url = {json.dumps(url)};
        // PO Token generation stub — returns null, falls back to no token
        console.log(JSON.stringify({{ token: null }}));
        """
        res = subprocess.run(
            [deno_path, "eval", script],
            capture_output=True, text=True, timeout=10,
        )
        if res.returncode == 0:
            data = json.loads(res.stdout.strip())
            return data.get("token")
    except Exception:
        return None
    return None
