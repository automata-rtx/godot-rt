#!/usr/bin/env python3
"""Check AMD diffuse/glossy integration with jittered FSR2 at an odd internal size."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory

    def load(name):
        result = np.asarray(Image.open(directory / f"fsr2_{name}.png").convert("RGB"), dtype=float) / 255
        if result.shape != (359, 641, 3):
            raise SystemExit("Incorrect FSR2 display size")
        return result

    disabled, quarter, one = load("disabled"), load("quarter"), load("one")
    gains = [(image - disabled).mean() for image in [quarter, one]]
    restore = np.abs(load("restored") - quarter).mean()
    off_error = np.abs(load("disabled_after") - disabled).mean()
    print(f"FSR2 display-RGB gains, quarter/one={gains}; restored MAE={restore:.6f}; disabled MAE={off_error:.6f}")
    if min(gains) < 0.005 or max(gains) > 0.2 or restore > 0.02 or off_error > 0.01:
        raise SystemExit("FSR2 contribution/history/restoration check failed")
    if np.abs(load("motion") - one).mean() < 0.005:
        raise SystemExit("Camera motion was not exercised")
    print("FSR2 integration passed with denoising, multibounce, and reflections enabled; no hardware timing claim.")


if __name__ == "__main__":
    main()
