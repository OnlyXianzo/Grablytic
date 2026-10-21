import os
import sys
import json
import time
import queue
import threading
import traceback
import contextvars
from datetime import datetime, timezone
from contextlib import contextmanager
from typing import Any, Generator

DEBUG = 10
INFO = 20
WARN = 30
ERROR = 40
FATAL = 50

LEVEL_NAMES = {10: "DEBUG", 20: "INFO", 30: "WARN", 40: "ERROR", 50: "FATAL"}


def _default_stderr_mirror() -> bool:
    """Whether ``_log()`` should echo a human-readable line to stderr.

    The mirror used to be unconditional, which made the level knob a lie
    on desktop: ``DesktopEngineService`` pipes the child's stderr straight
    into ``AppLogger.warn``, so every DEBUG record arrived in the user's
    own log as a WARNING, at every verbosity. The structured record
    already reaches the host over the framed stdout channel, so the
    mirror is only useful when a human is watching a terminal.

    Default: on for a TTY, off when stderr is a pipe or a file. Set
    ``GRABLYTIC_LOG_STDERR=1`` to force it on (a shell redirect to a log
    file, a container that collects stderr), or ``=0`` to force it off.
    """
    override = os.environ.get("GRABLYTIC_LOG_STDERR", "").strip().lower()
    if override in ("1", "true", "yes", "on"):
        return True
    if override in ("0", "false", "no", "off"):
        return False
    try:
        return bool(sys.stderr.isatty())
    except Exception:
        return False


_current_download_id: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "current_download_id", default=None
)


def get_current_download_id() -> str | None:
    return _current_download_id.get()


def set_current_download_id(download_id: str | None) -> contextvars.Token:
    return _current_download_id.set(download_id)


def reset_current_download_id(token: contextvars.Token) -> None:
    _current_download_id.reset(token)


@contextmanager
def download_context(download_id: str | None):
    token = _current_download_id.set(download_id)
    try:
        yield
    finally:
        _current_download_id.reset(token)


