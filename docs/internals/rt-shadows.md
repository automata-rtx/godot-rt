# RT shadows: implementation and rebuild contract

Read this when changing or porting the renderer. Project setup belongs in [the user guide](../../GodotForkDocs/features/rt-shadows.md); AMD GI's native material adapter is covered in [rt-materials.md](rt-materials.md). Paths below are relative to the engine root. Source symbols are anchors; line numbers and shader-version ordinals are intentionally not contracts.

**Prerequisite:** [shared RT foundation](shared-raytracing.md). This guide owns
shadow collection, light slots, tracing, filtering and map routing; it does not
authorize a separate geometry cache or GPU dependency layer.

The experimental [HybridPiP integration](hybrid-pip.md) adds a prepared light
token so regional shadow passes share one logical sample phase and light upload.
Each region still has its own depth/motion/denoising history. Preserve that
contract when porting this branch; calling the ordinary wrapper twice would
advance preparation independently. The ordinary single-region wrapper remains.

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

The canonical contract now lives in [shared RT geometry and lifetime](shared-raytracing.md#shared-geometry-and-lifetime). Read that foundation before implementing shadows or GI.

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

See [shared CPU submission reuse](shared-raytracing.md#shared-cpu-submission-reuse). This optimization serves both scene consumers and must be implemented once in RenderingDevice.

## Light identity and GPU data

Stable RT slots belong to light RIDs, not their current clustered-buffer position. Slots 0–254 are valid and 255 is the sentinel. The sun takes priority in selection; per-pixel selection retains at most four lights from the tile candidates. Excess selected-path lights illuminate without per-pixel RT occlusion; a missing slot in that pixel does not invoke a shadow map.

The AS mask folds the four bytes of the native 32-bit layer mask with OR; a resulting zero becomes `0xff`. Preserve the same fold for light caster masks and instances. This deliberately aliases layers separated by eight bits and is not full native layer isolation.

| Data | Contract |
| --- | --- |
| `RTShadows::LightParams` / shader light row | 64 bytes |
| Trace push constants | 120 bytes |
| Temporal push constants | 116 bytes, including the rotation from current view normals into the previous camera's basis |
| A-trous push constants | 48 bytes |
| Dequantization push constants | 32 bytes |
| Per-pixel light indices | RGBA8 UINT; four slots, unused channels 255 |
| Visibility mask | RGBA8 UNORM, **sqrt-encoded** visibility; square when decoding |
| Hit-distance channels | Normalized screen-space penumbra width, not a reusable world-space distance |

C++ static assertions do not validate GLSL layout. Compile/reflect every affected shader and compare the exact block end, without rounding it to an assumed 16-byte size. Preserve bindings, storage image formats and light-buffer layout on both sides. Godot's shader-version array arithmetic must derive from the current enum layout: AMD GI added a motion prepass, so an older hardcoded `SHADER_VERSION_COLOR_PASS` ordinal misindexes color variants.

## Trace and filtering algorithm

The trace shader reconstructs world position from reverse-Z depth and inverse view-projection, reads the matching world-space normal, culls lights per 8×8 tile, then selects up to four by contribution. Keep stable light-slot identities through all passes. Reuse the shader's sampling sequence and blue-noise conventions when porting rather than replacing them with unrelated random sampling.

Rays use opaque geometry. Accurate mode finds the nearest blocker for penumbra estimation; the fast mode permits first-hit termination. Light size and blocker/receiver geometry determine projected penumbra width, clamped to `MAX_PENUMBRA_PIXELS` (32) and stored normalized. Hard lights have zero penumbra. Directional rays derive range from the light shadow distance and caster extent; positional rays stop at the sampled emitter. Preserve native bias and normal-offset scaling from the trace source when rebuilding to avoid self-intersection regressions.

RT shadow denoising uses one temporal pipeline and one spatial pipeline. Each internal pixel retains a half-float receiver depth, an octahedral view normal and four independent ages in RGBA16UI. RGBA8 carries current ages to the first spatial pass. The normal prepass supplies the receiver orientation. If normals are unavailable, use the raw shadow mask. Release stale history when denoising is disabled.

The temporal shader estimates width from blocked samples in a 3×3 same-surface neighborhood, vetoes contacts at one pixel, and ramps reuse up to five pixels of penumbra. A 5×5 same-surface visibility estimate limits stale shadow on a moving blocker. Each reprojected tap must pass depth, previous-view normal and channel identity checks. Partial coverage reduces the old sample's weight. Age zero identifies a directly measured contact for the spatial pass. Keep this independent of the temporally filtered visibility: a lit ray can miss a blocker inside a broad penumbra. Spatial output stays out of the feedback loop.

A-trous filtering uses a 5×5 B-spline kernel with doubling stride, normal/depth weights and matching light slots. A 3×3 maximum penumbra over matching neighbors spreads reach into the lit edge. The minimum spatial radius applies only where a nonzero penumbra exists; do not blur hard contacts merely because the user requests a minimum radius. The first spatial pass saves its **temporal input** as next-frame history. Feeding its filtered output back would compound blur.

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
