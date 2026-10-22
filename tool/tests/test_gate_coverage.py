"""The gate scripts are themselves checked.

Finding #116: the docstring added in #113 wrote a raw-string example inside a
plain docstring. The `\\d` in it is not a valid escape, so every compile of
the gate emitted a warning about the gate's own prose: DeprecationWarning on
3.11, SyntaxWarning on 3.12 and later, and a SyntaxError in a future release.
CI was green because nothing turned warnings into errors.

Finding #118: the Ruff step's `src` was `engine/`, so every Python file in
`tool/` ran in CI without a linter behind it. The workflow points at both
trees now, and this file fails if that regresses.
"""

import py_compile
import re
import warnings
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tool"


def tool_modules() -> list[Path]:
    return sorted(p for p in TOOL.glob("*.py") if p.name != "__init__.py")


def test_every_tool_module_compiles_without_warnings(tmp_path):
    modules = tool_modules()
    # A glob that silently stops matching would make the loop vacuous.
    assert len(modules) >= 5, f"expected the gate scripts, found {modules}"

    offenders: list[str] = []
    for path in modules:
        with warnings.catch_warnings():
            warnings.simplefilter("error")
            try:
                py_compile.compile(
                    str(path),
                    cfile=str(tmp_path / f"{path.stem}.pyc"),
                    doraise=True,
                )
            except (Warning, py_compile.PyCompileError) as exc:
                # The warning is the finding; PyCompileError is how a
                # warning-as-error comes back out of py_compile.
                offenders.append(f"{path.name}: {exc}")

    assert not offenders, "tool modules emit compile warnings: " + "; ".join(offenders)


WORKFLOW = ROOT / ".github" / "workflows" / "verify.yml"


def test_the_ruff_gate_covers_the_tool_directory():
    # The gate that decides whether the build passes should be linted by the
    # same rules as the code it guards (#118). Plain text, not YAML: this
    # suite runs in the job that has no PyYAML.
    workflow = WORKFLOW.read_text(encoding="utf-8")
    step = re.search(
        r"name: Ruff correctness gate\n.*?args: \"([^\"]+)\"",
        workflow,
        re.DOTALL,
    )
    assert step, "the Ruff gate step is gone from verify.yml"
    src = re.search(r"src: \"([^\"]+)\"", workflow[step.start() : step.end() + 200])
    assert src, "the Ruff gate has no src"
    assert "tool/" in src.group(1).split(), f"Ruff src does not cover tool/: {src.group(1)}"
    assert "W605" in step.group(1), "the Ruff selection lost W605"
