#!/usr/bin/env python3
"""Check GI sampling toggles, black-history recovery, and emissive removal."""

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
        return np.asarray(Image.open(directory / f"sampling_{name}.png").convert("RGB"), dtype=np.float64) / 255.0

    baseline = load("disabled")
    for name in ("dark", "disabled_after"):
        if not np.array_equal(baseline, load(name)):
            raise SystemExit(f"{name}: direct-only control differs")
    for name in (
        "uniform",
        "guided",
        "uniform_restored",
        "adaptive_off",
        "adaptive_on",
        "cache_off",
        "cache_on",
        "sixteenth",
    ):
        gain = (load(name) - baseline).mean()
        print(f"{name}: mean display-RGB indirect gain={gain:.6f}")
        if gain <= 0.001:
            raise SystemExit(f"{name}: missing indirect contribution")
    # Box-front ROI excludes the emissive ceiling: this checks transported light.
    region = (slice(230, 265), slice(240, 290))
    emitted = (load("emissive")[region] - baseline[region]).mean()
    residual = np.abs(load("emission_removed")[region] - baseline[region]).mean()
    print(f"Emissive box-front gain={emitted:.6f}; residual after removal={residual:.6f}")
    if emitted <= 0.01 or residual > emitted * 0.2:
        raise SystemExit("Black-history discovery or emissive-history decay failed")
    memory = {
        name: (int(textures), int(buffers))
        for name, textures, buffers in re.findall(
            r"GI memory sampling_(\w+): textures=(\d+) buffers=(\d+)", (directory / "run.log").read_text()
        )
    }
    for name in ("guided", "uniform_restored", "adaptive_off", "adaptive_on"):
        if memory["uniform"] != memory[name]:
            raise SystemExit("Sampling toggle changed GPU resource allocation")
    if memory["disabled"][0] != memory["disabled_after"][0]:
        raise SystemExit("GI texture allocation did not return to baseline")
    # Isolate the cache's exact allocation, including its disabled placeholders.
    # Native renderer pools may grow between the initial and later stages.
    cache_bytes = 4096 * (1216 + 16 + 2 * 4) - (16 + 16 + 2 * 4)
    if memory["cache_on"][1] - memory["cache_off"][1] != cache_bytes or memory["cache_on"][0] != memory["cache_off"][0]:
        raise SystemExit("Displaced-probe cache toggle did not release/restore its GPU allocation")
    cache_checks = re.findall(
        r"AMD GI cache validation: frame=\d+ scheduled=(\d+) budget=(\d+) evicted=(\d+) reused=(\d+)",
        (directory / "run.log").read_text(),
    )
    if (
        not cache_checks
        or not any(int(row[2]) > 0 for row in cache_checks)
        or not any(int(row[3]) > 0 for row in cache_checks)
    ):
        raise SystemExit("GPU cache validation did not exercise both eviction and reuse")
    if any(int(row[0]) > int(row[1]) for row in cache_checks):
        raise SystemExit("Probe updates exceeded the primary-ray budget")
    print(f"GPU ownership/LRU permutation checks passed on {len(cache_checks)} frames; eviction and reuse exercised.")
    print("Direct-only controls exact; sampling switches keep a fixed budget, camera, multibounce and denoising.")
    print("A separate 1/16-primary-ray stage checks the sparsest update schedule.")
    print("This checks integration, not GPU performance or comparative image accuracy.")


if __name__ == "__main__":
    main()
