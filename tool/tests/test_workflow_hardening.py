"""The workflows are code: pin what they run, state what their token may do,
and keep secrets out of the shell's syntax.

Finding #119: 45 `uses:` references pointed at mutable tags.
Finding #120: four of seven workflows declared no `permissions:` at all.
Finding #121: `${{ secrets.X }}` was interpolated straight into `run:` blocks,
so a `$` in a signing password became shell syntax.
"""

import os
import re

WORKFLOWS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    ".github",
    "workflows",
)

USES = re.compile(r"^\s*-?\s*uses:\s*(\S+)", re.MULTILINE)
PINNED = re.compile(r"^[^@]+@[0-9a-f]{40}$")
PERMISSIONS = re.compile(r"^permissions:", re.MULTILINE)


def workflow_files():
    return sorted(
        os.path.join(WORKFLOWS, name)
        for name in os.listdir(WORKFLOWS)
        if name.endswith((".yml", ".yaml"))
    )


def references():
    for path in workflow_files():
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for match in USES.finditer(text):
            line = text[: match.start()].count("\n") + 1
            yield os.path.basename(path), line, match.group(1)


def test_the_scanner_finds_the_references():
    # A regex that stopped matching would make the next test vacuous.
    assert len(list(references())) >= 20


def test_every_action_is_pinned_to_a_commit_sha():
    loose = [
        f"{name}:{line} {ref}"
        for name, line, ref in references()
        if not ref.startswith("./") and not PINNED.match(ref)
    ]
    assert not loose, "tag-pinned actions:\n  " + "\n  ".join(loose)


def test_every_workflow_declares_its_token_permissions():
    missing = [
        os.path.basename(path)
        for path in workflow_files()
        if not PERMISSIONS.search(open(path, encoding="utf-8").read())
    ]
    assert not missing, f"workflows with no permissions block: {missing}"


def run_blocks(path):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    index = 0
    while index < len(lines):
        match = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", lines[index])
        if not match:
            index += 1
            continue
        start = index + 1
        indent = len(match.group(1))
        inline = match.group(2).strip()
        if inline and inline not in ("|", ">", "|-", ">-"):
            yield start, inline
            index += 1
            continue
        block = []
        index += 1
        while index < len(lines):
            line = lines[index]
            if line.strip() and len(line) - len(line.lstrip()) <= indent:
                break
            block.append(line)
            index += 1
        yield start, "\n".join(block)


def test_no_secret_is_interpolated_into_a_shell_script():
    offenders = []
    for path in workflow_files():
        for line_no, block in run_blocks(path):
            for token in ("${{ secrets.", "${{ env."):
                if token in block:
                    offenders.append(f"{os.path.basename(path)}:{line_no} {token}")
    assert not offenders, (
        "`${{ }}` inside a run: block is substituted before the shell parses "
        "the script, so the value is syntax, not data. Put it in `env:` and "
        "reference `$VAR` (or `$env:VAR` in a PowerShell step). A quoted "
        "heredoc delimiter is the one place the substitution is needed; there "
        "is none today, and `printf` avoids it:\n  " + "\n  ".join(offenders)
    )


def test_the_secret_scanner_reads_run_blocks():
    # The guard above is only as good as this parser, so prove it sees a block.
    blocks = [block for path in workflow_files() for _line, block in run_blocks(path)]
    assert any("pytest" in block for block in blocks), "no run: blocks parsed"
