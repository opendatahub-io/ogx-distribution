"""Parse JUnit XML results into structured test statistics.

Provides ``parse_results`` to scan a directory of JUnit XML files and
return aggregated test statistics.  Used as a library by
``junit_to_history.py`` to build the history file and optional stats
artifact.

Filename convention
-------------------
Each XML file is expected to match ``results_<provider>_<model>.xml``.
Files that don't match are silently skipped.

Return value of ``parse_results``
---------------------------------
``None`` when no valid results are found, otherwise a dict::

    {
        "models": [
            {"provider": "openai", "model": "gpt-4o-mini",
             "passed": 28, "failed": 2, "skipped": 0, "error": 0},
            ...
        ],
        "totals": {"passed": 142, "failed": 5, "skipped": 3, "error": 0},
        "providers": 3,
        "total": 150,
        "pass_pct": "94.7",
    }
"""

import os
import re
import xml.etree.ElementTree as ET
from glob import glob
from pathlib import Path

FILENAME_RE = re.compile(r"results_(?P<provider>[^_]+(?:-[^_]+)*)_(?P<model>.+)\.xml")


def parse_results(results_dir: str) -> dict | None:
    """Scan *results_dir* for JUnit XML files and return aggregated stats.

    Returns ``None`` when no matching XML files are found or all files
    have unrecognised filenames.
    """
    xml_files = sorted(glob(os.path.join(results_dir, "**", "*.xml"), recursive=True))
    if not xml_files:
        return None

    models = []
    totals = {"passed": 0, "failed": 0, "skipped": 0, "error": 0}

    for xml_path in xml_files:
        m = FILENAME_RE.match(Path(xml_path).name)
        if not m:
            continue

        counts = {"passed": 0, "failed": 0, "skipped": 0, "error": 0}
        tree = ET.parse(xml_path)
        for suite in tree.getroot().iter("testsuite"):
            for tc in suite.findall("testcase"):
                if tc.find("failure") is not None:
                    counts["failed"] += 1
                elif tc.find("error") is not None:
                    counts["error"] += 1
                elif tc.find("skipped") is not None:
                    counts["skipped"] += 1
                else:
                    counts["passed"] += 1

        entry = {"provider": m.group("provider"), "model": m.group("model"), **counts}
        models.append(entry)
        for k in totals:
            totals[k] += counts[k]

    if not models:
        return None

    total = sum(totals.values())
    providers = len(set(e["provider"] for e in models))
    pct = f"{totals['passed'] / total * 100:.1f}" if total else "0.0"

    return {
        "models": models,
        "totals": totals,
        "providers": providers,
        "total": total,
        "pass_pct": pct,
    }
