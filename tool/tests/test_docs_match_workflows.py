"""The CI table in the docs has to match the workflow it describes.

Finding #114: `verify.yml` grew a `linux_build` job and `docs/building.md`
still said "Six jobs" and never listed it. Nothing in the repo compared the
two, so the drift was invisible to every gate. It is a test now.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "verify.yml"
BUILDING = ROOT / "docs" / "building.md"

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


def test_the_workflow_actually_has_jobs_to_check():
    # A regex that silently stops matching would make the two tests above pass.
    assert len(jobs()) >= 5
