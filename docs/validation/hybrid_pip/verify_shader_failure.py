#!/usr/bin/env python3
"""Reject unrelated errors in the deliberate invalid-material shutdown log.

The caller must also require process exit 0 and the fixture completion marker.
Use the complete stdout/stderr log: file logging can end before renderer teardown.
"""

import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
unexpected = []
expected = 0
for index, line in enumerate(lines):
    if "ERROR:" not in line:
        continue
    context = "\n".join(lines[index + 1 : index + 3])
    allowed = (
        line == "SHADER ERROR: Unknown identifier in expression: 'HYBRID_PIP_EXPECTED_INVALID_IDENTIFIER'."
        or (
            line == "ERROR: Shader compilation failed."
            and "SceneShaderForwardClustered::ShaderData::set_code" in context
        )
        or (
            line == 'ERROR: Condition "error != OK" is true. Returning: error'
            and (
                "RaytracingMaterialSource::compile" in context
                or "RaytracingMaterialSource::prepare_material" in context
            )
        )
    )
    if allowed:
        expected += 1
    else:
        unexpected.append(line)

complete = any("HYBRID_PIP_FIXTURE complete failures=0" in line for line in lines)
passed = expected > 0 and complete and not unexpected
print(f"Expected shader errors: {expected}; unexpected errors: {len(unexpected)}; complete: {complete}")
for line in unexpected:
    print(line)
sys.exit(0 if passed else 1)
