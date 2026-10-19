from grablytic_engine import contract
import sys
import json
import concurrent.futures as _futures
import threading
import time
import queue as _queue_module
from grablytic_engine import (
    set_paths,
    bootstrap,
    get_formats,
    get_playlist_info,
    search_query,
    scan_resume_candidates,
    report_resume_attempt,
    start_download,
    cancel_download,
    get_queue_status,
    set_max_concurrent,
    clear_download_archive,
    set_update_channel,
    update_check,
    shutdown_downloads,
)
from grablytic_engine.downloader import _active_downloads, _downloads_lock
from grablytic_engine.logger import get_logger, set_global_queue, set_global_log_dir
from grablytic_engine.persistent import (
    init_persistent_logging,
    get_std_logger,
    traced_request,
    flush_now as persistent_flush,
)

log = get_logger("grablytic_engine.main")
_log_queue: _queue_module.Queue | None = None
_stdout_lock = threading.Lock()

# Head-of-line blocking. The stdin reader must never block behind a
# slow network extraction (formats/get, playlist/info, search/query). Slow
# methods run on a bounded worker pool; responses are correlated by request
# id over the single stdout lock, so out-of-order completion is safe. The
# envelope contract and method ids are byte-identical.
_MAX_IPC_WORKERS = 8
# Back-pressure (finding: unbounded pool queue). The number of slow-lane
# requests allowed in flight (running + queued) at any moment. The old
# unbounded `pool.submit()` grew without limit: every queued request held
# its params, and a stalled Dart reader could wedge all 8 workers on the
# stdout lock while the queue grew until the process died. Past this
# bound the engine SHEDS LOAD with an explicit, retryable ERROR_BUSY
# envelope instead of silently queueing — the client learns immediately
# that the engine is saturated rather than hanging until timeout.
_MAX_IPC_INFLIGHT = 24
# Fast local-only methods bypass the pool entirely and run inline in the
# reader thread: a 30s extraction must never delay cancel/queue-status.
# All are in-memory + lock-guarded (no network), so inline is safe.
_FAST_IPC_METHODS = frozenset(
    {
        "download/cancel",
        "download/queue_status",
        "download/set_concurrency",
        "download/clear_archive",
    }
)
# A single IPC line longer than this is refused instead of being read
# into memory. Legit envelopes (a 200-format preview) are far smaller;
# a runaway writer must not be able to OOM the engine.
_MAX_IPC_LINE_BYTES = 4 * 1024 * 1024
_paths_lock = threading.Lock()

# ── stdout framing firewall ────────────────────────────────────────────
# stdout is a FRAMED protocol channel: every byte must be exactly one
# JSON envelope followed by '\n'. A single stray write (yt-dlp's own
# stdout logger, a C extension, a third-party lib calling print())
# injects a non-JSON line and desyncs the client's LineSplitter for the
# WHOLE session — every later frame is then mis-parsed.
#
# Mitigation: replace the public `sys.stdout` with a shim that forwards
# stray writes to stderr. Installed by main() (NOT at import time) so
# test runners that capture stdout keep working.
#
# The real stdout is NEVER cached in a module global: the protocol
# writer resolves it dynamically through _out_stream(), so a runner that
# swaps sys.stdout between tests (pytest capture) is always honoured
# and a stale closed stream can never swallow frames.


class _StdoutFirewall:
    """`sys.stdout` replacement that can never corrupt protocol framing.

    Every write is forwarded to stderr. The real stdout stays reachable
    only through the module-level protocol writer.
    """

    def __init__(self, real_stdout, real_stderr):
        self._real = real_stdout
        self._err = real_stderr

    # -- text layer -------------------------------------------------
    def write(self, data):
        try:
            return self._err.write(data)
        except Exception:
            return len(data) if isinstance(data, (str, bytes)) else 0

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def flush(self):
        try:
            self._err.flush()
        except Exception:
            pass

    # -- binary layer ------------------------------------------------
    # `sys.stdout.buffer` must not hand out a real stdout fd: a raw
    # byte write there would inject garbage into the frame stream.
    @property
    def buffer(self):
        return _StderrBuffer(self._err)

    # -- introspection ----------------------------------------------
    @staticmethod
    def isatty():
        return False

    def fileno(self):
        try:
            return self._real.fileno()
        except Exception:
            return 1

    @property
    def encoding(self):
        return getattr(self._real, "encoding", "utf-8")

    @property
    def errors(self):
        return getattr(self._real, "errors", None)

    @property
    def closed(self):
        return False

    @staticmethod
    def writable():
        return True

    @staticmethod
    def readable():
        return False

    @staticmethod
    def seekable():
        return False

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _StderrBuffer:
    """Binary shim for `sys.stdout.buffer` — writes go to stderr."""

    def __init__(self, real_stderr):
        self._err = real_stderr

    def write(self, data):
        try:
            return self._err.buffer.write(data)
        except Exception:
            try:
                return self._err.write(
                    data.decode("utf-8", "replace")
                    if isinstance(data, bytes)
                    else str(data)
                )
            except Exception:
                return 0

    def flush(self):
        try:
            self._err.buffer.flush()
        except Exception:
            pass

    @staticmethod
    def writable():
        return True

    @staticmethod
    def readable():
        return False

    @staticmethod
    def seekable():
        return False


