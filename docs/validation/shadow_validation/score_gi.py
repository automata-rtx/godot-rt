#!/usr/bin/env python3
"""Check the diffuse transport stills; these are not hardware performance tests."""

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    off = load(args.directory / "gi_disabled.png")
    one = load(args.directory / "gi_one_bounce.png")
    three = load(args.directory / "gi_three_bounces.png")
    restored = load(args.directory / "gi_disabled_after.png")
    indirect_zero = load(args.directory / "gi_indirect_zero.png")
    material_changed = load(args.directory / "gi_material_changed.png")
    if not (off.shape == one.shape == three.shape == restored.shape):
        raise SystemExit("capture dimensions differ")
    if not np.array_equal(off, restored):
        raise SystemExit("disabling GI did not restore the original image exactly")
    if not np.array_equal(off, indirect_zero):
        raise SystemExit("zero indirect light energy changed direct illumination")
    # Short box front: it has no direct view of the point light. Its material
    # stays white; only the non-shadow-casting right wall changes green to blue.
    region = (slice(230, 265), slice(240, 290))
    delta = (material_changed[region] - three[region]).mean(axis=(0, 1))
    print(f"non-caster material update, box-front RGB delta: {delta}")
    if delta[1] >= -0.005 or delta[2] <= 0.005:
        raise SystemExit("material update did not change indirect color on the white box")
    if off.max() < 0.1:
        raise SystemExit("disabled control is unexpectedly dark")
    for label, capture in [("one bounce", one), ("three bounces", three)]:
        gain = (capture - off).mean()
        changed = np.any(capture != off, axis=2).sum()
        print(f"{label}: mean display-RGB gain={gain:.6f}, changed pixels={changed}")
        if gain < 0.005 or changed < off.shape[0] * off.shape[1] // 10:
            raise SystemExit(f"{label}: no substantial indirect-light contribution")
    if three.mean() <= one.mean():
        raise SystemExit("additional bounces did not recover additional light")
    memory = {
        label: (int(textures), int(buffers))
        for label, textures, buffers in re.findall(
            r"GI memory (\w+): textures=(\d+) buffers=(\d+)", (args.directory / "run.log").read_text()
        )
    }
    before = memory["gi_disabled"]
    active = memory["gi_three_bounces"]
    after = memory["gi_disabled_after"]
    if active[0] <= before[0] or after[0] != before[0]:
        raise SystemExit("validation textures did not allocate and return to baseline after deferred destruction")
    print(f"texture bytes: disabled={before[0]}, active={active[0]}, disabled again={after[0]}")
    print(f"buffer bytes retained above cold baseline: {after[1] - before[1]} (native renderer pools remain warm)")
    print("GI still checks passed; disabled image restored byte-for-byte")


if __name__ == "__main__":
    main()
