#!/usr/bin/env python3
"""Lint Bruno .bru files: verify each request file has at least one assertion block."""

import sys
from pathlib import Path

BRUNO_DIR = Path(__file__).resolve().parent.parent / "bruno" / "ogx-api"
SKIP = {"collection.bru"}
ASSERTION_MARKERS = ("tests {", "script:post-response")


def main():
    failures = []
    bru_files = sorted(BRUNO_DIR.rglob("*.bru"))
    bru_files = [
        f for f in bru_files if f.name not in SKIP and "environments" not in f.parts
    ]

    for path in bru_files:
        content = path.read_text()
        if not any(marker in content for marker in ASSERTION_MARKERS):
            failures.append(path.relative_to(BRUNO_DIR))

    if failures:
        print(f"Bruno files without assertions ({len(failures)}):")
        for f in failures:
            print(f"  {f}")
        sys.exit(1)

    print(f"All {len(bru_files)} Bruno request files have assertions.")


if __name__ == "__main__":
    main()
