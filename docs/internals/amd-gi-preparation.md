# AMD GI material preparation, loading and cache reuse

This is a required part of the current GI integration, not an optional lighting
algorithm. Implement after the [shared RT foundation](shared-raytracing.md) and
[native material/scene adapter](rt-materials.md), alongside [AMD GI](amd-gi.md).
It touches ShaderRD, RenderingDevice and scenario/viewport interfaces; coordinate
those shared-file changes with the port integrator. Game-facing API:
[loading preparation](../../GodotForkDocs/features/amd-gi-loading.md).

## Preparation and teardown contract

`update_material_pipelines` starts preparation after GI scene collection. The
render thread polls the bytecode compilation group. On threaded builds, a
dedicated low-priority thread and up to three child workers create the driver
pipelines from pinned shader RIDs. A shared atomic work cursor schedules the nine
material-heavy passes first. Each worker owns disjoint output slots; publication
waits for all workers. The default is `clamp(logical_processors / 2, 1, 4)`;
`GODOT_AMD_GI_PIPELINE_WORKERS=1..4` is a diagnostic override. Forward+ uses native
lighting and configured native reflections until scene
collection publishes a complete set matching the current material revision.
Builds in flight never access gameplay, scene or viewport data. When revisions
change, stop between driver calls and prepare only the newest request. Dispose
of partial pipelines and shader versions on the render thread.

An empty scene invalidates the scene/revision key. While GI stays enabled, one
completed version can be reused across scenes after comparing the entire generated
source, including material case numbering and texture array capacities. An inactive
worker retires without blocking the level transition. Final renderer shutdown
joins it before device teardown. Matching failures retry after 1/2/4/8/16/30
seconds (capped), with warnings limited to the first three. A changed request can
retry immediately. Verbose logs identify registered material IDs, shader paths,
code hashes, descriptor/source revisions, per-pass driver time, and bytecode or
resident cache hits. Bytecode hits alone do not guarantee quick driver compilation.
`RaytracingMaterialSource` uses content-hash shader IDs with collision rejection,
sorted shader definitions, and sampler-type-based descriptor bindings. This makes
an identical material set independent of normal discovery order; a hash collision
can change cache ordering but never aliases shaders. Descriptor capacities remain
part of the source identity. Do not restore discovery-order IDs when porting.

`scenario_set_amd_gi_preparation` stores material RIDs and a compilation hold on
the scenario. Scene collection stages those materials using the same transport
eligibility helper as visible surfaces, before native surface contexts. Screen
effects must never enter the compute material program. The caller owns material
lifetime. The hold cancels superseded jobs without blocking a render frame.
`viewport_get_amd_gi_preparation_status` reads a detached per-render-buffer snapshot;
Forward+ gates readiness on the actual GI render result, independent of diagnostics.
See the [game-facing contract](../../GodotForkDocs/features/amd-gi-loading.md).

Publication requests `RenderingDevice::update_pipeline_cache(false, true)`.
Checkpoint requests survive an in-flight save and retry on subsequent frames.
Disk writes use a process-specific temporary file and rename only after flushing.
Keep a completed `.previous` copy because Windows' generic directory rename is
remove-then-move; load the previous copy if interruption left the main file absent.
Cache-save failures permit another attempt. Shutdown releases the RD mutex while
joining a save task that needs that mutex to serialize the cache. Preserve the
existing device/cache validation on load; this is not cross-device portability.
Only fixed-frame image fixture launchers set
`GODOT_AMD_GI_FIXTURE_WAIT_FOR_PIPELINES=1`. Leave it unset for timing and for
tests of loading, material transitions or asynchronous recovery.

Compile with `AMD_GI_PASS` preprocessing that removes unrelated pass functions
**before SPIR-V generation**. Specialization alone previously retained native
material trees in every pass and caused Windows driver freezes. A successful
C++ build is insufficient evidence for replacing this approach.

`GODOT_AMD_GI_FAIL_MATERIAL_PIPELINE=once:last` or `always:last` exercises preparation
failure/recovery in a controlled fixture. Verify no partially ready output replaces
native lighting and that the complete compatible set resumes after recovery.
Teardown must release GI/material users before shared geometry/device resources;
see the shared ownership and DLSS cleanup notes for shutdown ordering.

## Port completion checks

Stage hidden and emission-enabled variants; reorder identical material discovery;
mutate uniforms without changing source; replace a scene during compilation;
inject failure/retry; exit while workers are active. Require native fallback until
the complete current revision is published and a successful GI draw establishes
readiness. Test cold and separate-process cached launches and backup-cache recovery.
Shader bytecode reuse is not proof of a driver pipeline cache hit. See
[validation routes](../VALIDATION.md). Do not import one project's loading overlay,
pause policy or eight-frame settle count as an engine requirement.
