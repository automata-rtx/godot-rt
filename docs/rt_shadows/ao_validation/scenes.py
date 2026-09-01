"""The scenes the references and the shader are compared on.

Both are built from axis aligned boxes and nothing else, so the same geometry
can be traced on the CPU without importing anything from the engine.

SOLID is the obvious scene, and on its own it is misleading. Everything in it is
solid and convex, which makes "everything behind the first occluder is also
occluded" accidentally TRUE -- a plain horizon march scores well there for the
wrong reason, and a visibility bitmask has nothing to win. THIN is the scene the
bitmask exists for: a louvre with sky between its slats, a standing fin five
centimeters thick, a table on thin legs. Pick it with AO_SCENE=thin.
"""

import os

import numpy as np

SOLID_BOXES = np.array([
    [0.0, -0.1, 0.0, 20.0, 0.2, 20.0],  # floor
    [-1.2, 0.35, 0.0, 0.7, 0.7, 0.7],
    [-0.25, 0.35, 0.0, 0.7, 0.7, 0.7],
    [0.7, 0.35, 0.0, 0.7, 0.7, 0.7],
    [1.65, 0.35, 0.0, 0.7, 0.7, 0.7],
    [0.0, 0.8, -1.2, 4.0, 1.6, 0.15],  # back wall
    [1.6, 0.9, 0.9, 1.6, 0.06, 1.0],  # floating shelf
])
SOLID_CAM_POS = np.array([3.2, 2.4, 3.2])
SOLID_CAM_TARGET = np.array([0.0, 0.4, 0.0])


def _thin_boxes() -> np.ndarray:
    boxes = [
        [0.0, -0.1, 0.0, 20.0, 0.2, 20.0],  # floor
        [-1.5, 1.05, 0.0, 0.05, 2.1, 2.2],  # standing fin
    ]
    for i in range(6):  # louvre: six slats with sky between them
        boxes.append([0.9, 1.1, -1.25 + i * 0.5, 2.4, 0.07, 0.22])
    boxes.append([0.4, 0.62, 1.6, 1.4, 0.06, 1.0])  # table top
    for dx in (-0.6, 0.6):
        for dz in (-0.42, 0.42):
            boxes.append([0.4 + dx, 0.3, 1.6 + dz, 0.07, 0.6, 0.07])  # legs
    return np.array(boxes)


THIN_BOXES = _thin_boxes()
THIN_CAM_POS = np.array([2.9, 1.9, 3.4])
THIN_CAM_TARGET = np.array([0.0, 0.45, 0.2])


def active() -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """The selected scene as (boxes, box lower corners, box upper corners,
    camera position, camera target)."""
    if os.environ.get("AO_SCENE") == "thin":
        boxes, pos, target = THIN_BOXES, THIN_CAM_POS, THIN_CAM_TARGET
    else:
        boxes, pos, target = SOLID_BOXES, SOLID_CAM_POS, SOLID_CAM_TARGET
    return boxes, boxes[:, :3] - boxes[:, 3:] * 0.5, boxes[:, :3] + boxes[:, 3:] * 0.5, pos, target
