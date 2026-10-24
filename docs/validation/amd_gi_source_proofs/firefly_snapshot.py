"""Source-shaped arithmetic proof; not an upstream GPU capture."""

import json
import math
import os
import random
from pathlib import Path
from typing import TypedDict

source = (
    Path(os.environ.get("AMD_CAPSAICIN_ROOT", "/workspace/amd-capsaicin-reference"))
    / "src/core/src/render_techniques/gi1/gi1.comp"
).read_text(encoding="utf-8-sig")
block = source[source.index("void CleanupFireflies(") : source.index("void NoDenoiserReflections(")]
assert "1.f - g_GlossyReflections_FirefliesBuffer[half_sample_pos]" in block
assert "specular                        += radiance_and_hit_distance * weight;" in block
assert "GIDenoiser_RemoveNaNs(specular)" in block


# HLSL saturate(NaN) returns zero. Keep the source compression transform.
def sanitize(x):
    c = x / (1 + x)
    c = 0 if math.isnan(c) else min(max(c, 0), 1)
    return c / max(1 - c, 1e-4)


def cleanup(values, marked, at):
    if not marked[at]:
        return values[at]
    weights = [1.0 - x for x in marked]
    total = sum(v * w for v, w in zip(values, weights))
    count = sum(weights)
    if abs(count) < 1e-3:
        total += values[at]
        count += 1
    return sanitize(total / count if count > 0 else total)


rng = random.Random(119869)
for _ in range(10000):
    values = [rng.random() * 100 for _ in range(5)]
    marked = [rng.randint(0, 1) for _ in values]
    expected = [cleanup(values, marked, i) for i in range(5)]
    order = list(range(5))
    rng.shuffle(order)
    actual = values.copy()
    for i in order:
        actual[i] = cleanup(actual, marked, i)
    assert actual == expected
original = [float("nan"), 10.0, 1.0]
marked = [1, 1, 0]


class CleanupResult(TypedDict):
    order: list[int]
    result: list[float]


results: list[CleanupResult] = []
for order in [[0, 1], [1, 0]]:
    values = original.copy()
    for i in order:
        values[i] = cleanup(values, marked, i)
    results.append({"order": order, "result": values})
assert results[0]["result"][1] != results[1]["result"][1]
print(
    json.dumps(
        {
            "finite_permutations": 10000,
            "legal_nonfinite_orders": results,
            "immutable": [cleanup(original, marked, i) for i in range(3)],
        },
        indent=2,
    )
)
