"""Make `import tool.<gate>` work however pytest was invoked.

The tests import the gate modules as `tool.check_*`, which only resolves when
the repository root is on `sys.path`. `python -m pytest` puts it there and a
bare `pytest` does not, so the suite passed locally and failed in CI with
"Interrupted: 1 error during collection" (#108 follow-up). The CI step runs
the bare form, so the root is added here rather than in the command line.
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

if ROOT not in sys.path:
    sys.path.insert(0, ROOT)
