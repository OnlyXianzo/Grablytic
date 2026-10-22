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
import re
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

API_BASE = "https://api.github.com"
DEFAULT_REPO = "OnlyXianzo/Grablytic"
TOKEN_ENV = "GITHUB_TOKEN"
AUTO_REPORT_ENV = "GRABLYTIC_AUTO_REPORT"
# Build-specific report target. GRABLYTIC_REPORT_REPO wins over the
# generic GITHUB_REPO, which wins over the built-in default.
REPORT_REPO_ENV = "GRABLYTIC_REPORT_REPO"
GENERIC_REPO_ENV = "GITHUB_REPO"
# "0" keeps the log tail out of the report entirely.
LOG_TAIL_ENV = "GRABLYTIC_REPORT_LOG_TAIL"

_REDACTED = "***REDACTED***"

# Query-string / assignment parameters whose VALUE is a secret. The
# parameter NAME is kept so the report stays debuggable; the VALUE never
# is.
_SECRET_PARAM_RE = re.compile(
    r"((?:token|sig|lsig|key|auth|password|passwd|secret|proxy|api_key|"
    r"apikey|session|cookie|po_token|signature|credential|jwt|bearer)"
    r"[=:][\x22']?)([^\x22'\s&,}]+)",
    re.IGNORECASE,
)
# scheme://user:password@host
_USERINFO_RE = re.compile(r"([a-zA-Z][a-zA-Z0-9+.-]*://)([^\s/@]+)@")

# Absolute local paths, in the three spellings that reach a log: `C:\Users\…`,
# the doubled form a repr or a JSON blob carries (`C:\\Users\\…`), and the
# forward-slash form. The old pattern consumed only `C:\`, so the rest of the
# path — including the account name — was published in the issue (SEC-001).
# Every repeat is disjoint (a segment cannot contain a separator), so a long run
# of separators cannot backtrack.
_LOCAL_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9])"
    r"(?:"
    r"[A-Za-z]:[\\/]+(?:[^\\/\s<>\"']+[\\/]+)*[^\\/\s<>\"']*"
    r"|/(?:[^/\s<>\"']+/)*[^/\s<>\"']+"
    r")"
)

_unreachable_warning_state = {"emitted": False}
_unreachable_warning_lock = threading.Lock()


def redact_text(value) -> str:
    """Redact secrets from a free-text field before it leaves the device.

    Reports are PUBLIC. An exception message that happens to embed a
    signed URL or a proxy credential must not ship as-is. The parameter
    name survives (``token=***REDACTED***``) so the report is still
    debuggable; the value never does.

    Delegates to the engine's shared scrubber so the notifier and the
    on-disk logger can never drift apart — the notifier used to know
    about ``token=`` and URL userinfo but not about ``Authorization:``
    or ``Cookie:`` headers, which is exactly what yt-dlp puts into
    exception messages.
    """
    if value is None:
        return ""
    try:
        text = value if isinstance(value, str) else str(value)
    except Exception:
        return "[field omitted: safe redaction failed]"
    try:
        from grablytic_engine.persistent import scrub_text

        text = scrub_text(text)
    except Exception:
        # Conservative fallback below is still followed by URL/path removal.
        pass
    text = _SECRET_PARAM_RE.sub(r"\1" + _REDACTED, text)
    text = re.sub(
        r"(?im)^([ \t]*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token)[ \t]*:)[^\r\n]*$",
        r"\1 " + _REDACTED,
        text,
    )
    text = re.sub(
        r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}", r"\1 " + _REDACTED, text
    )

    def _mask_userinfo(m: "re.Match[str]") -> str:
        userinfo = m.group(2)
        if ":" not in userinfo:
            return m.group(0)
        return f"{m.group(1)}{userinfo.split(':', 1)[0]}:{_REDACTED}@"

    text = _USERINFO_RE.sub(_mask_userinfo, text)
    # GitHub issues are public. Even a query-scrubbed URL can expose a private
    # resource identifier, so remove URLs and absolute local paths entirely.
    text = re.sub(r"https?://\S+", "[URL removed]", text, flags=re.IGNORECASE)
    text = _LOCAL_PATH_RE.sub("[local path removed]", text)
    return text


def redact_context(context) -> dict:
    """Redact a context mapping: sensitive KEYS and every VALUE."""
    if not context:
        return {}
    try:
        from grablytic_engine.persistent import sanitize as _sanitize
        from grablytic_engine.persistent import is_sensitive_key
    except Exception:
        _sanitize = None

        def is_sensitive_key(key) -> bool:  # noqa: D103 - conservative fallback
            lk = str(key).lower()
            return any(
                s in lk
                for s in (
                    "cookie",
                    "token",
                    "password",
                    "passwd",
                    "secret",
                    "auth",
                    "proxy",
                    "api_key",
                    "apikey",
                    "session",
                    "po_token",
                )
            )

    out: dict = {}
    try:
        items = list(context.items())
    except Exception:
        return {}
    for k, v in items:
        if is_sensitive_key(k):
            out[k] = _REDACTED
            continue
        if _sanitize is not None:
            try:
                v = _sanitize(v)
            except Exception:
                pass
        # Never pass structured or non-string values through untouched: their
        # repr may contain paths, URLs, or credentials just like free text.
        out[redact_text(k)] = redact_text(v)
    return out


