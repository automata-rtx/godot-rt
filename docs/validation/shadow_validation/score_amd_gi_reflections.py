#!/usr/bin/env python3
"""Check reflective materials, off-screen geometry, resolution/toggle restoration."""

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
        return np.asarray(Image.open(directory / f"reflections_{name}.png").convert("RGB"), dtype=float) / 255

    off, half, full = load("off"), load("half"), load("full")
    gain = (half - off).mean()
    restoration = np.abs(load("restored") - half).mean()
    disabled_error = np.abs(load("off_after") - off).mean()
    # Bright red emitter is behind the camera. It can only appear through RT.
    emitter = full - load("no_emitter")
    red = (emitter[:, :, 0] > 0.15) & (emitter[:, :, 0] > emitter[:, :, 1] + 0.05)
    mirror_pixels = int(red[105:195, 220:395].sum())
    print(f"Mirror emitter pixels={mirror_pixels}")
    print(
        f"Reflection display-RGB gain={gain:.6f}; restored MAE={restoration:.6f}; disabled MAE={disabled_error:.6f}; emitter pixels={red.sum()}"
    )
    if gain < 0.005 or mirror_pixels < 50 or restoration > 0.015 or disabled_error > 0.01:
        raise SystemExit("Reflection visibility/toggle check failed")
    moved_difference = np.abs(load("emitter_moved") - full)[105:195, 220:395].mean()
    returned_difference = np.abs(load("emitter_restored") - full)[105:195, 220:395].mean()
    print(f"Moving off-screen emitter: mirror change={moved_difference:.6f}, return MAE={returned_difference:.6f}")
    # Whole-mirror MAE also measures stochastic wall/floor lighting. Track the
    # isolated emissive patch and the regions it vacated to test geometry motion
    # and ghosting directly, without treating noise as a correspondence failure.
    region = (slice(120, 165), slice(260, 325))
    masks, centers = [], []
    for name in ("full", "emitter_moved", "emitter_restored"):
        delta = (load(name) - load("no_emitter"))[region]
        mask = (delta[:, :, 0] > 0.15) & (delta[:, :, 0] > delta[:, :, 1] + 0.05)
        y, x = np.where(mask)
        if len(x) < 200:
            raise SystemExit("Reflected emissive patch disappeared")
        masks.append(mask)
        centers.append(np.array([x.mean(), y.mean()]))
    overlap = (masks[0] & masks[2]).sum() / (masks[0] | masks[2]).sum()
    x = np.indices(masks[0].shape)[1]
    vacated = masks[0] & (x < centers[0][0] - 6)
    returned = masks[1] & (x > centers[1][0] + 6)
    ghost_move = (vacated & masks[1]).sum() / max(vacated.sum(), 1)
    ghost_return = (returned & masks[2]).sum() / max(returned.sum(), 1)
    print(
        f"Emitter shift={centers[1][0] - centers[0][0]:.3f}px; return overlap={overlap:.3f}; vacated residual={ghost_move:.3f}/{ghost_return:.3f}"
    )
    if centers[1][0] - centers[0][0] < 10 or np.linalg.norm(centers[2] - centers[0]) > 2 or overlap < 0.7:
        raise SystemExit("Reflected emitter did not move/return to the expected location")
    if vacated.sum() < 40 or returned.sum() < 40 or max(ghost_move, ghost_return) > 0.1:
        raise SystemExit("Reflected emitter left an excessive ghost in vacated regions")
    resolution_error = np.abs(half - full).mean()
    print(f"Half/full resolution mean absolute display-RGB difference={resolution_error:.6f}")
    if resolution_error > 0.035:
        raise SystemExit("Reflection resolution variants differ excessively")

    def linear(srgb):
        return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)

    compaction_error = np.abs(linear(full) - linear(load("uncompacted"))).mean()
    print(f"Compacted/direct-dispatch reflection linear RGB MAE={compaction_error:.6f}")
    if compaction_error > 0.005:
        raise SystemExit("Ray compaction changed the reflection estimator")
    log = (directory / "run.log").read_text()
    start, end = "stage reflections: emitter motion\n", "stage reflections: emitter motion finished"
    if log.count(start) != 1 or log.count(end) != 1:
        raise SystemExit("Missing moving-emitter validation interval")
    motion = log.split(start)[1].split(end)[0]
    # AMD reprojects/rejects individual samples. The removed fork-specific swept
    # boxes must not be required merely because they used to emit a diagnostic.
    if "AMD GI history reset:" in motion or "AMD GI reset reasons:" in motion:
        raise SystemExit("Moving reflections caused a global history reset")
    if motion.count("AMD GI reflection validation:") < 8:
        raise SystemExit("Moving-emitter interval did not exercise enough reflection frames")
    memory = {
        name: int(buffers)
        for name, buffers in re.findall(r"GI memory reflections_(\w+): textures=\d+ buffers=(\d+)", log)
    }
    height, width = half.shape[:2]
    # Reference reconstruction traces at half resolution but accumulates history
    # at full resolution: one half-resolution sample buffer, two full histories.
    expected = ((width + 1) // 2) * ((height + 1) // 2) * (64 + 4) + width * height * 64 * 2 + 16 - 48
    if memory["restored"] - memory["off_after"] != expected:
        raise SystemExit("Reflection buffers did not release on disable")
    checks = re.findall(r"AMD GI reflection validation: budget=(\d+) traced=(\d+) probes=(\d+)", log)
    if not checks or not any(int(traced) > 0 and int(probes) > 0 for _, traced, probes in checks):
        raise SystemExit("Missing GPU reflection sampling/probe-reuse checks")
    if any(int(traced) + int(probes) > int(budget) for budget, traced, probes in checks):
        raise SystemExit("Glossy sampling exceeded its primary budget")
    print(f"GPU sample checks passed on {len(checks)} frames; tracing and rough probe reuse exercised.")
    print("Reflections toggle releases its buffers; denoising and 1/4 diffuse-ray budget stayed fixed.")


if __name__ == "__main__":
    main()
