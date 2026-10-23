#!/usr/bin/env python3
"""Check controlled GI comparisons and report display-RGB settling differences."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    baseline = load(args.directory / "gi_disabled.png")
    for method in ("rt", "voxel", "sdfgi"):
        restored = load(args.directory / f"gi_disabled_after_{method}.png")
        if not np.array_equal(baseline, restored):
            raise SystemExit(f"Disabled control changed after {method}")
    print("All three disabled controls match the original image exactly.")
    for method in (
        "amd_quarter",
        "amd_one",
        "voxel_128",
        "voxel_256",
        "voxel_256_normal_bias",
        "sdfgi_default",
        "sdfgi_fine_occlusion",
    ):
        capture = load(args.directory / f"{method}.png")
        if capture.shape != baseline.shape:
            raise SystemExit(f"{method}: capture dimensions differ")
        gain = (capture - baseline).mean() / 255.0
        if gain <= 0:
            raise SystemExit(f"{method}: no positive average indirect contribution")
        print(f"{method}: mean display-RGB gain over disabled={gain:.6f}")
        if method.startswith("amd_"):
            continue
        early = load(args.directory / f"{method}_early.png")
        difference = np.abs(capture - early)
        print(
            f"  60 additional settling frames: mean absolute difference={difference.mean():.6f}/255, "
            f"99th percentile={np.percentile(difference, 99):.1f}/255, max={difference.max():.0f}/255"
        )
    print("These are display-space checks, not radiometric accuracy or GPU performance measurements.")


if __name__ == "__main__":
    main()
