#!/usr/bin/env python3
"""Exercise analytic-light growth across the old cap and unsupported-surface isolation."""

import sys
from pathlib import Path

log = (Path(sys.argv[1]) / "run.log").read_text()
assert "ERROR:" not in log and "COLLECTION FINISHED" in log, "Incomplete/error run"
assert "instances=2 lights=1025" in log, "Supported geometry or light growth lost"
assert "instances=2 lights=1" in log, "Active light-prefix shrink lost"
assert "AMD GI cache validation:" in log, "GI did not run"
assert "drawn=0" in log and "layers=0" in log, "Source material path allocated captures"
print(
    "1025 analytic lights plus an emitter, shrink to one light, unsupported surface isolation and zero atlas preparation passed."
)
print("Software Vulkan correctness only; not hardware performance or support for omitted surfaces.")
