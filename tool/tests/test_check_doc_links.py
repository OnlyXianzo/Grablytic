"""The doc-link checker has to see the link forms Markdown actually renders.

Finding #123: the destination pattern stopped at the first `)`, so a link to
`docs/weird(1).md` was reported as `./weird(1`, and the `<...>` form, the only
legal way to link to a path containing a space, was never matched at all.

Finding #124: reference-style links and `<a href>` were not checked, so a
broken link in either syntax merged green.

`CODE_OF_CONDUCT.md` already carries five reference definitions, so the syntax
is in use; they happen to point at absolute URLs today.
"""

import importlib.util
import os

import pytest

_MODULE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "check_doc_links.py",
)
_spec = importlib.util.spec_from_file_location("check_doc_links", _MODULE_PATH)
cdl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cdl)


def test_a_destination_may_contain_balanced_parentheses():
    assert list(cdl.link_targets("[x](./weird(1).md)")) == [("./weird(1).md", "")]


def test_an_angle_bracket_destination_may_contain_a_space():
    assert list(cdl.link_targets("[x](<./my file.md>)")) == [("./my file.md", "")]


def test_a_plain_destination_and_its_anchor():
    assert list(cdl.link_targets("[x](./a.md)")) == [("./a.md", "")]
    assert list(cdl.link_targets("[x](./a.md#frag)")) == [("./a.md", "frag")]


def test_a_remote_destination_is_returned_and_filtered_by_main():
    assert list(cdl.link_targets("[x](https://example.com/a)")) == [
        ("https://example.com/a", "")
    ]


def test_reference_definitions_resolve_case_insensitively():
    markdown = "[x][Ref]\n\n[ref]: ./nope.md\n"
    assert cdl.reference_definitions(markdown) == {"ref": "./nope.md"}
    assert cdl.reference_targets(markdown) == ["./nope.md"]


def test_an_undefined_reference_label_is_not_a_link():
    # CommonMark renders `[x][missing]` as literal text, so there is nothing
    # to check and nothing to report.
    assert cdl.reference_targets("[x][missing]\n") == []


def test_a_shorthand_reference_uses_its_own_text_as_the_label():
    # A definition target with a space needs the `<...>` form, same as inline.
    assert cdl.reference_targets("[ref][]\n\n[ref]: <./spaced name.md>\n") == [
        "./spaced name.md"
    ]
    assert cdl.reference_definitions("[ref]: <./spaced name.md>\n") == {
        "ref": "./spaced name.md"
    }


def test_an_html_anchor_is_read():
    assert cdl.html_targets('<a class="x" href="./gone.md">y</a>') == ["./gone.md"]


def _run(tmp_path, monkeypatch, files):
    doc = tmp_path / "docs"
    doc.mkdir()
    for name, text in files.items():
        (doc / name).write_text(text, encoding="utf-8")
    monkeypatch.setattr(cdl, "ROOT", str(tmp_path))
    return cdl.main()


def test_a_paren_path_that_exists_is_not_reported(tmp_path, monkeypatch, capsys):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "weird(1).md").write_text("# t\n", encoding="utf-8")
    (tmp_path / "docs" / "c.md").write_text("See [x](./weird(1).md).\n", encoding="utf-8")
    monkeypatch.setattr(cdl, "ROOT", str(tmp_path))
    assert cdl.main() == 0
    assert "weird(1" not in capsys.readouterr().out


def test_a_broken_angle_bracket_link_is_reported(tmp_path, monkeypatch, capsys):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "j.md").write_text("[x](<./my file.md>)\n", encoding="utf-8")
    monkeypatch.setattr(cdl, "ROOT", str(tmp_path))
    assert cdl.main() == 1
    assert "./my file.md" in capsys.readouterr().out


def test_a_broken_reference_link_is_reported(tmp_path, monkeypatch, capsys):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "a.md").write_text(
        "See [x][ref].\n\n[ref]: ./nope.md\n", encoding="utf-8"
    )
    monkeypatch.setattr(cdl, "ROOT", str(tmp_path))
    assert cdl.main() == 1
    assert "./nope.md" in capsys.readouterr().out


def test_a_broken_html_link_is_reported(tmp_path, monkeypatch, capsys):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "b.md").write_text(
        '<a href="./missing.md">x</a>\n', encoding="utf-8"
    )
    monkeypatch.setattr(cdl, "ROOT", str(tmp_path))
    assert cdl.main() == 1
    assert "./missing.md" in capsys.readouterr().out


def test_a_link_inside_a_fence_or_code_span_is_ignored(tmp_path, monkeypatch):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "d.md").write_text(
        "```\n[x](./nope.md)\n```\n\n`[y](./also-nope.md)`\n", encoding="utf-8"
    )
    monkeypatch.setattr(cdl, "ROOT", str(tmp_path))
    assert cdl.main() == 0


@pytest.mark.parametrize(
    "markdown",
    [
        "[x](./a.md)",
        "[x](<./a b.md>)",
        "[x][ref]\n\n[ref]: ./a.md",
        '<a href="./a.md">x</a>',
    ],
)
def test_every_supported_form_reports_a_missing_target(
    tmp_path, monkeypatch, capsys, markdown
):
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs" / "e.md").write_text(markdown, encoding="utf-8")
    monkeypatch.setattr(cdl, "ROOT", str(tmp_path))
    assert cdl.main() == 1
