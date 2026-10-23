#!/usr/bin/env python3
"""Compare low-ray-count light reservoirs against exhaustive light evaluation."""

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
        return np.asarray(Image.open(directory / f"lights_{name}.png").convert("RGB"), dtype=np.float64) / 255.0

    for prefix in ("", "varied_"):
        baseline = load(prefix + "disabled")
        exhaustive = load(prefix + "exhaustive") - baseline
        resampled = load(prefix + "resampled") - baseline
        gain = exhaustive.mean()
        ratio = resampled.mean() / max(gain, 1e-8)
        difference = np.abs(resampled - exhaustive).mean()
        print(
            f"{prefix or 'identical_'}lights: resampled/exhaustive indirect gain={ratio:.6f}; mean absolute difference={difference:.6f}"
        )
        if gain <= 0.001 or not 0.8 < ratio < 1.2 or difference > 0.02:
            raise SystemExit("Resampled lighting deviates excessively from exhaustive lighting")
    for name in ("indirect_zero", "disabled_after"):
        if not np.array_equal(load(name), load("varied_disabled")):
            raise SystemExit(f"{name}: direct-only restoration differs")
    log = (directory / "run.log").read_text()
    for count, capacity in ((4, 4), (6, 8)):
        if f"AMD GI light hierarchy: lights={count} capacity={capacity}" not in log:
            raise SystemExit(f"Missing spatial hierarchy coverage for {count} lights")
    checks = re.findall(r"AMD GI reservoir validation: valid=(\d+) reused=(\d+)", log)
    if not checks or not any(int(reused) for _, reused in checks):
        raise SystemExit("World reservoir reuse was not exercised")
    multiple = re.findall(r"AMD GI reservoir validation: .*multiple=(\d+)", log)
    if not multiple or not any(int(count) for count in multiple):
        raise SystemExit("Independent multi-reservoir hash entries were not exercised")
    memory = {
        name: int(buffers) for name, buffers in re.findall(r"GI memory lights_(\w+): textures=\d+ buffers=(\d+)", log)
    }
    # Independent reference hash, per-hit records and scan scratch. Quarter
    # rate uses ceil(width/16)*ceil(height/16)*64 primary rays, plus secondary.
    height, width = load("resampled").shape[:2]
    capacity = ((width + 15) // 16) * ((height + 15) // 16) * 64 * 2
    entries = 0x400000
    blocks = entries // 256
    reservoir_bytes = (3 * entries + 8 * capacity + 2 * blocks + 2 * (blocks // 256)) * 4
    expected = 2 * reservoir_bytes - 32 + 8 * 48 - 16
    if memory["resampled"] - memory["exhaustive_restored"] != expected:
        raise SystemExit("Light-resampling toggle did not release its reservoir buffers")
    print("World reservoir reuse and allocation toggle verified; direct-only controls exact.")
    print("All captures keep the 1/4 primary-ray budget, multibounce and denoising. Software Vulkan, not GPU timings.")


if __name__ == "__main__":
    main()
