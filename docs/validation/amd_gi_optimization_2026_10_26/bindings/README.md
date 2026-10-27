# GI binding lifetime fixture

This self-contained correctness fixture uses tiny odd-sized Forward+ viewports,
has no grass, and never loads fps-proto. It exercises the GI descriptor reuse
optimization; it is not a performance benchmark.

Run the editor with this directory as `--path` and `--script res://lifecycle.gd`,
with `GODOT_AMD_GI_VALIDATE_BINDINGS=1`. Set `GI_BINDING_OUT` to an existing or
creatable external capture directory. Use `--rendering-driver vulkan
--audio-driver Dummy --windowed --resolution 640x360`.

Acceptance requires exit 0, `GI_BINDING_FIXTURE complete failures=0`, the actual
engine-check marker `AMDGI bindings oracle: checked=true`, no `ERROR:`,
`SCRIPT ERROR:`, parse or oracle errors,
and review of captures. The script checks active GI diagnostics and exact current
viewport dimensions at every enabled stage, then checks green/red/blue foreground
changes for the initial material, same-texture pixel edit and resized replacement.
These image checks prove live raster changes, while the engine oracle must prove
that accelerated GI descriptor selection matches ordinary descriptor selection.
They are not a complete lighting-quality comparison.
The statistics-toggle stage intentionally reads GPU data: do not use this fixture
for performance measurements.

Coverage: both history parities; same-resource texture pixels; same-size and
different-size RD texture replacement; old resource destruction; uniform-only
updates; complete shader-version replacement; odd viewport resize; reflection
resolution changes; debug texture allocation/release; counter-buffer growth/shrink;
sky binding replacement; GI disable/re-enable; two independent world/viewports;
second viewport resize, destruction and recreation.

Supplement with the existing `amd_gi_scene_metadata` oracle for source layout and
descriptor mutation coverage. This fixture can also run with
`GODOT_AMD_GI_FAIL_MATERIAL_PIPELINE=once:last`: bounded readiness waits allow the
failed complete candidate to back off and recover at startup and after GI is
re-enabled. Disabling GI destroys the implementation object, so this per-instance
injection fires again on re-enable. Each wait is limited to 90 seconds and records
its duration and outcome in `lifecycle.json`; every current view must report a
rendered GI frame and its exact size. Ordinary mutations retain fixed-frame checks.
The runner must additionally confirm the expected failure warning and later
successful binding-oracle/render checks. An expected warning is not an engine
error, and unexpected errors must still fail. Benchmark with validation/statistics
and failure injection off.

Use `../run_regressions.py --rig bindings` with an explicit engine, label and
output directory. It rejects errors in the engine log and checks this fixture's
report and completion marker.
Capture and report paths belong under `.artifacts/`, never beside this fixture.
