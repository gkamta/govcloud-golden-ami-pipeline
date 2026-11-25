#!/usr/bin/env python3
"""Parse an OpenSCAP XCCDF results document and fail on CAT I findings."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

NS = {"x": "http://checklists.nist.gov/xccdf/1.2"}


def main() -> int:
    parser = argparse.ArgumentParser(description="OpenSCAP CAT I/II gate")
    parser.add_argument("results_xml")
    parser.add_argument("summary_path")
    parser.add_argument("--fail-on-cat2", action="store_true")
    args = parser.parse_args()

    tree = ET.parse(args.results_xml)
    failed = {"high": 0, "medium": 0, "low": 0, "unknown": 0}
    for rr in tree.findall(".//x:rule-result", NS):
        result = (rr.findtext("x:result", default="", namespaces=NS) or "").strip()
        if result != "fail":
            continue
        sev = (rr.get("severity") or "unknown").lower()
        failed[sev] = failed.get(sev, 0) + 1

    lines = [
        "OpenSCAP DISA STIG profile results",
        f"  CAT I  (high):   {failed.get('high', 0)} failed",
        f"  CAT II (medium): {failed.get('medium', 0)} failed",
        f"  CAT III(low):    {failed.get('low', 0)} failed",
        f"  unknown:         {failed.get('unknown', 0)} failed",
    ]
    summary = "\n".join(lines) + "\n"
    Path(args.summary_path).write_text(summary, encoding="utf-8")
    sys.stdout.write(summary)

    if failed.get("high", 0) > 0:
        return 10
    if args.fail_on_cat2 and failed.get("medium", 0) > 0:
        return 11
    return 0


if __name__ == "__main__":
    sys.exit(main())
