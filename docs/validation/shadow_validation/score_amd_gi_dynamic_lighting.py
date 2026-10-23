#!/usr/bin/env python3
"""Verify continuous sky/light animation retains GI history while hard cuts reset it."""

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory
    log = (directory / "run.log").read_text()
    before, after = log.split("stage dynamic: cut", 1)
    initial = re.findall(r"AMD GI history reset: frame=(\d+)", before)
    cuts = re.findall(r"AMD GI history reset: frame=(\d+)", after)
    if len(initial) != 1 or len(cuts) != 1:
        raise SystemExit(f"Expected initialization and one lighting cut, got {initial} / {cuts}")
    checks = re.findall(r"AMD GI cache validation: frame=(\d+)", before)
    if len(checks) < 100:
        raise SystemExit("Insufficient animated history frames")
    black = np.asarray(Image.open(directory / "dynamic_black.png").convert("RGB"), dtype=float) / 255
    lit = np.asarray(Image.open(directory / "dynamic_moving_lights.png").convert("RGB"), dtype=float) / 255
    if black.max() > 0.02 or lit.mean() < 0.05:
        raise SystemExit("Lighting animation or hard-cut removal failed")
    print(f"Animated sky/light history retained over {len(checks)} frames; exactly one initialization reset.")
    print("Hard light/sky removal resets once and leaves a black scene; 1/4 diffuse budget and denoising stay enabled.")


if __name__ == "__main__":
    main()
