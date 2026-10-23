#!/usr/bin/env python3
"""Repeated instances must share native captures without losing transformed normals."""

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
        return np.asarray(Image.open(directory / f"sharing_{name}.png").convert("RGB"), dtype=float) / 255.0

    baseline = load("disabled")
    shared = load("shared")
    assert np.array_equal(baseline, load("disabled_after")), "Disabled restoration differs"
    gain = (shared - baseline).mean()
    restored = np.abs(shared - load("restored")).mean()
    world = np.abs(shared - load("world_capture")).mean()
    print(f"GI gain={gain:.6f}; motion restoration={restored:.6f}; independent world capture MAE={world:.6f}")
    assert gain > 0.01 and restored < 0.008 and world < 0.008, "Shared capture changed shading or suppressed GI"
    log = (directory / "run.log").read_text()
    initial = log.split("stage sharing: transform only")[0]
    pages = [int(x) for x in re.findall(r"GI material preparation: resident=(\d+)", initial)]
    assert pages and max(pages) < 12, "Repeated spheres did not share material capture"
    section = log.split("stage sharing: transform only")[1].split("stage sharing: native world capture")[0]
    draws = [int(x) for x in re.findall(r"GI material pixels: resident=\d+ drawn=(\d+)", section)]
    assert len(draws) > 60 and not any(draws), "Object transforms redrew shared material pixels"
    assert "GI is suppressed" not in log
    print(
        f"300 repeated meshes share fewer than 12 capture chunks; no redraws across {len(draws)} transform/settle frames."
    )


if __name__ == "__main__":
    main()
