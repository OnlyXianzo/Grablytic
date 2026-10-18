"""Auto-reports are PUBLIC GitHub issues: secrets must not ship in them.

A crash report is assembled from free text — an exception message, a
traceback, a log tail, a context dict. Any of those can embed a signed
URL, a proxy credential or a cookie. Redaction happens at `build_body()`,
the single point every payload passes through.
"""

import pytest


def _gn():
    import grablytic_engine.github_notifier as gn
    return gn


@pytest.mark.unit
def test_query_param_secrets_are_redacted():
    gn = _gn()
    for raw in [
        "https://youtu.be/x?token=abc123def&v=2",
        "https://youtu.be/x?sig=abc123def",
        "https://youtu.be/x?lsig=abc123def",
        "https://youtu.be/x?key=abc123def",
        "https://youtu.be/x?auth=abc123def",
        "https://youtu.be/x?password=hunter2",
        "https://youtu.be/x?po_token=abc123def",
        "https://youtu.be/x?signature=abc123def",
    ]:
        out = gn.redact_text(raw)
        assert "abc123def" not in out, out
        assert "hunter2" not in out, out


@pytest.mark.unit
def test_url_userinfo_password_is_redacted():
    gn = _gn()
    out = gn.redact_text("proxy http://alice:sup3rs3cret@10.0.0.1:8080")
    assert "sup3rs3cret" not in out
    assert "alice" in out


@pytest.mark.unit
def test_user_only_userinfo_is_untouched():
    gn = _gn()
    out = gn.redact_text("http://alice@example.com/x")
    assert "alice" in out


@pytest.mark.unit
def test_build_body_redacts_every_free_text_field():
    gn = _gn()
    body = gn.build_body(
        "crash in https://x.test/v?token=abcdef123456",
        repro="repro with password=hunter2",
        expected="nothing",
        actual="failed on https://y.test/v?sig=deadbeef99",
        stack="Traceback: https://z.test/v?key=cafebabe12",
        log_tail="proxy http://bob:letmein123@1.2.3.4:8080",
        context={"note": "cookie=sessionvalue123"},
        fp="abc123",
    )
    for secret in ("abcdef123456", "hunter2", "deadbeef99", "cafebabe12",
                   "letmein123", "sessionvalue123"):
        assert secret not in body, body


@pytest.mark.unit
def test_build_body_redacts_sensitive_context_keys():
    gn = _gn()
    body = gn.build_body("s", context={"api_key": "abcdef123456",
                                       "normal": "visible"})
    assert "abcdef123456" not in body
    assert "visible" in body


@pytest.mark.unit
def test_report_target_is_configurable(monkeypatch):
    gn = _gn()
    monkeypatch.setenv("GRABLYTIC_REPORT_REPO", "owner/fork")
    assert gn.target_repo() == "owner/fork"
    monkeypatch.setenv("GITHUB_REPO", "owner/generic")
    assert gn.target_repo() == "owner/fork"
    monkeypatch.delenv("GRABLYTIC_REPORT_REPO")
    assert gn.target_repo() == "owner/generic"
    monkeypatch.delenv("GITHUB_REPO")
    assert gn.target_repo() == gn.DEFAULT_REPO


@pytest.mark.unit
def test_log_tail_is_opt_out(monkeypatch):
    gn = _gn()
    monkeypatch.delenv("GRABLYTIC_REPORT_LOG_TAIL", raising=False)
    assert gn.log_tail_enabled() is True
    monkeypatch.setenv("GRABLYTIC_REPORT_LOG_TAIL", "0")
    assert gn.log_tail_enabled() is False


@pytest.mark.unit
def test_notify_exception_does_not_leak_secrets(monkeypatch):
    gn = _gn()
    monkeypatch.setenv("GITHUB_TOKEN", "")
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("GRABLYTIC_AUTO_REPORT", raising=False)

    class _Boom(Exception):
        pass

    exc = _Boom("failed fetching https://x.test/v?token=abcdef123456")
    res = gn.notify_exception(exc, summary="summary", auto_only=True)
    body = res.get("body", "")
    assert "abcdef123456" not in body
    assert "abcdef123456" not in res.get("title", "")
