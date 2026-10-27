# Shared RT geometry and AMD GI material adaptation

Use this document when modifying caches, material evaluation or the shared acceleration structures. It complements [RT-shadow internals](rt-shadows.md) and [AMD GI internals](amd-gi.md). Paths are relative to the engine root. The AMD baseline policy applies: retain AMD GI's estimator, light ordering and history rules unless a documented, justified Godot integration requirement demands a change.

## Why this adapter exists

Godot materials, shader assignments, textures and instance values can change independently of meshes. The imported Capsaicin application path does not supply a general Godot-style independent-material-update contract. Copying that restriction would break supported project behavior. The adapter therefore separates persistent geometry/layout metadata from live material and instance values; it does not substitute a different GI estimator.

The active AMD path uses `renderer_rd/environment/rt_material_source.{h,cpp}`, `rt_gi_scene.{h,cpp}` and `shaders/effects/rt_material_source_inc.glsl` under `servers/rendering/`. The standalone/legacy validation path uses `rt_material_capture.cpp` and `rt_material_expand.glsl`. Its capture atlas and `material_atlas_mb`, `material_preparation_budget`, `material_tile_size` and `material_adaptive_resolution` controls are **not AMD source-material optimizations**. Keep the two consumers distinct.

## Source evaluation contract

`RaytracingMaterialSource::compile` reuses the native spatial `ShaderCompiler` to produce vertex/fragment helpers. Native material uniform layout must match the generated block exactly; the implementation compares total size and offsets. Global and instance uniforms, texture/sampler types, packed vertex attributes and per-instance inputs remain native inputs.

At a hit, source evaluation executes vertex helpers at triangle corners and interpolates supported outputs/varyings before fragment evaluation. This reconstructs material inputs; it does **not** deform the BLAS to follow arbitrary shader-written vertex positions. Skinning/blend shapes use the current posed mesh buffers through shared `RaytracingGeometry`.

Keep geometric and shading normals distinct, including tangent handedness and coordinate transforms. The primary GI attachment obtains a face geometric normal from raster-position derivatives; normal-mapped shading normals remain separate. Do not substitute an interpolated authored normal for geometric rejection/offset rules simply because both are named “normal.” This distinction was relevant to localized glossy-surface artifacts and remains an important porting contract.

Material programs requiring raster derivatives (`dFdx`, `dFdy`, `fwidth`, their fine/coarse variants or `textureQueryLod`) are omitted from GI transport with a warning. Inventing zero derivatives would silently alter their meaning. Explicit `textureLod`/`textureGrad` accesses remain authored. Vertex implicit texture reads use mip zero. The compiler's opt-in affine coordinate analysis qualifies supported emitter mappings for AMD's triangle-footprint filtering; unsupported mappings retain the existing fallback and warn. Do not advertise universal derivative, filtering or custom-deformation support.

## GI alpha candidates, winding and shadow masks

`RaytracingGIScene::update_scene` gives GI TLAS instances both `TRIANGLE_FACING_CULL_DISABLE` and `TRIANGLE_FLIP_FACING`: native clockwise winding must reach Vulkan's candidate front-face test correctly. Alpha-bearing programs (`uses_alpha`, `uses_alpha_clip` or `uses_discard`) additionally use `FORCE_NO_OPAQUE`, overriding the shared BLAS's opaque geometry. These GI flags do not change the separate opaque RT-shadow query.

In the production `AMD_GI_REFERENCE_RANDOM` path of `rt_gi_transport_inc.glsl`, ordinary transport uses `gl_RayFlagsNoneEXT`; a nonzero shadow mask uses `gl_RayFlagsNoOpaqueEXT` so even opaque candidates receive full 32-bit shadow-layer filtering. The TLAS traversal mask remains `0xff`. A candidate's hit-record shadow mask is its native instance layer mask when the surface casts shadows, otherwise zero. Keep that field distinct from its transport/light layer mask.

Candidate processing applies native front/back material culling only to nonopaque materials, evaluates their source opacity, and confirms covered triangles. Source `discard` produces zero opacity. Current non-stochastic coverage uses `opacity > 0.5`; admitted mix-alpha programs without alpha clipping use an object-position/frame hash as a stochastic threshold. This models straight-through fractional coverage, not refraction. It does not establish exact parity with every raster alpha-scissor threshold, alpha-hash control or antialiasing mode. Preserve the actual admission/exclusion rules and test foliage/transparent cases rather than describing all native alpha behavior as automatically supported.

## Invalidation matrix

No single dependency notification or material revision covers all of Godot's supported mutations. Retaining a RID is not evidence that its bytes, layout or borrowed resources are unchanged.

