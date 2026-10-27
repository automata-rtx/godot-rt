#!/usr/bin/env python3
"""Compare native instanced colors/custom data/IDs against separate mesh materials."""

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--retained-scene", action="store_true")
    args = parser.parse_args()
    directory = args.directory

    def load(name):
        return np.asarray(Image.open(directory / f"multimesh_{name}.png").convert("RGB"), dtype=float) / 255.0

    off, on = load("off"), load("on")
    direct = np.abs(off - load("reference_off")).mean()
    gi = np.abs(on - load("reference_on")).mean()
    restore = np.abs(on - load("restored")).mean()
    update = np.abs(on - load("updated")).mean()
    gain = (on - off).mean()
    print(
        f"Mesh/MultiMesh direct MAE={direct:.6f}; GI MAE={gi:.6f}; motion restoration={restore:.6f}; color/custom change={update:.6f}; GI gain={gain:.6f}"
    )
    assert direct < 0.001 and gi < 0.008 and restore < 0.008
    assert gain > 0.01 and update > 0.005

    def linear(srgb):
        return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)

    excluded = np.abs(linear(on) - linear(load("excluded"))).mean()
    print(f"Explicitly excluded 65,537-element procedural MultiMesh: linear RGB MAE={excluded:.6f}")
    assert excluded < 0.004
    assert np.array_equal(off, load("disabled_after"))
    log = (directory / "run.log").read_text()
    assert "GI is suppressed" not in log
    if args.retained_scene:
        emissive = "RETAINED_MULTIMESH emissive=true" in log
        assert emissive or "RETAINED_MULTIMESH nonemissive=true" in log, "Missing retained subject material mode"
        for stage in ("on", "restored", "updated"):
            start = f"RETAINED_MULTIMESH stage {stage}\n"
            end = f"RETAINED_MULTIMESH stage end_{stage}"
            assert log.count(start) == 1 and log.count(end) == 1, f"{stage}: missing or ambiguous coverage markers"
            remainder = log.split(start, 1)[1]
            assert end in remainder, f"{stage}: coverage markers out of order"
            section = remainder.split(end, 1)[0]
            streak = maximum = checked = 0
            for line in section.splitlines():
                if not line.startswith("AMD GI retained groups:"):
                    continue
                fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", line)}
                complete = (
                    fields["reused_surfaces"] > 0
                    and fields["reused_surfaces"] == fields["total_surfaces"]
                    and (
                        not emissive
                        or (
                            fields.get("reused_emitter_batches", 0) > 0
                            and fields.get("reused_emitter_triangles", 0) > 0
                        )
                    )
                )
                checked += 1
                streak = streak + 1 if complete else 0
                maximum = max(maximum, streak)
            assert maximum >= 2, f"{stage}: no two consecutive complete scene/emitter retention checks"
            print(
                f"Actual retention {stage}: {checked} updates, complete scene streak={maximum}, emissive_subjects={emissive}"
            )
        print("History-reset assertions require the separate ordinary TRACE_HISTORY run.")
    else:
        moving = log.split("stage multimesh: move")[1].split("stage multimesh: color/custom update")[0]
        assert "AMD GI history reset" not in moving
    print("Native element inputs, transformed normals, motion, live updates and disabled restoration pass.")


if __name__ == "__main__":
    main()