def install_stdout_firewall() -> bool:
    """Redirect stray stdout writes to stderr.

    Returns True when the firewall is active afterwards. After this
    call the ONLY way to emit a protocol frame is _write_stdout_line().
    Re-entrant: calling it again re-wraps the *current* real stdout
    (never a previously captured, possibly closed, stream).
    """
    try:
        current = sys.stdout
        if isinstance(current, _StdoutFirewall):
            current = current._real
        sys.stdout = _StdoutFirewall(current, sys.stderr)
        return True
    except Exception:
        return False


def restore_stdout() -> None:
    """Undo install_stdout_firewall() (tests + graceful shutdown)."""
    try:
        if isinstance(sys.stdout, _StdoutFirewall):
            sys.stdout = sys.stdout._real
    except Exception:
        pass


def _out_stream():
    """The stream that protocol frames are written to.

    Resolved dynamically: when the firewall is installed this is the
    real stdout behind it; otherwise it is whatever `sys.stdout` is
    right now (pytest capture, a redirected file, ...).
    """
    stream = sys.stdout
    if isinstance(stream, _StdoutFirewall):
        return stream._real
    return stream


def _write_stdout_line(line_str: str) -> None:
    """Atomically write and flush a line to stdout under _stdout_lock.

    Prevents interleaved JSON output between the background poll_queues
    thread and main request/response handling. Interleaved JSON lines
    corrupt the client/Dart JSON parser.
    """
    if not line_str.endswith("\n"):
        line_str += "\n"
    with _stdout_lock:
        stream = _out_stream()
        stream.write(line_str)
        stream.flush()


def _drain_log_queue() -> None:
    if _log_queue is None:
        return
    while True:
        try:
            log_entry = _log_queue.get_nowait()
            _write_stdout_line(json.dumps(log_entry))
        except _queue_module.Empty:
            break
        except Exception as exc:
            try:
                log.warn(f"Dropping malformed log entry: {type(exc).__name__}")
            except Exception:
                pass
            break


def _drain_progress_queue(progress_queue) -> None:
    while True:
        try:
            event = progress_queue.get_nowait()
            _write_stdout_line(event)
        except _queue_module.Empty:
            break
        except Exception as exc:
            try:
                log.warn(f"Dropping malformed progress event: {type(exc).__name__}")
            except Exception:
                pass
            break


def _result_event(download_id: str, result: dict) -> dict:
    if result.get("success", False):
        return {
            "type": "event",
            "event": "finished",
            "download_id": download_id,
            "filesize_bytes": result.get("filesize_bytes", 0),
            "total_bytes": result.get("filesize_bytes", 0),
            "file_path": result.get("file_path"),
            "thumbnail_path": result.get("thumbnail_path"),
        }
    if result.get("error_type") == "ERROR_CANCELLED":
        return {
            "type": "event",
            "event": "cancelled",
            "download_id": download_id,
            "error_type": "ERROR_CANCELLED",
            "error_message": result.get("error_message", "Download cancelled by user"),
        }
    return {
        "type": "event",
        "event": "error",
        "download_id": download_id,
        "error_type": result.get("error_type", "ERROR_UNKNOWN"),
        "error_message": result.get("error_message", "Unknown error"),
        "recoverable": result.get("recoverable", True),
        "suggests_vpn": result.get("suggests_vpn", False),
    }


def _mark_poll_result_delivered(download_id: str) -> None:
    try:
        from grablytic_engine.downloader import _mark_result_delivered

        _mark_result_delivered(download_id)
    except Exception:
        pass