| Mutation | Required adapter behavior |
| --- | --- |
| Local uniform value | Compare current uniform bytes and update retained storage without rebuilding unchanged mesh metadata. |
| Shader reassignment, code edit or removal | Re-resolve native material data, compile/support status, layout, culling/emission and surface admission. Do not retain raw `MaterialData*` across assignment. |
| Next pass or material override | Recheck effective material/admission and resulting dense indices; notification and content-revision coverage differ. |
| Texture binding, default or global texture | Resolve current typed texture descriptors; rewrite indices and refresh contexts if addresses change. |
| In-place texture pixels | Sample current contents; retain metadata only with correct GPU read/write dependencies. |
| Texture replacement, proxy or destruction | Repair descriptors and borrowed resources, including the appropriate color-space view. |
| Global/instance numeric uniforms | Use current shared uniform buffers; a changed instance allocation/offset changes context metadata. |
| `TIME` and frame inputs | Update the frame header and evaluate live shading. Never cache evaluated emission/RGB as material metadata. |
| Vertex/index region | Advance geometry revision and rebuild affected BLAS, even when the buffer RID is unchanged. |
| Attribute/skin region | Advance data revision and refresh corresponding source attribute copies/pose processing. |
| MultiMesh transform/color/custom data | Refresh per-element geometry/context values; ordinary scene notifications are insufficient. |
| Visibility, base type, membership, layer/GI policy | Reevaluate admission and ordering, including supported-to-unsupported transitions. |
| RID destruction/reuse | Use full generations in keys and remove or repair every borrowed handle. |
| Scenario/viewport change, disable/re-enable or failed preparation | Publish a complete current snapshot; multiple scene updates can occur within a global frame. |

Read `MeshStorage::mesh_surface_update_*_region`, `MaterialStorage::material_set_shader`, `material_set_next_pass`, `_material_queue_update`, texture replacement/proxy paths and MultiMesh setters when porting these rules. A future native API may improve notification coverage; verify it rather than deleting checks by assumption.

## Implemented CPU reuse

- Scenario membership is retained in full-RID order, invalidated on insertion/removal. It retains all instance types so base-type edits remain visible. Collection continues reading current eligibility, transforms, materials, masks and MultiMesh values.
- `RaytracingGIScene::SurfaceGeometryKey` validates full instance/mesh/posed-buffer identities, element/surface, buffer identities, formats and geometry revision before reusing a hit-geometry template. Current posed normal data must still be selected.
- Each unique material prepares shared context once per scene update. Shader selection and allocations persist; current native uniform bytes and texture bindings are polled after native preparation. `MaterialData::set_as_used()` preserves Godot's render-target usage contract even for offscreen GI consumers.
- Typed texture ordering remains dense. Stable-size index buffers update in place; descriptor/index/address changes repair every borrowing context.
- Context and hit buffers compare against the last successfully uploaded contents and update one bounding changed span. Reallocation uploads all contents. Header time and current source/global/instance values remain live.
- Dense GPU order remains the contract: admitted TLAS custom IDs, hit records, source contexts and emitter references use the same surface order. CPU cache keys are not a replacement GPU indexing scheme.

`RaytracingGIScene::retained_groups` additionally retains complete dense Hit/AS/Context ranges for unchanged ordinary instances or collector-stamped MultiMesh parents. Reuse requires matching full identities, input count/generation, dense offset, transform, effective materials, uniform offset, masks and surface count. `RaytracingMaterialSource::prepare_surface` still refreshes current unique resources in original first-use order. Shader code/`next_pass`, geometry/pose/data revisions and the resulting base Context must match before cursors can skip a group. Numeric uniforms, texture contents, `TIME` and resource-usage touches stay live. This removes repeated record construction; it does not cache evaluated lighting.

Source-mode emitter batches/ranges contain geometry and source IDs, so unchanged emission-writing groups can retain them too. Reuse additionally requires matching batch/triangle prefixes and emissive-sampling state. Earlier emitter membership/count changes or sampling toggles reconstruct offsets; native emission evaluation and GPU emitter-update behavior stay unchanged. Exclusion-report and motion-history modes use full traversal. Changed or incompletely stamped groups fall back to the existing path. Arrays truncate at final cursors, and failed preparation invalidates group reuse until a complete update succeeds. The [retention design](../validation/gi_cpu_retention_2026_10_26/SCENE_PLAN.md) records these guards; [runtime evidence and limits](../validation/gi_cpu_retention_2026_10_26/RESULTS.md) distinguish current passes from the unresolved legacy material-response scorer. High-churn scenes can pay reconstruction overhead and require separate timing.

Preserve graph-visible reads for native uniforms, descriptor-index buffers and copied attributes on every consuming dispatch. `add_buffer_reads` and `append_buffer_reads` expose the same live resource set; batching dependency lookup must preserve the reads themselves. Buffer-device addresses hide bindings from ordinary descriptor discovery. Group refresh touches retained source resources each update so pruning cannot evict a skipped group's dependencies.

