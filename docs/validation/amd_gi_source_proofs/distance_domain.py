import json
import math
import os
import warnings
from pathlib import Path

import numpy as np

root = (
    Path(os.environ.get("AMD_CAPSAICIN_ROOT", "/workspace/amd-capsaicin-reference"))
    / "src/core/src/render_techniques/gi1"
)
assert "#define MAX_HIT_DISTANCE 1e9f" in (root / "gi1.comp").read_text()
assert "return packHalf4(radiance)" in (root / "screen_probes.hlsl").read_text()
assert "uint4(round(kGI1_FloatQuantize * radiance))" in (root / "screen_probes.hlsl").read_text()
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    assert np.isinf(np.float16(1e9))
maximum = 65504
quantized = maximum * 10000
distance_sum = quantized * (2**32 - 1)
assert distance_sum < 2**64
result = {
    "reference_ray_extent": 1e9,
    "half_reference_extent": "infinity",
    "maximum_finite_binary16_distance": maximum,
    "uint32_distance_sum_first_overflow_samples": (2**32 - 1) // quantized + 1,
    "distance_64bit_sum_maximum_hits_uint32": distance_sum,
    "angular_parallax_error_degrees": {str(d): math.degrees(math.atan(d / maximum)) for d in [0.1, 1, 10, 100]},
    "extra_shared_bytes_per_64_bin_workgroup": 64 * 4,
}
print(json.dumps(result, indent=2))
