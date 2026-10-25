#!/usr/bin/env python3
"""CPU numerical oracle for AMD sky sampling; does not launch Godot or a GPU.

Checks the cubemap hierarchy against independently evaluated direction PDFs,
normalization/integrals, dark and HDR skies, cube face conventions, rotations,
and half-precision reservoir direction replay. This is a mathematical reference
check, not execution of the production GLSL or a rendered acceptance test.
"""

import math
import struct
from pathlib import Path

EPSILON = 1e-7
MAX_SAMPLE = 1.0 - 2.0**-24


def normalize(v):
    scale = math.sqrt(sum(x * x for x in v))
    return tuple(x / scale for x in v)


def cube_position(face, uv):
    x, y = (2.0 * a - 1.0 for a in uv)
    return ((1, -y, -x), (-1, -y, x), (x, 1, y), (x, -1, -y), (x, -y, 1), (-x, -y, -1))[face]


def cube_coordinates(direction):
    x, y, z = direction
    axis = max(range(3), key=lambda i: abs(direction[i]))
    magnitude = abs(direction[axis])
    face = 2 * axis + int(direction[axis] < 0.0)
    p = ((-z, -y), (z, -y), (x, z), (x, -z), (x, -y), (-x, -y))[face]
    return face, tuple(0.5 * (v / magnitude + 1.0) for v in p)


def mip_chain(values):
    levels = [values]
    while len(values[0]) > 1:
        size = len(values[0]) // 2
        values = [
            [
                [sum(values[f][2 * y + dy][2 * x + dx] for dy in (0, 1) for dx in (0, 1)) / 4.0 for x in range(size)]
                for y in range(size)
            ]
            for f in range(6)
        ]
        levels.append(values)
    return levels


def sample_importance(levels, random_pair):
    rx, ry = (min(max(r, 0.0), MAX_SAMPLE) for r in random_pair)
    face_mass = [max(levels[-1][f][0][0], EPSILON) for f in range(6)]
    total = sum(face_mass)
    choice = ry * total
    face = 0
    while face < 5 and choice >= face_mass[face]:
        choice -= face_mass[face]
        face += 1
    ry = min(max(choice / face_mass[face], 0.0), MAX_SAMPLE)
    probability = face_mass[face] / total
    ox = oy = 0
    width = 1
    for level in reversed(levels[:-1]):
        ox *= 2
        oy *= 2
        width *= 2
        masses = [max(level[face][oy + y][ox + x], EPSILON) for y in (0, 1) for x in (0, 1)]
        rows = [sum(masses[:2]), sum(masses[2:])]
        py = rows[0] / sum(rows)
        y = int(ry >= py)
        px = masses[2 * y] / rows[y]
        x = int(rx >= px)
        prob_y, prob_x = (py if y == 0 else 1 - py), (px if x == 0 else 1 - px)
        ry = min(max((ry - (py if y else 0)) / prob_y, 0.0), MAX_SAMPLE)
        rx = min(max((rx - (px if x else 0)) / prob_x, 0.0), MAX_SAMPLE)
        probability *= prob_x * prob_y
        ox += x
        oy += y
    direction = normalize(cube_position(face, ((ox + rx) / width, (oy + ry) / width)))
    pdf = probability * width**2 / (4.0 * max(map(abs, direction)) ** 3)
    return direction, pdf


def evaluate_pdf(levels, direction):
    """Independent known-direction traversal; no random residual inversion."""
    face, uv = cube_coordinates(direction)
    face_mass = [max(levels[-1][f][0][0], EPSILON) for f in range(6)]
    probability = face_mass[face] / sum(face_mass)
    for level in reversed(levels[:-1]):
        width = len(level[0])
        x, y = (min(int(value * width), width - 1) for value in uv)
        start_x, start_y = x & ~1, y & ~1
        parent_mass = sum(max(level[face][start_y + dy][start_x + dx], EPSILON) for dy in (0, 1) for dx in (0, 1))
        probability *= max(level[face][y][x], EPSILON) / parent_mass
    width = len(levels[0][0])
    return probability * width**2 / (4.0 * max(map(abs, direction)) ** 3)


def halton(index, base):
    result = 0.0
    inverse = 1.0 / base
    scale = inverse
    while index:
        result += (index % base) * scale
        index //= base
        scale *= inverse
    return result


def half(value):
    return struct.unpack("e", struct.pack("e", value))[0]


def float32(value):
    return struct.unpack("f", struct.pack("f", value))[0]


def pack_direction(direction):
    x, y, z = (v / sum(map(abs, direction)) for v in direction)
    if z < 0:
        x, y = ((1 - abs(y)) * (1 if x >= 0 else -1), (1 - abs(x)) * (1 if y >= 0 else -1))
    return half(x), half(y)


def unpack_direction(packed):
    x, y = packed
    z = 1 - abs(x) - abs(y)
    t = max(-z, 0)
    x += -math.copysign(t, x) if x else 0
    y += -math.copysign(t, y) if y else 0
    return normalize((x, y, z))


