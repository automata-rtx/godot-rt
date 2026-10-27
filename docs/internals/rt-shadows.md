# RT shadows: implementation and rebuild contract

Read this when changing or porting the renderer. Project setup belongs in [the user guide](../../GodotForkDocs/features/rt-shadows.md); AMD GI's native material adapter is covered in [rt-materials.md](rt-materials.md). Paths below are relative to the engine root. Source symbols are anchors; line numbers and shader-version ordinals are intentionally not contracts.

## Source map

| Responsibility | Source |
| --- | --- |
| Settings and Light3D defaults/API | `core/config/project_settings.cpp`, `scene/3d/light_3d.{h,cpp}`, RenderingServer bindings |
| Availability, per-frame setting snapshot | `environment/rt_scene.{h,cpp}` under `servers/rendering/renderer_rd/` |
| Caster collection, shadow-map routing, same-frame poses | `servers/rendering/renderer_scene_cull.cpp` |
| Shared BLAS/dequantization/cache | `renderer_rd/environment/rt_geometry.{h,cpp}`, `shaders/effects/rt_dequantize.glsl` |
| Shadow-only TLAS | `renderer_rd/environment/rt_scene.cpp`, `RaytracingScene::update` |
| Shared shadow/GI update scope | `renderer_rd/renderer_scene_render_rd.cpp`, `update_raytracing_scene` |
| Stable light slots and packed light rows | `renderer_rd/storage_rd/light_storage.{h,cpp}` |
| Trace, temporal, spatial passes | `renderer_rd/effects/rt_shadows.{h,cpp}`, `shaders/effects/rt_shadow_{trace,temporal,atrous}.glsl` |
| Prepass, attachments, pass ordering | `renderer_rd/forward_clustered/render_forward_clustered.{h,cpp}` |
| Forward shading and fog | `shaders/forward_clustered/scene_forward_clustered.glsl`, `shaders/scene_forward_lights_inc.glsl`, `environment/fog.cpp`, `shaders/volumetric_fog_process.glsl` |
| AS API and synchronization | `servers/rendering/rendering_device*`, `drivers/vulkan/rendering_device_driver_vulkan*` |

Table entries abbreviated with `renderer_rd/` are under `servers/rendering/`;
`environment/` and `shaders/` entries are under `servers/rendering/renderer_rd/`.

## Frame order that must survive a port

1. Snapshot directional routing/demotion settings before viewport work. Cull, atlas layout and light-buffer flags must see the same answer.
2. Collect eligible mesh/MultiMesh shadow casters from light volumes, including offscreen casters. Gather GI transport geometry separately: it includes participating non-shadow-casters.
3. Complete current mesh-instance updates for gathered posed geometry before AS work. GI explicitly requests updates for offscreen non-casters not covered by visible/shadow queues.
4. `RendererSceneRenderRD::update_raytracing_scene` opens one `RaytracingGeometry::begin_update()` scope, updates shadow and GI consumers, then calls `end_update()`. A shared frame budget/cache cannot reset between clients.
5. Decide remaining shadow-map work from actual RT scene availability. Render/resolved depth and normal/roughness, and assign current light slots, before dispatching RT shadows in `_pre_opaque_render`.
6. Trace, then temporal filtering and a-trous filtering when enabled. Fog and forward shading consume the current result; transparent shading uses its own map/fallback path.

Do not move the AS build back before the final pose updates. A build and a later skinning dispatch in the same GPU submission can still represent different animation states; submission in one frame alone does not establish the required order.

## Shared geometry introduced for AMD GI

`RaytracingGeometry` owns BLAS and optional dequantized positions. It knows geometry, not visibility, lights or materials. Shadow and GI consumers have separate TLAS and metadata. GI enable/disable must not invalidate BLAS still used by shadows.

