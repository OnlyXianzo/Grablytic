import json
import queue
import re
import threading
import time
from pathlib import Path
from typing import Any

import pytest

from truestream_engine.logger import (
    DEBUG,
    ERROR,
    FATAL,
    INFO,
    WARN,
    EngineLogger,
    _loggers,
    get_logger,
    set_global_log_dir,
    set_global_queue,
)


@pytest.fixture(autouse=True)
def _reset_global_state() -> None:
    _loggers.clear()
    yield


@pytest.fixture
def log_queue() -> queue.Queue[dict[str, Any]]:
    return queue.Queue()


@pytest.fixture
def log_dir(tmp_path: Path) -> str:
    d = tmp_path / "logs"
    d.mkdir()
    return str(d)


def _drain(q: queue.Queue[dict[str, Any]]) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    while not q.empty():
        items.append(q.get_nowait())
    return items


# ---------------------------------------------------------------------------
# get_logger
# ---------------------------------------------------------------------------


class TestGetLogger:
    @pytest.mark.unit
    def test_same_name_returns_same_instance(self) -> None:
        a = get_logger("test")
        b = get_logger("test")
        assert a is b

    @pytest.mark.unit
    def test_different_names_return_different_instances(self) -> None:
        a = get_logger("alpha")
        b = get_logger("beta")
        assert a is not b

    @pytest.mark.unit
    def test_name_is_set_correctly(self) -> None:
        logger = get_logger("mylogger")
        assert logger.name == "mylogger"


# ---------------------------------------------------------------------------
# _log — event structure
# ---------------------------------------------------------------------------


