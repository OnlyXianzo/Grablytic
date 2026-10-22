"""SEC-001: a crash report is a PUBLIC GitHub issue.

The scrubber knew `token=`, `Cookie:` headers and URL userinfo. It did not know
the three shapes `http.cookiejar` prints a cookie in, nor a Windows path past
its drive letter, so a traceback that formatted a jar or an `OSError` published
the session cookie and the account name.

Two halves: the exact shapes, and the shared corpus in
`test/fixtures/redaction_corpus.json`, which the Dart test runs too. A pattern
that stops matching here fails the Dart job as well, which is the point — the
two redactors feed one sink and used to be able to drift.
"""

import json
import time
from pathlib import Path

import pytest

SECRET = "SUPERSECRETVALUE"
CORPUS = (
    Path(__file__).resolve().parents[2] / "test" / "fixtures" / "redaction_corpus.json"
)


def _redact(text):
    from grablytic_engine.github_notifier import redact_text

    return redact_text(text)


@pytest.mark.unit
def test_cookiejar_repr_does_not_publish_the_cookie_value():
    out = _redact(
        f"Cookie(version=0, name='SID', value='{SECRET}', port=None, "
        "domain='.youtube.com')"
    )
    assert SECRET not in out
    # The fields a maintainer needs to tell which cookie leaked survive.
    assert "name='SID'" in out
    assert "domain='.youtube.com'" in out
    assert "value='***REDACTED***'" in out


@pytest.mark.unit
def test_cookiejar_str_does_not_publish_the_cookie_value():
    out = _redact(f"<Cookie SID={SECRET} for .youtube.com/>")
    assert SECRET not in out
    assert "for .youtube.com" in out


@pytest.mark.unit
def test_netscape_cookie_row_does_not_publish_the_cookie_value():
    out = _redact(f".youtube.com\tTRUE\t/\tTRUE\t0\tSID\t{SECRET}")
    assert SECRET not in out
    assert "SID" in out


@pytest.mark.unit
def test_a_value_outside_a_cookie_object_is_untouched():
    # Context, not a global `value=` rule: redacting every quoted value would
    # mangle ordinary diagnostics and tell nobody anything.
    text = "config value='keep-me' was rejected"
    assert _redact(text) == text


@pytest.mark.unit
@pytest.mark.parametrize(
    "path",
    [
        r"open('C:\Users\bob\Videos\x.mp4') failed",
        r"open('C:\\Users\\bob\\Videos\\x.mp4') failed",
        "open('C:/Users/bob/Videos/x.mp4') failed",
    ],
)
def test_windows_paths_do_not_publish_the_account_name(path):
    out = _redact(path)
    assert "bob" not in out
    assert "Users" not in out
    assert "failed" in out


@pytest.mark.unit
def test_posix_paths_are_still_removed():
    out = _redact("failed reading /home/alice/private/movie.mp4")
    assert "alice" not in out
    assert "movie.mp4" not in out


@pytest.mark.unit
def test_relative_documentation_links_survive():
    text = "see docs/building.md for details"
    assert _redact(text) == text


@pytest.mark.unit
def test_the_corpus_holds_for_the_engine_redactor():
    cases = json.loads(CORPUS.read_text(encoding="utf-8"))["cases"]
    assert len(cases) >= 10, "a truncated corpus must not pass vacuously"
    for case in cases:
        out = _redact(case["input"])
        for secret in case["must_not_contain"]:
            assert secret not in out, f"{case['name']}: leaked {secret!r} -> {out!r}"
        for keep in case.get("must_contain", []):
            assert keep in out, f"{case['name']}: lost {keep!r} -> {out!r}"


@pytest.mark.unit
@pytest.mark.parametrize(
    "payload",
    [
        "C:" + "\\" * 100_000,
        "/" + "/" * 100_000,
        "/" + "a/" * 50_000,
        "C:" + "\\a" * 50_000,
        "Cookie(" + "value='" * 20_000,
        ".youtube.com" + "\tTRUE\t/\tTRUE\t0\tSID\tx" * 20_000,
    ],
)
def test_hostile_text_is_redacted_in_linear_time(payload):
    """A redactor that backtracks is a redactor an attacker can stall.

    The path rules take runs of separators; overlapping quantifiers over those
    runs are the shape that goes exponential. One second is far above the
    measured ~40 ms for each of these and far below any blow-up.
    """
    started = time.perf_counter()
    _redact(payload)
    assert time.perf_counter() - started < 1.0
