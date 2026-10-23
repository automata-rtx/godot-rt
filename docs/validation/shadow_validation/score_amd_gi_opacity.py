#!/usr/bin/env python3
"""Check off-screen alpha coverage against hidden and opaque transport endpoints."""

import sys
from pathlib import Path

import numpy as np
from PIL import Image

root = Path(sys.argv[1])


def load(name):
    return np.asarray(Image.open(root / f"opacity_{name}.png").convert("RGB"), dtype=float) / 255.0


base = load("disabled")
if not np.array_equal(base, load("disabled_after")):
    raise SystemExit("Disabled control changed")
zero_error = np.abs(load("zero") - load("hidden")).mean()
one_error = np.abs(load("one") - load("opaque")).mean()
gains = {name: (load(name) - base).mean() for name in ("zero", "half", "one")}
print(f"Endpoint MAE: zero/hidden={zero_error:.6f}, one/opaque={one_error:.6f}; gains={gains}")
if zero_error > 0.002 or one_error > 0.002:
    raise SystemExit("Opacity endpoints do not match their transport controls")
if not gains["zero"] > gains["half"] + 0.001 > gains["one"] + 0.002:
    raise SystemExit("Fractional opacity did not lie between opaque and transparent controls")
print("Depth-writing alpha uses fractional off-screen coverage; quarter primary budget, denoiser ON.")