class TestLogEventStructure:
    @pytest.mark.unit
    def test_event_contains_all_required_fields(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.info("hello world")

        event = q.get_nowait()
        assert event["type"] == "log"
        assert event["level"] == "INFO"
        assert event["logger"] == "test"
        assert event["message"] == "hello world"
        assert event["ts"].endswith("Z")
        assert isinstance(event["context"], dict)
        assert event["extra"] == {}
        assert event["trace_id"] is None
        assert event["duration_ms"] is None
        assert event["exception"] is None

    @pytest.mark.unit
    def test_event_includes_extra(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.info("msg", extra={"url": "https://example.com"})

        event = q.get_nowait()
        assert event["extra"] == {"url": "https://example.com"}

    @pytest.mark.unit
    def test_event_includes_duration_ms(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.info("msg", duration_ms=1234)

        event = q.get_nowait()
        assert event["duration_ms"] == 1234

    @pytest.mark.unit
    def test_event_includes_exception_repr(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        exc = ValueError("bad value")
        logger.info("msg", exception=exc)

        event = q.get_nowait()
        assert event["exception"] == repr(exc)

    @pytest.mark.unit
    def test_event_includes_context(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.set_context(trace_id="abc-123", user="alice")
        logger.info("msg")

        event = q.get_nowait()
        assert event["context"] == {"trace_id": "abc-123", "user": "alice"}
        assert event["trace_id"] == "abc-123"

    @pytest.mark.unit
    def test_correct_level_name_is_set(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.debug("d")
        logger.info("i")
        logger.warn("w")
        logger.error("e")
        logger.fatal("f")

        events = _drain(q)
        assert [e["level"] for e in events] == ["DEBUG", "INFO", "WARN", "ERROR", "FATAL"]

    @pytest.mark.unit
    def test_timestamp_format(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.info("msg")

        event = q.get_nowait()
        assert re.match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z", event["ts"])


# ---------------------------------------------------------------------------
# Log level filtering
# ---------------------------------------------------------------------------


class TestMinLevelFiltering:
    @pytest.mark.unit
    def test_below_min_level_not_queued(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(ERROR)

        logger.debug("skip this")
        logger.info("skip this too")
        logger.warn("also skip")

        assert q.empty()

    @pytest.mark.unit
    def test_at_and_above_min_level_queued(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(WARN)

        logger.warn("warn msg")
        logger.error("error msg")
        logger.fatal("fatal msg")

        events = _drain(q)
        assert len(events) == 3

    @pytest.mark.unit
    def test_set_min_level_live(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)

        logger.set_min_level(FATAL)
        logger.info("should not appear")

        logger.set_min_level(DEBUG)
        logger.info("should appear now")

        events = _drain(q)
        assert len(events) == 1
        assert events[0]["message"] == "should appear now"


# ---------------------------------------------------------------------------
# Thread-local context isolation
# ---------------------------------------------------------------------------


class TestThreadLocalContext:
    @pytest.mark.unit
    def test_context_isolated_between_threads(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        results: list[dict[str, Any]] = []

        def worker(thread_id: str) -> None:
            logger.set_context(thread=thread_id)
            logger.info("from thread")

        t1 = threading.Thread(target=worker, args=("A",))
        t2 = threading.Thread(target=worker, args=("B",))
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        events = _drain(q)
        contexts = [e["context"]["thread"] for e in events]
        assert sorted(contexts) == ["A", "B"]

    @pytest.mark.unit
    def test_main_thread_context_untouched_by_worker(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.set_context(thread="main")

        def worker() -> None:
            logger.set_context(thread="worker")
            logger.info("worker msg")

        t = threading.Thread(target=worker)
        t.start()
        t.join()

        logger.info("main msg")

        events = _drain(q)
        main_event = next(e for e in events if e["message"] == "main msg")
        assert main_event["context"]["thread"] == "main"


# ---------------------------------------------------------------------------
# set_context / clear_context
# ---------------------------------------------------------------------------


class TestContextManagement:
    @pytest.mark.unit
    def test_set_context_adds_fields(self) -> None:
        logger = EngineLogger("test")
        logger.set_context(trace_id="t1", user="bob")
        ctx = logger._context.data  # type: ignore[attr-defined]
        assert ctx == {"trace_id": "t1", "user": "bob"}

    @pytest.mark.unit
    def test_set_context_merges_with_existing(self) -> None:
        logger = EngineLogger("test")
        logger.set_context(trace_id="t1")
        logger.set_context(user="bob")
        ctx = logger._context.data  # type: ignore[attr-defined]
        assert ctx == {"trace_id": "t1", "user": "bob"}

    @pytest.mark.unit
    def test_set_context_overwrites_existing_key(self) -> None:
        logger = EngineLogger("test")
        logger.set_context(trace_id="t1")
        logger.set_context(trace_id="t2")
        ctx = logger._context.data  # type: ignore[attr-defined]
        assert ctx == {"trace_id": "t2"}

    @pytest.mark.unit
    def test_clear_context_removes_all_fields(self) -> None:
        logger = EngineLogger("test")
        logger.set_context(trace_id="t1", user="bob")
        logger.clear_context()
        assert not hasattr(logger._context, "data") or logger._context.data == {}

    @pytest.mark.unit
    def test_clear_context_on_empty_does_not_raise(self) -> None:
        logger = EngineLogger("test")
        logger.clear_context()

    @pytest.mark.unit
    def test_context_copied_not_mutated_by_log(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.set_context(trace_id="abc")
        logger.info("first")
        logger.clear_context()
        logger.info("second")

        events = _drain(q)
        assert events[0]["trace_id"] == "abc"
        assert events[1]["trace_id"] is None


# ---------------------------------------------------------------------------
# Queue forwarding
# ---------------------------------------------------------------------------


class TestQueueForwarding:
    @pytest.mark.unit
    def test_events_appear_on_queue(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.info("queued message")

        event = q.get_nowait()
        assert event["message"] == "queued message"

    @pytest.mark.unit
    def test_none_queue_disabled(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        logger.info("first")
        logger.set_queue(None)
        logger.info("second")

        events = _drain(q)
        assert len(events) == 1
        assert events[0]["message"] == "first"

    @pytest.mark.unit
    def test_queue_put_error_swallowed(self) -> None:
        logger = EngineLogger("test")

        class BrokenQueue(queue.Queue[dict[str, Any]]):
            def put(self, item: dict[str, Any], block: bool = True, timeout: float | None = None) -> None:
                raise RuntimeError("broken")

        logger.set_queue(BrokenQueue())
        logger.set_min_level(DEBUG)
        logger.info("should not raise")  # does not raise


# ---------------------------------------------------------------------------
# File writing
# ---------------------------------------------------------------------------


class TestFileWriting:
    @pytest.mark.unit
    def test_log_file_is_written(self, log_dir: str) -> None:
        logger = EngineLogger("test")
        logger.set_log_dir(log_dir)
        logger.set_min_level(DEBUG)

        logger.info("write me to disk")

        files = list(Path(log_dir).iterdir())
        assert len(files) == 1

        content = files[0].read_text()
        parsed = json.loads(content.strip())
        assert parsed["message"] == "write me to disk"

    @pytest.mark.unit
    def test_log_file_naming(self, log_dir: str) -> None:
        logger = EngineLogger("test")
        logger.set_log_dir(log_dir)
        logger.set_min_level(DEBUG)

        logger.info("msg")

        files = list(Path(log_dir).iterdir())
        assert re.match(r"engine_\d{4}-\d{2}-\d{2}\.txt", files[0].name)

    @pytest.mark.unit
    def test_multiple_events_appended(self, log_dir: str) -> None:
        logger = EngineLogger("test")
        logger.set_log_dir(log_dir)
        logger.set_min_level(DEBUG)

        logger.info("first")
        logger.info("second")

        files = list(Path(log_dir).iterdir())
        assert len(files) == 1
        lines = files[0].read_text().strip().splitlines()
        assert len(lines) == 2
        assert json.loads(lines[0])["message"] == "first"
        assert json.loads(lines[1])["message"] == "second"

    @pytest.mark.unit
    def test_level_filter_respected_for_file(self, log_dir: str) -> None:
        logger = EngineLogger("test")
        logger.set_log_dir(log_dir)
        logger.set_min_level(ERROR)

        logger.info("should not appear")
        logger.warn("should not appear either")
        logger.error("error only")

        files = list(Path(log_dir).iterdir())
        lines = files[0].read_text().strip().splitlines()
        assert len(lines) == 1
        assert json.loads(lines[0])["level"] == "ERROR"

    @pytest.mark.unit
    def test_log_dir_created_if_not_exists(self, tmp_path: Path) -> None:
        new_dir = str(tmp_path / "nonexistent" / "deep")
        logger = EngineLogger("test")
        logger.set_log_dir(new_dir)
        logger.set_min_level(DEBUG)

        logger.info("create path")

        assert Path(new_dir).is_dir()
        files = list(Path(new_dir).iterdir())
        assert len(files) == 1

    @pytest.mark.unit
    def test_log_dir_write_error_swallowed(self, tmp_path: Path) -> None:
        logger = EngineLogger("test")
        logger.set_log_dir(tmp_path)
        logger.set_min_level(DEBUG)

        logger.info("this is fine")
        assert True  # no exception

    @pytest.mark.unit
    def test_json_format(self, log_dir: str) -> None:
        logger = EngineLogger("test")
        logger.set_log_dir(log_dir)
        logger.set_min_level(DEBUG)

        logger.set_context(trace_id="t1")
        logger.info("json check", extra={"key": "val"})

        files = list(Path(log_dir).iterdir())
        event = json.loads(files[0].read_text().strip())
        assert event["type"] == "log"
        assert event["level"] == "INFO"
        assert event["logger"] == "test"
        assert event["message"] == "json check"
        assert event["context"] == {"trace_id": "t1"}
        assert event["extra"] == {"key": "val"}
        assert event["trace_id"] == "t1"

    @pytest.mark.unit
    def test_daily_rotation(self, log_dir: str) -> None:
        logger = EngineLogger("test")
        logger.set_log_dir(log_dir)
        logger.set_min_level(DEBUG)

        logger.info("day one file")

        files = list(Path(log_dir).iterdir())
        assert len(files) == 1
        name = files[0].name
        assert name.startswith("engine_")
        assert name.endswith(".txt")
        assert re.match(r"engine_\d{4}-\d{2}-\d{2}\.txt", name)


# ---------------------------------------------------------------------------
# Global propagation
# ---------------------------------------------------------------------------


class TestGlobalPropagation:
    @pytest.mark.unit
    def test_set_global_log_dir_propagates(self, log_dir: str) -> None:
        a = get_logger("a")
        b = get_logger("b")
        assert a._log_dir is None
        assert b._log_dir is None

        set_global_log_dir(log_dir)

        assert a._log_dir == log_dir
        assert b._log_dir == log_dir

    @pytest.mark.unit
    def test_set_global_queue_propagates(self) -> None:
        a = get_logger("a")
        b = get_logger("b")
        q: queue.Queue[dict[str, Any]] = queue.Queue()

        set_global_queue(q)

        assert a._queue is q
        assert b._queue is q

    @pytest.mark.unit
    def test_set_global_queue_none_disables_all(self) -> None:
        a = get_logger("a")
        b = get_logger("b")
        set_global_queue(None)

        assert a._queue is None
        assert b._queue is None


# ---------------------------------------------------------------------------
# trace context manager
# ---------------------------------------------------------------------------


class TestTrace:
    @pytest.mark.unit
    def test_trace_logs_ok(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        with logger.trace("my_op"):
            pass

        events = _drain(q)
        assert len(events) == 1
        assert events[0]["message"] == "my_op OK"
        assert events[0]["level"] == "DEBUG"
        assert isinstance(events[0]["duration_ms"], int)
        assert events[0]["duration_ms"] >= 0

    @pytest.mark.unit
    def test_trace_logs_failed_on_exception(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        class CustomError(Exception):
            pass

        with pytest.raises(CustomError):
            with logger.trace("failing_op"):
                raise CustomError("boom")

        events = _drain(q)
        assert len(events) == 1
        assert events[0]["message"] == "failing_op FAILED"
        assert events[0]["level"] == "ERROR"
        assert isinstance(events[0]["duration_ms"], int)
        assert events[0]["exception"] is not None

    @pytest.mark.unit
    def test_trace_records_duration(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        with logger.trace("slow_op"):
            time.sleep(0.05)

        events = _drain(q)
        assert events[0]["duration_ms"] >= 40

    @pytest.mark.unit
    def test_trace_uses_custom_level(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        with logger.trace("important", level=INFO):
            pass

        events = _drain(q)
        assert events[0]["level"] == "INFO"

    @pytest.mark.unit
    def test_trace_uses_default_level(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        with logger.trace("default_level"):
            pass

        events = _drain(q)
        assert events[0]["level"] == "DEBUG"

    @pytest.mark.unit
    def test_trace_re_raises_original_exception(self) -> None:
        logger = EngineLogger("test")

        with pytest.raises(ValueError, match="boom"):
            with logger.trace("op"):
                raise ValueError("boom")


# ---------------------------------------------------------------------------
# log_exception
# ---------------------------------------------------------------------------


class TestLogException:
    @pytest.mark.unit
    def test_logs_exception_traceback(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        try:
            raise ValueError("something broke")
        except ValueError as e:
            logger.log_exception(e, "operation failed")

        events = _drain(q)
        assert len(events) == 1
        assert events[0]["level"] == "ERROR"
        assert "operation failed: something broke" in events[0]["message"]
        assert events[0]["exception"] == repr(ValueError("something broke"))

    @pytest.mark.unit
    def test_logs_exception_without_message(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        exc = ValueError("just the exception")
        logger.log_exception(exc)

        events = _drain(q)
        assert len(events) == 1
        assert events[0]["message"] == "just the exception"

    @pytest.mark.unit
    def test_logs_exception_at_custom_level(self) -> None:
        logger = EngineLogger("test")
        q: queue.Queue[dict[str, Any]] = queue.Queue()
        logger.set_queue(q)
        logger.set_min_level(DEBUG)

        exc = ValueError("warn level exception")
        logger.log_exception(exc, "custom level", level=WARN)

        events = _drain(q)
        assert events[0]["level"] == "WARN"