def target_repo(explicit: str | None = None) -> str:
    """Resolve the repository reports are filed against.

    Read at CALL time (not import time) so a build can point the
    notifier at its own fork without patching the source.
    """
    for candidate in (
        explicit,
        os.environ.get(REPORT_REPO_ENV),
        os.environ.get(GENERIC_REPO_ENV),
        DEFAULT_REPO,
    ):
        if candidate and str(candidate).strip():
            return str(candidate).strip()
    return DEFAULT_REPO


def log_tail_enabled() -> bool:
    """The log tail is included by default and dropped on request."""
    return os.environ.get(LOG_TAIL_ENV, "1").strip().lower() not in (
        "0",
        "false",
        "no",
        "off",
    )


def _warn_unreachable_repo(repo: str) -> None:
    """Warn once when the report target cannot be reached."""
    with _unreachable_warning_lock:
        if _unreachable_warning_state["emitted"]:
            return
        _unreachable_warning_state["emitted"] = True
    try:
        from grablytic_engine.logger import get_logger

        get_logger("grablytic_engine.github_notifier").warn(
            f"Cannot reach the report repository {repo!r}; reports will be "
            "dropped. Set GRABLYTIC_REPORT_REPO to a repository this build "
            "can write to."
        )
    except Exception:
        pass


def _token(explicit: str | None = None) -> str | None:
    tok = explicit or os.environ.get(TOKEN_ENV, "")
    tok = (tok or "").strip()
    return tok or None


def fingerprint(title: str, first_frame: str = "") -> str:
    digest = hashlib.sha256(f"{title}\n{first_frame}".encode("utf-8")).hexdigest()
    return digest[:12]


def _api_request(
    method: str, url: str, token: str, payload: dict | None = None, timeout: int = 15
) -> tuple[int, Any]:
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


def find_duplicate(
    fp: str, repo: str | None = None, token: str | None = None
) -> str | None:
    """Return the html_url of an open issue already carrying *fp*, else None."""
    tok = _token(token)
    if not tok:
        return None
    repo = target_repo(repo)
    q = urllib.parse.quote(f'repo:{repo} "{fp}" state:open')
    status, data = _api_request("GET", f"{API_BASE}/search/issues?q={q}", tok)
    if status != 200 or not isinstance(data, dict):
        if status in (404, 403, 401, -1):
            _warn_unreachable_repo(repo)
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


def create_issue(
    title: str,
    body: str,
    repo: str | None = None,
    token: str | None = None,
    labels: list[str] | None = None,
) -> str | None:
    """POST a new issue. Returns html_url on 201, else None."""
    tok = _token(token)
    if not tok:
        raise RuntimeError(
            f"{TOKEN_ENV} is not set — refusing to file without a token. "
            "Export GITHUB_TOKEN or file manually."
        )
    repo = target_repo(repo)
    status, data = _api_request(
        "POST",
        f"{API_BASE}/repos/{repo}/issues",
        tok,
        {
            "title": redact_text(title),
            "body": body,
            "labels": labels or ["bug"],
        },
        timeout=20,
    )
    if status == 201 and isinstance(data, dict):
        return data.get("html_url")
    if status in (404, 403, 401, -1):
        _warn_unreachable_repo(repo)
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


def build_body(
    summary: str,
    *,
    repro: str = "",
    expected: str = "",
    actual: str = "",
    fp: str = "",
    log_tail: str = "",
    stack: str = "",
    context: dict | None = None,
    app_version: str = "0.0.1-beta+1",
) -> str:
    # EVERY free-text field is redacted HERE, at the single point all
    # payloads pass through. A new caller cannot forget to redact.
    specs = env_specs()
    summary = redact_text(summary)
    repro = redact_text(repro)
    expected = redact_text(expected)
    actual = redact_text(actual)
    stack = redact_text(stack)
    log_tail = redact_text(log_tail)
    safe_ctx = redact_context(context)
    ctx_lines = "\n".join(f"- `{k}`: `{v}`" for k, v in safe_ctx.items()) or "_None._"
    stack_block = f"```\n{stack[:6000]}\n```" if stack else "_None captured._"
    tail_block = (
        f"```text\n{log_tail[:15000]}\n```" if log_tail else "_Log tail disabled._"
    )
    return f"""### Summary
{summary}

### Steps to reproduce
{repro or "_Auto-captured — see stack trace and logs below._"}

### Expected behavior
{expected or "Engine should not raise."}

### Actual behavior
{actual or "Unhandled engine exception."}

### Platform
- OS: {specs["os"]}
- Python: {specs["python"]} · yt-dlp: {specs["yt_dlp"]}
- App version: {app_version}

### Additional context
{ctx_lines}

### Stack trace
{stack_block}

### Server logs (tail, redacted)
{tail_block}

---
<!-- fingerprint: {fp} · auto-report: python -->
"""