class EngineLogger:
    def __init__(self, name: str):
        """Create a named logger with no file, queue, or instance callback sink.

        File, queue, and stderr delivery default to DEBUG and above; the
        Android callback defaults to INFO and above. Stderr defaults to
        the environment override or terminal detection.
        """
        self.name = name
        self._context = threading.local()
        self._queue: queue.Queue | None = None
        self._event_callback = None
        self._log_dir: str | None = None
        self._min_level: int = DEBUG
        # Bridge gate (Loop-1 hang fix): the Chaquopy/EventChannel callback
        # feeds the Flutter UI thread (LogBuffer + overlay rebuilds). yt-dlp
        # emits per-block DEBUG at tens of Hz per download; forwarding all
        # of it hung flagships with 10+ queued items (63k lines/7.5MB per
        # field session). INFO+ crosses the bridge; DEBUG stays in the file
        # log + in-memory queue (desktop drain), so diagnostics lose nothing.
        # Deliberately NOT per-download: loggers are process-global shared
        # singletons, so a per-download verbose flag would race across
        # concurrent downloads. Verbose users read DEBUG via Diagnostics →
        # File Logs (same bytes, zero UI cost).
        self._bridge_min_level: int = INFO
        # Human-readable stderr mirror. Off unless a person is watching:
        # on desktop the host treats every stderr line as a WARNING, so an
        # unconditional mirror re-levelled DEBUG records (see
        # _default_stderr_mirror).
        self._stderr_enabled: bool = _default_stderr_mirror()

    def set_context(self, **kwargs: Any) -> None:
        if not hasattr(self._context, "data"):
            self._context.data = {}
        self._context.data.update(kwargs)
        if "download_id" in kwargs:
            _current_download_id.set(kwargs["download_id"])

    def clear_context(self) -> None:
        if hasattr(self._context, "data"):
            self._context.data.clear()
        _current_download_id.set(None)

    def set_queue(self, q: queue.Queue | None) -> None:
        self._queue = q

    def set_event_callback(self, cb) -> None:
        """Direct push channel (Android/Chaquopy): ``cb.onEvent(json)``."""
        self._event_callback = cb

    def set_log_dir(self, path: str) -> None:
        self._log_dir = path

    def set_min_level(self, level: int) -> None:
        self._min_level = level

    def set_bridge_min_level(self, level: int) -> None:
        """Floor for the UI bridge callback (file + queue unaffected)."""
        self._bridge_min_level = level

    def set_stderr_enabled(self, enabled: bool) -> None:
        """Force the human-readable stderr mirror on or off."""
        self._stderr_enabled = bool(enabled)

    def _log(
        self,
        level: int,
        message: str,
        *,
        extra: dict | None = None,
        exception: BaseException | None = None,
        duration_ms: int | None = None,
    ) -> None:
        """Deliver a contextual record to configured sinks.

        File, queue, and stderr use the minimum level; the Android callback
        uses its separate bridge floor. The persistent logging bridge applies
        its own filtering. ``duration_ms`` is elapsed time in milliseconds.
        Sink failures are suppressed, but record construction and JSON
        serialization errors propagate to the caller.
        """
        # Cheapest possible early exit. Building the record costs a copied
        # dict, a strftime'd timestamp, a 10-key event dict and a json.dumps
        # — measured at 11.4 us with no sink at all — and yt-dlp's DEBUG
        # flood under `verbose` hits this path thousands of times per
        # download. Each sink below re-checks its own floor; this only
        # answers "would ANY of them take it", with the same floors.
        if not self._wants(level):
            return

        ctx = (
            getattr(self._context, "data", {}).copy()
            if hasattr(self._context, "data")
            else {}
        )
        level_name = LEVEL_NAMES.get(level, "UNKNOWN")
        now = datetime.now(timezone.utc)
        ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"
        did = (
            ctx.get("download_id")
            or (extra or {}).get("download_id")
            or _current_download_id.get()
        )
        trace_id = ctx.get("trace_id") or did
        if did:
            ctx["download_id"] = did

        event = {
            "type": "log",
            "level": level_name,
            "ts": ts,
            "logger": self.name,
            "message": message,
            "context": ctx,
            "extra": extra or {},
            "trace_id": trace_id,
            "download_id": did,
            "duration_ms": duration_ms,
            "exception": repr(exception) if exception else None,
        }

        # Serialize ONCE. The daily file, the queue and the bridge all
        # carry the same bytes; this used to be two json.dumps per record
        # on the hot path (thousands of lines per download).
        payload = json.dumps(event, default=str)

        # The human-readable mirror obeys the SAME level gate as every
        # other sink. It used to run first and unconditionally, before
        # the `_min_level` checks, so a host that pipes stderr into its
        # own logger (the desktop transport does exactly that) promoted
        # every DEBUG record to a WARNING and made set_min_level a no-op.
        if level >= self._min_level and self._stderr_enabled:
            try:
                print(f"[{level_name}] [{self.name}] {message}", file=sys.stderr)
            except Exception:
                pass

        if level >= self._min_level and self._log_dir:
            _write_daily_line(
                self._log_dir,
                now,
                payload + "\n",
                level=level,
                force_flush=level >= ERROR,
            )

        if level >= self._min_level and self._queue is not None:
            try:
                self._queue.put(event)
                notify_poll()
            except Exception:
                pass

        # Direct push channel (Android/Chaquopy): the Kotlin
        # EngineEventListener forwards every JSON blob to the Flutter
        # EventChannel. Falls back to the module-global callback so loggers
        # created before the setter ran still deliver. Never raises — a
        # logging path must not break downloads (or tests without Chaquopy).
        # Gated on _bridge_min_level (default INFO): DEBUG rides the file +
        # queue only, never the UI thread.
        cb = (
            self._event_callback
            if self._event_callback is not None
            else _global_event_callback
        )
        if cb is not None and level >= self._bridge_min_level:
            try:
                cb.onEvent(payload)
            except Exception:
                pass

        # Bridge to the rotating server_logs.log handler (STEP 3B).
        # Lazy import avoids a hard dependency cycle; failures are silent
        # so unit tests without persistent init keep passing.
        # Perf: persistent bridge is a second disk write per record. Gate to
        # WARNING+ so DEBUG/INFO ride the daily file + queue only — the
        # verbose diagnostics path (Diagnostics → File Logs) still has them,
        # but we avoid a redundant 30 µs redacted copy per record (75% of
        # per-record cost) that the viewer never shows at verbose-off.
        if level >= WARN:
            try:
                from grablytic_engine.persistent import bridge_event as _bridge

                _level_map = {10: 10, 20: 20, 30: 30, 40: 40, 50: 50}
                _bridge(
                    _level_map.get(level, 20),
                    f"[{self.name}] {message}"
                    + (f" :: {event['exception']}" if event.get("exception") else ""),
                )
            except Exception:
                pass

    def _wants(self, level: int) -> bool:
        """True when at least one sink would accept a record at [level].

        Mirrors the per-sink floors exactly: file/stderr/queue on
        `_min_level`, the UI bridge on `_bridge_min_level`, and the
        persistent rotating handler on its own configured level. Getting
        this wrong in either direction is a bug — too permissive wastes the
        work it exists to avoid, too strict silently swallows records.
        """
        if level >= self._min_level and (
            self._stderr_enabled or self._log_dir or self._queue is not None
        ):
            return True
        if level >= self._bridge_min_level and (
            self._event_callback is not None or _global_event_callback is not None
        ):
            return True
        floor = _persistent_bridge_level
        # Persistent bridge is gated to WARN+ (see _log above) so DEBUG/INFO
        # records that would only have hit persistent are not wanted.
        if floor is not None:
            effective = floor if floor > WARN else WARN
            if level >= effective:
                return True
        return False

    def debug(
        self,
        message: str,
        *,
        extra: dict | None = None,
        exception: BaseException | None = None,
        duration_ms: int | None = None,
    ) -> None:
        self._log(
            DEBUG, message, extra=extra, exception=exception, duration_ms=duration_ms
        )

    def info(
        self,
        message: str,
        *,
        extra: dict | None = None,
        exception: BaseException | None = None,
        duration_ms: int | None = None,
    ) -> None:
        self._log(
            INFO, message, extra=extra, exception=exception, duration_ms=duration_ms
        )

    def warn(
        self,
        message: str,
        *,
        extra: dict | None = None,
        exception: BaseException | None = None,
        duration_ms: int | None = None,
    ) -> None:
        self._log(
            WARN, message, extra=extra, exception=exception, duration_ms=duration_ms
        )

    def warning(
        self,
        message: str,
        *,
        extra: dict | None = None,
        exception: BaseException | None = None,
        duration_ms: int | None = None,
    ) -> None:
        """stdlib-compatible alias for :meth:`warn`.

        `warn` is the historical spelling and stays. `warning` is what
        every other logging facade exposes — Python's own `logging`, and
        the yt-dlp adapter in `downloader.py` — so a caller who reaches
        for it must not get an AttributeError *inside an except block*.
        That is precisely how this class once took the engine down at
        import time: `log.warning(...)` in the FFmpeg guard replaced the
        real error with an AttributeError.
        """
        self._log(
            WARN, message, extra=extra, exception=exception, duration_ms=duration_ms
        )

    def error(
        self,
        message: str,
        *,
        extra: dict | None = None,
        exception: BaseException | None = None,
        duration_ms: int | None = None,
    ) -> None:
        self._log(
            ERROR, message, extra=extra, exception=exception, duration_ms=duration_ms
        )

    def fatal(
        self,
        message: str,
        *,
        extra: dict | None = None,
        exception: BaseException | None = None,
        duration_ms: int | None = None,
    ) -> None:
        self._log(
            FATAL, message, extra=extra, exception=exception, duration_ms=duration_ms
        )

    @contextmanager
    def trace(self, label: str, level: int = DEBUG) -> Generator[None, None, None]:
        start = time.time()
        try:
            yield
        except Exception as e:
            self._log(
                ERROR,
                f"{label} FAILED",
                exception=e,
                duration_ms=int((time.time() - start) * 1000),
            )
            raise
        else:
            self._log(
                level, f"{label} OK", duration_ms=int((time.time() - start) * 1000)
            )

    def log_exception(
        self,
        exc: BaseException,
        message: str = "",
        *,
        level: int = ERROR,
        extra: dict | None = None,
    ) -> None:
        try:
            from grablytic_engine.persistent import format_traceback as _fmt_tb

            tb_text = _fmt_tb(exc)
        except Exception:
            try:
                tb_text = traceback.format_exc()
            except Exception:
                tb_text = repr(exc)
        full_msg = f"{message}: {exc}" if message else str(exc)
        # Keep `message` + `exception` repr stable for tests/IPC consumers;
        # full frames ride in `extra.traceback` for disk + GitHub reports.
        merged_extra = {"traceback": tb_text}
        if extra:
            merged_extra.update(extra)
        try:
            self._log(level, full_msg, exception=exc, extra=merged_extra)
        except Exception:
            self._log(level, full_msg, exception=exc, extra=extra)


