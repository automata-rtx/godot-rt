"""A legal reference update schedule disproves a universal 64-frame decay deadline."""

import json
import os
from pathlib import Path

import numpy as np

reference = (
    Path(os.environ.get("AMD_CAPSAICIN_ROOT", "/workspace/amd-capsaicin-reference"))
    / "src/core/src/render_techniques/gi1/gi1.comp"
).read_text()
for required in (
    "direct_sample_count = min(direct_radiance.w + new_direct_radiance.w",
    "direct_radiance = lerp(direct_radiance, new_direct_radiance, 1.0f / direct_sample_count)",
    "direct_radiance *= direct_sample_count",
):
    assert required in reference
value = np.array([16.0, 16.0, 16.0, 16.0], dtype=np.float32)
records = {}
updates = 0
for frame in range(1, 129):
    # A tile touched once every five frames is neither stale (age 50) nor
    # guaranteed the four-frame average implied by the global ray budget.
    if frame % 5 == 0:
        updates += 1
        update = np.zeros(4, dtype=np.float32)
        count = min(value[3] + update[3], 16.0)
        old_mean = value / max(value[3], 1.0)
        new_mean = update / max(update[3], 1.0)
        value = new_mean if old_mean[3] <= 0 else old_mean * (1 - 1 / count) + new_mean / count
        value = np.asarray(value * count, dtype=np.float16).astype(np.float32)
    if frame in (64, 80, 128):
        records[frame] = {
            "updates": updates,
            "sum_count": value.tolist(),
            "mean": (value[:3] / max(value[3], 1.0)).tolist(),
        }
assert records[64]["mean"] == [1.0, 1.0, 1.0]
assert records[80]["mean"] == [0.0, 0.0, 0.0]
print(
    json.dumps(
        {
            "reference_legal_counterexample": records,
            "claim": "64 display frames is not an AMD cache-decay guarantee",
            "limits": "CPU reference algebra; does not prove the actual scene update schedule or full-pipeline parity",
        },
        indent=2,
    )
)