def _collect_exception_logs():
    from grablytic_engine.persistent import flush_now, read_log_tail, sanitize

    try:
        flush_now()
    except Exception:
        pass
    if not log_tail_enabled():
        return ""
    try:
        return str(sanitize(read_log_tail()))[:15000]
    except Exception:
        return "<log tail unavailable>"


def _exception_traceback(exc: BaseException) -> tuple[str, str]:
    from grablytic_engine.persistent import format_traceback

    try:
        formatted = format_traceback(exc)
        first_frame = next(
            (
                line.strip()
                for line in formatted.splitlines()
                if line.strip().startswith("File ")
            ),
            "",
        )
        return formatted, first_frame
    except Exception:
        return repr(exc), ""


def _build_exception_report(exc, context, summary, log_tail, stack, first_frame):
    error_text = f"{type(exc).__name__}: {exc}"
    short = redact_text(error_text)
    if len(short) > 120:
        short = short[:120] + "…"
    fp = fingerprint(short, first_frame)
    title = f"[Auto-report {fp}] {short}"
    body = build_body(
        summary or "Automated engine crash report.",
        actual=f"```\n{error_text}\n{first_frame}\n```",
        fp=fp,
        log_tail=log_tail,
        stack=stack,
        context=context,
    )
    return fp, title, body


def _report_status(status: str, fp: str, title: str, body: str, **extra):
    return {
        "status": status,
        **extra,
        "fingerprint": fp,
        "title": title,
        "body": body,
    }


def _submit_exception_report(fp, title, body, repo, token):
    duplicate = find_duplicate(fp, repo=repo, token=token)
    if duplicate:
        return {
            "status": "duplicate",
            "url": duplicate,
            "fingerprint": fp,
            "title": title,
            "body": body,
        }
    try:
        url = create_issue(title, body, repo=repo, token=token)
    except RuntimeError as exc:
        return _report_status("manual_needed", fp, title, body, reason=str(exc))
    if url:
        return _report_status("created", fp, title, body, url=url)
    return _report_status("failed", fp, title, body)


def notify_exception(
    exc: BaseException,
    *,
    context: dict | None = None,
    repo: str | None = None,
    token: str | None = None,
    summary: str = "",
    auto_only: bool = True,
) -> dict[str, Any]:
    """Flush, fingerprint, deduplicate, and optionally file a report."""
    log_tail = _collect_exception_logs()
    stack, first_frame = _exception_traceback(exc)
    fp, title, body = _build_exception_report(
        exc, context, summary, log_tail, stack, first_frame
    )
    token_value = _token(token)
    auto_disabled = (
        auto_only and os.environ.get(AUTO_REPORT_ENV, "") != "1" and token is None
    )
    if auto_disabled:
        return _report_status("skipped", fp, title, body, reason="auto-report disabled")
    if not token_value:
        return _report_status("manual_needed", fp, title, body)
    return _submit_exception_report(fp, title, body, repo, token_value)


def main(argv: list[str]) -> int:
    """Manual trigger: ``python -m grablytic_engine.github_notifier --title "…"``."""
    import argparse

    ap = argparse.ArgumentParser(description="File a Grablytic issue from server logs.")
    ap.add_argument("--title", required=True)
    ap.add_argument("--summary", default="")
    ap.add_argument("--repo", default=None)
    args = ap.parse_args(argv)
    try:
        from grablytic_engine.persistent import read_log_tail, sanitize

        tail = str(sanitize(read_log_tail()))[:15000]
    except Exception as e:
        tail = f"<unavailable: {e}>"
    fp = fingerprint(args.title)
    body = build_body(
        args.summary or args.title, fp=fp, log_tail=tail if log_tail_enabled() else ""
    )
    tok = _token()
    if not tok:
        print(body)
        print(f"\n[{TOKEN_ENV} not set — body printed for manual filing. fp={fp}]")
        return 2
    dup = find_duplicate(fp, repo=target_repo(args.repo), token=tok)
    if dup:
        print(f"Duplicate open issue: {dup}")
        return 0
    url = create_issue(args.title, body, repo=target_repo(args.repo), token=tok)
    if url:
        print(f"Issue created: {url}")
        return 0
    print("Failed to create issue.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
