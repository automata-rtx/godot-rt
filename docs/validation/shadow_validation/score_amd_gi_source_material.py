#!/usr/bin/env python3
"""Check GPU source shading against authored triangle/material values, including mip filtering."""

import argparse
import re
from pathlib import Path

import numpy as np


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    path = parser.parse_args().directory
    log = (path / "run.log").read_text()
    if "ERROR:" in log or "SOURCE FINISHED" not in log:
        raise SystemExit("Engine errors or incomplete source-material fixture")
    phases = re.split(r"SOURCE phase (\d+)\n", log)
    checked = 0
    maximum = 0.0
    for index in range(1, len(phases), 2):
        phase = int(phases[index])
        records = re.findall(r"AMD GI source validation: ([0-9a-f]+)", phases[index + 1])
        if len(records) < 2:
            raise SystemExit(f"Missing GPU material samples in phase {phase}")
        # The first completed render can predate queued scene/uniform changes.
        for record in records[-2:]:
            values = np.frombuffer(bytes.fromhex(record), dtype="<f4").reshape(33, 4)
            if values[0, 0] != 1 or not np.isfinite(values).all():
                raise SystemExit("Expected exactly one finite source surface")
            if values[0, 2] != (0 if phase == 7 else 1):
                raise SystemExit("Native base-emissivity flag followed sampled RGB or failed shader replacement")
            if phase >= 6 and values[0, 3] != 0:
                raise SystemExit("Dark-phase hit emission was not zero")
            bias = 0.03125 + 0.0625 if phase == 0 else 0.125 + 0.25
            tint = np.array([1, 0.5, 0.25] if phase == 0 else [0.5, 1, 0.75])
            if phase >= 6:
                tint[:] = 0
            for sample in range(16):
                b, c = 0.0625 + (sample % 8) * 0.1, 0.125
                bridge = np.array([0.125 + 0.75 * b, 0.25 + 0.5 * c])
                if phase >= 2:
                    # RenderingServer::_surface_set_data truncates UV UNORM16.
                    corners = np.floor(np.array([[0.125, 0.25], [0.875, 0.25], [0.125, 0.75]]) * 65535) / 65535
                    bridge = corners[0] * (1 - b - c) + corners[1] * b + corners[2] * c
                # Native vertex-stage implicit reads always use mip zero,
                # independently of the fragment's volume/cone footprint.
                custom = 1.25 + b + 2 * c + 1.0
                color = 0.2 + 0.2 * b + 0.4 * c
                expected_albedo = np.r_[np.r_[bridge, color] + custom * 0.1 + bias, 0.25 + bridge[1] * 0.5]
                uv_extent = 0.5 if phase < 2 else np.floor(0.5 * 65535) / 65535
                uv_extent *= 4
                if sample >= 8:
                    # AMD's area-light builder packs per-corner UVs to half2.
                    uv_extent = float(np.float16(uv_extent))
                u, v = uv_extent * b, uv_extent * c
                if sample < 8:
                    x, y = min(int(u * 32), 31), min(int(v * 32), 31)
                    texture = np.array([(x + y) % 2, x / 31.0, y / 31.0])
                elif sample < 12:
                    # UV triangle area=4; 32x32 texture gives LOD 6, capped at 5.
                    texture = np.full(3, 0.5)
                else:
                    # Cone offset -2 selects LOD 4 (two texels per axis).
                    x, y = min(int(u * 2), 1), min(int(v * 2), 1)
                    texture = np.array([0.5, (7.5 + 16 * x) / 31, (7.5 + 16 * y) / 31])
                if phase >= 4:
                    coverage_x, coverage_y = min(int((u + 0.013) * 32), 31), min(int((v + 0.017) * 32), 31)
                    coverage = (coverage_x + coverage_y) % 2
                    expected_albedo[3] = coverage
                    if values[2 + 2 * sample, 3] != coverage:
                        raise SystemExit(f"Ray candidate coverage mismatch: phase={phase}, sample={sample}")
                error = max(
                    np.max(np.abs(values[1 + 2 * sample] - expected_albedo)),
                    np.max(np.abs(values[2 + 2 * sample, :3] - texture * tint)),
                )
                maximum = max(maximum, float(error))
                if error > 0.002:
                    raise SystemExit(
                        f"Source mismatch phase={phase} sample={sample}: error={error}; albedo={values[1 + 2 * sample]}, emission={values[2 + 2 * sample]}"
                    )
                checked += 1
    if checked != 256:
        raise SystemExit(f"Expected 256 checked GPU samples, got {checked}")
    print(f"{checked} source-material samples passed; maximum component error {maximum:.8f}.")
    print(
        "UV/UV2, vertex color/custom data, varyings, uniform/global/instance updates, point/volume/cone LOD, compressed attributes, transforms and actual textured-alpha/discard ray candidates exercised."
    )


if __name__ == "__main__":
    main()
