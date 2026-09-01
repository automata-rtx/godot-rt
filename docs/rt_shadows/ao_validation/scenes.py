"""The scenes the references and the shader are compared on.

Both are built from axis aligned boxes and nothing else, so the same geometry
can be traced on the CPU without importing anything from the engine.

SOLID is the obvious scene, and on its own it is misleading. Everything in it is
solid and convex, which makes "everything behind the first occluder is also
occluded" accidentally TRUE -- a plain horizon march scores well there for the
wrong reason, and a visibility bitmask has nothing to win. THIN is the scene the
bitmask exists for: a louvre with sky between its slats, a standing fin five
centimeters thick, a table on thin legs. Pick it with AO_SCENE=thin.

ROOM exists because those two, together, still missed a failure that made the
effect unusable. Both are viewed from OUTSIDE, from above, over one large flat
floor with open sky in every direction, and their mean occlusion is under one
percent -- so a correct occlusion barely enters the range the output transfer
operates on. A closed interior with the camera inside it puts seven percent of
the frame there instead of half of one percent. It is also the only scene that
is not square, so an aspect-dependent defect can appear at all. AO_SCENE=room.
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


def _room_boxes() -> np.ndarray:
    """A closed interior seen from inside it.

    Every surface has another within a meter or two, which is the only way to
    get a mean visibility near 0.93 instead of 0.99. The twelve meters of length
    give one frame a depth range of about 1.4 to 10.7 m, so a depth-scaled
    radius spans 0.19 to 1.45 m and any depth-dependent defect shows up as a
    spatial gradient. The side walls run to the frame border, so marches leave
    the screen constantly. The beams and the table legs give long straight
    creases at several orientations, which is what makes a transfer's plateau
    visible as a shape rather than as a number. The rugs sit 12 mm off the
    floor, which is a near-coplanar surface and stresses the elevation bias.
    """
    w, h, ln, t = 5.0, 2.8, 12.0, 0.2
    boxes = [
        [0.0, -t / 2, 0.0, w, t, ln],  # floor
        [0.0, h + t / 2, 0.0, w, t, ln],  # ceiling
        [-w / 2 - t / 2, h / 2, 0.0, t, h, ln],  # left wall
        [w / 2 + t / 2, h / 2, 0.0, t, h, ln],  # right wall
        [0.0, h / 2, -ln / 2 - t / 2, w, h, t],  # far wall
        [0.0, h / 2, ln / 2 + t / 2, w, h, t],  # wall behind the camera
    ]
    for z in (-3.0, 0.0, 3.0):
        boxes.append([0.0, h - 0.15, z, w, 0.3, 0.35])  # ceiling beams
    boxes.append([0.0, 0.74, -1.0, 1.4, 0.06, 3.6])  # table top
    for dx in (-0.6, 0.6):
        for z in (-3.6, -0.4):
            boxes.append([dx, 0.37, z, 0.08, 0.74, 0.08])  # table legs
    for sx in (-1.15, 1.15):
        for z in (-2.0, -0.2):
            boxes.append([sx, 0.22, z, 0.45, 0.44, 0.45])  # seat
            boxes.append([sx + (0.25 if sx > 0 else -0.25), 0.60, z, 0.06, 0.9, 0.45])  # back
    boxes.append([0.0, 0.006, -1.0, 2.6, 0.012, 4.4])  # rug
    boxes.append([0.0, 0.006, 3.6, 2.0, 0.012, 2.4])  # rug
    return np.array(boxes)


ROOM_BOXES = _room_boxes()
ROOM_CAM_POS = np.array([0.0, 1.62, 4.6])
ROOM_CAM_TARGET = np.array([0.0, 1.30, -4.0])


def active() -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, int, int]:
    """The selected scene as (boxes, box lower corners, box upper corners,
    camera position, camera target, viewport width, viewport height).

    The viewport belongs to the scene rather than to the tracer because it is
    part of what a scene tests: the effect radius under scale_radius_with_distance
    is anchored to screen height while a camera holds its VERTICAL field of view
    fixed, so a non-square scene is the only one that can catch an aspect bug.
    """
    scene = os.environ.get("AO_SCENE")
    if scene == "thin":
        return THIN_BOXES, *_corners(THIN_BOXES), THIN_CAM_POS, THIN_CAM_TARGET, 720, 720
    if scene == "room":
        return ROOM_BOXES, *_corners(ROOM_BOXES), ROOM_CAM_POS, ROOM_CAM_TARGET, 1280, 720
    return SOLID_BOXES, *_corners(SOLID_BOXES), SOLID_CAM_POS, SOLID_CAM_TARGET, 720, 720


def _corners(boxes: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    return boxes[:, :3] - boxes[:, 3:] * 0.5, boxes[:, :3] + boxes[:, 3:] * 0.5