- Mesh upload and posed buffers require AS-build-input, device-address and storage usage as appropriate. `MeshStorage::_raytracing_buffers_required()` is gated by the RT master setting and device features. This is why the master switch requires restart and why AMD GI currently depends on it.
- A compressed position buffer is expanded into float32 XYZ by compute. Allocate its destination with **`vertex_buffer_create`**, including `BUFFER_CREATION_AS_STORAGE_BIT`, device address and AS-build-input flags. A storage-buffer RID is rejected by the RD BLAS vertex-owner lookup; a vertex buffer without storage usage cannot be written by the dequantization shader.
- Only nonempty 3D triangle surfaces are admitted. Indexed and nonindexed triangles work. Preserve index width and source format, including the 65,536-vertex index-width boundary.
- Static cache keys use full mesh RID and surface. Posed keys use full posed-buffer RID and surface, distinguishing instances and rotating buffers. Never replace full RIDs with local indices that lose generations.
- READY entries validate source buffer identity and `MeshStorage::Surface::geometry_revision`. Vertex/index-region edits advance that revision and rebuild even if the RID is unchanged. Old documentation claiming these edits remain stale is obsolete.
- A posed version change triggers a **full BLAS rebuild**, including dequantization when necessary. This is not a BLAS refit implementation. A successful build advances the exported surface revision used by downstream caches.
- New builds are limited to 64 surfaces and roughly 1,048,576 triangles per update. A single admitted surface can exceed the remaining triangle allowance; existing posed refreshes are not bounded by this new-build allowance.
- Entries unused for more than 60 shared updates are eligible for eviction; sweeps run every eighth update. These are update counts, not wall time. `release_gi_only()` promptly drops GI-only entries and preserves current shadow users.
- Borrowed `Surface` pointers expire on cache mutation. Copy required handles/fields before another lookup can mutate storage. Destroy owned expanded buffers and BLAS through their actual lifetimes; do not assume upstream buffer destruction leaves dependent AS handles usable.

The current skinned rebuild failure path warns that the old shadow can be stale. This is a remaining failure limitation, not a guarantee that every failed GPU preparation recovers atomically.

## Caster collection and shadow TLAS

`_casts_into_acceleration_structure` accepts Mesh/MultiMesh with shadow casting enabled and native material caster eligibility. `_is_screen_space_shadow_caster` is its complement, keeping the two classification rules aligned. Material shadow exclusions also form the per-surface mask; first 32 surfaces have distinct mask bits. This classification does not evaluate alpha textures in a ray query.

Local lights query their volumes. Directional collection sweeps camera-shadow coverage toward the sun, controlled by caster-distance scale. The gather deduplicates instances. MultiMesh elements receive individual transforms and volume tests, with directional scatter policy applied per element. Directional coverage can avoid redundant positional spatial queries, but the positional light-volume list remains necessary for element eligibility.

The shadow and GI gathers share `InstanceGeometryData::rt_multimesh_expansion`,
a value-only cache of element world transforms and bounds. Its key includes full
mesh/MultiMesh RIDs, current rendered-buffer revision, parent transform, mesh
bounds and visible element count. Revision zero bypasses reuse; shadow-only
expansion also bypasses eager caching above the caster ceiling. Camera/light
intersection tests and directional scatter policy always run against current
values. Do not cache the selected subset just because geometry is unchanged.

`RaytracingScene::update` assembles one instance per admitted surface/element, up to 65,536. Its TLAS starts at capacity 64 and grows by powers of two. Preserve:

- the BLAS RID, transform, folded eight-bit layer mask and dense custom index;
- triangle culling disabled;
- `hit_sbt_range` count one, offset zero, even for ray-query-only use (RD validates it).

Shadow TLAS reuse uses a count-seeded, order-independent 32-bit content hash plus the shared geometry change flag. It is not the stronger ordered comparison used by GI. On change it requests a **full TLAS build** with `PREFER_FAST_TRACE`; shadow TLAS does not currently request `ALLOW_UPDATE` or refit. Empty/failed updates invalidate the current shadow scene rather than presenting a previous TLAS as current.

CPU preparation resolves each successful `(mesh RID, posed-instance RID, surface)`
once per scene update, copying the BLAS handle. Every unique source is resolved
again in the next update, including another viewport in the same frame. Failed
or deferred requests are retried as before; material masks and the first surface
request beyond the instance ceiling retain their original ordering. Retained
input slots reuse their hash contributions only when the exact transform, folded
layer mask and newly resolved BLAS handle match. Reordering invalidates affected
slots but preserves the order-independent TLAS decision. The full RD instance
array is assembled only when a build is required. This retains the preexisting
32-bit hash collision limitation; it does not introduce stronger scene equality.

