"""CPU proof of the proposed exact-default firefly shortcut; never launches Godot.

Integer count arithmetic is exactly representable in FP32 at the current radius
limit. Pixel tests cover the control-flow exceptions; they are not GPU evidence.
"""

import json
import math
import random


def rank(lower, higher, low, high):
    weight = float(lower + higher)
    return float(lower) < low * weight or float(higher) > high * weight


def mark(samples, width, height, stride, phase, px, py, radius, low, high, fast):
    rw, rh = (width + stride - 1) // stride, (height + stride - 1) // stride
    luma, roughness, distance = samples[py * rw + px]
    marked = False
    if roughness >= 0.0 and roughness <= 0.6:
        if distance < 0.0:
            marked = True
        elif not fast or low != 0.0 or high != 1.0:
            lower, higher = 0, 0
            half_radius = (radius + 1) // 2 if stride > 1 else radius
            for x in range(-half_radius, half_radius + 1):
                for y in range(-half_radius, half_radius + 1):
                    qx, qy = px + x, py + y
                    if (x == 0 and y == 0) or not (0 <= qx < rw and 0 <= qy < rh):
                        continue
                    fx, fy = qx * stride + phase[0], qy * stride + phase[1]
                    if not (0 <= fx < width and 0 <= fy < height):
                        continue
                    other_luma, other_roughness, _ = samples[qy * rw + qx]
                    if other_roughness > 0.6:
                        continue
                    weight = int(abs(x * stride) <= radius and abs(y * stride) <= radius)
                    higher += weight if other_luma < luma else 0
                    lower += weight if other_luma > luma else 0
            marked = rank(lower, higher, low, high)
    return marked


def main():
    maximum_neighbors = 33 * 33 - 1
    count_pairs = 0
    for lower in range(maximum_neighbors + 1):
        for higher in range(maximum_neighbors + 1 - lower):
            assert not rank(lower, higher, 0.0, 1.0)
            count_pairs += 1

    rng = random.Random(20261026)
    luminances = [0.0, -0.0, 0.1, 0.5, 1.0, -1.0, math.inf, -math.inf, math.nan]
    roughnesses = [-1.0, 0.0, 0.2, 0.6, 0.7, math.nan]
    distances = [-math.inf, -1.0, -0.0, 0.0, 1.0, math.inf, math.nan]
    thresholds = [
        (0.0, 1.0),
        (-0.0, 1.0),
        (0.05, 0.95),
        (0.0, 0.5),
        (0.5, 1.0),
        (1.0, 0.0),
        (math.nan, 1.0),
        (0.0, math.nan),
    ]
    cases = 0
    default_marked = 0
    custom_marked = 0
    for width, height in [(1, 1), (1, 7), (3, 5), (17, 13), (32, 24)]:
        for stride in [1, 2]:
            rw, rh = (width + stride - 1) // stride, (height + stride - 1) // stride
            for phase in [(x, y) for x in range(stride) for y in range(stride)]:
                samples = [
                    (rng.choice(luminances), rng.choice(roughnesses), rng.choice(distances)) for _ in range(rw * rh)
                ]
                for radius in [0, 1, 2, 3, 16]:
                    for low, high in thresholds:
                        for py in range(rh):
                            for px in range(rw):
                                baseline = mark(samples, width, height, stride, phase, px, py, radius, low, high, False)
                                optimized = mark(samples, width, height, stride, phase, px, py, radius, low, high, True)
                                assert baseline == optimized, (width, height, stride, phase, px, py, radius, low, high)
                                cases += 1
                                if low == 0.0 and high == 1.0:
                                    default_marked += optimized
                                else:
                                    custom_marked += optimized
    assert default_marked > 0, "Invalid/missing-hit cleanup branch was not covered."
    assert custom_marked > 0, "Custom-threshold fallback was not covered."
    print(
        json.dumps(
            {
                "maximum_neighbors": maximum_neighbors,
                "exhaustive_count_pairs": count_pairs,
                "pixel_control_flow_comparisons": cases,
                "default_negative_distance_marks": default_marked,
                "custom_threshold_marks": custom_marked,
                "result": "pass",
                "scope": "CPU arithmetic/control-flow only; GPU equivalence and timing still required",
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
