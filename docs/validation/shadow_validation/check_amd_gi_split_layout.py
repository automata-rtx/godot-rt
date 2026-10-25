#!/usr/bin/env python3
"""CPU address-domain proof for AMD's split reflection reconstruction.

No engine or GPU is launched. Exercise both sample strides, every checker phase,
small/odd dimensions, edge taps, both jitter directions and the fallback sweep.
This guards the easy-to-miss full-width/half-height intermediate allocation; it
does not establish GPU image quality, timing, or temporal stability.
"""

from itertools import product


def check_layout(width, height, stride, phase):
    half_width = (width + stride - 1) // stride
    half_height = (height + stride - 1) // stride
    phase_x, phase_y = phase if stride == 2 else (0, 0)
    written = {(x, y) for y in range(half_height) for x in range(width) if y * stride < height}
    checks = 0
    needs_full_width = False
    # Filter radius 32 covers all supported intermediate radii for these sizes.
    # Smaller radius and the three-tap fallback are subsets of these offsets.
    half_radius = (32 + stride - 1) // stride
    for x, y, jitter in product(range(width), range(height), (-1, 0, 1)):
        qx = x // stride + jitter
        for offset in range(-half_radius, half_radius + 1):
            qy = y // stride + offset
            full_x = qx * stride + phase_x
            full_y = qy * stride + phase_y
            if not (0 <= full_x < width and 0 <= full_y < height):
                continue
            assert 0 <= qx < half_width and 0 <= qy < half_height
            # Split Y reads a FULL x coordinate and HALF y coordinate. Every
            # read must be within the allocation and initialized by split X.
            assert (full_x, qy) in written
            needs_full_width |= full_x >= half_width
            checks += 1
    return checks, needs_full_width


def main():
    checks = 0
    old_half_width_failures = 0
    for width, height in ((1, 1), (2, 2), (3, 5), (5, 3), (17, 9), (37, 23)):
        for stride in (1, 2):
            for phase in product((0, 1), repeat=2):
                count, old_width_failed = check_layout(width, height, stride, phase)
                checks += count
                old_half_width_failures += int(old_width_failed)
    assert old_half_width_failures > 0, "Test must reject the old half-width layout."
    print(
        f"PASS: {checks} split Y reads map to initialized split X texels; "
        f"{old_half_width_failures} scenarios reject a half-width intermediate."
    )


if __name__ == "__main__":
    main()
