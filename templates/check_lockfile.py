#!/usr/bin/env python3
"""Verify that a uv-pip-compiled lockfile is in sync with its source.

Re-runs `uv pip compile <requirements>` and diffs the result against the
committed `<lockfile>`. Comments, blank lines, and pip-compile "via …"
annotation lines are stripped before comparison.

Outputs a JUnit-style XML report when --xunit-output is given so colcon test
can surface the failure.
"""
from __future__ import annotations

import argparse
import difflib
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# pip-compile / uv emit lines like "    # via foo" to record provenance.
# These are informative-only and should be ignored when comparing locks.
_VIA_RE = re.compile(r"^\s*#\s*via\b.*$")
_HEADER_COMMENT_RE = re.compile(r"^\s*#")
_BLANK_RE = re.compile(r"^\s*$")


def _normalize(content: str) -> list[str]:
    out: list[str] = []
    for raw in content.splitlines():
        line = raw.rstrip()
        if _BLANK_RE.match(line):
            continue
        if _VIA_RE.match(line):
            continue
        if _HEADER_COMMENT_RE.match(line):
            continue
        # Strip inline trailing comments (after the spec) for robustness.
        if " #" in line:
            line = line.split(" #", 1)[0].rstrip()
        out.append(line)
    return sorted(out)


def _compile(uv: str, requirements: Path, cache_dir: Path | None) -> str:
    cmd = [uv, "pip", "compile", "--no-header", "--annotation-style", "line", str(requirements)]
    if cache_dir is not None:
        cmd[2:2] = ["--cache-dir", str(cache_dir)]
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"uv pip compile failed (rc={proc.returncode}):\n{proc.stderr}"
        )
    return proc.stdout


def _write_xunit(path: Path, test_name: str, message: str | None) -> None:
    failed = message is not None
    suite = ET.Element(
        "testsuite",
        name=test_name,
        tests="1",
        failures="1" if failed else "0",
        errors="0",
    )
    case = ET.SubElement(
        suite, "testcase", name=test_name, classname="ament_uv_virtualenv"
    )
    if failed:
        ET.SubElement(case, "failure", message="lockfile out of sync").text = message
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(str(path), encoding="utf-8", xml_declaration=True)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--uv", required=True, help="Path to the uv executable.")
    p.add_argument("--requirements", required=True, type=Path)
    p.add_argument("--lockfile", required=True, type=Path)
    p.add_argument("--uv-cache", type=Path, default=None)
    p.add_argument("--xunit-output", type=Path, default=None)
    p.add_argument("--test-name", default="ament_uv_lockfile_check")
    args = p.parse_args()

    if not args.requirements.exists():
        msg = f"REQUIREMENTS not found: {args.requirements}"
        print(msg, file=sys.stderr)
        if args.xunit_output is not None:
            _write_xunit(args.xunit_output, args.test_name, msg)
        return 2

    if not args.lockfile.exists():
        msg = (
            f"LOCKFILE not found: {args.lockfile}\n"
            f"Generate it via: colcon build --cmake-target "
            f"{os.environ.get('AMENT_CURRENT_PREFIX', '<pkg>')}_lock_virtualenv"
        )
        print(msg, file=sys.stderr)
        if args.xunit_output is not None:
            _write_xunit(args.xunit_output, args.test_name, msg)
        return 2

    try:
        generated = _compile(args.uv, args.requirements, args.uv_cache)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        if args.xunit_output is not None:
            _write_xunit(args.xunit_output, args.test_name, str(e))
        return 2

    committed = args.lockfile.read_text()

    diff = list(
        difflib.unified_diff(
            _normalize(committed),
            _normalize(generated),
            fromfile=str(args.lockfile),
            tofile="(re-resolved from " + str(args.requirements) + ")",
            lineterm="",
        )
    )

    if not diff:
        if args.xunit_output is not None:
            _write_xunit(args.xunit_output, args.test_name, None)
        print(f"OK: {args.lockfile} is in sync with {args.requirements}")
        return 0

    msg_lines = [
        f"{args.lockfile} is out of sync with {args.requirements}.",
        "Re-resolving would produce different pins; commit the new lockfile via:",
        f"  colcon build --cmake-target {os.environ.get('PROJECT_NAME', '<pkg>')}_lock_virtualenv",
        "",
        "Diff:",
        *diff,
    ]
    msg = "\n".join(msg_lines)
    print(msg, file=sys.stderr)
    if args.xunit_output is not None:
        _write_xunit(args.xunit_output, args.test_name, msg)
    return 1


if __name__ == "__main__":
    sys.exit(main())
