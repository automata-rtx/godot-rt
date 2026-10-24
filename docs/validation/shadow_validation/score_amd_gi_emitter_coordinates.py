#!/usr/bin/env python3
"""Compare native emitter sampling with independently mapped triangle/mip values."""

import argparse
import re
from pathlib import Path

import numpy as np


def mapping(uv, uv2, mode, compressed):
    if mode == 0:
        return uv
    if mode in (1, 9):
        return uv2
    if mode == 2:
        return uv2 * [4, 0.25] + [0.02, 0.03]
    if mode == 3:
        angle = -0.61 if compressed else 0.37
        scale = [0.5, 0.125] if compressed else [0.25, 0.5]
        rotation = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
        return (uv2 * scale) @ rotation.T + [0.3, 0.1]
    if mode == 4:
        return uv * [0.125, 0.25] + [0.1, 0.2]
    if mode == 5:
        return uv2 * [2, 0.25]
    if mode == 6:
        return uv2 * 0.5
    if mode == 7:
        return uv2[..., ::-1] * [-0.5, 0.25] + [0.6, 0.1]
    if mode == 8:
        return uv2 / [4, 2]
    if mode == 10:
        return np.broadcast_to(uv2[0], uv2.shape).copy()
    raise AssertionError(mode)


def texel(uv, level):
    size = 32 >> level
    xy = np.clip(np.floor(uv * size), 0, size - 1)
    return np.r_[level / 8, (xy + 0.5) / size]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory
    log = (directory / "run.log").read_text()
    assert "COORDINATE FINISHED" in log and "ERROR:" not in log
    assert "outside the supported 2D affine" not in log, "An approved mapping fell back to UV0"
    phases = re.split(r"COORDINATE phase (\d+)\n", log)
    checked = 0
    worst = 0.0
    for i in range(1, len(phases), 2):
        phase = int(phases[i])
        compressed, mode = phase >= 11, phase % 11
        records = re.findall(r"AMD GI source validation: ([0-9a-f]+)", phases[i + 1])[-2:]
        assert len(records) == 2
        for record in records:
            values = np.frombuffer(bytes.fromhex(record), dtype="<f4").reshape(33, 4)
            assert np.isfinite(values).all() and values[0, 0] == 1 and values[0, 2] == 1
            for sample in range(16):
                bary = np.array([0.0625 + (sample % 8) * 0.1, 0.125])
                weights = np.r_[1 - bary.sum(), bary]
                uv = np.array([[0, 0], [0.5, 0], [0, 0.5]])
                uv2 = np.array([[0.125, 0.25], [0.875, 0.25], [0.125, 0.75]])
                if compressed:
                    uv, uv2 = np.floor(uv * 65535) / 65535, np.floor(uv2 * 65535) / 65535
                uv *= 4
                if sample >= 8:
                    uv = uv.astype(np.float16).astype(float)
                mapped = mapping(uv, uv2, mode, compressed)
                point = weights @ mapped
                corners = mapped.astype(np.float16).astype(float)
                a, b = corners[1] - corners[0], corners[2] - corners[0]
                area = abs(a[0] * b[1] - a[1] * b[0])
                lod = 0.0
                if sample >= 8:
                    lod = 0.5 * np.log2(32 * 32 * area) if area else -np.inf
                    lod += -2 if sample >= 12 else 0
                if mode == 8:
                    lod += 0.375
                if mode == 9:
                    lod = 2
                lod = np.clip(lod, 0, 5)
                lower = int(np.floor(lod))
                fraction = lod - lower
                expected = texel(point, lower) * (1 - fraction) + texel(point, min(lower + 1, 5)) * fraction
                actual = values[2 + sample * 2, :3]
                error = float(np.max(np.abs(expected - actual)))
                worst = max(worst, error)
                assert error < 0.003, f"phase={phase} sample={sample} mip={lod} expected={expected} actual={actual}"
                checked += 1
    assert checked == 704, checked
    print(f"{checked} GPU samples passed; maximum component error {worst:.8f}.")
    print(
        "UV0/UV2, scale/translation/rotation/mirroring, aliases, compound assignment, varyings, flat mapping, explicit LOD, bias, compressed vertices and live uniforms verified."
    )


if __name__ == "__main__":
    main()