def _drain_result_queue(download_id: str, result_queue) -> None:
    while True:
        try:
            result = result_queue.get_nowait()
            _write_stdout_line(json.dumps(_result_event(download_id, result)))
        except _queue_module.Empty:
            break
        except Exception as exc:
            try:
                log.warn(f"Dropping malformed result event: {type(exc).__name__}")
            except Exception:
                pass
            break
        else:
            _mark_poll_result_delivered(download_id)


def _poll_download_queues(download_id: str) -> None:
    with _downloads_lock:
        info = _active_downloads.get(download_id)
        if not info:
            return
        progress_queue = info.get("progress_queue")
        result_queue = info.get("result_queue")
    if progress_queue:
        _drain_progress_queue(progress_queue)
    if result_queue:
        _drain_result_queue(download_id, result_queue)


def poll_queues():
    while True:
        _drain_log_queue()
        with _downloads_lock:
            active_ids = list(_active_downloads)
        for download_id in active_ids:
            _poll_download_queues(download_id)
        time.sleep(0.1)


class _InvalidParam(Exception):
    """A required IPC parameter is missing or null."""

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


def _req(params, key):
    """Fetch a REQUIRED parameter, or raise a typed error.

    The old dispatch chain read `params["url"]` directly, so a host
    that omitted a field got a KeyError: no envelope came back, the
    client waited for a response that would never arrive, and the
    download hung.
    """
    try:
        value = params[key]
    except (KeyError, TypeError):
        raise _InvalidParam(f"Missing required parameter: {key}")
    if value is None:
        raise _InvalidParam(f"Missing required parameter: {key}")
    return value


def _negotiate_contract(params):
    """Check the request's contract version.

    Returns None when the request is acceptable, or an error envelope.

    A request WITHOUT a version is accepted — a host that predates the
    contract still works. A request with a DIFFERENT MAJOR version is
    refused: a major bump means the method set or the field names
    changed, and guessing would produce a half-understood request.
    """
    raw = (params or {}).get("contract_version")
    if raw is None:
        return None
    parsed = contract.parse_version(raw)
    if parsed is None:
        return {
            "success": False,
            "error_type": contract.ERROR_CONTRACT_MISMATCH,
            "error_message": f"Invalid contract version: {raw!r}",
            "expected_contract_version": contract.CONTRACT_VERSION,
        }
    major, _minor = parsed
    if major != contract.CONTRACT_MAJOR:
        return {
            "success": False,
            "error_type": contract.ERROR_CONTRACT_MISMATCH,
            "error_message": (
                f"Engine speaks contract {contract.CONTRACT_VERSION_STRING}, "
                f"the request speaks {major}.x — refusing."
            ),
            "expected_contract_version": contract.CONTRACT_VERSION,
        }
    return None


def _h_engine_bootstrap(_params):
    return bootstrap()


def _h_engine_contract(_params):
    return contract.contract_info()


def _h_download_start(params):
    return start_download(
        url=_req(params, "url"),
        download_id=_req(params, "download_id"),
        config=params.get("config"),
        network_type=params.get("network_type", "wifi"),
    )


def _h_download_cancel(params):
    return cancel_download(_req(params, "download_id"))


def _h_download_queue_status(_params):
    return get_queue_status()


def _h_download_set_concurrency(params):
    return set_max_concurrent(params.get("max_concurrent", 2))


def _h_download_clear_archive(params):
    return clear_download_archive(params.get("archive_path"))


def _h_formats_get(params):
    return get_formats(_req(params, "url"), params.get("config"))


def _h_playlist_info(params):
    return get_playlist_info(_req(params, "url"), params.get("config"))


def _h_search_query(params):
    return search_query(
        query=params.get("query", ""),
        site=params.get("site", "youtube"),
        limit=params.get("limit", 20),
        config=params.get("config"),
    )


def _h_resume_scan(params):
    return scan_resume_candidates(
        _req(params, "cache_dir"),
        limit=params.get("limit", 50),
        recursive=params.get("recursive", True),
        max_attempts=params.get("max_attempts", 3),
    )


def _h_resume_report(params):
    return report_resume_attempt(
        _req(params, "cache_dir"),
        _req(params, "filepath"),
        params.get("success", False),
    )


def _h_update_check(_params):
    return update_check()


def _h_set_update_channel(params):
    return set_update_channel(_req(params, "channel"))


