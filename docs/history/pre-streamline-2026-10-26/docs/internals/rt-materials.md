> Historical snapshot from `66bd97e00d` before the 2026-10-26 documentation audit. Claims and line numbers may be superseded. Do not use as current configuration guidance.

# RT materials: current implementation map

Start with [AMD GI status/limits](../AMD_GI_IMPLEMENTATION.md) and
[approved boundaries](../AMD_GI_ADAPTER_DECISIONS.md). The complete old material
capture guide is preserved in [the archive](../history/AMD_GI_ARCHIVE.md#snapshot-rt-materials);
read it only when changing the legacy validator.

## AMD GI source materials

- `servers/rendering/renderer_rd/environment/rt_material_source.{h,cpp}` compiles native vertex/fragment material programs into GI compute helpers. Native material/global/instance uniforms, texture/sampler bindings and packed vertex attributes are inputs.
- `rt_gi_scene.cpp` collects supported surfaces/lights and reports omissions. `renderer_scene_cull.cpp` supplies scene instances and honors `GI_MODE_DISABLED`.
- Shared `RaytracingGeometry` supplies BLAS triangle positions/indices and posed geometry. Source attribute copies gain device addresses only on revisions; no CPU mesh readback or triangle material atlas is used for AMD GI.
- `rt_material_source_inc.glsl` reconstructs native material inputs at hits. Vertex outputs/varyings are interpolated. Geometry and shading normals remain distinct and transform once; the screen shading-normal path includes normal maps.
- `ShaderCompiler` has an opt-in affine coordinate analysis used by this consumer. Supported emitter mappings supply triangle-corner coordinates to AMD's existing footprint formula. Ordinary UV0 retains its helper. No additional rays, passes, buffers or full material invocations are added by this correction; hardware cost is unmeasured.
- Explicit authored texture LOD/gradient reads remain explicit. Vertex implicit reads use mip zero. Unknown emitter mappings warn and retain fallback filtering; raster-derivative shaders are omitted rather than receiving invented zero derivatives.
- Resource/shader initialization is gated by GI enable. Disable releases the source consumer resources. Compilation/first-use and target-hardware cost still need profiling.

`GODOT_AMD_GI_VALIDATE_SOURCE=1` enables diagnostic known-value readbacks; it is not
normal frame rendering. Source, mapped emitter, winding and deformation fixtures
are in `docs/validation/shadow_validation/`. See [validation](../VALIDATION.md).

## Legacy capture is a separate consumer

The uncached `rt_validation` integrator and standalone material-bake diagnostic
still use `rt_material_capture.cpp` / `rt_material_expand.glsl` and the capture atlas.
The `material_atlas_mb`, `material_preparation_budget`, `material_tile_size` and
`material_adaptive_resolution` controls do not improve current AMD GI materials.
Do not reintroduce their coarse material representation into AMD GI.

## Persistent scene/material research: 2026-10-24

Research baseline: `4ca77d59c70b0fd9558cd41657819649e99d3931`, with independent
material, scene and adversarial investigations. The owner subsequently requested
completion of the researched integration in the same effort. The implementation
below follows those findings. Keep AMD's estimator, light ordering and history rules.

AMD Capsaicin GI-1.2 (`914b91596cd119eda85fbc1d3c7ee6ac391b1452`) separates
[persistent instances, transforms and materials](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/blob/914b91596cd119eda85fbc1d3c7ee6ac391b1452/src/core/src/capsaicin/capsaicin_internal_scene.cpp#L1388-L1682).
Its material update is gated by mesh changes and explicitly does not support
independent material changes. Adopt the separation of metadata and changing
values; do not import this application restriction into Godot.

### Invalidation findings

Source locations below identify functions rather than relying on mutable line
numbers. Native material/mesh/texture storage lives in `renderer_rd/storage_rd/`.

| Change | Required behavior | Existing mechanism and limitation |
| --- | --- | --- |
| Local uniform value | Update one material's uniform bytes; retain context if layout/address stays stable | `MaterialStorage::_material_queue_update` advances `content_revision`; in-place uniform updates need not emit dependency notifications. |
| Shader assignment/code, including removal | Recheck support, layout, culling, opacity, emission and surface admission | `material_set_shader` with a null shader has a notification path without a content-revision increment. Shader code changes queue owning materials. Never retain raw `MaterialData*` across assignment. |
| Next pass | Recheck surface admission and dense indices | `material_set_next_pass` notifies dependencies without advancing material content revision. |
| Texture binding/default/global texture | Resolve current RD view and typed descriptor slot; refresh indices and any changed buffer addresses | Queued updates exist, but current per-frame traversal repacks texture indices. Same material RID does not imply stable index-buffer contents or address. |
| Texture pixel edit | Sample current content without rebuilding unchanged metadata | In-place updates do not require new context bytes. They still require correct resource dependencies and current emission evaluation. |
| Texture replacement/proxy/deletion | Refresh descriptors and invalidate old resources | `TextureStorage::texture_replace` / `texture_proxy_update` and native descriptor invalidation need lifecycle tests, including sRGB views. |
| Global numeric/instance uniform value | Update shared GPU uniform storage | Current generated shaders already read that storage. An instance uniform allocation/offset change still changes its context. |
| TIME and other frame inputs | Keep the frame header and shading current | Metadata reuse must not cache emitted RGB or material evaluation results. |
| Mesh vertex/index/attribute/skin region | Revalidate geometry and attribute copies | `mesh_surface_update_*_region` advances source revisions without a general dependency notification. |
| MultiMesh color/custom | Refresh affected context fields | `multimesh_instance_set_color` / `multimesh_instance_set_custom_data` mark the buffer dirty without a general scene dependency notification. |
| Overrides, transforms, visibility and membership | Resolve effective materials and participating surfaces | These use several setters and dirty paths; no single existing scene event covers all of them. |
| Resource destruction/reuse | Evict or repair every borrowed reference | Keys must contain full RID generations, not local indices. |
| Scenario/viewport switch, disable, retry | Publish a complete current snapshot | GI scene storage is renderer-level; multiple updates can occur within one global frame. |

Neither dependency notifications alone nor material revisions alone are a
complete invalidation mechanism. Whole-scene early-outs based on either would
miss supported Godot changes.

### Implemented adaptation and deliberate boundaries

1. Retain the existing dense output order. Successful surface traversal assigns
   TLAS custom IDs, hit/context indices and emitter material references together.
   Persistent CPU cache keys must not become a new GPU index scheme.
2. Poll current unique material/mesh inputs after queued native updates finish,
   rather than trusting incomplete notification/revision coverage. Material
   eligibility still reads current data/shader/next-pass state. Each used material
   prepares its shared context once per scene update; current uniform bytes and
   texture bindings are checked while shader selection and allocations persist.
3. Separate shared mesh layout templates, material metadata, per-instance values
   and transform/pose data. Avoid duplicating full material state per surface.
   Reuse allocated uniform/index buffers when possible; refresh all borrowing
   contexts when addresses or descriptor indices change.
4. Compare current context/hit bytes against the last successful upload and send
   one bounding changed span, avoiding many tiny transfers and unchanged writes.
   Reallocation publishes complete contents. Snapshots copy only the changed span.
   The TIME header and live shader/global/instance values remain current.
5. Preserve existing dense typed texture ordering. Stable-sized texture-index
   buffers update in place. Persistent sparse descriptor slots are unnecessary
   for this design and are not introduced; they would add retirement/capacity rules.
6. Cache complete scenario membership in RID order, invalidated by scenario
   insertion/removal. Retain all instance types, so base-type edits stay visible.
   Reevaluate eligibility, transforms, overrides, masks and MultiMesh values every
   update. This avoids repeated sorting without relying on incomplete dirty events.

Retained metadata must still register every required `compute_list_add_buffer_read`.
The current source adapter expires resources not touched in the current update;
any future skip path must retain both resources and their dependency registration.
Dirty generations must be committed only after successful preparation, with
failure/retry and multiple-view updates handled explicitly.

The source adapter now calls `MaterialData::set_as_used()` once per used material
per scene update, following Godot's native render-target usage contract for
offscreen GI consumers. Runtime render-target behavior still requires validation.

### Adversarial validation

Use the current full reconstruction as an oracle: compare context bytes, dense
IDs, effective descriptors, hit flags, emitter ranges and material outputs after
shared uniform edits; texture replacement/proxy/deletion; shader-to-null and
supported/unsupported transitions; next-pass/override changes; TIME/global/instance
updates; same-buffer mesh edits; MultiMesh transform/color/custom changes;
insertion/removal/RID reuse; buffer growth; disable/re-enable; scenario switches;
and a failed update followed by retry. Preserve all indirect buffer dependencies.

The mutation fixture `amd_gi_scene_metadata` and the opt-in
`GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1` oracles compare collection, geometry records,
dependencies, attribute copies, material uniform/index data and uploaded contexts
against current source inputs. They are diagnostic readbacks, never a performance
mode. The fixture is added but not run under the owner's source-only restriction.
Posed-buffer swapping, texture proxy/deletion, failed allocation retries and
multi-scenario GPU comparisons remain runtime coverage requirements; do not claim
that the new fixture alone exercises every lifecycle case listed above.

The agents rejected using `RenderingDevice::acceleration_structure_is_valid`
as a TLAS-content validity check: it tests ownership only. The separate narrow
TLAS optimization compares ordered input fields and per-surface geometry revisions
retained from successful builds. Surface geometry templates validate current full
resource IDs, buffer identities, format and geometry revisions. Packed transforms
retain values derived from the exact transform. The Vulkan address cache belongs
to the actual buffer lifetime. None bypasses native geometry/material validation.

RenderingDevice, its graph and Vulkan now support an explicit TLAS update request.
GI requests in-place refit only for transform changes with otherwise identical
ordered topology/flags and geometry revisions. RD additionally requires initial
ALLOW_UPDATE, a submitted prior build, equal nonzero count and all-active lists;
otherwise it records a full build. Scratch covers both build and update sizes,
and graph acceleration-structure read/write dependencies remain intact. D3D12 and
Metal RT stubs have compatible signatures; their RT support is not expanded.
BLAS refitting is not added: the measured workload had no skinned BLAS refreshes,
and AMD's animated path can itself force fresh builds. Its skinning is not a
universal refit-only model.

Validation completed without starting Godot: Windows editor compilation, independent
cross-review, formatting/whitespace/spelling and shell syntax checks. The production
TLAS eligibility test compiled as a standalone native test and passed 15 checks.
GPU refit correctness and CPU/GPU performance are unmeasured. Retained CPU records
consume additional memory proportional to scene size; vectors retain peak capacity.

### Muzzle-light storage and primary face normals (2026-10-24)

The owner's follow-up test reports improved overall performance, but firing-time
CPU spikes and localized gold AK reflection flicker. These are observations, not
a controlled before/after measurement of the fixes below.

The game's muzzle-flash script changes visibility for 45 ms and randomizes its
transform. It does not mutate a material or shader. Its additive, unshaded mesh
is excluded from the source-material GI scene; the child OmniLight changes the
analytic-light list. Previously the emitter region began at
`active_light_count * sizeof(LightData)`. Each count transition invalidated all
emitter geometry, even for unchanged static surfaces. The earlier large-level
profile contained 12,563 batches, making this a substantial command-recording
path. This is a source-level explanation consistent with the reported spikes;
no new firing profile establishes its exact contribution.

AMD GI now addresses emitters after the retained analytic capacity. The existing
frame `emitters.y` word carries that physical offset in `uvec4` units. The active
count and all dense logical light IDs remain unchanged. Buffer growth copies the
last successful emitter span before retiring the old allocation; failed copies
do not publish the replacement. The legacy capture path retains its packed
active-count prefix and invalidation. No extra descriptor, sampling change or
history reset is introduced. Capacity growth still incurs allocation/transfer
cost, but repeated visibility changes within capacity do not rebuild emitters.

AMD's pinned `visibility_buffer.frag` derives the primary face normal with
`normalize(cross(ddy_fine(world), ddx_fine(world)))`, separately from authored
vertex and normal-map shading normals. The Godot GI attachment instead used
its native `geo_normal`, which is the interpolated pre-normal-map normal. Those
are different inputs to ray-origin offsets and reflection plane filtering.
The correction is confined to the GI attachment: derive the actual face normal
from rasterized position derivatives before fragment material changes/discards,
then transform to world space. Native Godot lighting and the GI shading-normal
attachment preserve their existing authored normals.

Read-only decoding of the actual gold AK body found 1,773 triangles, of which
20 have a corner normal more than 10 degrees from the face normal and four exceed
30 degrees. The maximum is about 87.6 degrees on a tiny triangle. The gold
material is a plain metallic StandardMaterial3D with roughness 0.25 and no normal
map. This supports investigating the semantic mismatch, but does not prove it
is the sole cause of the visible flicker. Meshes/materials are not edited; no
denoiser thresholds, roughness clamps or ray-bias constants are changed.