_loggers: dict[str, EngineLogger] = {}
_loggers_lock = threading.Lock()

# Loop-2 I/O shield: open/write/close per DEBUG line was 3 syscalls × tens
# of Hz × downloads on low-end eMMC (visible I/O jitter). Cached handles
# with a 5 s flush cadence (immediate on ERROR+) cut syscalls ~100x with the
# same durability for triage (crash lines always force-flush). Keyed by real
# path; guarded by one lock; closed at interpreter exit. Never raises.
_file_sinks: dict[str, Any] = {}
_file_sinks_lock = threading.Lock()
_FILE_FLUSH_INTERVAL_S = 5.0


# (log_dir, day) -> resolved path. `realpath` walks every component with a
# syscall each, and `makedirs` + `strftime` are equally invariant inside one
# calendar day: together they were 48% of a written record's cost.
_sink_path_cache: dict[tuple[str, str], str] = {}
_sink_path_lock = threading.Lock()


def _day_stamp(now: datetime) -> str:
    """`YYYY-MM-DD` without strftime's format-string machinery."""
    return f"{now.year:04d}-{now.month:02d}-{now.day:02d}"


def _daily_sink_path(log_dir: str, now: datetime) -> str:
    """Absolute path of today's engine log file, memoised per day.

    The cache is keyed by (log_dir, day) and pruned to the current day on
    every miss, so one stale entry cannot accumulate. A directory that is
    moved or re-symlinked mid-session keeps writing to the old path until
    the day rolls over — which is also what an already-open file handle
    does, so nothing is lost that was not already lost.
    """
    day = _day_stamp(now)
    key = (log_dir, day)
    with _sink_path_lock:
        cached = _sink_path_cache.get(key)
    if cached is not None:
        return cached

    os.makedirs(log_dir, exist_ok=True)
    path = os.path.realpath(os.path.join(log_dir, f"engine_{day}.txt"))
    with _sink_path_lock:
        for stale in [k for k in _sink_path_cache if k[0] == log_dir and k[1] != day]:
            _sink_path_cache.pop(stale, None)
        _sink_path_cache[key] = path
    return path


