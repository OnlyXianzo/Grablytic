"""Persistent server-side logging (STEP 3B).

Thread-safe, time-buffered file persistence built on stdlib ``logging``:

- ``RotatingFileHandler`` targeting ``server_logs.log`` (default 2 MB x 5
  backups). RotatingFileHandler is internally locked, so concurrent download
  threads / the IPC loop can log without write-lock corruption.
- Periodic flush worker (every 30 s) + instant flush on ERROR/FATAL so an
  unhandled exception never loses its traceback.
- :func:`traced_request` middleware wrapper capturing request/response
  boundaries, latency, sanitized payloads and full traceback frames.

Only stdlib dependencies — safe for Chaquopy + desktop bundles.
"""

from __future__ import annotations

import copy
import logging
import logging.handlers
import os
import threading
import time
import traceback
from typing import Any, Callable

SERVER_LOG_NAME = "server_logs.log"
DEFAULT_MAX_BYTES = 2 * 1024 * 1024  # 2 MB per file
DEFAULT_BACKUP_COUNT = 5
FLUSH_INTERVAL_S = 30.0

_SENSITIVE_SUBSTRINGS = (
    "cookie", "token", "password", "passwd", "secret", "auth",
    "proxy", "api_key", "apikey", "session", "po_token",
)

_lock = threading.RLock()
_configured_dir: str | None = None
_handler: logging.handlers.RotatingFileHandler | None = None
_std_logger: logging.Logger | None = None
_flush_thread: threading.Thread | None = None
_flush_stop = threading.Event()


def sanitize(obj: Any) -> Any:
    """Deep-copy *obj* with sensitive values replaced by ***REDACTED***.

    Handles dicts, lists/tuples and strings (query-string token masking).
    Never mutates the caller's object — the engine keeps working with the
    original while only the redacted copy hits disk / GitHub.
    """
    if isinstance(obj, dict):
        redacted: dict[Any, Any] = {}
        for k, v in obj.items():
            lk = str(k).lower()
            if any(s in lk for s in _SENSITIVE_SUBSTRINGS):
                redacted[k] = "***REDACTED***"
            else:
                redacted[k] = sanitize(v)
        return redacted
    if isinstance(obj, (list, tuple)):
        cleaned = [sanitize(v) for v in obj]
        return type(obj)(cleaned) if isinstance(obj, tuple) else cleaned
    if isinstance(obj, str) and len(obj) > 8:
        # Mask token= / sig= / key= query params, keep names for debugging.
        import re
        return re.sub(
            r"((?:token|sig|key|auth)[=:][\"']?)([^\"'&\s,}]+)",
            r"\1***REDACTED***",
            obj,
            flags=re.IGNORECASE,
        )
    return obj


def format_traceback(exc: BaseException, limit: int = 40) -> str:
    """Full traceback frames, truncated to ~8 KB for log/GitHub safety."""
    try:
        frames = traceback.format_exception(
            type(exc), exc, exc.__traceback__, limit=limit
        )
        text = "".join(frames)
    except Exception:
        text = repr(exc)
    if len(text) > 8192:
        text = "... [TRUNCATED] ...\n" + text[-8192:]
    return text


