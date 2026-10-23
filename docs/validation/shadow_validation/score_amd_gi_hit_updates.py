#!/usr/bin/env python3
"""Validate all-hit cache coverage, lower-cost toggle, and unchanged primary budget."""

import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

root = Path(sys.argv[1])
log = (root / "run.log").read_text()
checks = re.findall(r"AMD GI hit update validation: primary=(\d+) secondary=(\d+) shared_cells=(\d+)", log)
if not checks or not any(int(row[1]) > 0 and int(row[2]) > 0 for row in checks):
    raise SystemExit("GPU hit coverage did not exercise shared cells and secondary hits")
if not any(int(row[0]) > 0 and int(row[1]) == 0 for row in checks):
    raise SystemExit("Single-bounce all-hit path was not exercised")


def load(name):
    return np.asarray(Image.open(root / f"hits_{name}.png").convert("RGB"), dtype=np.float64) / 255


base = load("disabled")
if not np.array_equal(base, load("disabled_after")):
    raise SystemExit("Disabled control differs")
gains = {name: (load(name) - base).mean() for name in ("one", "all", "all_single")}
restored = np.abs(load("one_restored") - load("one")).mean()
print(f"Indirect display-RGB gains {gains}; restored MAE={restored:.6f}")
if min(gains.values()) <= 0.001 or gains["all"] < gains["all_single"] + 0.002 or restored > 0.004:
    raise SystemExit("Cache mode/multibounce lighting control failed")
memory = {name: int(value) for name, value in re.findall(r"GI memory hits_(\w+): textures=\d+ buffers=(\d+)", log)}
h, w = base.shape[:2]
rays = ((w + 15) // 16) * ((h + 15) // 16) * 64
expected = 4096 * 85 * 4 + rays * 2 * 48 - 16
if memory["all"] - memory["one_restored"] != expected:
    raise SystemExit("All-hit toggle did not release heads and sample records")
if any(int(row[0]) > rays or int(row[1]) > rays for row in checks):
    raise SystemExit("Hit count exceeded primary/continuation capacity")
print(f"GPU all-hit lists verified on {len(checks)} frames; toggle releases {expected} buffer bytes.")
print("Primary diffuse budget stays 1/4; all-hit shading can add visibility and continuation work.")