def _write_daily_line(
    log_dir: str,
    now: datetime,
    line: str,
    *,
    level: int = INFO,
    force_flush: bool = False,
) -> None:
    # Durability contract: INFO and above are write-through (flushed every
    # line) so triage/report/export readers never see a stale file. DEBUG —
    # the per-block flood — rides the 64 KiB buffer with a 5 s flush cadence.
    # Either way there is exactly one write syscall per line and no open/close
    # churn (the old code paid open+write+close per line).
    try:
        path = _daily_sink_path(log_dir, now)
        with _file_sinks_lock:
            sink = _file_sinks.get(path)
            if sink is None or sink.get("closed", False):
                sink = {
                    "fh": open(path, "a", buffering=1 << 16),
                    "last_flush": _time_monotonic(),
                    "closed": False,
                }
                _file_sinks[path] = sink
            sink["fh"].write(line)
            if (
                force_flush
                or level >= INFO
                or _time_monotonic() - sink["last_flush"] >= _FILE_FLUSH_INTERVAL_S
            ):
                sink["fh"].flush()
                sink["last_flush"] = _time_monotonic()
    except Exception:
        pass


def _time_monotonic() -> float:
    return time.monotonic()


def close_log_sinks() -> None:
    """Flush + close all cached daily handles. Idempotent, never raises."""
    try:
        with _file_sinks_lock:
            items = list(_file_sinks.items())
            _file_sinks.clear()
        for _, sink in items:
            try:
                sink["fh"].flush()
            except Exception:
                pass
            try:
                sink["fh"].close()
            except Exception:
                pass
    except Exception:
        pass


