"""Automated GitHub Issue notifier (Python side, STEP 3C).

Stdlib only (urllib / json / os / platform) — no new dependencies for the
Chaquopy / desktop bundle.

Behavior:
  1. Flush persistent logs, read the ``server_logs.log`` tail.
  2. Fingerprint the failure (error type + first traceback frame).
  3. ``GET /search/issues`` for an open issue containing the fingerprint —
     return it instead of filing a duplicate (anti-spam).
  4. ``POST /repos/{owner}/{repo}/issues`` with env specs + redacted logs.

Secrets: token comes ONLY from ``GITHUB_TOKEN`` env (or an explicit arg).
Never hardcoded, never logged. Without a token the helpers return a
``manual_needed`` result carrying the formatted body for copy-paste filing.

Auto-filing is gated by ``GRABLYTIC_AUTO_REPORT=1`` — anonymous by default.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

API_BASE = "https://api.github.com"
DEFAULT_REPO = os.environ.get("GITHUB_REPO", "OnlyXianzo/Grablytic")
TOKEN_ENV = "GITHUB_TOKEN"
AUTO_REPORT_ENV = "GRABLYTIC_AUTO_REPORT"


def _token(explicit: str | None = None) -> str | None:
    tok = explicit or os.environ.get(TOKEN_ENV, "")
    tok = (tok or "").strip()
    return tok or None


def fingerprint(title: str, first_frame: str = "") -> str:
    digest = hashlib.sha256(f"{title}\n{first_frame}".encode("utf-8")).hexdigest()
    return digest[:12]


def _api_request(method: str, url: str, token: str,
                 payload: dict | None = None,
                 timeout: int = 15) -> tuple[int, Any]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            status = getattr(resp, "status", 200)
            try:
                return status, json.loads(body) if body else {}
            except json.JSONDecodeError:
                return status, {}
    except urllib.error.HTTPError as e:
        try:
            raw = e.read().decode("utf-8", errors="replace")[:500]
        except Exception:
            raw = ""
        return e.code, {"_http_error": raw}
    except Exception as e:  # network down, DNS, timeout — never crash engine
        return -1, {"_transport_error": repr(e)}


def find_duplicate(fp: str, repo: str = DEFAULT_REPO,
                   token: str | None = None) -> str | None:
    """Return the html_url of an open issue already carrying *fp*, else None."""
    tok = _token(token)
    if not tok:
        return None
    q = urllib.parse.quote(f'repo:{repo} "{fp}" state:open')
    status, data = _api_request("GET", f"{API_BASE}/search/issues?q={q}", tok)
    if status != 200 or not isinstance(data, dict):
        return None
    try:
        if int(data.get("total_count", 0)) <= 0:
            return None
        items = data.get("items") or []
        if not items:
            return None
        return items[0].get("html_url")
    except Exception:
        return None


def create_issue(title: str, body: str, repo: str = DEFAULT_REPO,
                 token: str | None = None,
                 labels: list[str] | None = None) -> str | None:
    """POST a new issue. Returns html_url on 201, else None."""
    tok = _token(token)
    if not tok:
        raise RuntimeError(
            f"{TOKEN_ENV} is not set — refusing to file without a token. "
            "Export GITHUB_TOKEN or file manually."
        )
    status, data = _api_request(
        "POST", f"{API_BASE}/repos/{repo}/issues", tok,
        {"title": title, "body": body,
         "labels": labels or ["bug", "auto-report"]},
        timeout=20,
    )
    if status == 201 and isinstance(data, dict):
        return data.get("html_url")
    return None


def env_specs() -> dict[str, str]:
    try:
        import yt_dlp  # type: ignore
        ytdlp_v = getattr(yt_dlp, "version", "?")
    except Exception:
        ytdlp_v = "not-installed"
    return {
        "python": platform.python_version(),
        "os": f"{platform.system()} {platform.release()} ({platform.machine()})",
        "yt_dlp": str(ytdlp_v),
    }


def build_body(summary: str, *, repro: str = "", expected: str = "",
               actual: str = "", fp: str = "", log_tail: str = "",
               stack: str = "", context: dict | None = None,
               app_version: str = "0.0.1-beta+1") -> str:
    specs = env_specs()
    ctx_lines = "\n".join(f"- `{k}`: `{v}`"
                           for k, v in (context or {}).items()) or "_None._"
    stack_block = f"```\n{stack[:6000]}\n```" if stack else "_None captured._"
    return f"""### Summary
{summary}

