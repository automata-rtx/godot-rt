"""Reproduce the pinned shader's append/read index domains; no renderer substitute."""

import json
import os
from itertools import permutations, product
from pathlib import Path

root = (
    Path(os.environ.get("AMD_CAPSAICIN_ROOT", "/workspace/amd-capsaicin-reference"))
    / "src/core/src/render_techniques/gi1"
)
source = (root / "gi1.comp").read_text()
assert "g_HashGridCache_VisibilityRayBuffer[ray_index] = did;" in source
assert "bool bypass_cache = ((g_HashGridCache_VisibilityRayBuffer[did2] >> 31) != 0);" in source
assert "uint did2 = did + g_HashGridCache_VisibilityCountBuffer0[0];" in source
assert "if (!reservoir.isValid())" in source
# 3 primary hits, 1 continuation. Only primary 0 and secondary 3 have valid
# shadow rays. This is one permitted serial order of the atomic append.
visibility_count0 = 3
shadow_queue = [0, 3 | 0x80000000, 0, 0]
did2 = visibility_count0
actual = bool(shadow_queue[did2] >> 31)
expected = True
assert actual != expected
cases = mismatches = 0
# Even without holes, all atomic append permutations are legal.
for order in permutations(range(4)):
    for bypass in product((False, True), repeat=4):
        queue = [i | (int(bypass[i]) << 31) for i in order]
        for secondary in (2, 3):
            cases += 1
            mismatches += bool(queue[secondary] >> 31) != bypass[secondary]
result = {
    "reference": "914b91596cd119eda85fbc1d3c7ee6ac391b1452",
    "mixed_hit_queue": [hex(x) for x in shadow_queue],
    "secondary_hit": did2,
    "reference_bypass": actual,
    "associated_hit_bypass": expected,
    "all_valid_permutation_cases": cases,
    "wrong_bypass_results": mismatches,
    "scope": "CPU execution of the exact append/read index equations, not an upstream GPU capture",
}
assert mismatches > 0
print(json.dumps(result, indent=2))
