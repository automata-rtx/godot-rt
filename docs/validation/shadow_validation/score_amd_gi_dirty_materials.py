#!/usr/bin/env python3
"""Verify static material reuse and live texture, uniform, TIME and global updates."""

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
        return np.asarray(Image.open(directory / f"dirty_{name}.png").convert("RGB"), dtype=float) / 255

    if not np.array_equal(load("disabled"), load("disabled_after")):
        raise SystemExit("Disabled material restoration differs")
    roi = np.s_[230:265, 240:290]
    for a, b in [("green", "blue"), ("global_green", "global_blue")]:
        delta = (load(b)[roi] - load(a)[roi]).mean(axis=(0, 1))
        print(f"{a} -> {b}, receiver RGB delta={delta}")
        if delta[1] > -0.003 or delta[2] < 0.003:
            raise SystemExit("Updated texture/global value did not reach indirect receiver")
    emission_gain = (load("emission")[roi] - load("blue")[roi])[:, :, 1].mean()
    if emission_gain < 0.005:
        raise SystemExit("Material uniform update did not reach indirect receiver")
    log = (directory / "run.log").read_text()
    stages = re.split(r"stage dirty: (\w+)\n", log)
    for index in range(1, len(stages), 2):
        name, body = stages[index : index + 2]
        draws = [int(n) for n in re.findall(r"GI material pixels: resident=\d+ drawn=(\d+)", body)]
        if len(draws) < 20:
            raise SystemExit(f"Missing material diagnostics in {name}")
        tail = draws[-16:]
        if name in ("time", "global"):
            if tail != [1] * 16:
                raise SystemExit(f"Dynamic material was cached or unchanged pages redrawn in {name}: {tail}")
        elif any(tail):
            raise SystemExit(f"Static material pages still redraw in {name}: {tail}")
        print(f"{name}: {sum(draws)} page draws over {len(draws)} active frames; last 16={sum(tail)}")
    print(
        f"Static pages reuse pixels; green emission gain={emission_gain:.6f}; dynamic shader fallback updates only its page."
    )


if __name__ == "__main__":
    main()
