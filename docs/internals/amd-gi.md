# AMD GI implementation and rebuild contracts

Baseline audited against fork commit `66bd97e00d` (Godot 4.8-dev); the CPU reuse
contracts below also cover the 2026-10-26 optimization changes. User setup and controls live
in `GodotForkDocs/features/amd-gi.md`; [decisions](../AMD_GI_ADAPTER_DECISIONS.md)
define the accepted adapters and prohibited shortcuts. Read this file for a port,
not the historical implementation diary.

## Baseline and responsibility split

The algorithm baseline is AMD Capsaicin GI 1.2, commit
`914b91596cd119eda85fbc1d3c7ee6ac391b1452`. `thirdparty/amd_gi/README.md` records
provenance and `generate_blue_noise.py` reproduces the bundled sequence. Keep the
license and pinned source identity. A new AMD version is an algorithm migration,
not an incidental Godot port; do not silently substitute it.

Godot owns scene/material lifetime, buffer creation, GPU dependencies, shader
translation, visible receiver inputs, light conventions, and presentation. AMD
owns probe/cache sampling, GridStream proposals, accumulation, continuation weights,
reconstruction, and denoising. GLSL translation and native source-material dispatch
are necessary adapters; this is not a claim of bit-identical output to Capsaicin.

## Source map

Paths are relative to the engine root. Abbreviated `shaders/`, `storage_rd/`
and environment filenames in the table are under `servers/rendering/renderer_rd/`.
Use symbols rather than historical line numbers.

| Area | Primary files / symbols |
| --- | --- |
| Public settings | `core/config/project_settings.cpp`, `rendering/global_illumination/amd_gi/` |
| Collection | `servers/rendering/renderer_scene_cull.cpp`: GI eligibility, stable scenario order, ordinary MultiMesh expansion |
| Renderer ownership | `servers/rendering/renderer_rd/renderer_scene_render_rd.cpp`: `is_rtgi_enabled`, `update_raytracing_scene`, diagnostic query |
| Shared geometry / shadow dependency | `servers/rendering/renderer_rd/environment/rt_geometry.*`, `rt_scene.*`; `storage_rd/mesh_storage.cpp` |
| GI scene and binding records | `servers/rendering/renderer_rd/environment/rt_gi_scene.*`: `RaytracingGIScene`, source-material contexts, emitters/lights, GI TLAS |
| Material compiler | `servers/rendering/renderer_rd/environment/rt_material_source.*`; `shaders/effects/rt_material_source_inc.glsl` |
| Orchestration and ABI | `servers/rendering/renderer_rd/environment/amd_gi.{cpp,h}`: `AMDGI`, `ViewData`, `Pass`, `PushConstant`, `FrameUniform` |
| Preparation recovery | `servers/rendering/renderer_rd/environment/amd_gi_pipeline_preparation.h`, `prepare_material_pipelines` |
| Algorithm shader | `servers/rendering/renderer_rd/shaders/effects/amd_gi.glsl` and `amd_gi_*_inc.glsl` |
| Native lighting / emitters | `shaders/effects/rt_gi_transport_inc.glsl`, `shaders/effects/rt_gi_emitters.glsl`, `shaders/effects/amd_gi_lights_inc.glsl` |
| Sky conversion | `shaders/effects/amd_gi_environment.glsl`, `amd_gi_sky_sampling_inc.glsl` |
| Receiver/composite | `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp`, `shaders/forward_clustered/scene_forward_clustered.glsl` |
| RD synchronization | `servers/rendering/rendering_device.cpp`, `rendering_device_graph.cpp`, Vulkan device driver |
| Public diagnostics | `RenderingServer::viewport_get_amd_gi_diagnostics`, `AMDGI::get_diagnostics`, `amd_gi_debug*_inc.glsl` |

`rt_material_capture.*` is the legacy uncached validator. Its atlas controls do not
control production AMD GI; porting that capture as the production material path
would lose native material fidelity and resurrect obsolete tuning assumptions.

## Startup, collection, and shared geometry

AMD enable is live, but currently depends on the startup RT-shadow master.
`RaytracingScene::register_settings` latches `raytraced_shadows/enabled`;
`MeshStorage::_raytracing_buffers_required` uses that flag plus ray-query/device-
address support when allocating both static and skinned mesh buffers. Setting AMD
GI alone after meshes were uploaded cannot make their buffers legal AS inputs.
Forward+ constructs shared tracing state once and creates the shadow effect only
when tracing is available. Preserve this dependency or deliberately redesign and
validate it; do not document enable independence that the implementation lacks.

