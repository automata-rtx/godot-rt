#!/usr/bin/env python3
"""Raster-only decorative shells must not disable or contaminate transport."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory

    def load(name):
        return np.asarray(Image.open(directory / f"overlay_{name}.png").convert("RGB"), dtype=float) / 255

    off, on = load("off"), load("on")
    decorated_off, decorated_on = load("decorated_off"), load("decorated_on")
    assert np.array_equal(off, load("disabled_after"))
    assert np.abs(off - decorated_off).mean() > 0.0001, "Decorative shell was not visible"
    gain = (decorated_on - decorated_off).mean()
    # Compare only pixels untouched by raster decoration, using the independent
    # direct-only controls to define this mask rather than hand-picked regions.
    unchanged = np.max(np.abs(decorated_off - off), axis=2) < 1 / 255
    error = np.abs(decorated_on[unchanged] - on[unchanged]).mean()
    print(f"Decorated GI gain={gain:.6f}; unchanged-surface MAE={error:.6f}")
    assert gain > 0.01 and error < 0.008
    log = (directory / "run.log").read_text()
    assert "GI is suppressed" not in log
    section = log.split("stage overlay: decorative passes")[1]
    assert "AMD GI history reset" not in section
    print("Decorative passes preserve GI, physical geometry and history; disabled restoration is exact.")


if __name__ == "__main__":
    main()
