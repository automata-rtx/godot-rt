#!/usr/bin/env python3
"""Integration contracts, not whole-pipeline AMD image equivalence."""

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("rig", choices=("amd_gi_consequential", "amd_gi_exposure"))
args = parser.parse_args()
log = (args.directory / "run.log").read_text()
assert "ERROR:" not in log and "GI is suppressed" not in log
label = "consequential" if args.rig == "amd_gi_consequential" else "exposure"
assert f"AMD {label} integration completed: 0 failures" in log


def load(name):
    return np.asarray(Image.open(args.directory / f"{label}_{name}.png").convert("RGB"), dtype=float) / 255


if label == "consequential":
    for diagnostic in ("hit update", "multibounce", "cache"):
        assert f"AMD GI {diagnostic} validation:" in log, diagnostic
    empty = log.split("CONSEQUENTIAL stage: empty screen")[1].split("CONSEQUENTIAL stage: restored screen")[0]
    assert "primary=0 secondary=0" in empty, "Zero-work dispatch was not exercised"
    assert re.search(r"scheduled=0 budget=\d+", empty), "Empty probe schedule not exercised"
    assert load("disabled").shape[:2] == (177, 317), "Odd-size resize not exercised"
    camera_change = log.split("CONSEQUENTIAL stage: camera replacement")[1].split(
        "CONSEQUENTIAL stage: camera restored"
    )[0]
    assert "AMD GI history reset:" not in camera_change, "Camera replacement globally reset GI"
    second = load("second")
    assert second.shape[:2] == (91, 159) and second.mean() > 0.01, "Second viewport failed to render"
    difference = np.abs(load("return") - load("after_viewport")).mean()
    assert difference < 0.02, f"Main viewport changed after secondary viewport lifetime: MAE={difference}"
    print(
        "Compacted hit ownership, cache LRU, continuation, empty-screen dispatch, camera replacement, independent viewport lifetime, odd-size resize and disable completed."
    )
else:
    manual, bright, restored = load("manual"), load("bright"), load("restored")
    assert bright.mean() > manual.mean() * 1.05, "Manual exposure did not affect rendering"
    restoration = np.abs(manual - restored).mean()
    assert restoration < 0.02, f"Exposure restoration MAE={restoration}"
    auto, dark = load("auto"), load("dark_adapted")
    assert auto.mean() > 0.01 and dark.mean() > 0.001, "Auto-exposure output is black"
    resets = re.findall(r"AMD GI reset reasons:.*", log)
    assert len(resets) == 1 and "frame=0" in resets[0], resets
    histories = re.findall(r"AMD GI glossy history:.*mean=([0-9.]+)", log)
    assert histories and max(map(float, histories)) > 1.5, "Reflection history never accumulated"
    print(f"Manual/automatic exposure branches and history retention exercised; restoration MAE={restoration:.6f}.")
print("Default quarter primary rays, denoising enabled; software Vulkan, not hardware performance or AMD image parity.")
