#!/usr/bin/env python3
"""Check moving spotlight GI and compare light resampling with exhaustive shading."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
directory = parser.parse_args().directory


def load(name):
    srgb = np.asarray(Image.open(directory / f"flashlight_{name}.png").convert("RGB"), dtype=float) / 255.0
    return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)


for side in ("left", "right"):
    gain = (load(side + "_gi") - load(side + "_direct")).mean()
    print(f"{side}: linear RGB mean indirect gain={gain:.6f}")
    if gain < 0.002:
        raise SystemExit("Spotlight must produce indirect illumination")
resampled, exhaustive = load("right_gi"), load("right_exhaustive")
mae = np.abs(resampled - exhaustive).mean()
ratio = resampled.mean() / exhaustive.mean()
print(f"Resampled/exhaustive: linear RGB MAE={mae:.6f}, mean ratio={ratio:.6f}")
if mae > 0.002 or not 0.95 < ratio < 1.05:
    raise SystemExit("Spotlight light resampling differs excessively from exhaustive shading")
if not np.array_equal(load("off_gi"), load("off_direct")):
    raise SystemExit("Disabled flashlight leaves stale illumination")
log = (directory / "run.log").read_text()
segment = log.split("FLASHLIGHT stage: continuous movement")[1].split("FLASHLIGHT stage: right settle")[0]
if "AMD GI reset reasons:" in segment or "ERROR:" in log or "GI is suppressed" in log:
    raise SystemExit("Moving flashlight must not reset history or suppress GI")
print("Moving spotlight retains history and switching it off removes its indirect light.")