# The dispatch registry. Method ids are frozen — the
# registry exists so the chain is data, not control flow, and so the
# contract can assert that it and the contract agree.
_METHOD_HANDLERS = {
    "engine/bootstrap": _h_engine_bootstrap,
    "engine/contract": _h_engine_contract,
    "download/start": _h_download_start,
    "download/cancel": _h_download_cancel,
    "download/queue_status": _h_download_queue_status,
    "download/set_concurrency": _h_download_set_concurrency,
    "download/clear_archive": _h_download_clear_archive,
    "formats/get": _h_formats_get,
    "playlist/info": _h_playlist_info,
    "search/query": _h_search_query,
    "resume/scan": _h_resume_scan,
    "resume/report": _h_resume_report,
    "engine/update_check": _h_update_check,
    "engine/set_update_channel": _h_set_update_channel,
}

if set(_METHOD_HANDLERS) != set(contract.METHODS):
    # The contract and the registry are two views of the same list; a
    # drift means a host would call a method the contract does not
    # advertise (or the other way round).
    raise RuntimeError(
        "IPC contract drift: registry=%s contract=%s"
        % (sorted(_METHOD_HANDLERS), sorted(contract.METHODS))
    )


def _dispatch_method(method, params):
    """Pure method dispatch. Thread-safe: all targets are themselves
    thread-safe (network extractions, lock-guarded queue)."""
    handler = _METHOD_HANDLERS.get(method)
    if handler is None:
        return {
            "success": False,
            "error_type": contract.ERROR_UNKNOWN_METHOD,
            "error_message": f"Method {method} not found",
        }
    try:
        return handler(params or {})
    except _InvalidParam as exc:
        return {
            "success": False,
            "error_type": contract.ERROR_INVALID_PARAM,
            "error_message": exc.message,
        }


def _execute_parsed_request(req_id, method, params):
    """Run one already-parsed request and write its envelope.

    May run on the reader thread (fast lane / paths/set) or a pool worker
    (slow extractions). Stdout stays serialized via _write_stdout_line so
    concurrent completions never interleave; Dart correlates by id.
    """
    try:
        # Sanitized copy for the engine log (never raw secrets: proxy
        # creds, po_token, signed-URL sigs ride in params/config).
        try:
            from grablytic_engine.persistent import sanitize as _sanitize

            _safe_params = _sanitize(params)
        except Exception:
            _safe_params = {}
        log.info(f"Method: {method}", extra={"params": _safe_params})

        # Sanitized copy for the rotating handler (never raw secrets).
        try:
            from grablytic_engine.persistent import sanitize as _sanitize

            get_std_logger().debug(">> %s params=%s", method, _sanitize(params))
        except Exception:
            pass

        res = None
        # Contract negotiation first: a mismatched MAJOR version is
        # refused before anything is dispatched.
        _mismatch = _negotiate_contract(params)
        if _mismatch is not None:
            res = _mismatch
        elif method == "paths/set":
            # Forward set_paths' verdict — it fails closed on
            # non-absolute roots / untrusted binaries. The old code
            # always answered success, hiding rejections from the UI.
            # Serialized: mutates the global log queue.
            with _paths_lock:
                res = set_paths(
                    data_dir=params["data_dir"],
                    output_dir=params["output_dir"],
                    ffmpeg_path=params.get("ffmpeg_path"),
                    cache_dir=params["cache_dir"],
                    cookies_path=params.get("cookies_path"),
                    aria2c_path=params.get("aria2c_path"),
                    deno_path=params.get("deno_path"),
                    po_token=params.get("po_token"),
                    ffmpeg_ld_path=params.get("ffmpeg_ld_path"),
                    nodejs_path=params.get("nodejs_path"),
                )
                data_dir = params["data_dir"]
                set_global_log_dir(data_dir + "/logs")
                global _log_queue
                log_queue = _queue_module.Queue()
                set_global_queue(log_queue)
                _log_queue = log_queue
                # Persistent rotating log (STEP 3B): server_logs.log + 30s
                # flush worker live alongside the legacy daily JSONL file.
                try:
                    init_persistent_logging(data_dir + "/logs")
                except Exception:
                    pass
        else:
            # Request/response middleware boundary (STEP 3B): latency,
            # sanitized payloads and full tracebacks via traced_request.
            _method = method
            _params = params

            def _dispatch():
                return _dispatch_method(_method, _params)

            try:
                std_log = get_std_logger()
            except Exception:
                std_log = None  # type: ignore[assignment]
            res = traced_request(
                str(method),
                params if isinstance(params, dict) else {},
                _dispatch,
                logger=std_log,
                engine_log=log,
            )

        response = {"id": req_id}
        if isinstance(res, dict) and res.get("success") is False:
            response["error"] = res
        else:
            response["result"] = res

        _write_stdout_line(json.dumps(response))

    except Exception as e:
        log.log_exception(e, f"Error processing {method}")
        try:
            persistent_flush()
        except Exception:
            pass
        # Opt-in auto-report (STEP 3C): gated by GRABLYTIC_AUTO_REPORT=1
        # inside notify_exception; never blocks the error response.
        try:
            from grablytic_engine.github_notifier import notify_exception

            notify_exception(e, context={"method": str(method)})
        except Exception:
            pass
        err_res = {
            "id": req_id,
            "error": {
                "success": False,
                "error_type": "ERROR_INTERNAL",
                "error_message": str(e),
            },
        }
        _write_stdout_line(json.dumps(err_res))


