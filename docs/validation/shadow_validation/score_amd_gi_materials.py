#!/usr/bin/env python3
"""Check retained capture geometry, vertex-attribute invalidation, and GI transport."""

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory

    def load(name):
        return np.asarray(Image.open(directory / f"materials_{name}.png").convert("RGB"), dtype=np.float64) / 255.0

    if not np.array_equal(load("disabled"), load("disabled_after")):
        raise SystemExit("Disabled restoration differs")
    region = (slice(230, 265), slice(240, 290))
    green, blue, rebuilt = (load(name)[region] for name in ("green", "blue_updated", "blue_rebuilt"))
    delta = (blue - green).mean(axis=(0, 1))
    difference = np.abs(blue - rebuilt).mean()
    print(f"Non-caster vertex-color transfer RGB delta={delta}; fresh-surface difference={difference:.6f}")
    if delta[1] >= -0.003 or delta[2] <= 0.003 or difference > 0.015:
        raise SystemExit("Retained material preparation did not track attribute-buffer edits")
    records = re.findall(r"GI material preparation: resident=(\d+) prepared=(\d+)", (directory / "run.log").read_text())
    positive = [int(prepared) for _, prepared in records if int(prepared)]
    if len(records) < 100 or positive != [7, 1, 1]:
        raise SystemExit(f"Expected initial seven pages and two single-page rebuilds; got {positive}")
    print(f"Retained preparation verified over {len(records)} frames; only changed source pages rebuilt.")


if __name__ == "__main__":
    main()
