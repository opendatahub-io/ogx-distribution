#!/usr/bin/env python3
"""Parse JUnit XML results and append to history.json for the test report."""

import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from glob import glob
from pathlib import Path

FILENAME_RE = re.compile(
    r"results_(?P<provider>[^_]+(?:-[^_]+)*)_(?P<model>[^.]+)\.xml"
)


def parse_junit(xml_path: str) -> dict:
    """Parse a single JUnit XML file and return summary + per-test data."""
    tree = ET.parse(xml_path)
    root = tree.getroot()

    fname = Path(xml_path).name
    m = FILENAME_RE.match(fname)
    provider = m.group("provider") if m else "unknown"
    file_model = m.group("model") if m else "unknown"

    counts = {"passed": 0, "failed": 0, "skipped": 0, "error": 0}
    for suite in root.iter("testsuite"):
        for tc in suite.findall("testcase"):
            if tc.find("failure") is not None:
                counts["failed"] += 1
            elif tc.find("error") is not None:
                counts["error"] += 1
            elif tc.find("skipped") is not None:
                counts["skipped"] += 1
            else:
                counts["passed"] += 1

    return {"provider": provider, "model": file_model, **counts}


def main():
    results_dir = sys.argv[1]
    history_file = sys.argv[2]
    output_file = sys.argv[3]

    xml_files = sorted(glob(os.path.join(results_dir, "**", "*.xml"), recursive=True))
    if not xml_files:
        print("No JUnit XML files found", file=sys.stderr)
        sys.exit(0)

    models = []
    totals = {"passed": 0, "failed": 0, "skipped": 0, "error": 0}
    for xf in xml_files:
        entry = parse_junit(xf)
        models.append(entry)
        for k in totals:
            totals[k] += entry[k]

    run = {
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "run_number": os.environ.get("GITHUB_RUN_NUMBER", "0"),
        "run_id": os.environ.get("GITHUB_RUN_ID", "0"),
        "run_url": (
            f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', '')}"
            f"/actions/runs/{os.environ.get('GITHUB_RUN_ID', '0')}"
        ),
        "ogx_version": os.environ.get("OGX_VERSION", ""),
        "branch": os.environ.get("GITHUB_REF_NAME", ""),
        "commit": os.environ.get("GITHUB_SHA", "")[:8],
        "totals": totals,
        "models": models,
    }

    history = []
    if os.path.exists(history_file) and os.path.getsize(history_file) > 0:
        with open(history_file) as f:
            history = json.load(f)

    history.append(run)
    history = history[-20:]

    with open(output_file, "w") as f:
        json.dump(history, f, indent=2)

    print(f"Parsed {len(xml_files)} XML files, {sum(totals.values())} tests total")
    for m in models:
        print(
            f"  {m['provider']}/{m['model']}: {m['passed']}P {m['failed']}F {m['skipped']}S {m['error']}E"
        )


if __name__ == "__main__":
    main()
