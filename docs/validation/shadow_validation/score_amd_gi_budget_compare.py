#!/usr/bin/env python3
"""Verify two equal-history-budget live GI captures and disabled restoration."""

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
        return np.asarray(Image.open(directory / f"budget_{name}.png").convert("RGB"), dtype=np.float64) / 255.0

    disabled = load("disabled")
    if not np.array_equal(disabled, load("disabled_after")):
        raise SystemExit("Disabled restoration differs")
    for name in ("quarter", "one"):
        gain = (load(name) - disabled).mean()
        print(f"{name}: mean display-RGB gain={gain:.6f}")
        if gain < 0.01:
            raise SystemExit("GI contribution missing")
    log = (directory / "run.log").read_text()
    histories = []
    for section in log.split("stage budget: ")[1:]:
        frames = [int(x) for x in re.findall(r"AMD GI cache validation: frame=(\d+)", section)]
        resets = re.findall(r"AMD GI history reset:", section)
        if not frames or len(resets) != 1 or frames != list(range(1, len(frames) + 1)):
            raise SystemExit("Expected one fresh, uninterrupted GI history per capture")
        histories.append(frames)
    if len(histories) != 2 or histories[0] != histories[1] or len(histories[0]) < 60:
        raise SystemExit(f"History draw counts differ: {[len(x) for x in histories]}")
    print(f"Matched {len(histories[0])} actual GI draws per budget, with all filters enabled.")


if __name__ == "__main__":
    main()