def init_persistent_logging(
    log_dir: str,
    max_bytes: int = DEFAULT_MAX_BYTES,
    backup_count: int = DEFAULT_BACKUP_COUNT,
    level: int = logging.DEBUG,
) -> logging.Logger:
    """Configure (or reconfigure) the rotating ``server_logs.log`` handler.

    Idempotent per directory — repeat calls with the same dir are no-ops.
    Safe to call from ``paths/set`` and from tests with tmp dirs.
    """
    global _configured_dir, _handler, _std_logger
    with _lock:
        if _configured_dir == log_dir and _std_logger is not None:
            return _std_logger
        os.makedirs(log_dir, exist_ok=True)
        path = os.path.join(log_dir, SERVER_LOG_NAME)

        logger = logging.getLogger("truestream.server")
        logger.setLevel(level)
        logger.propagate = False

        if _handler is not None:
            try:
                logger.removeHandler(_handler)
                _handler.close()
            except Exception:
                pass
            _handler = None

        _handler = logging.handlers.RotatingFileHandler(
            path, maxBytes=max_bytes, backupCount=backup_count,
            encoding="utf-8",
        )
        _handler.setLevel(level)
        _handler.setFormatter(logging.Formatter(
            "%(asctime)s.%(msecs)03d [%(levelname)s] [%(name)s] %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        ))
        logger.addHandler(_handler)

        _configured_dir = log_dir
        _std_logger = logger
        _ensure_flush_worker_locked()
        return logger


def get_std_logger(name: str = "truestream.server") -> logging.Logger:
    """Return a child stdlib logger sharing the rotating handler."""
    with _lock:
        base = _std_logger
    if base is None:
        # Not initialized yet (e.g. unit tests) — return a non-persisting
        # logger so callers never crash before paths/set arrives.
        fallback = logging.getLogger(name)
        return fallback
    return base.getChild(name.split(".")[-1]) if name != base.name else base


def bridge_event(level: int, message: str) -> None:
    """Forward an EngineLogger event line to the rotating handler (if any).

    Sanitized first (SEC-02): engine lines routinely embed signed URLs
    (sig/lsig) from extractor chatter, and server_logs.log is an
    exfil-adjacent surface (diagnostics exports). Never raises.
    """
    with _lock:
        logger = _std_logger
    if logger is None:
        return
    try:
        safe = sanitize(message)
        logger.log(level, safe if isinstance(safe, str) else message)
        if level >= logging.ERROR:
            flush_now()
    except Exception:
        pass


def flush_now() -> None:
    """Flush the rotating handler to disk immediately (crash path)."""
    with _lock:
        handler = _handler
    if handler is None:
        return
    try:
        handler.acquire()
        try:
            handler.flush()
        finally:
            handler.release()
    except Exception:
        pass


def _ensure_flush_worker_locked() -> None:
    global _flush_thread
    if _flush_thread is not None and _flush_thread.is_alive():
        return
    _flush_stop.clear()
    _flush_thread = threading.Thread(
        target=_flush_loop, name="truestream-log-flush", daemon=True
    )
    _flush_thread.start()


def _flush_loop() -> None:
    while not _flush_stop.wait(FLUSH_INTERVAL_S):
        try:
            flush_now()
        except Exception:
            pass


def stop_flush_worker() -> None:
    _flush_stop.set()


def server_log_path() -> str | None:
    with _lock:
        d = _configured_dir
    if d is None:
        return None
    return os.path.join(d, SERVER_LOG_NAME)


def read_log_tail(max_bytes: int = 100 * 1024) -> str:
    """Read the tail of ``server_logs.log`` for crash reports.

    Never loads the whole file — seeks to the last *max_bytes*.
    """
    path = server_log_path()
    if path is None or not os.path.isfile(path):
        return "No server logs recorded yet."
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                raw = f.read(max_bytes)
                text = raw.decode("utf-8", errors="replace")
                nl = text.find("\n")
                if 0 <= nl < 4096:
                    text = text[nl + 1:]
                return f"... [TRUNCATED — last {max_bytes // 1024}KB of {size // 1024}KB] ...\n{text}"
            return f.read().decode("utf-8", errors="replace")
    except Exception as exc:
        return f"Failed to read server log tail: {exc}"


def traced_request(
    method: str,
    params: dict | None,
    handler: Callable[[], Any],
    *,
    logger: logging.Logger | None = None,
    engine_log: Any | None = None,
) -> Any:
    """Middleware wrapper for one JSON-RPC dispatch.

    - Logs the request boundary with sanitized payload at DEBUG.
    - Measures wall-clock latency.
    - Logs the response boundary (ok + latency, or error + full traceback).
    - Flushes instantly on failure so the report pipeline sees the frames.

    Returns ``handler()`` verbatim; exceptions propagate unchanged.
    """
    log = logger or get_std_logger()
    safe_params = sanitize(params or {})
    start = time.time()
    trace_id = None
    try:
        if isinstance(params, dict):
            trace_id = params.get("download_id") or params.get("trace_id")
    except Exception:
        pass
    prefix = f"[{trace_id}] " if trace_id else ""
    log.debug("%s>> %s params=%s", prefix, method, safe_params)
    if engine_log is not None:
        try:
            engine_log.debug(f"{prefix}>> {method}",
                             extra={"params": safe_params})
        except Exception:
            pass
    try:
        result = handler()
    except Exception as exc:
        latency_ms = int((time.time() - start) * 1000)
        tb = format_traceback(exc)
        log.error("%s!! %s FAILED in %dms: %r\n%s",
                  prefix, method, latency_ms, exc, tb)
        if engine_log is not None:
            try:
                engine_log.log_exception(exc, f"{prefix}{method} FAILED")
            except Exception:
                pass
        flush_now()
        raise
    latency_ms = int((time.time() - start) * 1000)
    try:
        safe_preview = str(sanitize(result))[:500]
    except Exception:
        safe_preview = "<unserializable>"
    log.debug("%s<< %s OK in %dms preview=%s",
              prefix, method, latency_ms, safe_preview)
    return result
