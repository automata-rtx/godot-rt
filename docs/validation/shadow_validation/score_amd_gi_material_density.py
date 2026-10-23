#!/usr/bin/env python3
"""Validate live capture-density changes and repeated tinted-instance sharing."""

import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

root = Path(sys.argv[1])
log = (root / "run.log").read_text()


def load(name):
    return np.asarray(Image.open(root / f"density_{name}.png").convert("RGB"), dtype=float) / 255.0


base, eight = load("disabled"), load("eight")
assert np.array_equal(base, load("disabled_after"))
assert (eight - base).mean() > 0.01
for name in ["four", "restored"]:
    error = np.abs(load(name) - eight).mean()
    print(f"{name}: display-RGB MAE={error:.6f}")
    assert error < 0.008
resident = [int(x) for x in re.findall(r"GI material pixels: resident=(\d+)", log)]
assert resident and max(resident) < 64, "Repeated tinted instances did not share captures"
bytes_by_size = {}
for size, count in re.findall(r"GI material atlas:.*tile_size=(\d+) bytes=(\d+)", log):
    bytes_by_size[int(size)] = int(count)
assert bytes_by_size[8] == bytes_by_size[4] * 4
assert log.count("AMD GI history reset:") == 3
assert "GI is suppressed" not in log
print(
    f"Atlas allocation 8/4 tiles: {bytes_by_size}; {max(resident)} resident capture pages for 200 tinted instances plus room/large surface."
)
print("Live density switches reset GI history and reduce atlas allocation by four; disabled restoration is exact.")