The subsequent CPU follow-up memoizes successful base Context preparation by full
material/mesh/surface identity within one scene-update epoch. Per-instance fields
are applied afterward; first-use refresh and dense texture order remain unchanged.
Pending Context write intervals survive failed preparation/uploads. Scene record
comparisons use reconstructed group ranges only when the previous complete scene
was successfully published; otherwise they recover through full comparison.
See the [implementation and review](../validation/gi_cpu_retention_2026_10_26/CPU_FOLLOWUP_IMPLEMENTATION.md)
for bypass/oracle controls and the explicit lack of new runtime evidence.

## GI TLAS and upload reuse

The GI TLAS compares the exact ordered instance fields and per-surface geometry revisions against the last successful build. Identical inputs skip work. Transform-only changes can request in-place TLAS refit only when topology, instance ordering, IDs, masks, SBT range, flags and geometry revisions remain compatible.

The GI allocation includes `ALLOW_UPDATE`. RenderingDevice additionally checks a submitted prior build, matching nonzero instance count and all-active lists; otherwise the request falls back to a full build. Scratch storage covers both build and update requirements. Vulkan uses the same AS for source/destination in update mode, with graph-visible AS read/write dependencies. Other driver interface signatures match, without claiming their RT support has expanded.

`acceleration_structure_is_valid()` establishes resource ownership, **not** current TLAS contents. Preserve successful-build snapshots, native dependency tracking and lifetime-bound Vulkan buffer-address caching. Shadow TLAS still uses full builds/hash reuse, and changing poses still rebuild BLAS; the GI TLAS refit does not optimize either path.

Both GI and shadows also use [shared CPU submission reuse](rt-shadows.md#shared-cpu-submission-reuse)
inside RenderingDevice. Retained native instance bytes and BLAS dependencies
reduce CPU preparation; they do not change GI refit eligibility or allow partial
GPU inputs, skipped graph reads, or reuse after a dependent BLAS rebuild/free.

Analytic light count and emissive light-table location must be independent. `RaytracingGIScene::_ensure_buffers` anchors the emitter span at retained analytic **capacity**, not current active analytic count. Toggling a muzzle light within capacity therefore does not move the emitter table and spuriously force full emitter regeneration. Capacity growth copies the retained emitter span to its new offset before publishing replacement storage; copy/allocation failure must not publish a partly relocated table. This addresses a structural firing-time cost without changing AMD's sampling order.

## Failure and resource lifecycle

Only successful preparation/build/upload may advance reusable snapshots and dirty-state commitments. Unsupported source shaders are omitted through `ERR_UNAVAILABLE`; other preparation failures reject the update instead of blessing incomplete records. The consumer must then take its failed-preparation recovery path, invalidate stale results as required and retry with current inputs. Treat resource-handle validity, preparation success and history usability as three different conditions.

GI disable releases source-consumer resources. Shared geometry's `release_gi_only()` retains current shadow users. Preserve native buffer/descriptor invalidation and graph retirement when replacing resources; do not add device-wide waits as a substitute for correct ownership. Shutdown order and external upscaler cleanup are covered by their own integration notes.

## Porting and adversarial checks

Source inspection establishes these contracts, not exhaustive runtime correctness. Required regression cases include:

- Independent uniform, shader-to-null, next-pass, override, texture binding/pixel/proxy/deletion and supported/unsupported shader transitions.
- Live `TIME`, global/instance uniforms and render-target textures, including offscreen transport users.
- Same-buffer geometry edits; posed-buffer rotation; source attribute revisions; MultiMesh transform/color/custom updates.
- Instance insertion/removal/RID reuse; buffer capacity growth; material sharing across many surfaces; transient analytic lights while emitters remain present.
- Failed allocation/upload/build followed by retry; disable/re-enable; multiple viewports/scenarios; cleanup with retained/shared resources.
- Compare cached preparation with a full reconstruction: dense IDs, context/hit bytes, descriptors, dependency lists, emitter spans and actual shading results.

`GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1` enables reconstruction/readback oracles. A retained-group candidate is fully reconstructed and its Context, Hit, AS fields/revision, emitter batches/ranges and dense counts compared before overwrite; per-group RID logs prove that the intended fixture subject was checked. Test both emissive and nonemissive subjects, sampling toggles and changed earlier emitter prefixes. `GODOT_AMD_GI_DISABLE_RETAINED_GROUPS=1` bypasses group reuse, and `GODOT_AMD_GI_TRACE_RETAINED_GROUPS=1` reports actual reuse/oracle, emitter reuse and reconstructed emission-group coverage. `GODOT_AMD_GI_VALIDATE_SOURCE=1` enables known-value source diagnostics.

These are diagnostic modes, not valid performance measurements. Fixtures live under `docs/validation/shadow_validation/`; follow [validation](../VALIDATION.md) and the [retention acceptance plan](../validation/gi_cpu_retention_2026_10_26/SCENE_PLAN.md#adversarial-checks-and-validation). A fixture's presence or a successful build does not prove every lifecycle case above has passed on the target GPU.
