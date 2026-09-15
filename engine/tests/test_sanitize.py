"""T3-15: sanitize() must cover proxy userinfo creds in strings, terminate
on cyclic structures, and redact mapping-like proxies (Chaquopy Java maps
are not `dict` instances)."""

import pytest

from grablytic_engine.persistent import sanitize


@pytest.mark.unit
def test_userinfo_password_redacted_in_string():
    out = sanitize("fetch failed: http://user:s3cret@proxy:8080/x")
    assert "s3cret" not in out
    assert "user:***REDACTED***@proxy:8080" in out


@pytest.mark.unit
def test_user_only_host_untouched():
    out = sanitize("via http://user@proxy:8080/x")
    assert out == "via http://user@proxy:8080/x"


@pytest.mark.unit
def test_cyclic_dict_terminates():
    d: dict = {}
    d["self"] = d
    d["url"] = "http://x.test/v"
    out = sanitize(d)
    assert out["url"] == "http://x.test/v"
    assert out["self"] == "***CYCLIC***"


@pytest.mark.unit
def test_mapping_proxy_redacted():
    from collections.abc import Mapping

    class _JavaMapLike(Mapping):
        def __init__(self, data):
            self._data = data

        def __getitem__(self, k):
            return self._data[k]

        def __iter__(self):
            return iter(self._data)

        def __len__(self):
            return len(self._data)

    proxy = _JavaMapLike({"proxy": "http://user:pw@h:8080", "n": 1})
    assert not isinstance(proxy, dict)
    out = sanitize(proxy)
    assert out["n"] == 1
    assert "pw" not in str(out["proxy"])
