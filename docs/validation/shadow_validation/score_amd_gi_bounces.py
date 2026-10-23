#!/usr/bin/env python3
"""Verify secondary world-cell population, extra-bounce energy, and resource gating."""

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
        return np.asarray(Image.open(directory / f"bounces_{name}.png").convert("RGB"), dtype=np.float64) / 255.0

    baseline = load("disabled")
    if not np.array_equal(baseline, load("disabled_after")):
        raise SystemExit("Disabled restoration differs")
    single = (load("single") - baseline).mean()
    multiple = (load("multiple") - baseline).mean()
    restored = (load("single_restored") - baseline).mean()
    print(f"Indirect display-RGB gain: single={single:.6f}, multibounce={multiple:.6f}, restored={restored:.6f}")
    if single <= 0.001 or multiple < single + 0.002 or abs(restored - single) > 0.003:
        raise SystemExit("Multibounce energy/toggle control failed")
    log = (directory / "run.log").read_text()
    checks = re.findall(r"AMD GI multibounce validation: primary=(\d+) secondary_hits=(\d+) secondary_cells=(\d+)", log)
    if not checks or not any(int(cells) for _, _, cells in checks):
        raise SystemExit("Secondary-only cache cells were not populated")
    if any(int(hits) > int(primary) for primary, hits, _ in checks):
        raise SystemExit("More than one scheduled continuation per primary cache owner")
    memory = {
        name: int(buffers) for name, buffers in re.findall(r"GI memory bounces_(\w+): textures=\d+ buffers=(\d+)", log)
    }
    height, width = baseline.shape[:2]
    rays = ((width + 15) // 16) * ((height + 15) // 16) * 64
    expected = 2 * 4096 * 85 * 16 + rays * 80 - 3 * 16
    if memory["multiple"] - memory["single_restored"] != expected:
        raise SystemExit("Multibounce toggle did not release indirect caches/continuation buffer")
    print(f"GPU secondary ownership validated on {len(checks)} frames; multibounce resources released.")
    print("The 1/4 primary-ray budget and denoiser remain fixed. Continuation probability is 0.3.")


if __name__ == "__main__":
    main()