`GODOT_RT_DISABLE_SHADOW_REUSE=1` selects the original CPU reconstruction path.
`GODOT_RT_VALIDATE_SHADOW_REUSE=1` compares the optimized ordered RD records and
hash against full reconstruction and checks shared MultiMesh values directly.
`GODOT_RT_CPU_PROFILE=1` reports gather, MultiMesh expansion/culling and scene
preparation timings/counts. Keep these diagnostics off for performance samples.

GI has a separate conditional transform-only TLAS refit implemented in `rt_gi_scene.cpp` and RD/Vulkan. Do not describe that optimization as applying to shadow TLAS or skinned BLAS. See [the shared adaptation contract](rt-materials.md#gi-tlas-and-upload-reuse).

## Shared CPU submission reuse

`RenderingDevice::tlas_build` retains each TLAS's ordered full BLAS RIDs, native
instance inputs/packed bytes and unique graph trackers. An identical validated
BLAS order permits repacking only changed transforms, IDs, masks, flags or SBT
offsets. Every build still copies the complete input into its own reserved mapped
ring range and registers every BLAS graph dependency. Retaining CPU bytes does
not authorize reusing an in-flight GPU upload range or omitting synchronization.

`_blas_remove_tlas_dependencies` invalidates dependent CPU caches on both rebuild
and free, including same-RID rebuilds. Reconstruction validates all references
before publishing replacement weak links in both directions. Failure leaves the
cache invalid; no borrowed tracker/native address can be used until validation
succeeds. Clear CPU-only arrays before deferred GPU destruction copies the AS.
Frequent topology changes or posed BLAS rebuilds conservatively reconstruct the
cache; this optimization does not eliminate those workloads.

`GODOT_RT_DISABLE_TLAS_REUSE=1` restores original submission preparation;
`GODOT_RT_VALIDATE_TLAS_REUSE=1` compares every native byte, both weak dependency
directions and graph trackers against current owners. The native fixtures must
allocate BLAS inputs with both AS-build-input and device-address usage and verify
a nonzero address. See [acceptance and runtime fixtures](../validation/rt_cpu_optimization_2026_10_26/TESTING.md)
and [detailed submission notes](../validation/rt_cpu_optimization_2026_10_26/TLAS_REUSE.md).

## Light identity and GPU data

Stable RT slots belong to light RIDs, not their current clustered-buffer position. Slots 0–254 are valid and 255 is the sentinel. The sun takes priority in selection; per-pixel selection retains at most four lights from the tile candidates. Excess selected-path lights illuminate without per-pixel RT occlusion; a missing slot in that pixel does not invoke a shadow map.

The AS mask folds the four bytes of the native 32-bit layer mask with OR; a resulting zero becomes `0xff`. Preserve the same fold for light caster masks and instances. This deliberately aliases layers separated by eight bits and is not full native layer isolation.

| Data | Contract |
| --- | --- |
| `RTShadows::LightParams` / shader light row | 64 bytes |
| Trace push constants | 120 bytes |
| Temporal push constants | 112 bytes |
| A-trous push constants | 48 bytes |
| Dequantization push constants | 32 bytes |
| Per-pixel light indices | RGBA8 UINT; four slots, unused channels 255 |
| Visibility mask | RGBA8 UNORM, **sqrt-encoded** visibility; square when decoding |
| Hit-distance channels | Normalized screen-space penumbra width, not a reusable world-space distance |

C++ static assertions do not validate GLSL layout. Compile/reflect every affected shader and compare the exact block end, without rounding it to an assumed 16-byte size. Preserve bindings, storage image formats and light-buffer layout on both sides. Godot's shader-version array arithmetic must derive from the current enum layout: AMD GI added a motion prepass, so an older hardcoded `SHADER_VERSION_COLOR_PASS` ordinal misindexes color variants.

## Trace and filtering algorithm

The trace shader reconstructs world position from reverse-Z depth and inverse view-projection, reads the matching world-space normal, culls lights per 8×8 tile, then selects up to four by contribution. Keep stable light-slot identities through all passes. Reuse the shader's sampling sequence and blue-noise conventions when porting rather than replacing them with unrelated random sampling.

Rays use opaque geometry. Accurate mode finds the nearest blocker for penumbra estimation; the fast mode permits first-hit termination. Light size and blocker/receiver geometry determine projected penumbra width, clamped to `MAX_PENUMBRA_PIXELS` (32) and stored normalized. Hard lights have zero penumbra. Directional rays derive range from the light shadow distance and caster extent; positional rays stop at the sampled emitter. Preserve native bias and normal-offset scaling from the trace source when rebuilding to avoid self-intersection regressions.

Temporal filtering:

1. Reject sky/invalid pixels; reproject with current-to-previous camera matrices.
2. Validate each of four bilinear history taps separately against exact four-slot index equality, expected previous linear depth, view bounds and positive projection.
3. Decode sqrt visibility before statistical operations. Estimate local current moments and account for single/few-sample noise when clamping history; `history_clamp_sigma = 0` disables that clamp.
4. Use history length to accumulate, with `lag_response` responding to history disagreement. Moving-object motion is not supplied as a per-object velocity field here; depth/slot rejection and clamp response are not a guarantee of trail-free motion.

A-trous filtering uses a 5×5 B-spline kernel with doubling stride, normal/depth weights and matching light slots. A 3×3 maximum penumbra over matching neighbors spreads reach into the lit edge. Filter floor/history fill apply only where nonzero penumbra exists; do not blur hard contacts merely because the user requests a minimum radius. The first spatial pass saves its **temporal input** as next-frame history. Feeding its filtered output back would compound blur.

All visibility consumers must decode the same square-root representation, including the history path and fog/forward helpers that use the mask. Preserve the explicit ray-query shader language/extensions when moving shader build machinery.

## Forward, maps, fog and shared GI attachments

RT availability forces the prepass inputs it consumes. AMD GI adds its own motion/geometric-normal path; integrate prepass variants and framebuffer attachments together with screen-space-shadow caster-mask sharing. Do not transplant an older RT-only variant index table over the GI version.

Opaque shading looks up the selected light's RT slot. Transparent passes cannot use the opaque surface's screen-space mask. `shadow_map_enabled` retains a supplemental map without disabling opaque RT. Directional RT fog traces its own froxel rays; local fog needs the map path. Preserve directional demotion settings and their frame snapshot when retaining maps.

At the RD level, buffer writes, skinning, dequantization, BLAS/TLAS builds and ray-query reads require graph-visible dependencies. Device addresses do not make dependencies implicit. Shared GI adds source-buffer reads and Vulkan TLAS update support; retaining cached metadata must not accidentally drop these registrations.

## Rebuild acceptance checklist

- Master-off/device-unsupported paths allocate no RT-only geometry resources and retain native rendering behavior.
- Compressed/uncompressed and indexed/nonindexed geometry build; skinned, blend-shape and same-buffer vertex/index edits affect the current trace.
- Offscreen casters and GI-only posed geometry use current poses; disabling GI preserves shadow-owned BLAS.
- MultiMesh transforms, visibility and directional scatter policy behave independently per element.
- Light slot reorder/removal, alpha receivers, supplemental maps, fog and live directional toggles preserve routing.
- Layer aliases, four-light overlap, admission budgets and alpha-card opacity are documented limits, not hidden regressions.
- Reflect C++/GLSL layouts, verify generated shader dependencies and inspect render-graph barriers.
- Test raw and denoised hard/soft shadows, disocclusion and moving lights; verify temporal history receives the unblurred result.
- Exercise allocation/build failure, disable/re-enable and cleanup. A successful build alone is not GPU behavior validation.

`GODOT_RT_DEBUG=1` enables gather/build diagnostics. Use the fixtures and procedures in [validation](../VALIDATION.md); archived tuning reports are historical evidence, not proof of the current binary.