def _busy_envelope(req_id, _method) -> dict:
    """Explicit, retryable load-shed envelope (never a silent hang)."""
    return {
        "id": req_id,
        "error": {
            "success": False,
            "error_type": "ERROR_BUSY",
            "error_message": (
                f"Engine is busy ({_MAX_IPC_INFLIGHT} requests in flight); "
                "retry shortly"
            ),
            "recoverable": True,
            "retryable": True,
        },
    }


def _handle_cli(argv) -> bool:
    if len(argv) <= 1:
        return False
    command = argv[1]
    if command == "bootstrap":
        _write_stdout_line(json.dumps(bootstrap()))
    elif command == "formats" and len(argv) >= 3:
        _write_stdout_line(json.dumps(get_formats(argv[2])))
    else:
        _write_stdout_line(f"Unknown CLI command: {command}")
    return True


def _run_guarded_request(req_id, method, params, inflight) -> None:
    try:
        _execute_parsed_request(req_id, method, params)
    finally:
        try:
            inflight.release()
        except Exception:
            pass


def _report_ipc_parse_error(exc: Exception, method: str, req_id) -> None:
    log.log_exception(exc, f"Error processing {method}")
    try:
        persistent_flush()
    except Exception:
        pass
    try:
        from grablytic_engine.github_notifier import notify_exception

        notify_exception(exc, context={"method": str(method)})
    except Exception:
        pass
    _write_stdout_line(
        json.dumps(
            {
                "id": req_id,
                "error": {
                    "success": False,
                    "error_type": "ERROR_INTERNAL",
                    "error_message": str(exc),
                },
            }
        )
    )


def _parse_ipc_request(line: str):
    req_id = None
    method = "<unparsed>"
    params = {}
    if len(line) > _MAX_IPC_LINE_BYTES:
        raise ValueError(f"IPC line exceeds {_MAX_IPC_LINE_BYTES} bytes")
    request = json.loads(line)
    req_id = request.get("id")
    method = request.get("method")
    params = request.get("params", {})
    return req_id, method, params


def _dispatch_ipc_request(req_id, method, params, pool, inflight) -> None:
    if method in _FAST_IPC_METHODS or method == "paths/set":
        _execute_parsed_request(req_id, method, params)
        return
    if not inflight.acquire(blocking=False):
        try:
            log.warn(
                f"IPC load shed: {method} rejected, "
                f"{_MAX_IPC_INFLIGHT} requests already in flight"
            )
        except Exception:
            pass
        _write_stdout_line(json.dumps(_busy_envelope(req_id, method)))
        return
    try:
        pool.submit(_run_guarded_request, req_id, method, params, inflight)
    except Exception:
        try:
            inflight.release()
        except Exception:
            pass
        _write_stdout_line(json.dumps(_busy_envelope(req_id, method)))


def _process_ipc_line(line: str, pool, inflight) -> None:
    req_id = None
    method = "<unparsed>"
    params = {}
    try:
        req_id, method, params = _parse_ipc_request(line)
    except Exception as exc:
        _report_ipc_parse_error(exc, method, req_id)
        return
    _dispatch_ipc_request(req_id, method, params, pool, inflight)


def main():
    if _handle_cli(sys.argv):
        return
    install_stdout_firewall()
    threading.Thread(target=poll_queues, daemon=True).start()
    inflight = threading.BoundedSemaphore(_MAX_IPC_INFLIGHT)
    with _futures.ThreadPoolExecutor(
        max_workers=_MAX_IPC_WORKERS, thread_name_prefix="ipc"
    ) as pool:
        for line in sys.stdin:
            line = line.strip()
            if line:
                _process_ipc_line(line, pool, inflight)
    try:
        shutdown_downloads(timeout=5.0)
    except Exception:
        pass


if __name__ == "__main__":
    log.info("Engine started")
    main()
