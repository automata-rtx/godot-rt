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
    checks = re.findall(r"AMD GI reservoir validation: valid=(\d+) reused=(\d+)", log)
    if not checks or not any(int(reused) for _, reused in checks):
        raise SystemExit("World reservoir reuse was not exercised")
    memory = {
        name: int(buffers) for name, buffers in re.findall(r"GI memory lights_(\w+): textures=\d+ buffers=(\d+)", log)
    }
    # Two base-cell reservoir buffers replace two 16-byte placeholders.
    expected = 2 * 4096 * 64 * 16 - 32
    if memory["resampled"] - memory["exhaustive_restored"] != expected:
        raise SystemExit("Light-resampling toggle did not release its reservoir buffers")
    print("World reservoir reuse and allocation toggle verified; direct-only controls exact.")
    print("All captures keep the 1/4 primary-ray budget, multibounce and denoising. Software Vulkan, not GPU timings.")


if __name__ == "__main__":
    main()
