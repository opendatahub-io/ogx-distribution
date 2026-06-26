#!/usr/bin/env python3
"""Parse Bruno CLI JSON output, print summary, optionally write JUnit XML.

Bruno CLI v3 counts only declarative `tests {}` / `assert {}` blocks in its
summary table.  Tests written in `script:post-response` (which is what we use)
land in `postResponseTestResults` and are silently ignored by the counter.

Usage:
  bruno-summary.py <results.json> [junit-output.xml]

Exit code: 0 if all pass, 1 if any fail.
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def write_junit_xml(iterations, xml_path):
    """Write JUnit XML from parsed Bruno results."""
    testsuites = ET.Element("testsuites")
    suite = ET.SubElement(testsuites, "testsuite", name="bruno-crud")

    total_tests = total_failures = total_errors = 0

    for iteration in iterations:
        for result in iteration.get("results", []):
            name = result.get("path") or result.get("name", "unknown")
            resp = result.get("response", {})
            runtime = f"{resp.get('responseTime', 0) / 1000:.3f}"

            for bucket in (
                "postResponseTestResults",
                "testResults",
                "preRequestTestResults",
            ):
                for t in result.get(bucket, []):
                    total_tests += 1
                    desc = t.get("description", "unnamed assertion")
                    tc = ET.SubElement(
                        suite, "testcase", name=desc, classname=name, time=runtime
                    )
                    if t.get("status") != "pass":
                        total_failures += 1
                        fail = ET.SubElement(
                            tc, "failure", message=desc, type="AssertionError"
                        )
                        fail.text = t.get("error", desc)

            if result.get("error"):
                total_tests += 1
                total_errors += 1
                tc = ET.SubElement(
                    suite,
                    "testcase",
                    name=f"{name} (request error)",
                    classname=name,
                    time=runtime,
                )
                err = ET.SubElement(
                    tc, "error", message=str(result["error"]), type="RequestError"
                )
                err.text = str(result["error"])

    suite.set("tests", str(total_tests))
    suite.set("failures", str(total_failures))
    suite.set("errors", str(total_errors))

    Path(xml_path).parent.mkdir(parents=True, exist_ok=True)
    tree = ET.ElementTree(testsuites)
    ET.indent(tree, space="  ")
    tree.write(xml_path, xml_declaration=True, encoding="unicode")


def main():
    if len(sys.argv) < 2:
        print("Usage: bruno-summary.py <results.json> [junit.xml]", file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1]) as f:
        data = json.load(f)

    iterations = data if isinstance(data, list) else [data]

    requests_pass = requests_fail = 0
    tests_pass = tests_fail = 0
    failures = []

    for iteration in iterations:
        for result in iteration.get("results", []):
            name = result.get("path") or result.get("name", "?")
            status = result.get("status", "unknown")

            if status == "pass":
                requests_pass += 1
            else:
                requests_fail += 1

            for bucket in (
                "postResponseTestResults",
                "testResults",
                "preRequestTestResults",
            ):
                for t in result.get(bucket, []):
                    if t.get("status") == "pass":
                        tests_pass += 1
                    else:
                        tests_fail += 1
                        failures.append(f"  FAIL  {name}: {t.get('description', '?')}")

            if result.get("error"):
                failures.append(f"  ERR   {name}: {result['error']}")

    total_requests = requests_pass + requests_fail
    total_tests = tests_pass + tests_fail
    ok = requests_fail == 0 and tests_fail == 0

    # Write JUnit XML if output path provided
    xml_path = sys.argv[2] if len(sys.argv) > 2 else None
    if xml_path:
        write_junit_xml(iterations, xml_path)
        print(f"  JUnit XML:  {xml_path}")

    print()
    print(f"  Requests:   {requests_pass}/{total_requests} passed")
    print(f"  Assertions: {tests_pass}/{total_tests} passed")
    print(f"  Status:     {'PASS' if ok else 'FAIL'}")

    if failures:
        print()
        for line in failures:
            print(line)

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
