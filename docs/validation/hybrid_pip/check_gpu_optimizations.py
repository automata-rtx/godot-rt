"""Offline checks; never launches Godot or submits GPU work.

Usage: python check_gpu_optimizations.py BASELINE_SPIRV_DIR CANDIDATE_SPIRV_DIR
The inputs are outputs of the same offline compiler/material stubs for all
native/regional GI variants. This does not replace real driver validation.
"""

import collections
import json
import math
import struct
import sys
from pathlib import Path


def module(path):
    data = path.read_bytes()
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    assert words[0] == 0x07230203
    instructions = []
    i = 5
    while i < len(words):
        length = words[i] >> 16
        assert length
        instructions.append(words[i : i + length])
        i += length
    return instructions


def access_flags(instructions):
    decorations, members, pointers, variables = {}, {}, {}, {}
    for instruction in instructions:
        op, a = instruction[0] & 0xFFFF, instruction[1:]
        if op == 71:
            decorations.setdefault(a[0], {})[a[1]] = a[2:]
        elif op == 72:
            members.setdefault(a[0], {}).setdefault(a[1], set()).add(a[2])
        elif op == 32:
            pointers[a[0]] = a[2]
        elif op == 59:
            variables[a[1]] = a[0]
    result = {}
    for var, pointer in variables.items():
        flags = decorations.get(var, {})
        if flags.get(34) != (0,) or 33 not in flags:
            continue
        block = pointers[pointer]
        block_members = members.get(block, {})
        result[flags[33][0]] = (
            24 in flags
            or 24 in decorations.get(block, {})
            or bool(block_members)
            and all(24 in m for m in block_members.values())
        )
    return result


def check_spirv(baseline, candidate):
    paths = sorted(candidate.glob("*.spv"))
    assert len(paths) == 117
    consumers = 0
    for path in paths:
        before, after = module(baseline / path.name), module(path)

        # Allow only OpName/OpMemberName/OpDecorate/OpMemberDecorate changes.
        # All type, constant, function, memory, arithmetic and control-flow
        # instructions AND their IDs/operands must remain exactly equal.
        def without_names_and_decorations(instructions):
            return [i for i in instructions if i[0] & 0xFFFF not in (5, 6, 71, 72)]

        assert without_names_and_decorations(before) == without_names_and_decorations(after), path.name
        # Existing decorations must remain; the only additions permitted are
        # NonWritable on the known shared buffers.
        old_decor = collections.Counter(i for i in before if i[0] & 0xFFFF in (71, 72))
        new_decor = collections.Counter(i for i in after if i[0] & 0xFFFF in (71, 72))
        assert not old_decor - new_decor, path.name
        for instruction in new_decor - old_decor:
            assert instruction[2 if instruction[0] & 0xFFFF == 71 else 3] == 24, path.name
        flags = access_flags(after)
        assert flags[17]  # Previous radiance cache is never written.
        stage = int(path.stem.split("-")[-1])
        if 33 <= stage <= 53 or stage in (3, 4, 5, 6, 8, 9, 57, 58):
            consumers += 1
            shared = (13, 16, 17, 18, 19, 32, 33, 34, 35, 36, 44, 46, 59, 62)
            if path.name.startswith("batch"):
                shared += (68, 69)
            for binding in shared:
                if binding == 16 and stage == 46:
                    assert not flags[binding]  # Reflection cache aging atomic.
                else:
                    assert flags[binding], (path.name, binding)
    return {"unchanged_executable_spirv_variants": len(paths), "qualified_consumer_variants": consumers}


def moments(taps, center):
    norm = center + sum(w for x, y, w in taps)
    mean = [sum(t[i] * t[2] for t in taps) / norm for i in (0, 1)]
    covariance = [[sum(t[i] * t[j] * t[2] for t in taps) / norm - mean[i] * mean[j] for j in (0, 1)] for i in (0, 1)]
    return mean, covariance


def check_blur():
    root = Path(__file__).resolve().parents[3]
    source = (root / "servers/rendering/renderer_rd/effects/hybrid_pip.cpp").read_text()
    # Read the shipped coefficients so the numerical check covers their values.
    import re

    arrays = []
    for name in ("radii", "weights"):
        literal = re.search(r"float " + name + r"\[\] = \{([^}]+)\}", source)[1]
        arrays.append([float(x.strip().removesuffix("f")) for x in literal.split(",")])
    radii, weights = arrays
    old = []
    for tap in range(96):
        fraction = (tap + 0.5) / 96
        angle = tap * 2.39996323
        old.append((
            math.cos(angle) * math.sqrt(fraction),
            math.sin(angle) * math.sqrt(fraction),
            math.exp(-2 * fraction),
        ))
    new = []
    for tap in range(16):
        ring = tap // 4
        angle = ring * 2.39996323 + (tap % 4) * math.pi * 0.5
        new.append((
            math.cos(angle) * math.sqrt(radii[ring]),
            math.sin(angle) * math.sqrt(radii[ring]),
            math.exp(-2 * radii[ring]) * weights[ring] * 4,
        ))
    old_mean, old_cov = moments(old, 0.5)
    mean, cov = moments(new, 1 / 12)
    old_variance = (old_cov[0][0] + old_cov[1][1]) / 2
    variance = (cov[0][0] + cov[1][1]) / 2
    assert max(abs(x) for x in mean) < 1e-10
    assert abs(cov[0][0] - cov[1][1]) < 1e-10 and abs(cov[0][1]) < 1e-10
    assert abs(variance / old_variance - 1) < 0.001
    assert all(w > 0 and x * x + y * y <= 1 for x, y, w in new)
    # Radius compensation is continuous at mip boundaries and cannot exceed
    # the requested footprint. Constant HDR colors survive normalized filtering.
    alpha = sum(t[2] for t in new) / (sum(t[2] for t in new) + 1 / 12)
    for radius in (0.1, 0.25, 0.5, 1, 2, 3, 3.001, 5.999, 6, 6.001, 10.72, 16.08, 32.16):
        lod = max(math.log2(max(radius / 3, 1)), 0)
        lo = math.floor(lod)
        box = ((1 - (lod - lo)) * 4**lo + (lod - lo) * 4 ** (lo + 1) - 1) / 12
        sample_radius = math.sqrt(max(radius * radius - box / 0.17174118, 0))
        assert 0 <= sample_radius <= radius
        effective = variance * sample_radius * sample_radius + alpha * box
        assert abs(effective / (old_variance * radius * radius) - 1) < 0.001
    return {
        "old_axis_mean_variance": old_variance,
        "new_axis_variance": variance,
        "new_centroid": mean,
        "kernel_extent_change_requires_visual_review": True,
        "note": "Moments and normalization do not prove sparse sampling is visually equivalent.",
    }


if __name__ == "__main__":
    assert len(sys.argv) == 3, __doc__
    print(json.dumps({"spirv": check_spirv(Path(sys.argv[1]), Path(sys.argv[2])), "blur": check_blur()}, indent=2))
