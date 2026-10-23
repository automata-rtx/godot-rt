#!/usr/bin/env python3
"""Check history continuity and residency; this is not visual acceptance."""

import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
if "AUDIT FINISHED" not in text or re.search(r"\bERROR:|error:", text):
    sys.exit("gameplay regression did not complete cleanly")
stages = dict(zip(re.findall(r"AUDIT stage: (.*)", text), re.split(r"AUDIT stage: .*", text)[1:]))
for name in ("moving metal", "light pulses", "flickering geometry"):
    if name not in stages or "AMD GI reset reasons:" in stages[name]:
        sys.exit(f"{name}: missing stage or unexpected global reset")
moving = re.findall(r"glossy history: frame=\d+ pixels=(\d+) fresh=(\d+)", stages["moving metal"])
pixels = sum(int(p) for p, _ in moving)
fresh = sum(int(f) for _, f in moving)
if pixels == 0 or fresh / pixels >= 0.25:
    sys.exit("moving receiver rejected most of its glossy history")
preparations = re.findall(r"GI material preparation: resident=\d+ prepared=(\d+)", stages["flickering geometry"])
if not preparations or sum(map(int, preparations)) != 1:
    sys.exit("flickering mesh must prepare once and reuse its capture on later appearances")
print(f"Moving glossy history: {fresh}/{pixels} fresh samples; no pulse/reset or capture-churn regression.")
