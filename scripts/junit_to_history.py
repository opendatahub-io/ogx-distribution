#!/usr/bin/env python3
"""Parse JUnit XML results and append to history.json for the test report.

Uses ``junit_stats.parse_results`` for the actual XML parsing and then
builds a timestamped run entry for the trend-chart history file.

An optional fourth argument writes the raw stats dict to a JSON file
so downstream workflow steps (e.g. Slack notifications) can consume it
without re-parsing the XML.
"""

import json
import os
import sys
from datetime import datetime, timezone

from junit_stats import parse_results


def main():
    results_dir = sys.argv[1]
    history_file = sys.argv[2]
    output_file = sys.argv[3]
    stats_file = sys.argv[4] if len(sys.argv) > 4 else None

    stats = parse_results(results_dir)
    if stats is None:
        print("No JUnit XML files found, writing empty history", file=sys.stderr)
        history = []
        if os.path.exists(history_file) and os.path.getsize(history_file) > 0:
            with open(history_file) as f:
                history = json.load(f)
        with open(output_file, "w") as f:
            json.dump(history, f, indent=2)
        sys.exit(0)

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
        "totals": stats["totals"],
        "models": stats["models"],
    }

    history = []
    if os.path.exists(history_file) and os.path.getsize(history_file) > 0:
        with open(history_file) as f:
            history = json.load(f)
        for run_entry in history:
            run_entry["models"] = [
                m for m in run_entry["models"] if m["provider"] != "unknown"
            ]

    history.append(run)
    history = history[-20:]

    with open(output_file, "w") as f:
        json.dump(history, f, indent=2)

    if stats_file:
        with open(stats_file, "w") as f:
            json.dump(stats, f, indent=2)


if __name__ == "__main__":
    main()
