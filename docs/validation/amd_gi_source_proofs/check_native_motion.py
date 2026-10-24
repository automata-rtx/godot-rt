"""Source-checked algebra oracle for Godot's previous-surface attachment.
This proves the matrix/interpolation contract, not a rendered GPU comparison.
"""

import json
from pathlib import Path

import numpy as np

root = Path(__file__).resolve().parents[3]
shader = (root / "servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered.glsl").read_text()
host = (root / "servers/rendering/renderer_rd/storage_rd/render_scene_data_rd.cpp").read_text()
assert "scene_data_block.prev_data.inv_projection_matrix * prev_screen_position" in shader
assert "(previous_view / previous_view.w) * scene_data_block.prev_data.inv_view_matrix" in shader
assert "store_transform_transposed_3x4(prev_cam_transform, prev_ubo.inv_view_matrix)" in host
assert "prev_correction.add_jitter_offset(prev_taa_jitter)" in host
rng = np.random.default_rng(442)
worst = 0.0
for _ in range(4096):
    q, _ = np.linalg.qr(rng.normal(size=(3, 3)))
    cam = np.eye(4)
    cam[:3, :3] = q
    cam[:3, 3] = rng.uniform(-100, 100, 3)
    # An invertible perspective projection, including independent temporal jitter.
    proj = np.zeros((4, 4))
    proj[0, 0] = 1.3
    proj[1, 1] = 2.0
    proj[0, 2], proj[1, 2] = rng.uniform(-0.002, 0.002, 2)
    proj[2, 3] = 0.1
    proj[3, 2] = -1
    previous = np.ones((3, 4))
    previous[:, :3] = rng.uniform(-10, 10, (3, 3))
    previous[:, 2] -= 30
    weights = rng.uniform(0, 1, 3)
    weights /= weights.sum()
    # Native smooth interpolation evaluates at the current perspective barycentrics.
    old_clip = previous @ proj.T
    interpolated = weights @ old_clip
    old_view = np.linalg.inv(proj) @ interpolated
    old_view /= old_view[3]
    # GLSL mat3x4 contains three rows of the affine camera as its columns.
    attachment = old_view @ cam[:3, :].T
    expected = (cam @ (weights @ previous))[:3]
    worst = max(worst, float(np.max(np.abs(attachment - expected))))
    assert np.allclose(attachment, expected, rtol=0, atol=1e-10)
print(
    json.dumps(
        {
            "cases": 4096,
            "maximum_world_error": worst,
            "failures": 0,
            "scope": "CPU matrix/interpolation contract; native previous pose and previous jitter supplied by existing Forward+ motion path",
        },
        indent=2,
    )
)
