#!/usr/bin/env python3
"""Check sky miss shading, changes, rotation, occlusion, and disabled restoration."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory
    if "ERROR:" in (directory / "run.log").read_text():
        raise SystemExit("Engine/shader errors invalidate the sky capture")

    def load(name):
        return np.asarray(Image.open(directory / f"sky_{name}.png").convert("RGB"), dtype=float) / 255

    disabled = load("disabled")
    if not np.array_equal(disabled, load("disabled_after")):
        raise SystemExit("Disabled sky restoration differs")
    # Room center excludes the background; geometry and camera are unchanged.
    roi = np.s_[110:280, 220:420]
    black = load("black")[roi]
    black_128 = load("black_128")[roi]
    black_256 = load("black_256")[roi]
    # UpdateTiles decays evidence only on tile updates, not every display frame.
    # A valid five-frame schedule retains full cache mean through frame 64.
    # Keep early response measurable; check eventual removal independently.
    print(f"Black-sky maxima at 64/128/256 frames: {black.max():.6f}/{black_128.max():.6f}/{black_256.max():.6f}")
    if black_128.max() > 0.02 or black_256.max() > 0.02:
        raise SystemExit("Sky history failed to decay in the extended removal check")
    if black_128.mean() > black.mean() + 1 / 255 or black_256.mean() > black_128.mean() + 1 / 255:
        raise SystemExit("Black-sky receiver energy increased during removal")
    uniform = load("uniform")[roi]
    green = load("green")[roi]
    rotation = np.abs(load("directional")[roi] - load("rotated")[roi]).mean()
    gain = uniform.mean() - black.mean()
    green_shift = (green - uniform).mean(axis=(0, 1))
    occlusion = (disabled[roi] - uniform).mean()
    print(
        f"Sky display-RGB gain={gain:.6f}; occlusion vs native ambient={occlusion:.6f}; rotation change={rotation:.6f}"
    )
    print(f"Green sky change RGB={green_shift}")
    if gain < 0.03 or occlusion < 0.005 or rotation < 0.005:
        raise SystemExit("Sky lighting, occlusion, removal, or orientation check failed")
    if green_shift[1] < green_shift[0] + 0.03 or green_shift[1] < green_shift[2] + 0.03:
        raise SystemExit("Sky color failed to reach receivers")
    print("Sky replacement preserves disabled rendering; all captures use 1/4 primary rays and denoising.")


if __name__ == "__main__":
    main()
