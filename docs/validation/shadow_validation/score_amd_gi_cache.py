#!/usr/bin/env python3
"""Verify GPU probe-cache ownership during camera motion and history expiry."""

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory
    log = (directory / "run.log").read_text()
    checks = re.findall(
        r"AMD GI cache validation: frame=\d+ scheduled=(\d+) budget=(\d+) evicted=(\d+) reused=(\d+)", log
    )
    if not checks or not any(int(row[2]) for row in checks) or not any(int(row[3]) for row in checks):
        raise SystemExit("Cache test did not exercise displacement and reuse")
    if any(int(row[0]) > int(row[1]) for row in checks):
        raise SystemExit("Probe update budget exceeded")
    if "AMD GI local motion:" not in log:
        raise SystemExit("Cache test did not exercise geometry motion with displaced history")
    resets = re.findall(r"AMD GI history reset:", log)
    if len(resets) != 1:
        raise SystemExit(f"Expected one initialization reset, got {len(resets)}")

    def load(name):
        return np.asarray(Image.open(directory / f"cache_{name}.png").convert("RGB"), dtype=np.float64)

    baseline = load("disabled")
    if not np.array_equal(baseline, load("disabled_after")):
        raise SystemExit("Disabled restoration differs")
    for name in ("returned", "expired"):
        if (load(name) - baseline).mean() <= 0.255:
            raise SystemExit(f"Missing indirect light: {name}")
    print(f"GPU queue/ownership/LRU checks passed on {len(checks)} frames, with displacement and reuse.")
    print("Camera sweep with moving geometry preserved unaffected history; disabled control restored exactly.")


if __name__ == "__main__":
    main()
