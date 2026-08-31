"""The case the visibility bitmask exists for.

The box scene is entirely solid and convex, so "everything behind the first
occluder is also occluded" happens to be TRUE there -- which is why a horizon
march scores well on it. This scene is built out of thin geometry with sky
behind it: a louvre of slats, a standing fin, and a table on thin legs. Here the
horizon assumption is false almost everywhere, and the two estimators should
finally separate.
"""
import numpy as np

_b = [
    [0.0, -0.1, 0.0, 20.0, 0.2, 20.0],          # floor
    [-1.5, 1.05, 0.0, 0.05, 2.1, 2.2],          # standing fin, 5 cm thick
]
# Louvre: six slats with sky between them, over the right half of the floor.
for i in range(6):
    _b.append([0.9, 1.1, -1.25 + i * 0.5, 2.4, 0.07, 0.22])
# Table: a thin top on four thin legs.
_b.append([0.4, 0.62, 1.6, 1.4, 0.06, 1.0])
for dx in (-0.6, 0.6):
    for dz in (-0.42, 0.42):
        _b.append([0.4 + dx, 0.3, 1.6 + dz, 0.07, 0.6, 0.07])

BOXES = np.array(_b)
CAM_POS = np.array([2.9, 1.9, 3.4])
CAM_TARGET = np.array([0.0, 0.45, 0.2])