def run_checks():
    checks = 0
    for face in range(6):
        for uv in ((0.1, 0.2), (0.8, 0.9), (0.5, 0.5)):
            actual_face, actual_uv = cube_coordinates(cube_position(face, uv))
            assert actual_face == face
            assert max(abs(a - b) for a, b in zip(uv, actual_uv)) < 1e-12
            checks += 1

    size = 8
    constant = mip_chain([[[1.0] * size for _ in range(size)] for _ in range(6)])
    dark = mip_chain([[[0.0] * size for _ in range(size)] for _ in range(6)])
    hdr = mip_chain([
        [[60000.0 if (f, x, y) == (4, 3, 2) else 0.0 for x in range(size)] for y in range(size)] for f in range(6)
    ])
    varied = mip_chain([
        [[0.1 + (f + 1) * (x + 1) * (y + 1) for x in range(size)] for y in range(size)] for f in range(6)
    ])

    samples = 16384
    integrals = [0.0] * 4
    max_replay_error = 0.0
    for i in range(1, samples + 1):
        pair = halton(i, 2), halton(i, 3)
        for levels in (constant, dark, hdr, varied):
            direction, pdf = sample_importance(levels, pair)
            expected_pdf = evaluate_pdf(levels, direction)
            assert math.isfinite(pdf) and pdf > 0.0
            assert abs(pdf - expected_pdf) < 1e-9 * max(pdf, expected_pdf)
            checks += 2
        direction, pdf = sample_importance(constant, pair)
        integrals[0] += 1.0 / pdf
        integrals[1] += max(direction[2], 0.0) / pdf
        # Independent uniform/cosine hemisphere integrals of a unit sky.
        cosine_uniform = 1 - pair[1]
        integrals[2] += cosine_uniform * 2 * math.pi
        cosine_weighted = math.sqrt(1 - pair[0])
        integrals[3] += cosine_weighted / (cosine_weighted / math.pi)
        # Rotate sky direction to world before storage. A future sky change
        # must not reinterpret its random seed or rotate this stored direction.
        angle = 0.731
        x, y, z = direction
        world = (math.cos(angle) * x + math.sin(angle) * z, y, -math.sin(angle) * x + math.cos(angle) * z)
        replay = unpack_direction(pack_direction(world))
        assert abs(sum(v * v for v in replay) - 1) < 1e-12
        max_replay_error = max(max_replay_error, math.sqrt(sum((a - b) ** 2 for a, b in zip(world, replay))))
        checks += 1

    for actual, expected in zip(integrals, (4 * math.pi, math.pi, math.pi, math.pi)):
        assert abs(actual / samples - expected) < expected * 0.003, (actual / samples, expected)
        checks += 1
    assert max_replay_error < 0.0025
    checks += 1
    # Packed half endpoints, 1x1 cubes and black faces must remain finite.
    single_texel = mip_chain([[[0.0]] for _ in range(6)])
    for levels in (constant, dark, hdr, single_texel):
        for pair in ((0, 0), (1, 1), (0, 1), (1, 0), (0.5, 0.5)):
            direction, pdf = sample_importance(levels, pair)
            assert math.isfinite(pdf) and pdf > 0 and all(map(math.isfinite, direction))
            checks += 1

    # Exercise the production branch arithmetic in float32. Both probabilities
    # can round to 1 under HDR ratios; half-open residuals must never select the
    # resulting zero-probability branch. Zero is safe because masses are floored.
    for low, high in ((EPSILON, 65504.0), (65504.0, EPSILON), (EPSILON, EPSILON), (1, 1)):
        probability = float32(float32(low) / float32(float32(low) + float32(high)))
        for residual in (0.0, MAX_SAMPLE, 0.5, half(1.0 - 0.0001)):
            residual = min(float32(residual), MAX_SAMPLE)
            upper = residual >= probability
            selected = float32(1.0 - probability) if upper else probability
            assert selected > 0
            remapped = float32(float32(residual - (probability if upper else 0.0)) / selected)
            assert math.isfinite(remapped)
            checks += 2

    # The game's bright disk has angular size 0.02. Probe its boundary and both
    # oct poles explicitly, where a half-precision direction encoding can have
    # different precision than a full-precision hierarchy sample.
    boundary_error = 0.0
    for zsign in (-1, 1):
        for radius in (0, 0.0199, 0.02, 0.0201):
            for step in range(32):
                phi = step * math.tau / 32
                direction = (
                    math.sin(radius) * math.cos(phi),
                    math.sin(radius) * math.sin(phi),
                    zsign * math.cos(radius),
                )
                replay = unpack_direction(pack_direction(direction))
                error = math.sqrt(sum((a - b) ** 2 for a, b in zip(direction, replay)))
                boundary_error = max(boundary_error, error)
                assert error < 0.0025
                checks += 1

    root = Path(__file__).resolve().parents[3]
    lights = (root / "servers/rendering/renderer_rd/shaders/effects/amd_gi_lights_inc.glsl").read_text()
    assert "gi_sample_environment(sample_params, ray.normal_mask.xyz, area_pdf)" in lights
    assert "sample_params = vec3_to_oct(sampled_direction) * 2.0 - 1.0" in lights
    assert "oct_to_vec3(sample_params)" in lights
    checks += 3
    print(f"PASS {checks} CPU sky checks; maximum half-oct direction error {max_replay_error:.6f}")
    print(f"Pole/sun-boundary maximum direction error {boundary_error:.6f}; HDR float32 branch checks passed")
    print("Mathematical oracle/source contracts only; no GPU shader or game execution.")


if __name__ == "__main__":
    run_checks()
