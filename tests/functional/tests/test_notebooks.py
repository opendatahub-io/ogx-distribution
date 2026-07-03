"""
Run Jupyter notebooks as tests: verify each notebook executes to completion without
unhandled exceptions. Uses pytest + nbformat + nbconvert (ExecutePreprocessor).
See: https://blog.iqmo.com/blog/python/jupyter_notebook_testing/
"""

import pytest
from pathlib import Path
import nbformat
from nbconvert.preprocessors import ExecutePreprocessor

REPO_ROOT = Path(__file__).resolve().parent.parent
NOTEBOOK_DIR = REPO_ROOT / "notebooks"
# Notebooks to skip (e.g. long-running, demo-only, or replaced by split test notebooks)
SKIP_NOTEBOOKS = []
TIMEOUT = 600  # seconds per notebook


def _collect_notebooks():
    if not NOTEBOOK_DIR.exists():
        return []
    return [
        f for f in sorted(NOTEBOOK_DIR.glob("*.ipynb")) if f.name not in SKIP_NOTEBOOKS
    ]


@pytest.mark.parametrize("notebook", _collect_notebooks(), ids=lambda p: p.name)
def test_notebook_execution(notebook: Path):
    """Run notebook to completion; fail on any unhandled exception."""
    with open(notebook) as f:
        nb = nbformat.read(f, as_version=4)
    assert any("assert " in c.source for c in nb.cells if c.cell_type == "code"), (
        f"{notebook.name} has no assert statements"
    )
    ep = ExecutePreprocessor(timeout=TIMEOUT)
    ep.preprocess(nb)
