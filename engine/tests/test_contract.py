"""The engine <-> host IPC contract is versioned and enforced.

A host and an engine from different builds could disagree about a field
name, a method name or an error code, and the mismatch surfaced as a
silent null or a KeyError in the middle of a download. The contract is
now versioned, and the dispatch chain is a registry.
"""

import pytest


def _main():
    import grablytic_engine.__main__ as main_mod
    return main_mod


def _contract():
    import grablytic_engine.contract as contract_mod
    return contract_mod


# ──────────────────────────────────────────────────────────── the contract

@pytest.mark.unit
def test_contract_info_describes_the_contract():
    info = _contract().contract_info()
    assert info["success"] is True
    assert info["contract_major"] == 1
    assert info["contract_minor"] == 0
    assert info["contract_version_string"] == "1.0"
    assert "engine/bootstrap" in info["methods"]


@pytest.mark.unit
def test_the_registry_and_the_contract_agree():
    main = _main()
    assert set(main._METHOD_HANDLERS) == set(_contract().METHODS)


@pytest.mark.unit
def test_every_contract_method_has_a_handler():
    main = _main()
    for method in _contract().METHODS:
        assert callable(main._METHOD_HANDLERS.get(method)), method


@pytest.mark.unit
@pytest.mark.parametrize("raw,expected", [
    (1, (1, 0)),
    ("1", (1, 0)),
    ("1.0", (1, 0)),
    ("2.3", (2, 3)),
    (None, None),
    ("", None),
    ("x", None),
    (True, None),
    (1.5, None),
])
def test_version_parsing(raw, expected):
    assert _contract().parse_version(raw) == expected


# ─────────────────────────────────────────────────────────── negotiation

@pytest.mark.unit
def test_a_request_without_a_version_is_accepted():
    """A host that predates the contract still works."""
    main = _main()
    assert main._negotiate_contract({}) is None
    assert main._negotiate_contract({"contract_version": None}) is None


@pytest.mark.unit
def test_a_matching_version_is_accepted():
    main = _main()
    assert main._negotiate_contract({"contract_version": 1}) is None
    assert main._negotiate_contract({"contract_version": "1.0"}) is None


@pytest.mark.unit
def test_a_mismatched_major_version_is_refused():
    main = _main()
    res = main._negotiate_contract({"contract_version": 2})
    assert res is not None
    assert res["success"] is False
    assert res["error_type"] == "ERROR_CONTRACT_MISMATCH"
    assert res["expected_contract_version"] == 1


@pytest.mark.unit
def test_a_garbage_version_is_refused():
    main = _main()
    res = main._negotiate_contract({"contract_version": "banana"})
    assert res is not None
    assert res["error_type"] == "ERROR_CONTRACT_MISMATCH"


# ───────────────────────────────────────────────────────── the dispatch

@pytest.mark.unit
def test_an_unknown_method_is_reported():
    main = _main()
    res = main._dispatch_method("nope/nope", {})
    assert res["success"] is False
    assert res["error_type"] == "ERROR_UNKNOWN_METHOD"


@pytest.mark.unit
def test_a_missing_required_parameter_is_reported():
    """The old chain raised KeyError: no envelope came back at all and
    the client waited forever."""
    main = _main()
    res = main._dispatch_method("download/start", {})
    assert res["success"] is False
    assert res["error_type"] == "ERROR_INVALID_PARAM"
    assert "url" in res["error_message"]


@pytest.mark.unit
def test_a_null_required_parameter_is_reported():
    main = _main()
    res = main._dispatch_method("download/start",
                                {"url": None, "download_id": "x"})
    assert res["error_type"] == "ERROR_INVALID_PARAM"


@pytest.mark.unit
def test_the_contract_method_answers():
    main = _main()
    res = main._dispatch_method("engine/contract", {})
    assert res["success"] is True
    assert res["contract_version_string"] == "1.0"
