#!/usr/bin/env python3
"""Compare shared GPU poses with independently baked static geometry."""

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
        return np.asarray(Image.open(directory / f"deformation_{name}.png").convert("RGB"), dtype=np.float64) / 255.0

    if not np.array_equal(load("disabled"), load("disabled_after")):
        raise SystemExit("Disabled restoration differs")
    for count in (4, 8):
        pose, baked, direct, baked_direct = (
            load(f"{name}_{count}") for name in ("pose", "baked", "pose_direct", "baked_direct")
        )
        direct_difference = np.abs(direct - baked_direct).mean()
        difference = np.abs(pose - baked).mean()
        gain = (pose - direct).mean()
        print(f"{count} weights: direct MAE={direct_difference:.6f}, GI MAE={difference:.6f}, gain={gain:.6f}")
        if direct_difference > 0.004 or difference > 0.008 or gain < 0.01:
            raise SystemExit("Posed material/geometry does not match independently baked reference")
    log = (directory / "run.log").read_text()
    if "ERROR:" in log or "GI is suppressed" in log:
        raise SystemExit("Deformation renderer diagnostics failed")
    for section in log.split("stage deformation: animate ")[1:]:
        motion = section.split("saved deformation_pose_")[0]
        prepared = [int(x) for x in re.findall(r"GI material preparation: resident=\d+ prepared=(\d+)", motion)]
        drawn = [int(x) for x in re.findall(r"GI material pixels: resident=\d+ drawn=(\d+)", motion)]
        if len(prepared) < 60 or any(prepared) or len(drawn) < 60 or any(drawn):
            raise SystemExit(
                f"Source shading must follow native poses without preparing or drawing capture pages: {prepared}, {drawn}"
            )
        resets = re.findall(r"AMD GI history reset:", motion)
        moving = re.findall(r"AMD GI local motion: frame=\d+ bounds=(\d+)", motion)
        if len(resets) != 1 or len(moving) < 8 or any(int(x) != 1 for x in moving):
            raise SystemExit(
                f"Animation must report one diagnostic motion region without global resets: {len(resets)}, {moving}"
            )
    print("Both native pose formats, blend shapes, and FSR2 pose buffers match static references.")


if __name__ == "__main__":
    main()
