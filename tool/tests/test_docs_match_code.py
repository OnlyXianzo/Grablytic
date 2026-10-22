"""The tables in the docs have to match the code they describe.

Finding #114: `verify.yml` grew a `linux_build` job, `docs/building.md`
still said "Six jobs" and never listed it, and the table in `README.md`
stopped one job short too. Nothing in the repo compared the tables with the
workflow, so the drift was invisible to every gate. The same page's IPC
table was five methods behind `contract.METHODS`. Both drifts are tests now.
"""

import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "verify.yml"
BUILDING = ROOT / "docs" / "building.md"
README = ROOT / "README.md"
ARCHITECTURE = ROOT / "docs" / "architecture.md"
CONTRACT = ROOT / "engine" / "grablytic_engine" / "contract.py"

COUNTS = {
    1: "One",
    2: "Two",
    3: "Three",
    4: "Four",
    5: "Five",
    6: "Six",
    7: "Seven",
    8: "Eight",
    9: "Nine",
}

JOB = re.compile(r"^  ([a-z][a-z0-9_]*):\s*\n    name:\s*(.+)$", re.MULTILINE)
STATED = re.compile(r"Triggers on every push and PR\. (\w+) jobs:")


def jobs() -> list[tuple[str, str]]:
    return JOB.findall(WORKFLOW.read_text(encoding="utf-8"))


def building_docs() -> str:
    return BUILDING.read_text(encoding="utf-8")


def readme() -> str:
    return README.read_text(encoding="utf-8")


def table_heading(job_name: str) -> str:
    """The name a table row would use.

    "Python Engine Tests (3.11 / 3.12)" -> "Python Engine Tests"
    "Android API 35 — Flutter → …"      -> "Android API 35"
    """
    return re.split(r"\s+[(\u2014]", job_name, maxsplit=1)[0].strip()


def test_the_stated_job_count_matches_the_workflow():
    stated = STATED.search(building_docs())
    assert stated, "the 'N jobs' sentence is gone; update this test with the docs"
    assert stated.group(1) == COUNTS.get(len(jobs())), (
        f"docs/building.md says {stated.group(1)}, verify.yml defines {len(jobs())}"
    )


def test_every_job_has_a_row_in_the_docs_table():
    docs = building_docs()
    missing = [
        name for _key, name in jobs() if f"| {table_heading(name)} |" not in docs
    ]
    assert not missing, f"jobs with no row in docs/building.md: {missing}"


def test_every_job_has_a_row_in_the_readme_table():
    text = readme()
    missing = [
        name for _key, name in jobs() if f"| {table_heading(name)} |" not in text
    ]
    assert not missing, f"jobs with no row in the README CI table: {missing}"


def contract_methods() -> list[str]:
    """The method names in `contract.METHODS`, read without importing.

    `tool/tests` runs from the repo root, and the engine package is only
    importable after `pip install -e engine/`. Parsing keeps this test
    runnable with a bare `pytest tool/tests`.
    """
    tree = ast.parse(CONTRACT.read_text(encoding="utf-8"))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            getattr(t, "id", None) == "METHODS" for t in node.targets
        ):
            return list(ast.literal_eval(node.value))
    raise AssertionError("METHODS is gone from contract.py")


HEADING = re.compile(r"^#{1,6} ", re.MULTILINE)
ROW = re.compile(r"^\|([^|]*)\|", re.MULTILINE)


def ipc_table_rows(markdown: str) -> list[str]:
    """First-column text of the rows in the IPC channel table.

    Scoped to the `### Channels` table on purpose. Finding #117: this used to
    be a substring search over the whole page, so one prose sentence that
    named a method satisfied it while the row a contributor reads was gone.
    """
    start = markdown.find("### Channels")
    assert start != -1, "docs/architecture.md has no '### Channels' heading"
    rest = markdown[start:]
    end = HEADING.search(rest, len("### Channels"))
    section = rest[: end.start()] if end else rest
    return ROW.findall(section)


def test_every_contract_method_has_an_ipc_table_row():
    rows = ipc_table_rows(ARCHITECTURE.read_text(encoding="utf-8"))
    # A table that stopped parsing would make the assertion below vacuous.
    assert len(rows) >= 10, f"parsed only {len(rows)} IPC rows"
    documented = set()
    for cell in rows:
        documented.update(re.findall(r"`([^`]+)`", cell))
    missing = [m for m in contract_methods() if m not in documented]
    assert not missing, f"methods with no row in the IPC table: {missing}"


def test_the_workflow_actually_has_jobs_to_check():
    # A regex that silently stops matching would make the two tests above pass.
    assert len(jobs()) >= 5