### Steps to reproduce
{repro or '_Auto-captured — see stack trace and logs below._'}

### Expected behavior
{expected or 'Engine should not raise.'}

### Actual behavior
{actual or 'Unhandled engine exception.'}

### Platform
- OS: {specs['os']}
- Python: {specs['python']} · yt-dlp: {specs['yt_dlp']}
- App version: {app_version}

### Additional context
{ctx_lines}

### Stack trace
{stack_block}

### Server logs (tail, redacted)
```text
{log_tail[:15000]}
```

---
<!-- fingerprint: {fp} · auto-report: python -->
"""


def notify_exception(exc: BaseException, *, context: dict | None = None,
                     repo: str = DEFAULT_REPO,
                     token: str | None = None,
                     summary: str = "",
                     auto_only: bool = True) -> dict[str, Any]:
    """Full pipeline: flush → tail → dedup → file.

    Returns ``{"status": ..., "url": ..., "fingerprint": ..., "title": ...}``
    where status ∈ created | duplicate | manual_needed | failed | skipped.
    With ``auto_only=True`` (default) filing requires
    ``GRABLYTIC_AUTO_REPORT=1``; otherwise returns ``skipped`` after logging.
    """
    from grablytic_engine.persistent import (
        flush_now, read_log_tail, sanitize, format_traceback,
    )

    try:
        flush_now()
    except Exception:
        pass
    try:
        raw_tail = read_log_tail()
        log_tail = str(sanitize(raw_tail))[:15000]
    except Exception:
        log_tail = "<log tail unavailable>"

    err_str = f"{type(exc).__name__}: {exc}"
    try:
        tb_full = format_traceback(exc)
        first_frame = next(
            (ln.strip() for ln in tb_full.splitlines()
             if ln.strip().startswith("File ")), "")
    except Exception:
        tb_full, first_frame = repr(exc), ""

    short = err_str if len(err_str) <= 120 else err_str[:120] + "…"
    fp = fingerprint(short, first_frame)
    title = f"[Auto-report {fp}] {short}"
    body = build_body(summary or "Automated engine crash report.",
                      actual=f"```\n{err_str}\n{first_frame}\n```",
                      fp=fp, log_tail=log_tail, stack=tb_full,
                      context=context)

    tok = _token(token)
    if auto_only and os.environ.get(AUTO_REPORT_ENV, "") != "1" and token is None:
        return {"status": "skipped", "reason": "auto-report disabled",
                "fingerprint": fp, "title": title, "body": body}
    if not tok:
        return {"status": "manual_needed", "fingerprint": fp,
                "title": title, "body": body}

    dup = find_duplicate(fp, repo=repo, token=tok)
    if dup:
        return {"status": "duplicate", "url": dup,
                "fingerprint": fp, "title": title, "body": body}
    url = None
    try:
        url = create_issue(title, body, repo=repo, token=tok)
    except RuntimeError as e:
        return {"status": "manual_needed", "reason": str(e),
                "fingerprint": fp, "title": title, "body": body}
    if url:
        return {"status": "created", "url": url,
                "fingerprint": fp, "title": title, "body": body}
    return {"status": "failed", "fingerprint": fp, "title": title, "body": body}


def main(argv: list[str]) -> int:
    """Manual trigger: ``python -m grablytic_engine.github_notifier --title "…"``."""
    import argparse
    ap = argparse.ArgumentParser(description="File a Grablytic issue from server logs.")
    ap.add_argument("--title", required=True)
    ap.add_argument("--summary", default="")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    args = ap.parse_args(argv)
    try:
        from grablytic_engine.persistent import read_log_tail, sanitize
        tail = str(sanitize(read_log_tail()))[:15000]
    except Exception as e:
        tail = f"<unavailable: {e}>"
    fp = fingerprint(args.title)
    body = build_body(args.summary or args.title, fp=fp, log_tail=tail)
    tok = _token()
    if not tok:
        print(body)
        print(f"\n[{TOKEN_ENV} not set — body printed for manual filing. fp={fp}]")
        return 2
    dup = find_duplicate(fp, repo=args.repo, token=tok)
    if dup:
        print(f"Duplicate open issue: {dup}")
        return 0
    url = create_issue(args.title, body, repo=args.repo, token=tok)
    if url:
        print(f"Issue created: {url}")
        return 0
    print("Failed to create issue.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
