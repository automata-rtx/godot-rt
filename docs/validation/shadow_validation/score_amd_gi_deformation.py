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
    parser.add_argument("--retained-scene", action="store_true")
    args = parser.parse_args()
    directory = args.directory

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
        if not args.retained_scene:
            resets = re.findall(r"AMD GI history reset:", motion)
            moving = re.findall(r"AMD GI local motion: frame=\d+ bounds=(\d+)", motion)
            if len(resets) != 1 or len(moving) < 8 or any(int(x) != 1 for x in moving):
                raise SystemExit(
                    f"Animation must report one diagnostic motion region without global resets: {len(resets)}, {moving}"
                )
    if args.retained_scene:
        for count in (4, 8):
            start = f"RETAINED_DEFORMATION stage pose_{count}\n"
            end = f"RETAINED_DEFORMATION stage end_pose_{count}"
            if log.count(start) != 1 or log.count(end) != 1:
                raise SystemExit(f"pose_{count}: missing or ambiguous coverage markers")
            remainder = log.split(start, 1)[1]
            if end not in remainder:
                raise SystemExit(f"pose_{count}: coverage markers out of order")
            section = remainder.split(end, 1)[0]
            streak = maximum = checked = reused_updates = reconstructed_updates = 0
            for line in section.splitlines():
                if not line.startswith("AMD GI retained groups:"):
                    continue
                fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", line)}
                complete = fields["reused_surfaces"] > 0 and fields["reused_surfaces"] == fields["total_surfaces"]
                checked += 1
                reused_updates += fields["reused_surfaces"] > 0
                reconstructed_updates += fields["reused_surfaces"] < fields["total_surfaces"]
                streak = streak + 1 if complete else 0
                maximum = max(maximum, streak)
            if count == 4 and maximum < 2:
                raise SystemExit("Settled four-weight pose did not exercise complete scene retention")
            if count == 8 and reused_updates < 2:
                raise SystemExit("Eight-weight FSR2 pose did not coexist with actual retained scene records")
            print(
                f"Actual retention pose_{count}: {checked} updates, complete scene streak={maximum}, "
                f"updates also reconstructing records={reconstructed_updates}"
            )
        print("Eight-weight FSR2 may alternate pose buffers; actor-specific reuse is not asserted.")
        print("Motion-region/history-reset assertions require the separate ordinary TRACE_HISTORY run.")
    print("Both native pose formats, blend shapes, and FSR2 pose buffers match static references.")


if __name__ == "__main__":
    main()
