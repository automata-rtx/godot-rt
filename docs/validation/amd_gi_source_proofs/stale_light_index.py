"""Source-checked domain counterexample; no upstream GPU execution claimed."""

import json
import os
from pathlib import Path

root = Path(os.environ.get("AMD_CAPSAICIN_ROOT", "/workspace/amd-capsaicin-reference")) / "src/core/src"
source = (root / "components/light_builder/light_builder.hlsl").read_text()
assert "Light getLight(uint index)" in source and "return g_LightBuffer[index];" in source
# Ordinary nonzero-to-nonzero delta-light count changes do not set the
# LightBuilder lightSettingsChanged flag (documented separately in L05).
previous = ["point A", "point B"]
current = ["point A"]
reservoir_index = 1
assert reservoir_index < len(previous) and reservoir_index >= len(current)
print(
    json.dumps(
        {
            "previous_count": len(previous),
            "current_count": len(current),
            "previous_reservoir_index": reservoir_index,
            "current_logical_index_valid": False,
            "reference_access": "g_LightBuffer[1]",
            "proposed_action": "Reject this unavailable historical sample before reading any light data",
            "limits": "Logical index-domain proof, not a claim of physical allocation out-of-bounds or upstream GPU output",
        },
        indent=2,
    )
)
