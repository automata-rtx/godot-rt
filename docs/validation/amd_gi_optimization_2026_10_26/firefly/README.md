# Exact-default firefly optimization proof

This regression targets the exact-default shortcut in
`mark_reflection_fireflies()`. It preserves negative-distance marking and cleanup,
while avoiding neighbor ranking when thresholds are exactly 0 and 1.

From the repository root, preparation and the CPU proof do not launch Godot:

```powershell
python docs/validation/amd_gi_optimization_2026_10_26/firefly/prove_default_rank.py
python docs/validation/amd_gi_optimization_2026_10_26/firefly/prepare_gpu_fixture.py
```

Use an installed Python 3 executable instead of `python` if needed. The generator
puts its shaders, binary inputs, copied standalone project and script in
`.artifacts/gi-opt-20261026/firefly/generated/`. Generated files and results are
not tracked. It rejects output locations inside `docs/`.

After authorizing engine execution, the Windows runner prepares and launches the
isolated fixture:

```powershell
& docs/validation/amd_gi_optimization_2026_10_26/firefly/run_gpu_fixture.ps1
```

Optional arguments: `-SkipTiming`, `-Engine <absolute-executable-path>`, and
`-Python <python-executable>`. The default engine is the repository's console
editor. The runner isolates user data, records the executable checksum and exit
code, and requires a passing result JSON. It never touches a game project. The
window is 320x180; synthetic compute timing uses 1280x720 inputs.

The generator extracts the actual production marking function, packed sample
layout, unpack, luminance and pixel-coordinate helpers. It emits the original
and proposed functions, differing only by the exact-default guard. If the guard
has already been implemented, it reconstructs the original by removing that
single guard. Manifest hashes identify the source and generated shaders.

GPU equality covers 1,000 cases: five dimensions including odd/tiny images,
full/half modes, all four half-resolution phases, radii 0/1/2/3/16,
default/custom/NaN thresholds, nonfinite sample radiance, invalid roughness and
negative/missing hit distances. Differing clear sentinels catch unwritten pixels.
Outputs must match byte-for-byte, and marks must be exactly 0 or 1. Cleanup is not
reimplemented: unchanged production cleanup must consume the same mask. CPU
proof supplies independent count-bound reasoning.

The timing mode alternates original/optimized ordering, warms both pipelines,
records 11 samples per variant, and uses 8 dispatches per sample. GPU timestamps
are converted from nanoseconds using the Vulkan driver's actual convention.
Default and custom thresholds are measured at full/half resolution. All pixels
are eligible in this synthetic input, so these times are **not** a predicted
whole-game saving. Production benchmarks remain required.

Evidence belongs in the parent optimization report. Presence of this fixture
does not establish a passing hardware run.
