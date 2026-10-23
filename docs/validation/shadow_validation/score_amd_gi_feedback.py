#!/usr/bin/env python3
"""Check native lighting feedback, fog/exposure separation, and resource toggles."""

import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

root = Path(sys.argv[1])
log = (root / "run.log").read_text()
stages = re.split(r"stage feedback: (\w+)\n", log)
means = {}
for name, block in zip(stages[1::2], stages[2::2]):
    checks = re.findall(r"AMD GI feedback validation: frame=(\d+) covered=(\d+) accepted=(\d+) mean=([\d.]+)", block)
    if not checks or not any(int(row[2]) > 0 for row in checks):
        raise SystemExit(f"{name}: GPU feedback lookup was not exercised")
    means[name] = float(next(row[3] for row in checks if int(row[0]) == 64))
for name in ("fog", "exposure"):
    relative = abs(means[name] / means["plain"] - 1)
    print(f"Unexposed feedback mean {name}/plain relative difference: {relative:.6f}")
    if relative > 0.03:
        raise SystemExit(f"{name} contaminated lighting feedback")


def load(name):
    return np.asarray(Image.open(root / f"feedback_{name}.png").convert("RGB"), dtype=np.float64) / 255


for name in ("indirect_zero", "disabled_after"):
    if not np.array_equal(load(name), load("disabled")):
        raise SystemExit(f"{name}: direct-only image differs")
if np.abs(load("fog") - load("plain")).mean() < 0.01:
    raise SystemExit("Fog control did not affect the final display image")
if np.abs(load("exposure") - load("plain")).mean() < 0.01:
    raise SystemExit("Exposure control did not affect the final display image")
memory = {name: int(size) for name, size in re.findall(r"GI memory feedback_(\w+): textures=(\d+)", log)}
h, w = load("plain").shape[:2]
# RenderingDevice reports driver-aligned allocation sizes, not logical texels.
released = memory["restored"] - memory["off"]
if released < w * h * 8 or memory["restored"] != memory["plain"] or memory["indirect_zero"] != memory["off"]:
    raise SystemExit("Feedback toggle did not release its RGBA16F target")
print(f"Feedback texture allocation released: {released} bytes (logical minimum {w * h * 8}).")
print("GPU feedback accepted; fog/exposure separated; texture toggle and exact disabled controls pass.")
