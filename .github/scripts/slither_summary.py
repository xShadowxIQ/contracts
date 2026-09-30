#!/usr/bin/env python3
"""Print Slither detector results from a JSON report, in triage-friendly form."""
import json
import sys
from collections import Counter

ORDER = {"High": 0, "Medium": 1, "Low": 2, "Informational": 3, "Optimization": 4}


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: slither_summary.py <report.json>")
        return 2
    path = sys.argv[1]
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        print(f"could not read {path}: {exc}")
        return 1

    dets = data.get("results", {}).get("detectors", []) or []
    print(f"detectors fired: {len(dets)}")
    if not dets:
        print("(clean - no detectors matched)")
        return 0

    counts = Counter(d.get("impact", "?") for d in dets)
    print("by impact: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    print("-" * 72)

    for d in sorted(dets, key=lambda x: ORDER.get(x.get("impact", ""), 9)):
        desc = " ".join(d.get("description", "").split())
        print(f"[{d.get('impact','?')}/{d.get('confidence','?')}] {d.get('check')}")
        print(f"    {desc[:700]}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())