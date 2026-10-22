"""The ratchet's two promises: a number means nothing without a reason, and
`--update` cannot be used to make a failure go away.

Finding #107: the engine budget was raised 234 -> 235 in the same commit as
the new `except Exception`, and the build passed with only a one-line JSON
change to show for the decision.
"""

import importlib.util
import json
import os

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "check_broad_catches.py",
)
_spec = importlib.util.spec_from_file_location("check_broad_catches", _MODULE_PATH)
cbc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cbc)


def test_parse_budget_reads_a_decoded_object():
    assert cbc._parse_budget({"a": 3, "b": {"limit": 4, "why": "why"}}) == {
        "a": (3, None),
        "b": (4, "why"),
    }
    assert cbc._parse_budget([1, 2]) == {}


def test_parse_entry_accepts_a_bare_integer():
    assert cbc._parse_entry(163) == (163, None)


def test_parse_entry_reads_a_limit_and_why():
    assert cbc._parse_entry({"limit": 235, "why": "because"}) == (235, "because")


def test_parse_entry_rejects_noise():
    assert cbc._parse_entry("235") == (None, None)
    assert cbc._parse_entry(True) == (None, None)
    assert cbc._parse_entry({"limit": "235"}) == (None, None)
    assert cbc._parse_entry({"limit": 235, "why": "   "}) == (235, None)


def test_raise_without_a_reason_is_refused():
    failures = cbc._raised_without_reason(
        {"python_except_exception_in_engine": 235},
        {"python_except_exception_in_engine": (234, None)},
    )
    assert failures and "without a 'why'" in failures[0]


def test_raise_with_a_reason_is_allowed():
    assert (
        cbc._raised_without_reason(
            {"python_except_exception_in_engine": 235},
            {"python_except_exception_in_engine": (234, "str() may raise")},
        )
        == []
    )


def test_reductions_never_need_a_reason():
    assert cbc._raised_without_reason({"a": 160}, {"a": (163, None)}) == []


def test_missing_entry_is_reported():
    failures = cbc._raised_without_reason({"a": 1}, {})
    assert failures and "no budget entry" in failures[0]


def test_serialise_keeps_a_reason_while_the_limit_is_unchanged(tmp_path):
    path = tmp_path / "budget.json"
    path.write_text(json.dumps({"a": {"limit": 5, "why": "kept"}, "b": 2}))

    data = cbc._serialise({"a": 5, "b": 2}, cbc._load_budget(str(path)))
    assert data["a"] == {"limit": 5, "why": "kept"}
    assert data["b"] == 2


def test_serialise_drops_the_reason_when_the_limit_moves(tmp_path):
    # #109: at 300 the file would still cite the argument written for 235.
    path = tmp_path / "budget.json"
    path.write_text(json.dumps({"a": {"limit": 235, "why": "written for 235"}}))

    data = cbc._serialise({"a": 300}, cbc._load_budget(str(path)))
    assert data["a"] == 300


def test_serialise_drops_the_reason_on_a_reduction(tmp_path):
    path = tmp_path / "budget.json"
    path.write_text(json.dumps({"a": {"limit": 235, "why": "written for 235"}}))

    data = cbc._serialise({"a": 200}, cbc._load_budget(str(path)))
    assert data["a"] == 200


def test_a_second_raise_needs_a_new_reason(tmp_path):
    """The whole point: one reason authorises one raise, not every later one."""
    path = tmp_path / "budget.json"
    path.write_text(json.dumps({"a": {"limit": 100, "why": "for the 100th"}}))

    first = cbc._serialise({"a": 120}, cbc._load_budget(str(path)))
    assert cbc._raised_without_reason({"a": 120}, cbc._parse_budget(first)) == []

    second = cbc._raised_without_reason({"a": 150}, cbc._parse_budget(first))
    assert second and "without a 'why'" in second[0]
