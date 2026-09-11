import os
import sys
import json
import time
import queue
import threading
import traceback
from datetime import datetime, timezone
from contextlib import contextmanager
from typing import Any, Generator

DEBUG = 10
INFO = 20
WARN = 30
ERROR = 40
FATAL = 50

LEVEL_NAMES = {10: "DEBUG", 20: "INFO", 30: "WARN", 40: "ERROR", 50: "FATAL"}


class EngineLogger:
    def __init__(self, name: str):
        self.name = name
        self._context = threading.local()
        self._queue: queue.Queue | None = None
        self._log_dir: str | None = None
        self._min_level: int = DEBUG

    def set_context(self, **kwargs: Any) -> None:
        if not hasattr(self._context, 'data'):
            self._context.data = {}
        self._context.data.update(kwargs)

    def clear_context(self) -> None:
        if hasattr(self._context, 'data'):
            self._context.data.clear()

    def set_queue(self, q: queue.Queue | None) -> None:
        self._queue = q

    def set_log_dir(self, path: str) -> None:
        self._log_dir = path

    def set_min_level(self, level: int) -> None:
        self._min_level = level

    def _log(self, level: int, message: str, *, extra: dict | None = None, exception: BaseException | None = None, duration_ms: int | None = None) -> None:
        ctx = getattr(self._context, 'data', {}).copy() if hasattr(self._context, 'data') else {}
        level_name = LEVEL_NAMES.get(level, "UNKNOWN")
        now = datetime.now(timezone.utc)
        ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"

        event = {
            "type": "log",
            "level": level_name,
            "ts": ts,
            "logger": self.name,
            "message": message,
            "context": ctx,
            "extra": extra or {},
            "trace_id": ctx.get("trace_id"),
            "duration_ms": duration_ms,
            "exception": repr(exception) if exception else None,
        }

        print(f"[{level_name}] [{self.name}] {message}", file=sys.stderr)

        if level >= self._min_level and self._log_dir:
            date_str = now.strftime("%Y-%m-%d")
            log_file = os.path.join(self._log_dir, f"engine_{date_str}.txt")
            try:
                os.makedirs(self._log_dir, exist_ok=True)
                with open(log_file, "a") as f:
                    f.write(json.dumps(event, default=str) + "\n")
            except Exception:
                pass

        if level >= self._min_level and self._queue is not None:
            try:
                self._queue.put(event)
            except Exception:
                pass

        # Bridge to the rotating server_logs.log handler (STEP 3B).
        # Lazy import avoids a hard dependency cycle; failures are silent
        # so unit tests without persistent init keep passing.
        try:
            from truestream_engine.persistent import bridge_event as _bridge
            import logging as _stdlib_logging

            _level_map = {10: 10, 20: 20, 30: 30, 40: 40, 50: 50}
            _bridge(_level_map.get(level, 20),
                    f"[{self.name}] {message}"
                    + (f" :: {event['exception']}" if event.get("exception") else ""))
        except Exception:
            pass

    def debug(self, message: str, *, extra: dict | None = None, exception: BaseException | None = None, duration_ms: int | None = None) -> None:
        self._log(DEBUG, message, extra=extra, exception=exception, duration_ms=duration_ms)

    def info(self, message: str, *, extra: dict | None = None, exception: BaseException | None = None, duration_ms: int | None = None) -> None:
        self._log(INFO, message, extra=extra, exception=exception, duration_ms=duration_ms)

    def warn(self, message: str, *, extra: dict | None = None, exception: BaseException | None = None, duration_ms: int | None = None) -> None:
        self._log(WARN, message, extra=extra, exception=exception, duration_ms=duration_ms)

    def error(self, message: str, *, extra: dict | None = None, exception: BaseException | None = None, duration_ms: int | None = None) -> None:
        self._log(ERROR, message, extra=extra, exception=exception, duration_ms=duration_ms)

    def fatal(self, message: str, *, extra: dict | None = None, exception: BaseException | None = None, duration_ms: int | None = None) -> None:
        self._log(FATAL, message, extra=extra, exception=exception, duration_ms=duration_ms)

    @contextmanager
    def trace(self, label: str, level: int = DEBUG) -> Generator[None, None, None]:
        start = time.time()
        try:
            yield
        except Exception as e:
            self._log(ERROR, f"{label} FAILED", exception=e, duration_ms=int((time.time() - start) * 1000))
            raise
        else:
            self._log(level, f"{label} OK", duration_ms=int((time.time() - start) * 1000))

    def log_exception(self, exc: BaseException, message: str = "", *, level: int = ERROR) -> None:
        try:
            from truestream_engine.persistent import format_traceback as _fmt_tb
            tb_text = _fmt_tb(exc)
        except Exception:
            try:
                tb_text = traceback.format_exc()
            except Exception:
                tb_text = repr(exc)
        full_msg = f"{message}: {exc}" if message else str(exc)
        # Keep `message` + `exception` repr stable for tests/IPC consumers;
        # full frames ride in `extra.traceback` for disk + GitHub reports.
        try:
            self._log(level, full_msg, exception=exc,
                      extra={"traceback": tb_text})
        except Exception:
            self._log(level, full_msg, exception=exc)


_loggers: dict[str, EngineLogger] = {}


def get_logger(name: str) -> EngineLogger:
    if name not in _loggers:
        _loggers[name] = EngineLogger(name)
    return _loggers[name]


def set_global_log_dir(path: str) -> None:
    for logger in _loggers.values():
        logger.set_log_dir(path)


def set_global_queue(q: queue.Queue | None) -> None:
    for logger in _loggers.values():
        logger.set_queue(q)
