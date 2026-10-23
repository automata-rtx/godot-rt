#!/usr/bin/env python3
"""Compare native instanced colors/custom data/IDs against separate mesh materials."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory

    def load(name):
        return np.asarray(Image.open(directory / f"multimesh_{name}.png").convert("RGB"), dtype=float) / 255.0

    off, on = load("off"), load("on")
    direct = np.abs(off - load("reference_off")).mean()
    gi = np.abs(on - load("reference_on")).mean()
    restore = np.abs(on - load("restored")).mean()
    update = np.abs(on - load("updated")).mean()
    gain = (on - off).mean()
    print(
        f"Mesh/MultiMesh direct MAE={direct:.6f}; GI MAE={gi:.6f}; motion restoration={restore:.6f}; color/custom change={update:.6f}; GI gain={gain:.6f}"
    )
    assert direct < 0.001 and gi < 0.008 and restore < 0.008
    assert gain > 0.01 and update > 0.005
    assert np.array_equal(off, load("disabled_after"))
    log = (directory / "run.log").read_text()
    assert "GI is suppressed" not in log
    moving = log.split("stage multimesh: move")[1].split("stage multimesh: color/custom update")[0]
    assert "AMD GI history reset" not in moving
    print("Native element inputs, transformed normals, motion, live updates and disabled restoration pass.")


if __name__ == "__main__":
    main()
