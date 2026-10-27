#!/usr/bin/env python3
"""Require exact hard-shadow captures and non-vacuous mutation controls.

Compare same-machine baseline and candidate run_lifecycle.py output directories.
Uses decoded PNG channel bytes; exact equivalence is independent of color space.
No numerical image-quality claim is made from gamma-encoded differences.
"""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def read(path):
    return np.asarray(Image.open(path).convert("RGB"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    baseline_manifest = json.loads((args.baseline / "manifest.json").read_text())
    candidate_manifest = json.loads((args.candidate / "manifest.json").read_text())
    if not baseline_manifest.get("passed") or not candidate_manifest.get("passed"):
        raise RuntimeError("Both capture runs must have passed parse, engine-error and completion checks")
    for field in ("project_sha256", "script_sha256"):
        if baseline_manifest[field] != candidate_manifest[field]:
            raise RuntimeError(f"Fixture identity differs: {field}")
    expected = json.loads((args.baseline / "lifecycle.json").read_text())
    actual = json.loads((args.candidate / "lifecycle.json").read_text())
    if expected != actual or actual["failures"]:
        raise RuntimeError("Lifecycle reports differ or have recorded failures")
    comparisons = []
    total_pixels = 0
    for row in expected["stages"]:
        for index, size in enumerate(row["views"]):
            name = f"{row['stage']}_{index}.png"
            before = read(args.baseline / name)
            after = read(args.candidate / name)
            shape = (size["height"], size["width"], 3)
            if before.shape != shape or after.shape != shape:
                raise RuntimeError(f"Unexpected image dimensions in {name}")
            changed = int(np.count_nonzero(np.any(before != after, axis=2)))
            comparisons.append({"capture": name, "different_pixels": changed})
            total_pixels += shape[0] * shape[1]
            if changed:
                raise RuntimeError(f"{name}: {changed} differing pixels; hard-shadow equivalence failed")
    controls = []
    # These pairs change only ray-caster eligibility; raster geometry/lighting
    # remain fixed. A fixture with missing/disabled RT shadows must fail them.
    for left, right in [
        ("initial", "all_shadow_casters_disabled"),
        ("shadow_mask_excluded", "shadow_mask_restored"),
        ("scatter_disabled", "scatter_restored"),
    ]:
        before = read(args.baseline / f"{left}_0.png")
        after = read(args.baseline / f"{right}_0.png")
        changed = int(np.count_nonzero(np.any(before != after, axis=2)))
        controls.append({"left": left, "right": right, "different_pixels": changed})
        if changed < 32:
            raise RuntimeError(f"Vacuous shadow control {left}/{right}: only {changed} differing pixels")
    result = {"passed": True, "captures": comparisons, "pixels": total_pixels, "controls": controls}
    (args.candidate / "comparison.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
