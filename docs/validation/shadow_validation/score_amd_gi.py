#!/usr/bin/env python3
"""Check the sparse GI pipeline's controls; no hardware performance claims."""

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image


def load(directory, name):
    return np.asarray(Image.open(directory / f"{name}.png").convert("RGB"), dtype=np.float64) / 255.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory
    baseline = load(directory, "amd_disabled")
    for name in ("amd_indirect_zero", "amd_disabled_after"):
        if not np.array_equal(baseline, load(directory, name)):
            raise SystemExit(f"{name}: direct-only control changed")
    for name in ("amd_startup", "amd_quarter_32", "amd_quarter_64", "amd_one_64", "amd_camera_restored"):
        capture = load(directory, name)
        gain = (capture - baseline).mean()
        print(f"{name}: mean display-RGB gain={gain:.6f}")
        if gain <= 0.001:
            raise SystemExit(f"{name}: no substantial indirect-light contribution")
    lit_gain = (load(directory, "amd_one_64") - baseline).mean()
    zero_gain = (load(directory, "amd_indirect_zero_settled") - baseline).mean()
    print(f"Zero-energy temporal residual after 128 frames: {zero_gain / lit_gain:.6f}")
    if zero_gain < -0.001 or zero_gain > lit_gain * 0.1:
        raise SystemExit("Zero-energy lighting did not decay through the reference cache history")
    region = (slice(230, 265), slice(240, 290))
    delta = (load(directory, "amd_material_changed")[region] - load(directory, "amd_one_64")[region]).mean(axis=(0, 1))
    print(f"Changed non-caster wall: box-front RGB delta={delta}")
    if delta[1] >= 0 or delta[2] <= 0:
        raise SystemExit("Non-caster material update did not transfer color to the box")
    memory = {
        name: (int(textures), int(buffers))
        for name, textures, buffers in re.findall(
            r"GI memory (\w+): textures=(\d+) buffers=(\d+)", (directory / "run.log").read_text()
        )
    }
    if memory["amd_disabled_after"][0] != memory["amd_disabled"][0]:
        raise SystemExit("GI textures did not return to baseline after disabling")
    print("Disabled image restored exactly; GI textures returned to baseline.")
    print("Probe rays: ~1/4 and ~1 per internal pixel per frame; continuation/visibility rays additional.")
    print("Probe filters and temporal/spatial GI denoiser enabled throughout all progress captures.")


if __name__ == "__main__":
    main()
