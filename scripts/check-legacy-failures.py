#!/usr/bin/env python3
"""Strict known-failure check for the frozen pre-v7 `self_service` target.

The mixed historical target `clients/core/tests/self_service.rs` holds 14
assertions that fail by design (REQ-MSG-005's historical-scope amendment; see
docs/operations/archival-ci-correction.md). They are listed by exact name in
scripts/ci-legacy-client-tests.txt and are neither fixed nor waived.

This script runs the WHOLE target without exclusions and passes only when
the observed result is exactly the documented one:

- every listed name ran and FAILED;
- every other test in the target ran and passed;
- nothing was ignored or filtered out, and cargo's own summary agrees with the
  parsed lines.

Anything else fails: a new failure, a listed test that now passes (update the
list in the same pull request), a missing or renamed test, or a build error.
Only the set of failing names is compared, not why each one fails. A green
result therefore means "the same listed tests fail and every other test
passes", never "the historical target passes" and never "each failure has the
same cause". The raw cargo exit and every failing name are printed, cargo's own
output is streamed as it runs, and the report goes to the Actions step summary.

Usage:
  python3 scripts/check-legacy-failures.py              # runs cargo
  python3 scripts/check-legacy-failures.py --log FILE --exit-code N   # offline
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LIST = ROOT / "scripts/ci-legacy-client-tests.txt"
COMMAND = [
    "cargo", "+1.98.1", "test", "--locked",
    "--manifest-path", "clients/core/Cargo.toml", "--test", "self_service",
]
LINE = re.compile(r"^test (\S+) \.\.\. (ok|FAILED|ignored)\s*$")
SUMMARY = re.compile(r"^test result: (?:ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored; "
                     r"(\d+) measured; (\d+) filtered out;")


def expected_names():
    names = [line.strip() for line in LIST.read_text().splitlines() if line.strip()]
    if len(names) != len(set(names)):
        raise SystemExit(f"duplicate names in {LIST}")
    return set(names)


def evaluate(output, exit_code, expected):
    """Return (ok, report_lines) for one cargo run of the self_service target."""
    results = {}
    problems = []
    summary = None
    for line in output.splitlines():
        match = LINE.match(line.strip())
        if match:
            name, status = match.groups()
            if name in results:
                problems.append(f"test reported twice: {name}")
            results[name] = status
            continue
        found = SUMMARY.match(line.strip())
        if found:
            if summary is not None:
                problems.append("more than one test summary: more than one test binary ran")
            *counts, measured, filtered = (int(value) for value in found.groups())
            summary = tuple(counts)
            if measured or filtered:
                problems.append(f"cargo reports {measured} measured and {filtered} filtered out: "
                                "the whole target must run unfiltered")
    failed = {name for name, status in results.items() if status == "FAILED"}
    passed = {name for name, status in results.items() if status == "ok"}
    ignored = {name for name, status in results.items() if status == "ignored"}
    if not results or summary is None:
        problems.append("no test results parsed: the target did not build or run")
    if summary is not None and summary != (len(passed), len(failed), len(ignored)):
        problems.append(f"cargo summary {summary} disagrees with parsed lines "
                        f"{(len(passed), len(failed), len(ignored))}")
    for name in sorted(expected - set(results)):
        problems.append(f"listed historical test did not run: {name}")
    for name in sorted(expected & passed):
        problems.append(f"listed historical test now passes: {name}. Remove it from "
                        "scripts/ci-legacy-client-tests.txt and update the count in "
                        "scripts/test-ci-wiring.py and docs/operations/ci.md in the same change")
    for name in sorted(failed - expected):
        problems.append(f"NEW failure outside the historical list: {name}")
    for name in sorted(ignored):
        problems.append(f"ignored test: {name}")
    if failed and exit_code == 0:
        problems.append("cargo exited 0 although tests failed")
    if not failed and exit_code != 0:
        problems.append(f"cargo exited {exit_code} with no failed test")
    report = [
        f"Raw cargo exit: {exit_code}",
        f"Passed: {len(passed)}; failed: {len(failed)} (expected {len(expected)} historical); "
        f"ignored: {len(ignored)}",
    ]
    report += [f"historical failure (retained, not fixed): {name}" for name in sorted(failed & expected)]
    report += [f"PROBLEM: {problem}" for problem in problems]
    report.append(f"RESULT: PASS (the same {len(expected)} listed tests fail; every other test passes)"
                  if not problems else "RESULT: FAIL")
    return not problems, report


def main():
    parser = argparse.ArgumentParser(
        description="Strict known-failure check for the frozen pre-v7 self_service target.")
    parser.add_argument("--log", type=Path, help="evaluate a saved cargo output instead of running cargo")
    parser.add_argument("--exit-code", type=int, help="cargo exit code for --log")
    args = parser.parse_args()
    if (args.log is None) != (args.exit_code is None):
        parser.error("--log and --exit-code go together")
    if args.log is not None:
        output, exit_code = args.log.read_text(), args.exit_code
    else:
        # Stream cargo's output while keeping it for evaluation, so a hung test
        # is visible in the job log before the job timeout ends it.
        lines = []
        with subprocess.Popen(COMMAND, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT) as process:
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                lines.append(line)
        output, exit_code = "".join(lines), process.returncode
    expected = expected_names()
    ok, report = evaluate(output, exit_code, expected)
    print("\n".join(report))
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write("### Legacy pre-v7 `self_service` history (exact known failures)\n\n")
            summary.write(f"Green means the same {len(expected)} listed tests fail and every other "
                          "test passes. They are not fixed, and their causes are not compared.\n\n")
            summary.write("\n".join(f"- {line}" for line in report) + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