def flush_log_sinks() -> None:
    """Flush buffered daily-file lines to disk WITHOUT closing handles.

    DEBUG lines ride a 64 KiB / 5 s buffer (INFO+ are write-through), so a
    reader that opens ``engine_YYYY-MM-DD.txt`` directly — e.g. the Android
    MediaStore export — can miss the newest bytes. Call this before any
    out-of-band file copy (the export path does). Keeps handles open, so
    logging continues undisturbed. Idempotent, never raises.
    """
    try:
        with _file_sinks_lock:
            items = list(_file_sinks.values())
        for sink in items:
            try:
                sink["fh"].flush()
            except Exception:
                pass
        try:
            with _file_sinks_lock:
                for sink in _file_sinks.values():
                    sink["last_flush"] = _time_monotonic()
        except Exception:
            pass
    except Exception:
        pass


try:
    import atexit as _atexit

    _atexit.register(close_log_sinks)
except Exception:
    pass

# Module-global push callback (Android/Chaquopy). Stored here so loggers
# created AFTER the setter ran inherit it via get_logger().
_global_event_callback = None

# Module-global log dir. Same late-binding rationale: set_paths() may run
# before some lazily-created loggers exist (Android calls it directly).
_global_log_dir: str | None = None

# Module-global bridge floor (see EngineLogger._bridge_min_level).
_global_bridge_min_level: int = INFO

# Wake flag for the background drain thread (see __main__.poll_queues).
# Producers — the log queue here, and the progress/result queues via
# hooks._put_bounded — set it so the drain runs on demand instead of on a
# 10 Hz timer. Lives here because hooks already imports this module.
_poll_wakeup = threading.Event()


def notify_poll() -> None:
    """Tell the drain thread there is work. Never raises.

    ``threading.Event.set`` has no failure mode of its own, so there is no
    handler to write here: a producer on a download thread must not pay a
    try/except for a call that cannot throw.
    """
    _poll_wakeup.set()


def wait_for_poll(timeout: float) -> bool:
    """Block until a producer signals, or [timeout]. Clears the flag."""
    try:
        fired = _poll_wakeup.wait(timeout=timeout)
    except (TypeError, ValueError):
        # A caller passed a nonsense timeout. Falling back to the idle
        # interval keeps the drain alive instead of killing the thread.
        return False
    _poll_wakeup.clear()
    return bool(fired)


# Floor of the rotating server_logs handler, tracked so the early gate in
# _log() can skip records no sink would take. None = not installed.
_persistent_bridge_level: int | None = None


def set_persistent_bridge_level(level: int | None) -> None:
    """Record the persistent bridge's floor (called by persistent.init).

    ``None`` means "no rotating handler installed". The gate must know this
    or it would drop records that only the persistent bridge would have
    written — the exact class of bug that makes a log file empty when a
    user needs it most.
    """
    global _persistent_bridge_level
    _persistent_bridge_level = level


def get_logger(name: str) -> EngineLogger:
    with _loggers_lock:
        if name not in _loggers:
            _loggers[name] = EngineLogger(name)
            if _global_event_callback is not None:
                _loggers[name].set_event_callback(_global_event_callback)
            if _global_log_dir is not None:
                _loggers[name].set_log_dir(_global_log_dir)
            _loggers[name].set_bridge_min_level(_global_bridge_min_level)
        return _loggers[name]


def set_global_log_dir(path: str) -> None:
    global _global_log_dir
    _global_log_dir = path
    with _loggers_lock:
        targets = list(_loggers.values())
    for logger in targets:
        logger.set_log_dir(path)


def set_global_queue(q: queue.Queue | None) -> None:
    with _loggers_lock:
        targets = list(_loggers.values())
    for logger in targets:
        logger.set_queue(q)


def set_global_event_callback(cb) -> None:
    """Register the Android push callback on all loggers (present + future).

    ``cb`` must expose ``onEvent(json_string)`` (Chaquopy Java proxy).
    Pass ``None`` to detach. Never raises.
    """
    global _global_event_callback
    _global_event_callback = cb
    with _loggers_lock:
        targets = list(_loggers.values())
    for logger in targets:
        try:
            logger.set_event_callback(cb)
        except Exception:
            pass


def set_global_bridge_min_level(level: int) -> None:
    """Floor for the UI bridge callback on all loggers (present + future).

    File + queue delivery are unaffected at any setting. Never raises.
    """
    global _global_bridge_min_level
    _global_bridge_min_level = level
    with _loggers_lock:
        targets = list(_loggers.values())
    for logger in targets:
        try:
            logger.set_bridge_min_level(level)
        except Exception:
            pass
