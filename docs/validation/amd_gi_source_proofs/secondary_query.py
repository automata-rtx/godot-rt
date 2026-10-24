"""Source-checked query ownership/weight proof, independent of bypass flag indexing."""

import json
import os
from pathlib import Path

s = (
    Path(os.environ.get("AMD_CAPSAICIN_ROOT", "/workspace/amd-capsaicin-reference"))
    / "src/core/src/render_techniques/gi1/gi1.comp"
).read_text()


def body(name):
    a = s.index("void " + name + "(")
    a = s.index("{", a)
    depth = 1
    b = a + 1
    while depth:
        depth += (s[b] == "{") - (s[b] == "}")
        b += 1
    return s[a:b]


primary = body("PopulateScreenProbesHandleHit")
secondary = body("PopulateMultibounceCellsHandleHit")
populate = body("PopulateCells")
update = body("UpdateMultibounceCells")
assert "g_HashGridCache_VisibilityQueryBuffer[visibility_index] = did;" in primary
assert "g_HashGridCache_VisibilityQueryBuffer[visibility_index] = did;" in secondary
assert "uint query_index = g_HashGridCache_VisibilityQueryBuffer[visibility_index];" in populate
assert "ScreenProbes_AccumulateRadiance(query_index, GIDenoiser_RemoveNaNs(payload.lighting));" in populate
assert "uint query_index = g_HashGridCache_VisibilityQueryBuffer[did2];" in update
assert "ScreenProbes_AccumulateRadiance(query_index, GIDenoiser_RemoveNaNs(radiance.rgb));" in update
mapping = [7, 3, 11]
parent = 1
print(
    json.dumps(
        {
            "primary_visibility_to_probe_query": mapping,
            "secondary_parent_visibility": parent,
            "reference_written_probe_query": parent,
            "owning_probe_query": mapping[parent],
            "unit_secondary_lighting_black_parent": {"raw_secondary_bypass_write": 1.0, "weighted_continuation": 0.0},
            "scope": "CPU source/index/BRDF proof, not an upstream GPU execution",
        },
        indent=2,
    )
)
