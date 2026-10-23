#!/usr/bin/env python3
"""Check emission-only transport, live removal, and flicker without global resets."""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
directory = parser.parse_args().directory


def energy(name):
    srgb = np.asarray(Image.open(directory / f"emitter_{name}.png").convert("RGB"), dtype=float) / 255.0
    linear = np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)
    height, width = linear.shape[:2]
    # Floor/box receivers only: excludes the directly visible luminous panel.
    return linear[int(height * 0.6) : int(height * 0.85), int(width * 0.25) : int(width * 0.75)].mean()


sampled, hit_only, removed = (energy(name) for name in ("on", "hit_only", "removed"))
print(f"Linear receiver energy: explicit={sampled:.6f}, hit-only={hit_only:.6f}, removed={removed:.6f}")
assert sampled > 0.005 and hit_only > 0.005
assert 0.7 < sampled / hit_only < 1.3, "Explicit area sampling changes mean energy excessively"
assert removed < sampled * 0.02, "Removed emitter leaves excessive stale illumination"
for cycle in range(4):
    off, on = energy(f"flicker_off_{cycle}"), energy(f"flicker_on_{cycle}")
    print(f"Cycle {cycle}: off={off:.6f}, on={on:.6f}")
    assert off < on and on > 0.2 * sampled, "Emitter response fails during repeated toggles"
log = (directory / "run.log").read_text()
assert "EMITTER FINISHED" in log and "ERROR:" not in log and "GI is suppressed" not in log
assert "AMD GI reset reasons:" not in log.split("EMITTER stage: flicker")[1]
print("Explicit emitter transport, bounded removal tail, and flicker continuity pass at quarter rate.")
