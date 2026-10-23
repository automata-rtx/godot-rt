#!/usr/bin/env python3
"""Verify row packing, relocation of cached pixels, and cross-layer triangle lookup."""

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
        return np.asarray(Image.open(directory / f"atlas_{name}.png").convert("RGB"), dtype=float) / 255

    baseline = load("disabled")
    if not np.array_equal(baseline, load("disabled_after")):
        raise SystemExit("Off-camera padding altered disabled room")
    small = load("small")
    if (small - baseline).mean() < 0.01:
        raise SystemExit("Scene with more than 32 surfaces did not receive GI")
    for name in ["shifted", "split", "grown", "shrunk"]:
        error = np.abs(load(name) - small).mean()
        print(f"Atlas {name}: mean absolute display-RGB difference={error:.6f}")
        if error > 0.01:
            raise SystemExit("Atlas relocation/cross-layer lookup changed room materials")
    log = (directory / "run.log").read_text()
    shift = log.split("stage atlas: shift", 1)[1].split("stage atlas: split", 1)[0]
    draws = [int(n) for n in re.findall(r"GI material pixels: resident=\d+ drawn=(\d+)", shift)]
    copies = [int(n) for n in re.findall(r"GI material atlas: tiles=\d+ copied=(\d+)", shift)]
    if [n for n in draws if n] != [1] or max(copies, default=0) < 40 or any(copies[-16:]):
        raise SystemExit("Relocated static pages were not copied exactly when needed")
    resident = [int(n) for n in re.findall(r"GI material pixels: resident=(\d+)", log)]
    if max(resident, default=0) <= 48:
        raise SystemExit("Large surface did not cross atlas layers")
    layers = [int(n) for n in re.findall(r"GI material atlas:.*layers=(\d+)", log)]
    assert layers and max(layers) > 32 and layers[-1] <= 6, "Atlas did not grow/shrink within live budget"
    assert "GI is suppressed" not in log, "Scene capacity was exceeded"
    print(f"Atlas grew to {max(layers)} layers, then shrank to {layers[-1]} with a live 8 MiB limit.")
    print("More than 32 surfaces fit; resizing one source redraws one capture and relocates retained pixels.")


if __name__ == "__main__":
    main()