`is_rtgi_enabled` checks tracing availability, Vulkan, single view, MSAA off,
Environment, SDFGI/SSIL conflicts, and AMD's device limits. `AMDGI::is_supported`
requires half floats, 38 storage buffers per stage/aggregate pipeline layout, 12 storage images per
stage/aggregate pipeline layout, eight color attachments, and 32768 bytes compute shared memory. Its
older 32-buffer warning is inaccurate. Orthographic views clear only their GI
outputs; they must not evict other views' shared resources. Reflection-probe
rendering does not execute this GI path.

Collection scans participating scenario geometry independently of camera position;
`max_distance` limits rays, not CPU collection. Stable RID order is rebuilt only
when `gi_order_dirty`. Visibility, camera layers, GI mode, overlays, lightmaps, and
visible VoxelGI affect eligibility. Keep CPU collection exclusions separate from
surface/material exclusions so diagnostics explain where geometry disappeared.

CPU-managed 3D MultiMesh expands the visible count with parent x element transform,
per-element bounds, color, and custom data. Reuse mesh geometry while maintaining
per-element transport identity. GPU-indirect MultiMesh and shader-deformed vertices
must remain explicitly unsupported until their actual data/lifetime is integrated.

`InstanceGeometryData::rt_multimesh_expansion` retains only world transforms and
bounds. Its key includes full MultiMesh/mesh RIDs, rendered-buffer revision, parent
transform, mesh bounds, and visible count. Advance `multimesh_get_buffer_revision`
at actual backend allocation/layout changes, element writes, and bulk uploads,
including physics interpolation. Dependency/AABB notifications are insufficient:
custom bounds can suppress them. Revision zero disables reuse. Destroy the cache
with its instance base data, including base-type changes; keep material, layer,
uniform, color/custom-data, and participation inputs live.

Each rebuilt expansion also receives a globally monotonic generation. GI inputs
carry that generation and the complete first-element count, allowing scene
preparation to retain a parent group without inspecting every child again. Never
replace it with a per-parent counter that restarts on recreation or infer parent
stability from only the first child's transform. Zero/incomplete group metadata
uses full preparation.

Collection also retains complete unchanged MultiMesh blocks directly in its
existing dense input vector. Current eligibility and shared material/mask/uniform
fields are checked before skipping child emission; changed inputs overwrite a
cursor prefix and the remaining tail is trimmed. Scenario/view changes cannot
bypass these checks. The [CPU follow-up](../validation/gi_cpu_retention_2026_10_26/CPU_FOLLOWUP_IMPLEMENTATION.md)
documents this and changed-range comparison contracts. The owner accepted the
follow-up build after testing; a new automated runtime regression pass remains pending.

`RaytracingGIScene::geometry_preparations` shares successful copied geometry
descriptors by full mesh/posed-instance RID and surface. Refresh each source once
per `update_scene` epoch (`material_frame`), not once per engine frame: multiple
viewports/scenes can update in one frame. Never retain a borrowed shared-geometry
map pointer or reuse a previous epoch's source buffers/pose metadata.

