#!/usr/bin/env python3
"""Check that local scene churn preserves unrelated GI history."""

import argparse
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
log = (parser.parse_args().directory / "run.log").read_text()
if "CHURN stage: finished" not in log or "ERROR:" in log or "GI is suppressed" in log:
    raise SystemExit("Scene churn rig did not finish cleanly")
if log.count("AMD GI reset reasons:") != 1:
    raise SystemExit("Only initialization may reset global history in this rig")
for name, minimum in [("translation", 7), ("rotation", 0), ("additions/removals", 8), ("material edit", 1)]:
    segment = log.split("CHURN stage: " + name + "\n")[1].split("CHURN stage:")[0]
    regions = re.findall(r"AMD GI dirty regions: frame=\d+ count=(\d+)", segment)
    if len(regions) != minimum or any(int(count) != 1 for count in regions):
        raise SystemExit(f"Unexpected dirty regions for {name}: {regions}")
print("Collection crossings, additions/removals and material edits stay local; rotation keeps history.")