`RaytracingGIScene::retained_groups` keeps unchanged dense Hit/AS/Context ranges in
place after current resource refresh. Full identity/count/order, parent metadata,
shader/next-pass state, geometry/pose revisions and native base Context must match.
Changed groups reconstruct their slots; membership changes and final cursor
truncation preserve dense GPU IDs. Source emitter batches/ranges can also remain
in place because they contain geometry/IDs, not evaluated emission. Their batch
and triangle prefixes and emissive-sampling state must match; earlier emitter
membership changes or sampling toggles reconstruct affected offsets.
Failed preparation invalidates group reuse before partial writes can be published.
Live material uniforms, textures, `TIME`, offscreen texture usage and pruning
touches remain active. See [material reuse contracts](rt-materials.md#implemented-cpu-reuse)
and the [reviewed retention plan](../validation/gi_cpu_retention_2026_10_26/SCENE_PLAN.md).
Emissive/nonemissive mutation oracles, actual retained image/light-storage tests,
native GPU dependency tests and controlled Live World comparisons passed; see
[results and remaining limits](../validation/gi_cpu_retention_2026_10_26/RESULTS.md).
Fully changing scenes can pay extra reconstruction overhead and require separate
timing; the target-game result is not a universal performance claim.

`update_raytracing_scene` brackets **both** shadow and GI updates with shared
`RaytracingGeometry::begin_update/end_update`. GI has separate transport records
and TLAS, while mesh BLAS/deformation are shared. Releasing GI must not evict a
shadow consumer's geometry. Dynamic skinning, BLAS writes, TLAS instance-buffer
reads, and ray queries must depend on the same frame's data through RD's graph.
Preserve explicit build-input reads, indirect arguments, and storage writes; raw
Vulkan barriers alone cannot repair incorrect graph ordering. See [RT shadow
implementation](rt-shadows.md) for the shared dependency/ownership changes.

## Material and light identity

Native source-material contexts permit material/resource updates independently
of mesh BLAS identity. Shader layout changes revise the source-program signature;
uniforms/textures/instance data update the appropriate bindings rather than
forcing all geometry to rebuild. See [material implementation](rt-materials.md)
for supported shader semantics, material sharing, resource changes, alpha queries,
and lifetime invariants. Unsupported semantics must remain diagnosed exclusions.

Emitter classification follows whether the shader writes EMISSION, not whether
its current evaluated RGB is nonzero. Muzzle-flash dark phases must not repeatedly
reclassify geometry or recompile a global material layout. Dynamic lights retain
logical light counts independently of storage capacity. Sampling masks, Godot
attenuation/energy, emitter coordinates, and indirect multipliers must reach the
native transport boundary. Negative lights remain excluded from GI feedback and
sampling while native direct lighting stays intact.

The GPU prepares triangle emitters and GridStream light proposals. Fresh proposals
remain active with `light_resampling=false`; that switch controls optional temporal
reservoir reuse only. Historical indices are validated against the current logical
light list. A flat grid axis is one cell; do not invent thickness. Supported affine
emitter coordinates feed AMD's existing filtering formula; unsupported nonlinear
mapping retains a diagnosed fallback, not a promise of arbitrary shader support.

## Per-view data and pass flow

`ViewData` owns per-viewport probe, cache, reconstruction, feedback, and reflection
histories. Stored probes use an 8x8 screen grid and 64 directions; update spacing
8/16/32 changes the budget, with partial tiles rounded up. World hash buckets hold
16 tiles; each tile has 85 cells (64 + 16 + 4 + 1 mip cells). Optional retained
probes, indirect caches, hit lists, and reservoirs have real storage costs.
Disabled resources retain valid tiny bindings where required; inactive shaders
must not access those placeholders.

`Pass` values must match shader defines and descriptor layouts. The current C++
ABI asserts a 128-byte push constant and 544-byte frame uniform. Preserve packing,
integer widths, texture formats, and compile-time pass selection when translating.

`BindingReuse` compares the complete current uniform list once per render: type,
binding, and every full resource RID, including entries unused by a shader variant.
`ViewData` retains per-pass descriptor handles separately for each set-0 history
parity and one common material set. A newly published full shader-version RID
clears all snapshots/handles; changed binding lists clear the affected cache.
Handles are borrowed from `UniformSetCacheRD`: `free_data` discards them without
freeing them, and each reuse must pass RD's `uniform_set_is_valid` check before
binding. Reuse never replaces dispatches, barriers, or explicit graph buffer reads.

The render loop's dependency phases are:

1. Reset/purge caches and optional reservoirs; reproject probes; bin retained
   probes, select updates, patch, compact, and gather update work.
2. Prepare and trace primary probe rays; allocate/register world-cache hits.
   Optional continuation population allocates/registers secondary hits.
3. Prepare lights and light masks **before** light-grid dispatch; build GridStream
   proposals, shade hit records, and update cache cells. Optional reservoir
   compaction/prefix scans preserve the same contribution ordering.
4. Build direct-cache mips. Optional indirect update/mips and secondary shading
   propagate weighted contributions; compacted hit and parent indices must agree.
5. Resolve probes, store/order retained probes, generate masks, filter/project SH,
   reconstruct near-field/interpolated GI, then temporal and spatial denoise.
6. Classify glossy samples; optionally compact and dispatch tracing indirectly.
   Mark/clean fireflies, reconstruct with split X/Y or a-trous, apply temporal
   processing as selected, and produce glossy output.
7. Run requested debug display/statistics passes. Disabled diagnostics must not
   add regular readbacks or scans.

`mark_reflection_fireflies` skips neighbor ranking only when the low/high
thresholds are exactly 0/1: nonnegative integer counts make both upstream rank
tests false. The supported radius bounds keep those counts finite and exact.
Preserve roughness admission, negative-distance marking, raw diagnostic recording,
the mask write, and the following cleanup pass. Custom thresholds (including
nonfinite values) retain the original rank path. When porting, recheck count/weight
semantics and run the [extracted shader equivalence fixture](../validation/amd_gi_optimization_2026_10_26/firefly/README.md)
before retaining this shortcut; it changes no filter settings or reconstruction.

Trace/light passes declare geometry and source-material buffer reads. Barriers
between dependent compute dispatches and both storage/indirect usage on work
buffers are part of correctness. Preserve primary/secondary compacted shadow-ray
RNG domains and BRDF/PDF weights; seemingly equivalent reordering can change them.

Resource-layout changes (internal resolution, probe spacing, cache capacity,
retained pool, multibounce/reservoir/all-hit mode, reflection resolution/filter)
recreate affected state. Sampling/filter changes reset appropriate history;
light-order changes also invalidate history. Debug view selection alone does not.
Normal dynamic geometry uses AMD's cache update behavior; there is no blanket
swept-box/history reset to add during a port.

## Sky, receiver inputs, and final shading

Forward+ supplies normals/material data, motion/depth, Environment sky orientation,
ambient/reflected energy, background color, and exposure normalization. Rebuild
these against the later Godot version's actual coordinate and exposure conventions;
copying field names without confirming their meaning is unsafe.

Luminance sky sampling uses separate ordinary box-mean cubemap mips, not the native
GGX-prefiltered radiance mip chain. Keep Vulkan face orientation, zero-mass face/CDF
endpoint handling, and stored world-direction identity. The signed-half2 octahedral
payload preserves identity during resampling; it still has finite quantization.
Uniform, cosine, and luminance sky modes do not change diffuse probe guiding.

Native forward shading applies the authored material response to diffuse and glossy
outputs. Previous opaque outgoing lighting includes direct, emission, and indirect
terms for near-field and reflection-hit feedback even when optional diffuse
`screen_feedback` is off. Capture complete feedback **before** debug display
isolation, or debug view changes will alter the estimator. Native SSR suppression
must wait for ready AMD reflection pipelines. Normal transforms, motion conventions,
and first-person geometry are critical validation surfaces, not cosmetic details.

## Failed preparation and teardown

`prepare_material_pipelines` keys readiness by scene pointer plus source shader
revision. Build all required shader/pipeline candidates before publishing. On
failure free candidates, preserve the previous set but forbid using its stale ABI
for the new request, and retry after 1/2/4/8/16/30 seconds (capped). A changed request
can retry immediately. First failures warn; repeated failures must not flood logs.

Compile with `AMD_GI_PASS` preprocessing that removes unrelated pass functions
**before SPIR-V generation**. Specialization alone previously retained native
material trees in every pass and caused Windows driver freezes. A successful
C++ build is insufficient evidence for replacing this approach.

`GODOT_AMD_GI_FAIL_MATERIAL_PIPELINE=once:last` or `always:last` exercises preparation
failure/recovery in a controlled fixture. Verify no partially ready output replaces
native lighting and that the complete compatible set resumes after recovery.
Teardown must release GI/material users before shared geometry/device resources;
see the shared ownership and DLSS cleanup notes for shutdown ordering.

## Porting sequence and acceptance

1. Pin the new Godot revision and preserve this AMD revision/license. Map changed
   RD limits, shader layouts, scene APIs, and forward material/exposure contracts.
2. Port shared ray-query/device-address/AS tracking and RT geometry/shadow ownership.
   Validate same-frame skinning/BLAS/TLAS behavior before cached GI obscures errors.
3. Port native source-material compilation and dynamic bindings, GI collection,
   MultiMesh records, lights/emitters, and diagnostics. Validate independent material
   changes, deletion/recreation, dynamic light counts, and exclusions.
4. Port the AMD shader library and ABI, then the ordered dispatch/resource history
   logic. Rebuild pipeline preprocessing, preparation recovery, sky conversion,
   native forward composite, and full feedback capture.
5. Compile every pass and run CPU/layout/source proofs, then authorized GPU fixtures.
   Start with static lighting, moving geometry, normals, materials/opacity/emission,
   light changes, sky/exposure, and cache behavior; then MultiMesh, live mode changes,
   view resizing, nonmultiple-of-eight sizes, failure recovery, and shutdown.
6. Compare native/AMD transport under motion and difficult reflective faces, not just
   a stationary average image. Profile CPU collection/preparation/AS and GPU phases
   separately with diagnostic readbacks disabled. Record hardware, build, scene,
   internal resolution, options, frame range, and source revision.

`docs/validation/shadow_validation/amd_gi_*.{gd,tscn}` and matching `score_*.py`
provide focused fixtures. `amd_gi_options.tscn` prepares a 36-combination sampler/
filter matrix and all 32 views. `docs/validation/amd_gi_source_proofs/README.md`
explains CPU counterexamples; these prove specific source defects, not rendering
parity. Some historical proof proposals (notably immutable firefly input) were
withdrawn. Read the decision boundary before adopting a proof's proposed remedy.

Current known limits include glossy thin-face/motion artifacts and blur, unsupported
shader displacement/GPU-indirect MultiMesh, and no accepted full optional-mode GPU
matrix. Do not certify the future port solely because these fixtures exist or the
current default build has been used successfully.

The [2026-10-26 optimization plan](../validation/amd_gi_optimization_2026_10_26/PLAN.md)
and [results](../validation/amd_gi_optimization_2026_10_26/RESULTS.md) record scope,
adversarial checks, and measured evidence. The accompanying regression runner
requires uncached scene/descriptor oracles and mutation fixtures; disable those
diagnostics during timing. Keep correctness evidence separate from performance.

The [scene-retention acceptance plan](../validation/gi_cpu_retention_2026_10_26/SCENE_PLAN.md#adversarial-checks-and-validation)
requires actual emissive and nonemissive subject coverage, sampling transitions and lifecycle
mutations. `GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1` reconstructs retained candidates
and logs per-group RID matches for Context/Hit/AS/emitter/count checks;
`GODOT_AMD_GI_TRACE_RETAINED_GROUPS=1` reports group/surface and emitter reuse counts.
`GODOT_AMD_GI_DISABLE_RETAINED_GROUPS=1` provides the full-preparation comparison.
Use those records to establish coverage before measuring with diagnostics off.

## Bounded live tuning

See [the panel integration contract](../../GodotForkDocs/features/amd-gi-tuning.md).
The owner authorized exposing narrow experimental controls on 2026-10-27;
reference defaults remain unchanged. `FrameUniform::tuning` (matching GLSL vec4)
contains cache count, diffuse history scale, distance angular scale, reserved.
Runtime reads occur inside the existing enabled GI render path. Nonfinite values
use defaults; finite values are clamped, and cache count is rounded.

Reference evidence at pinned Capsaicin 914b9159:
- `gi1.h`: `gi1_hash_grid_cache_max_sample_count=16` and
  `gi1_hash_grid_cache_cell_size=32` are already upstream options.
- `gi1.comp` cache accumulation and `hash_grid_cache.hlsl` filtered lookup use
  the SAME max sample count. Our accumulation, lookup, and debug lookup remain linked.
- `gi1.cpp` converts the cache pixel footprint to an angle using FOV and internal
  resolution. Scale that 32-pixel footprint inside tan; do not change the separate
  screen-probe footprint or minimum world-cell size. All cache keys and thin-wall
  bypass consumers use the shared `cache_cell_size` function.
- `gi1.comp::ReprojectGI` blends the history allowance from 4 to as much as 64,
  depending on detected brightness change and screen position. The new scale
  multiplies that allowance before its minimum-one clamp. It does not alter the
  brightness-change detector, spatial rejection, or reflection denoiser.

The limits 12–16 and 0.75–1 are conservative engineering bounds (at most a quarter
reduction), NOT an AMD-documented optimal range. Lower cache count also permits
fine mip use earlier; lower denoiser allowance can increase spatial filtering while
history is short. Lower angular footprint can cross a quantization boundary and
halve actual cell size locally, despite a small slider movement. It also changes
cache bypass distances. These coupled effects require scene testing.

Response changes are deliberately absent from `configuration_changed`: counts
adapt through normal accumulation, with no blanket reset. Distance scale joins
that comparison and is stored per ViewData. Effective changes use the existing
full history-reset path, invalidating cache, retained probes, screen and reflection
history together; they do not change buffer sizes or force pipeline compilation.
Equal effective settings (including clamped values) do not trigger another reset.
Shader defaults keep the original equations; no probe/ray budget is increased.

## Tuning visualization capture

Modes 32–37 are documented in the portable debug guide. Mode 34 writes the existing
binding-64 debug output in INTERPOLATE, before pixels is overwritten by temporal
and spatial filtering. The final DEBUG_VIEW pass leaves that capture intact.
Other modes read completed buffers in DEBUG_VIEW. Existing inter-pass barriers
order these accesses; no added buffer, readback, reset or transport changes.
The debug image remains full-size only while a compute view is selected. A disabled
view binds the existing tiny placeholder, which the capture branch must never index.
Raw/final displays use the same irradiance/PI and debug exposure transfer, excluding
native material/ambient/glossy terms. The history heatmap uses a fixed 64-sample scale.
The cell checker is deliberately a geometric visualization, not a guessed directional
cache lookup. Green compares the current footprint against the default 32-pixel angle.
