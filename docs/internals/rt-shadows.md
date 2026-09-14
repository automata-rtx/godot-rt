# Raytraced Shadows: Internals

Pass by pass, for someone modifying it. Not here: settings, node defaults, coverage, ceilings,
tuning (`docs/features/rt-shadows.md`); symptom-first diagnosis (`docs/TROUBLESHOOTING.md`);
measurements and refuted ideas (`docs/HISTORY.md`); scoring a change (`docs/VALIDATION.md`);
re-applying the fork (`docs/PORTING.md`).

## Two invariants that each cost a debugging session

**1. The dequantized position buffer must come from `vertex_buffer_create`, with
`BUFFER_CREATION_AS_STORAGE_BIT`.** In `servers/rendering/rendering_device.cpp`:

| Line | What it does | Consequence |
| --- | --- | --- |
| `:323` | `blas_create` resolves a geometry's vertex buffer through `vertex_buffer_owner.get_or_null()` **alone** | a `storage_buffer_create` RID lands in `storage_buffer_owner` (`:1509`), fails this lookup, and the build errors `Parameter "vertex_buffer" is null.` every frame, every compressed surface, forever |
| `:4756` | `uniform_set_create` refuses a **vertex** buffer bound as storage without `BUFFER_USAGE_STORAGE_BIT` | the dequantize pass's uniform set is refused and the structure is built from a buffer nothing ever wrote |
| `:1465` | `storage_buffer_create` sets that bit unconditionally; `vertex_buffer_create` only when asked | which is why switching functions silently loses it |

`uniform_set_create` does accept a vertex buffer for a storage binding (`:4753`), so the vertex path
loses nothing. Live call: `environment/rt_scene.cpp`, `_build_blas_geometry`, all three of
`BUFFER_CREATION_AS_STORAGE_BIT | BUFFER_CREATION_DEVICE_ADDRESS_BIT |
BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT`. Invisible under validation
(harness rigs build uncompressed; imported meshes are compressed by default), so in a real project
**no compressed mesh cast a raytraced shadow at all**.

**2. A C++/GLSL push constant size mismatch is a silently skipped pass in every shippable
configuration** (`CLAUDE.md` for why). `static_assert`s in `effects/rt_shadows.h` catch a C++-side
field change; **nothing catches the shader side.** Reflected size is the block's exact end, not
rounded up to 16, so a trailing pad on one side alone changes it. Reading it needs Godot's two
preamble lines stripped (glslang cannot infer a stage from `.glsl`, chokes on `#[compute]`):

```
sed -e 's/^#\[compute\]//' -e 's/^#VERSION_DEFINES//' <shader>.glsl > /tmp/x.comp
glslangValidator -V /tmp/x.comp -o /tmp/x.spv -q | grep '^Params: '
```

Scratch directory, never the repository. A mode-gated shader reflects the same block size with no
mode defined; modes select bindings, not constants.

## The frame

Once per camera render that is not a reflection probe.

| # | Step | Where |
| --- | --- | --- |
| 1 | Gather casters: per raytraced light, `aabb_query` the scenario geometry index with that light's bounds. **Not frustum culled.** MultiMesh elements culled individually | `renderer_scene_cull.cpp`, `_render_scene` |
| 2 | Flush skinning for gathered deforming casters, then build BLAS/TLAS | `renderer_scene_cull.cpp` → `RaytracingScene::update()` |
| 3 | Decide which lights give up their shadow map (directional first), render the maps that remain | `renderer_scene_cull.cpp` |
| 4 | Depth pre-pass with normal/roughness, forced on and MSAA-resolved | `render_forward_clustered.cpp`, `_render_scene` |
| 5 | Fill light buffers; raytraced lights acquire slots and write `rt_lights` rows | `LightStorage::update_light_buffers` |
| 6 | Trace: one compute dispatch, tile cull → per-pixel top four → rays. Writes mask, index, hit distance | `RTShadows::_trace` |
| 7 | Denoise: one temporal pass, then `spatial_passes` a-trous iterations | `RTShadows::_temporal`, `_atrous` |
| 8 | Volumetric fog: own ray per froxel, directional only | `environment/fog.cpp` + `volumetric_fog_process.glsl` |
| 9 | Forward pass samples the mask instead of the shadow atlas | `scene_forward_lights_inc.glsl`, `scene_forward_clustered.glsl` |

- Steps 6-7 sit in `_pre_opaque_render`, after the depth pre-pass resolve and after
  `update_light_buffers` assigned slots — both prerequisites, in that order.
- Cost scales with raytraced lights **overlapping a pixel**, not with how many the scene holds
  (`docs/features/rt-shadows.md`). No shadow map is rendered for a raytraced light unless
  `shadow_map_enabled` asked, so a scene can hold far more shadow-casting lights than the atlas has
  room for.

## Code map

| Concern | Files |
| --- | --- |
| Structure build, cache, settings accessors | `servers/rendering/renderer_rd/environment/rt_scene.{h,cpp}` |
| Trace and denoiser dispatch, light record, push constants | `servers/rendering/renderer_rd/effects/rt_shadows.{h,cpp}` |
| Shaders | `servers/rendering/renderer_rd/shaders/effects/rt_shadow_{trace,temporal,atrous}.glsl`, `rt_dequantize.glsl` |
| Slots, light records, demotion, projector recovery | `servers/rendering/renderer_rd/storage_rd/light_storage.{h,cpp}` |
| Caster gather, directional volumes, shadow-map skipping | `servers/rendering/renderer_scene_cull.cpp` |
| Buffer creation bits | `servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp` |
| Per-surface caster eligibility | `servers/rendering/renderer_rd/storage_rd/material_storage.cpp` (`material_shadow_casting_disabled`) |
| Frame integration, buffer allocation, set-1 bindings | `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` |
| Availability virtuals | `servers/rendering/renderer_rd/renderer_scene_render_rd.cpp` |
| Forward shading | `shaders/scene_forward_lights_inc.glsl`, `shaders/forward_clustered/scene_forward_clustered.glsl`, `shaders/light_data_inc.glsl` |
| Fog | `servers/rendering/renderer_rd/environment/fog.cpp`, `shaders/environment/volumetric_fog_process.glsl` |

Availability is three deliberately separate questions:

| Predicate | True when |
| --- | --- |
| `RaytracingScene::is_available()` | setting latched on AND `SUPPORTS_RAY_QUERY` |
| `RendererSceneRenderRD::is_raytracing_scene_available()` | that, plus `_uses_raytraced_shadows()` (a virtual, so Mobile answers no and keeps its maps), plus a valid `RTShadows` |
| `is_raytraced_shadow_mask_available(rb)` | that, plus **exactly one view**, plus (in `RenderForwardClustered`) render buffers holding `RB_SCOPE_FORWARD_CLUSTERED`. Excludes stereo and reflection probes — **same test, different reasons**: multiview is single-layer throughout; a reflection probe has none of the depth and normal data the mask is written from |

## 0. Settings plumbing

- `raytraced_shadows/*` read through **`GLOBAL_GET_CACHED`**: a typed copy keyed on
  `ProjectSettings`' version counter, so a steady-state live read is an integer compare, not a
  string lookup, and the value reaches the renderer next frame.
- `RaytracingScene::update_frame_settings()` is called from `RendererSceneRenderRD::update()`
  **before any viewport draws**, where Godot snapshots its own per-frame rendering settings. It
  makes the three `directional/*` settings one answer for the whole frame.

## 1. Caster gather

`renderer_scene_cull.cpp`, in `_render_scene`, gated on `is_raytracing_scene_available() &&
!p_reflection_probe.is_valid()`.

| Mechanism | Detail |
| --- | --- |
| Query | per raytraced-shadow **candidate** light, push `light_instance->transformed_aabb` into `rt_light_bounds_scratch`; the gather is an **`aabb_query` over `Scenario::INDEXER_GEOMETRY`** run over that scratch. A light's reach bounds everything that can occlude it, so the query is exact and cost ties to what the lights reach, not to level size |
| Dedup | a per-`Instance` pass stamp (`instance->rt_caster_pass`) set at the leaf, since one instance is returned by every light touching it |
| Eligibility | `_casts_into_acceleration_structure()` at the top of the file: `cast_shadows != SHADOW_CASTING_SETTING_OFF`, base type `INSTANCE_MESH` or `INSTANCE_MULTIMESH`, upstream's instance-level `geom->can_cast_shadows`. **`_is_screen_space_shadow_caster()` is literally its negation**, so a caster test added anywhere else silently breaks the contact shadow's complement (`docs/internals/screen-space-shadows.md`) |
| Ordering | **the per-instance directional caster cull runs BEFORE the raytraced decision.** Reordering the two risks double-spending the mask slot budget |
| Enclosed lights | lights a directional volume already encloses are partitioned to the back of the array, not dropped: a swap-partition walk sets `rt_light_query_count` to the non-enclosed prefix, only that prefix is queried, and the pass stamp would discard every duplicate at the leaf anyway — the common case being a sun's swept volume swallowing every lamp in an interior. They stay in the array because the **per-element MultiMesh test below iterates the whole list** and asks a different question; erasing them loses the elements those lamps were the only reason to include |
| Skinning flush | single-mesh casters emit one `RaytracingInstance` each; a valid `mesh_instance` is marked with `mesh_instance_check_for_update()`, and `update_mesh_instances()` flushed **after the gather loop, before `update_raytracing_scene()`** — upstream skins only frustum survivors and raytraced casters are not frustum culled, so without it a character behind the camera casts the pose it last held on screen |
| MultiMesh expansion | **here**, in the culler: one record per element, `transform = instance transform * element transform`, sharing the mesh RID; no multimesh field in the caster record. Rejects: null mesh, `!multimesh_uses_3d_transforms()`. Element count is `visible >= 0 ? MIN(visible, total) : total` — the sign is the test, because the multimesh reports `-1` for "all" and elements past the visible count still hold a stale transform |
| Per-element test | each element is bounded by the shared mesh AABB through its composed transform and tested against **every lamp volume first, unconditionally**; only if nothing reached it is the directional volume consulted, and only when `scatter_casters != Disabled`. `Near Camera` also requires the element bounds' center within `scatter_distance` of the camera. `Disabled` means a raytraced sun casts no shadow from any MultiMesh or GridMap at all |
| `MAX_RT_CASTERS` | 65536, counting caster *instances*, warns once. The test is repeated inside the element loop as well as around the instance loop, or one MultiMesh overruns it alone; that break exits the MultiMesh only, the outer walk continues |
| Cost split | `_rt_report_cpu_cost()` (top of `renderer_scene_cull.cpp`) reports gather and build separately, 120-frame averages with peaks, under `GODOT_RT_DEBUG`. The split is the point: gather grows with world size, build with instance count and movement |

### Per-surface caster eligibility

`surface_mask`, one bit per surface, computed where upstream already walks an instance's per-surface
materials (`renderer_scene_cull.cpp`, the dirty-instance update that appends materials and registers
each as a dependency) — which makes invalidation free: a runtime material swap re-dirties the
instance and the mask is recomputed in the same pass.

| Rule | Detail |
| --- | --- |
| Initial value | `0xFFFFFFFF`, bits only ever cleared. No material means it casts. Surfaces at index 32 and beyond have no bit and always cast. A `material_override` zeroes the whole mask |
| Predicate | `MaterialStorage::material_shadow_casting_disabled()`: true when the shader does not `casts_shadows()` and no `next_pass` rescues it. **Not `!material_casts_shadows()`** — upstream's errs toward yes, because there the instance stays in the shadow render list and each draw decides with the material in hand, whereas a raytraced caster is decided once as it enters the structure, and the terminal case is the common one: a pane of glass. Write the negation and the mask is all ones forever, which looks like the stage working |
| Layering | sits on top of an instance-level answer the gather already tested, which folds in `material_overlay`, `cast_shadows = Off` and the rest. The mask deliberately does not repeat any of it; **re-testing them here is the obvious mistake** |
| Alpha | alpha-scissor and alpha-hash cast, cutout ignored: upstream marks them casting because the depth prepass gives them a depth to write, this predicate agrees, the structure cannot honor a cutout |

## 2. Acceleration structure

`RaytracingScene::update(p_instances)` — `environment/rt_scene.cpp`. One BLAS per mesh surface, one
TLAS per frame. **Every "frame" in this object is an `update()` call**, so two viewports build up to
64 structures each per rendered frame, sweep twice as often, and cut the 60-frame grace period to 30
rendered frames. Each camera also pays a TLAS rebuild: one process-wide object rebuilt from that
camera's own caster list, which differs from the other camera's the moment a directional light
exists, its volume being the camera's own frustum swept toward it. Costs rebuilds, not correctness.

### Cache keying and the freed-buffer guard

`SurfaceKey { RID source; uint32_t surface; }`, hashed `hash_murmur3_one_32(surface,
source.get_id())`.

| Rule | Detail |
| --- | --- |
| What `source` is | the **per-instance skinned vertex buffer** when the caster carries a mesh instance and `mesh_instance_get_vertex_buffer()` returns one; the **mesh RID** otherwise. The culler fills `mesh_instance` only on the single-mesh path, so every static mesh and every MultiMesh element keys on the mesh and one structure serves all of them — which makes MultiMesh expansion cheap: an element contributes a transform and nothing else |
| Never key a static entry on its own vertex buffer | even though that is what it builds from. The mesh RID is valid for every caster the gather hands over and survives clear-and-re-add, so every surface gets a distinct non-null key with or without a buffer — which lets an unbuildable surface be *remembered* ineligible instead of re-attempted every call |
| Why a guard at all | every `PrimitiveMesh` clears and re-adds surface zero on any property change, as does `ArrayMesh.clear_surfaces()`. That frees the vertex buffer and takes the structure with it (`blas_create` registered it as a dependent). A mesh-keyed cache would hand out the freed handle forever after, and **one dead handle fails the whole TLAS build**, not one shadow |
| The guard | on every `BLAS_READY` hit, compare `_get_surface_source_buffer()` against the entry's `source_buffer` and **erase** on mismatch — not skip, since a skipped entry is handed out again next frame. Exact because `RID_Owner` stamps a fresh validator into every RID; a vanished surface answers null, which also fails |
| Key ≠ guarded quantity, deliberately | a mesh-keyed entry's key survives `clear_surfaces()` so the dead entry is still found and erasable, while its buffer does not, so the comparison fails. Key on the buffer instead and the dead entry is never looked up again — it sits there until eviction while a second is built beside it. For a buffer-keyed skinned entry, key and recorded buffer are the same RID so the comparison can never fail; it need not, because that buffer going away takes the key with it and the entry leaves through eviction holding a freed handle — what `_release_blas`'s `acceleration_structure_is_valid()` check is for |
| Not asked per frame | whether the device still holds the structure: that query is `_THREAD_SAFE_METHOD_` and would take the device lock once per surface per frame. It stays on the free and teardown paths. Nothing tells this cache a mesh or instance went away, so the guard and the sweep are the only two ways an entry leaves |

### Entry states, eligibility, dequantize, skinning

| Rule | Detail |
| --- | --- |
| States | `BLAS_UNBUILT` is a fresh record's initial value and is **never stored**: a surface losing the build budget has no entry inserted and is reached again by the next walk. `BLAS_READY` is the only state re-examined. `BLAS_INELIGIBLE` is permanent for the life of the key — the used-this-frame stamp is refreshed before the state is read and the buffer comparison is scoped to ready entries, so an ineligible surface neither re-tests nor ages out. A device-call failure (allocate, then build) is cached as permanently as a non-triangle primitive |
| Rejections | `_build_blas_geometry()` rejects `primitive != PRIMITIVE_TRIANGLES`, zero vertices, `ARRAY_FLAG_USE_2D_VERTICES`, `ARRAY_FLAG_USES_EMPTY_VERTEX_ARRAY`, no vertex buffer, fewer than 3 vertices with no index buffer |
| Index buffer | LOD 0 only, used when `index_count >= 3` — a LOD silhouette does not match the shadow the raster path would cast; `ArrayMesh.shadow_mesh` is not consulted either |
| Build flags | `PREFER_FAST_BUILD` skinned (rebuilt every pose change), `PREFER_FAST_TRACE` static |
| Failure message | `blas_create` failure prints once and blames the restart-required setting, because that is almost always it — the buffers were uploaded before `enabled` was on |

Godot's default compressed positions (`ARRAY_FLAG_COMPRESS_ATTRIBUTES`) are `R16G16B16A16_UNORM`
normalized into the surface AABB, not a legal acceleration structure format. `rt_dequantize.glsl`
exists only to expand them to a tightly packed `float32x3` buffer:

```
vec2 xy = unpackUnorm2x16(src[base]);  vec2 zw = unpackUnorm2x16(src[base + 1]);
position = vec3(xy.x, xy.y, zw.x) * aabb_size + aabb_position;
```

| Rule | Detail |
| --- | --- |
| Dispatch | `local_size_x = 64` over `vertex_count`, source stride passed in **words** (`source_stride / 4`; the source stride is a fixed `sizeof(uint16_t) * 4`) |
| Uncompressed | zero-copy: the surface's own vertex buffer, offset 0, stride 12 — depends on positions being a contiguous `float32x3` block at offset 0 ahead of the attributes |
| Ownership | the expanded buffer belongs to the **entry, not the build**; the entry also holds `source_buffer`, `source_stride`, `source_aabb`, so a skinned refresh re-expands the new pose into the *same* allocation — the geometry description was fixed at creation and cannot be re-pointed. `_release_blas` frees it on every path that drops an entry, ineligible included, since it is allocated before the build is tried |
| Creation bits | see **Two invariants**, above |
| `r_entry.skinned` | true only when the per-instance buffer differs from the mesh's own, so a mesh instance with no bones and no blend shapes falls back to the shared mesh BLAS |
| Staleness | `mesh_instance_get_last_change()`; differing from `skin_version` on a cache hit, `_refresh_skinned_blas()` re-dequantizes (if compressed), calls `blas_build()` in place and sets `blas_changed_this_frame`. No refit entry point exists on `RenderingDevice`; a rebuild reuses the existing scratch allocation |
| Importer behavior | Godot's importers already disable vertex compression for skinned and morph-target meshes, so skinned geometry usually arrives in the format the structure wants |
| In-place mesh updates | only skinned surfaces carry a version check, so `surface_update_vertex_region()` and `ImmediateMesh` rewrites trace the geometry first built from. Replacing the surface outright trips the freed-buffer guard and is correct |

### Buffer creation bits, upstream side

`MeshStorage::_raytracing_buffers_required()` = latched `enabled` AND `SUPPORTS_RAY_QUERY` AND
`SUPPORTS_BUFFER_DEVICE_ADDRESS`. Ray query is tested even though the predicate only decides usage
bits, because D3D12's `has_feature()` has no `SUPPORTS_RAY_QUERY` case and returns false — without
it every mesh buffer got AS usage nothing could consume.

| Allocation | Bits | Why |
| --- | --- | --- |
| `mesh_add_surface` — vertex, attribute, skin, index buffers | `DEVICE_ADDRESS \| ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY \| AS_STORAGE`, OR-ed in whole | vertex and index are build input; the other two ride the same word. Nothing validates usage against a build's needs, so unused usage is cheaper than discovering which ones were needed |
| its LOD index buffers | none | only LOD 0 is ever traced |
| `_mesh_instance_add_surface_buffer` — the skeleton/blend-shape target | device address and AS build input added to the storage bit upstream already sets | a skinned caster builds from *this* buffer, not the rest pose. Widen only the first site and every static caster works while every skinned one fails at `blas_create` — printing the "uploaded before the setting was on" message, which reads as a stale setting that restarting does not fix. The helper is called again for the motion-vector second buffer, so both of the pair come through it |

`AS_STORAGE` on the vertex buffer is the bit upstream would not have set — it grants storage usage
only to a surface with skin data, blend shapes or `ARRAY_FLAG_USE_STORAGE_BUFFER` — but the
dequantize pass binds the mesh's own vertex buffer as storage, static casters included.

### Budgets and eviction

| Constant | Value | Why |
| --- | --- | --- |
| `MAX_BLAS_BUILDS_PER_FRAME` | 64 | a level streaming in can bring hundreds of surfaces into range at once |
| `MAX_BLAS_BUILD_TRIANGLES_PER_FRAME` | `1 << 20` | 64 small surfaces and 64 large ones are not the same frame |
| `FRAMES_UNTIL_EVICTION` | 60 | skinned structures are per instance; without eviction every character that ever existed keeps one alive |
| `FRAMES_BETWEEN_SWEEPS` | 8 | a sweep walks the whole cache; an entry is ineligible for 60 frames anyway, so every eighth costs it at most seven more |
| minimum TLAS capacity | 64, doubling | capacity is fixed at creation, so exceeding it means recreating |
| light buffer capacity | 16, doubling | same reason |

| Rule | Why |
| --- | --- |
| Gates **first-time builds only**, checked *after* the cache lookup returned | a skinned surface whose pose moved refreshes regardless of the frame's new-build load — a deferred pose is a visibly wrong shadow where a deferred first build is only a late one |
| A surface that loses the budget contributes **no TLAS entry at all** | the list is shorter, and since instance count seeds the contents hash that alone reads as a change |
| A build slot is spent **before** the attempt, ineligible surfaces included; triangles are charged only on success, saturating subtract | a mesh larger than the whole triangle budget builds in one frame and zeroes the remainder. A predictive "would this fit" test would defer such a mesh forever |

### TLAS build and the contents hash

`contents_hash = hash_murmur3_one_64(instance_count)`, then per instance a hash of **exactly three
fields in this order** — BLAS handle id, the 8-bit instance mask, the full transform (nine basis
components row-major, then three origin) — through `hash_fmix32()` and **added**, not chained.

| Rule | Detail |
| --- | --- |
| Summed, not chained | a ray query reads nothing depending on array position, so two orderings describe the same scene and the spatial index's iteration order must not read as a change. `hash_fmix32` before the add, or the sum degenerates into additive collisions |
| Field choice | the mask is in it as the only thing catching a `layers` change with nothing moving. The array index is out because it defeats order independence and nothing in the trace reads it; geometry flags and the hit-SBT range are out as the same constant for every instance |
| Rebuild test | `rebuild = !tlas_built \|\| blas_changed_this_frame \|\| contents_hash != tlas_contents_hash`. Any BLAS built or refreshed this frame invalidates the bounds the TLAS cached for it, hence the flag. A freshly created or resized TLAS clears `tlas_built`, describing nothing yet |
| Two flags | `tlas_built` (a successful build exists, outliving a frame) and `tlas_valid` (this frame may trace against it) are deliberately distinct |
| Per instance | `transform`, `id` = its index, `mask = RTShadows::fold_layer_mask(layer_mask)`, `flags = ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT` (always — `shadow_reverse_cull_face` is per light while the TLAS is per scenario, so flip-facing cannot be honored at all), `hit_sbt_range = HitShaderBindingTableRange(int64_t(1) << 32)`, offset 0 count 1, because `tlas_build()` rejects a zero range even with no ray pipeline in use |
| **The two 65,536 ceilings** | `MAX_RT_CASTERS` (65536) bounds the gather, counts caster *instances*, warns once. A **second 65536 lives here**, a bare literal tested before each TLAS instance push and **silent** when hit — it counts caster *surfaces*, so any scene of multi-surface meshes reaches this one first, with nothing printed |
| `fold_layer_mask` | `effects/rt_shadows.h`, the single owner of the 32→8 fold: OR the four bytes, promote a zero fold to `0xFF`. Both producers must come through it — the light side (`LightStorage`) and the instance side (`RaytracingScene`) — or a caster silently stops answering a light with nothing reporting why |

## 3. Light slots

`LightStorage::update_light_buffers`, `light_storage.{h,cpp}`. A slot is an index into `rt_lights`,
the storage buffer the trace walks.

### Who is marked raytraced

Decided **once**, in the culler, before anything acts on it, because the atlas layout, the light
buffer and the shadow loops visit lights in three different orders and must agree. Split in three:

| Question | Test |
| --- | --- |
| **Candidate** (`_light_is_raytraced_shadow_candidate`) | the light only: shadows enabled, type omni or spot (area lights keep their maps), or directional, which additionally needs `is_raytraced_directional_available()` (the directional setting AND a traceable scene). Suns are gated the way the culler gates gathering their casters, so a sun cannot give up its map with nothing gathered for it |
| **Can use** (`_light_uses_raytraced_shadows`) | adds that this renderer samples the mask and `has_traceable_scene()` holds. Yes without either leaves the light unshadowed rather than falling back |
| **Does this pass have a mask** | the caller's: not a reflection probe, and `is_raytraced_shadow_mask_available()` for these render buffers |

The culler enforces the **255-light ceiling** itself, iterating `scenario->directional_lights` first
(directional lights are never in `scene_cull_result.lights` — an empty AABB means the bounds-indexed
cull never sees them), then the culled positional list, counting as it goes. Load-bearing twice: it
stops a light being skipped by the culler and then denied a channel, and it lets the slot allocator
evict the least-recently-seen slot knowing the victim cannot be a light in this pass. The fork's
earlier split — culler skipping on light eligibility, renderer granting channels only when it would
produce a mask — meant that under multiview every omni and spot was skipped and then denied a
channel, rendering with **no shadow at all**.

### Sticky allocation

| Mechanism | Detail |
| --- | --- |
| `_rt_slot_acquire` | a light already holding a slot refreshes `rt_slot_frame` and keeps it. Free list first, then a new slot while `rt_slot_owner.size() < MAX_RT_LIGHTS` (255, so indices stop at 254 and 255 stays the `SLOT_NONE` sentinel), then evict the oldest `rt_slot_frame` |
| `_rt_slot_sweep` | once per frame number, releasing any slot unseen for more than `RT_SLOT_GRACE_FRAMES` (4). With every slot free it clears both vectors so the buffer restarts from zero rather than staying at the high-water mark |
| Stickiness is a denoiser requirement, not an optimization | both denoiser stages compare the whole four-index vector for equality, so a light changing index invalidates the entire screen's history; assigning in light-buffer order (sorted by distance to camera) re-rolls every index as the camera moves |
| The buffer is **sparse** | a slot may belong to a light outside this pass. `_rt_light_store` zero-fills gaps and the trace skips a row by `radius <= 0`, which is why a live light must keep a positive radius whatever its type |
| Debug counter | `rt_slots_assigned_this_frame`; steady state is zero |
| A slot is granted only when the pass will genuinely trace | `rt_shadows_available = p_use_raytraced_shadows && p_using_shadows`. A slot with nothing behind it makes the forward shader skip the atlas *and* read "fully lit" from the mask, strictly worse than not enabling the feature |
| `shadow_opacity > 0.001` before spending a slot | both fills require it (authoring rule: `docs/features/rt-shadows.md`). Load-bearing for the sun: `fade_from`/`fade_to` are written only inside that guard while the record reads both, and `directional_lights` is `memnew_arr` over a struct with no initializers and is not zeroed — so without the test a zero-opacity sun reads last frame's values or indeterminate memory, and spends a slot plus a full set of rays on a result the shader discards |

## 4. The trace

`rt_shadow_trace.glsl`, one compute dispatch over the internal size. **`#version 460`** — the only
shader in the tree that is not 450, because glslang gates `rayQueryEXT` and every `rayQuery*EXT`
builtin on 460. `local_size` is `TILE_SIZE`x`TILE_SIZE`x1 = 8x8 = 64 threads. Set 0 bindings: 0
TLAS, 1 depth, 2 `dest_visibility` (image), 3 `dest_index` (uimage), 4 `dest_hit_distance` (image),
5 the `RTLights` storage buffer, 6 normal/roughness.

| Input | Detail |
| --- | --- |
| `normal_roughness` | not produced by default, which is why `depth_pass_mode` is forced whenever `is_raytracing_scene_available()` — and the resolve is forced too |
| World position | reconstructed with `scene_data->get_cam_projection()` / `get_cam_transform()`, which carry the reverse-Z + Y-flip correction and the jitter the depth buffer was written with; the raw members collapse every pixel to ~0.1 units from the camera |
| Pre-pass normal | rotated to world by a **quaternion** in the push constant — a normal crossed from neighboring depth taps fringes every silhouette, and the camera basis will not fit in 128 bytes beside the inverse view-projection |

### Tile stage

Two claim passes, both behind `tile_has_surface`, with a `barrier()` between them.

| Step | Detail |
| --- | --- |
| Tile bounds | each thread reconstructs its world position and the 64 of them reduce a world-space bounding box in shared memory with `atomicMin`/`atomicMax`. Shared-memory atomics are integer only, so a float is mapped by `order_preserving_bits()`: invert all 32 bits when the sign bit is set, otherwise set the sign bit; `order_preserving_float()` undoes it |
| Who contributes | only threads with a surface — in bounds **and** reverse-Z depth `> 0`, excluding sky and the ragged edge past the screen. Min initialized to `0xFFFFFFFF`, max to `0`, which that encoding places above and below every real coordinate, so `min[0] <= max[0]` is the entire "this tile has geometry" test. A pure-sky tile claims nothing |
| Directional first, in a pass of its own, with **no geometric test** | a sun reaches every surface, and its only range question — is the receiver inside the view *depth* range casters were gathered for — is per pixel; a sphere around the camera answers a different question, radial distance always being at least the view depth, so it rejects tiles the per-pixel check accepts and the frame's corners lose the sun before its fade begins. The `barrier()` makes the ordering real — without it a fast thread's lamp takes a low slot ahead of a slow thread's sun. That pass cannot fill the list alone: upstream caps a pass at `MAX_DIRECTIONAL_LIGHTS` (8), which lives on the **base scene-render interface** — where the scene culler stops gathering suns, and what sizes the directional light uniform buffer |
| Lamps | `closest = clamp(light.position, bounds_min, bounds_max)`, admitted when `dot(closest - position, closest - position) <= radius * radius`. **There is no cone test** — narrowing a spot at tile level is the wrong way to be wrong: an extra candidate costs one rejected distance test, a missing one costs a shadow |
| Overflow mechanism | both passes claim with `atomicAdd` on `tile_light_count` and store only where the returned slot is below `MAX_TILE_LIGHTS` (128); the counter keeps climbing and the per-pixel loop reads `min(count, MAX_TILE_LIGHTS)`. Which lights lose depends on the order the atomics resolved, so it can differ between adjacent tiles. Ceilings and consequences: `docs/features/rt-shadows.md` |
| Walk | each thread walks every 64th row of the light buffer, twice. It is handed the **whole sparse slot table**, sized to the highest live slot and capped at `MAX_RT_LIGHTS`, nothing narrowing it per view or per tile |

### Per-pixel stage

- `if (!in_bounds) return;` sits **after the last tile barrier**, not at the top: every invocation
  must reach every `barrier()`.
- Normal: `texelFetch(source_normal_roughness).xyz * 2 - 1`; length under `1e-6` means nothing wrote
  that pixel's normal and the fallback faces the viewer, the only assumption that cannot push a ray
  origin inside the surface. Otherwise rotated to world by the quaternion.
- Four discards, in order: a directional light whose `view_depth > radius`; a lamp beyond `radius`
  or nearer than `1e-4`; a spot where `dot(-L, axis) < cos_spot_angle` (outside the cone it
  contributes nothing, so ordinary attenuation handles it); anything scoring zero, which after the
  range tests can only mean the surface faces away.

```
max(energy, 1e-4) * falloff^2 * max(dot(N, L), 0)
falloff = 1.0 for directional; max(1 - distance / max(radius, 1e-4), 0) for a lamp
```

| Term | Why |
| --- | --- |
| `N` | the pre-pass normal in world space, not the normal-mapped one |
| `falloff^2` | a stand-in for irradiance |
| `dot(N, L)` | what stops the lamps *behind* a surface — most of them, in a room lit from every side — taking channels from those in front, a light below the horizon being already fully shadowed |
| `max(energy, 1e-4)` | floored so a zero-energy light still outranks an empty channel, which is why fading energy to zero releases neither channel nor rays (`docs/features/rt-shadows.md`) |
| Directional does not attenuate | it scores flat and outranks a lamp on any surface the lamp is not close to — right outdoors, and losing the channel at the far end of its range costs nothing because the shadow has faded by then |
| **No color or luminance term** | the record carries no color: a channel is worth the same whatever the light's hue |
| Insertion | strict `>` into the four-entry array (`LIGHTS_PER_PIXEL` = 4, one RGBA8 mask texel per pixel) held in descending score, the displaced entry cascading down. Strict rather than `>=` so a tie leaves the array alone; the tie falls to whichever light the tile's candidate list reached first, and since that list is shared memory walked in one order, every pixel in the tile settles it identically |
| **Then bubble-sorted by ascending light index** | the index array only, scores never read again. Not cosmetic: both denoiser stages compare the *entire* four-index vector for equality, and ranking order is not canonical (it turns on distance and normal, changing across a surface and between frames), so an equality test over it rejects nearly every tap and the result collapses to the center pixel with its single ray of noise intact. Sorting also packs live channels low for free, `SLOT_NONE` being 255 and real slots stopping at 254 |

### Sampling and the ray loop

Noise is **baked into the shader**: a 32x32 void-and-cluster (Ulichney) blue noise mask as `const
uint BLUE_NOISE[256]`, four 8-bit values per word. No texture, no binding, no generation step, so it
cannot be lost in a port.

```
index = (pos.y & 31) * 32 + (pos.x & 31)
value = float((BLUE_NOISE[index >> 2] >> ((index & 3) * 8)) & 0xFF) / 255.0
```

| Constant | Why |
| --- | --- |
| Blue noise, not white | its energy sits at high spatial frequencies, which the spatial filter downstream removes well, where low-frequency error it hardly removes at all. White noise here does not resolve at one ray |
| Two sampling dimensions | the same function read at the pixel and at the pixel offset by `(13, 7)` |
| Time is an **additive R2 step** | `fract(spatial + float(frame) * vec2(0.7548776662, 0.5698402910))`. Not a shift of the sampling position — shifting re-rolls the pattern every frame and can revisit nearly the same point, where an irrational increment spreads a pixel's own sequence evenly, and that sequence is exactly what the temporal accumulation averages. R2's pair rather than two chosen irrationals, because R2 stays evenly spread *jointly*. First output is the disk rotation (x 2pi), second the radial jitter. Not the temporal store dither, which is interleaved gradient noise advanced by `frame * 0.61803399` |
| Vogel disk, **radius jittered inside each stratum** | `r = sqrt((index + radial_jitter) / count)`, `theta = index * 2.39996323 + phi`. At the shipped one sample a fixed 0.5 pins the ray at `sqrt(0.5)` of the emitter radius every frame, and with only the angle moving the temporal average converges on the shadow of a **ring at 0.707r** rather than of the disk (`docs/HISTORY.md`) |

Per selected light:

| Rule | Detail |
| --- | --- |
| `sample_count` | `light.size > 0 ? max(requested_samples, 1) : 1`. A point emitter casts one deterministic shadow |
| `ray_flags` | `light.size > 0 ? params.ray_flags : (params.ray_flags \| gl_RayFlagsTerminateOnFirstHitEXT)`. **Per light, not per dispatch**: both penumbra formulas multiply by `light.size`, so at zero the closest-occluder distance is discarded whatever it cost to find, and one hard lamp should not spend the others' traversal budget. `accurate_occluder_distance` off ORs the flag in for every light; in the push constant rather than a define so the trade costs no second pipeline |
| Origin offset | `world_position + normal * light.normal_bias * (1.0 + distance_to_light * 0.01)` — scaled by distance because the reconstructed position is least precise far away. For the sun that distance is the distance from the camera, there being no light to be far from |
| Backfacing | `dot(normal, light_dir) <= 0` writes visibility 0 with no ray: the forward pass shades with the normal-mapped normal, which can still face the light, so the mask has to say so rather than rely on N·L |
| **Ray interval clamp** | `ray_tmin = min(light.bias, ray_length * 0.5)`, ray initialized with `tmax = ray_length - ray_tmin`. Both ends are pulled in by the bias, so a short ray can invert the interval, and `GL_EXT_ray_query` requires `tMin <= tMax` while saying nothing about what happens otherwise — undefined rather than clamped, on two vendors. Reachable with no slider touched: `light.bias` is `shadow_bias * 0.05`, so the interval inverts below 1 cm from a default `SpotLight3D` and below 3 mm from a default `OmniLight3D`, and again from above because `max_ray_distance` shortens `ray_length` just before. Clamp the **near** end — raising `tMax` to meet `tMin` gives a degenerate interval that finds nothing while still paying for traversal setup |
| **Every sample is traced** | no early out on a pair of probe rays that agree; no pair can answer for a disk (`docs/HISTORY.md` — the shadow got *sharper* as the sample count rose) |
| Flag values spelled out in C++ | shader constants with no shared header: `gl_RayFlagsOpaqueEXT` = 1, `gl_RayFlagsTerminateOnFirstHitEXT` = 4 |
| `while (rayQueryProceedEXT(...)) {}` | every candidate is opaque, so this is the form the specification asks for rather than extra work |

Outputs per channel:

```
visibility = 1 - occluded / traced,  then mix(visibility, 1.0, range_fade)  // directional only
blocker_to_light = max(distance_to_light - mean_blocker, 1e-4)              // lamp only
penumbra_world   = is_directional ? mean_blocker * light.size
                                  : light.size * (mean_blocker / blocker_to_light)
penumbra_pixels  = penumbra_world * focal_pixels / view_distance
hit_distance     = clamp(penumbra_pixels / MAX_PENUMBRA_PIXELS, 0, 1)
```

- `MAX_PENUMBRA_PIXELS` is **32.0**, the widest penumbra the 8-bit hit-distance channel can
  describe, in *internal* pixels (`docs/internals/dlss.md`), and must match in the trace and the
  a-trous. `focal_pixels = abs(screen.y * 0.5 * camera_projection.columns[1][1])` — pixels a
  one-meter object covers one meter from the camera, so the denoiser is told a width in the unit its
  kernel steps in. The lamp formula is similar triangles; the directional one is the same in the
  limit, `light.size` already holding a tangent. Penumbra width is what makes a raytraced shadow
  harden at contact, and the denoiser can only preserve it if told how wide to filter.
- **Every pixel on screen writes all three images unconditionally** — surface or not, light or not —
  with fully lit visibility, zero hit distance, four `SLOT_NONE` channels. Nothing clears those
  three on a frame the trace runs: they are cleared once at creation, and the white fallback clear
  covers only frames the trace does not run at all. Both denoiser stages early-out on `depth <= 0 ||
  index == all SLOT_NONE`, and the forward pass matches its light's slot against that same index
  texel — a lit surface no raytraced light reached is exactly the pixel where only the index half
  can fire, so a texel left unwritten there reads as a real light assignment carrying last frame's
  visibility.

### The sqrt encode

Visibility is stored as its square root and squared on read (`VIS_ENCODE`/`VIS_DECODE`, defined
identically in all three shaders and in `rt_shadow_lookup()`). Eight bits spread evenly over [0,1]
put the same absolute step everywhere, but a shadow's detail is all at the dark end, where that step
is a large *relative* error and bands across a wide penumbra. The root spends half the code range
below a quarter visibility.

**Filtering still happens in linear visibility.** Every read decodes, every write encodes: averaging
roots and squaring darkens every penumbra by Jensen's inequality (`docs/HISTORY.md`). NVIDIA's SIGMA
filters *in* sqrt space on purpose; this system does not. One missed decode lightens every umbra
almost invisibly unless measured.

## 5. The denoiser

Keeps its own history rather than leaning on the image's temporal antialiasing, because with SMAA or
no AA nothing downstream would average the shadow signal over time. `RTShadows::render()` sequences
it.

| Rule | Detail |
| --- | --- |
| Sequence | one temporal pass writing ping-pong **A**, then `spatial_passes` a-trous iterations with step `1 << i` — at the default of three that is 1, 2, 4, so the outermost tap of the last pass sits eight pixels out |
| Ping-pong | each iteration reads one buffer and writes the other, except the last, which writes `output_mask` itself, so the forward pass reads one texture whether the denoiser ran or not |
| History write | **only the first iteration writes history, and what it writes is its own *input*** — the temporal accumulation — never its output |
| Skipped entirely | mask = raw trace, if any of its pipelines or textures is missing. The trace's own targets are required and checked separately, because a device out of memory partway through would otherwise report success and leave the mask at the zero it was cleared to, i.e. fully shadowed |

### The four history textures

| Texture | Format | Written by | Read by |
| --- | --- | --- | --- |
| history visibility | `R8G8B8A8_UNORM` | first a-trous iteration | temporal, next frame |
| history index | `R8G8B8A8_UINT` | first a-trous iteration | temporal, next frame |
| history meta | `R16G16_SFLOAT` | first a-trous iteration | temporal, next frame |
| history length | `R8_UNORM` | temporal | a-trous, **same** frame |

Two look like one quantity stored twice and are not. **Length** carries the accumulation count
sideways within one frame, temporal to a-trous, which needs it to widen a freshly disoccluded
pixel's filter. **Meta** carries that count plus the depth forward to the next frame: R a raw linear
view distance, G the count. Both store the count **normalized to `temporal_frames`** (the length
texture is eight bits); meta stores the normalized value it was handed rather than re-deriving one,
and **the temporal pass is the only place that multiplies back up by the window.** Getting that
asymmetry wrong pins the blend factor at 1 and throws the history away every frame — which reads as
a denoiser that does not work rather than as a bug with a location.

### Temporal pass

`rt_shadow_temporal.glsl`. Bindings: 0 source visibility (the trace's mask), 1 depth, 3 history
visibility, 4 history meta, 5 `dest_visibility` = denoise A, 6 `dest_history_length`, 7 source
index, 8 history index.

| Mechanism | Detail |
| --- | --- |
| Shared early-out | `depth <= 0 \|\| current_index == uvec4(SLOT_NONE)` passes the value through and writes zero history length. Depth zero is sky under reverse-Z; all-`SLOT_NONE` means no raytraced light reaches the pixel. The sky half is a must-not — filtering there pulls neighboring geometry into the sky, and a history left behind bleeds into whatever moves in front of it later. The unreached half is free, and outdoors it is most of the screen. **Do not write this test as "the mask is fully lit in all four channels":** a pixel a light does reach that happens to read fully lit is one noisy sample in a region that still needs filtering, and skipping it leaves speckle |
| Reprojection is **by camera, not motion vectors** | the velocity buffer is written by the opaque color pass, which runs *after* the mask is needed, so it is a frame stale; under MSAA it is only resolved when TAA or an upscaler asks. Camera reprojection is exact for static geometry, and geometry that moved on its own is rejected by the surface test rather than smeared. Matrix is `prev_view_projection * inv_view_projection`, previous projection rebuilt through the same depth correction and `prev_taa_jitter` the current one gets |
| `previous_clip.w` | the previous clip position scaled by the reciprocal of this pixel's view depth — **a ratio, not a distance**; `expected_depth = previous_clip.w * linear_view_depth(depth)` scales it back. Compare against a tolerance in meters instead and every tap is rejected every frame, silently: the accumulation never builds and the only sign is a spatial filter that never narrows |

Surface test, per bilinear tap, in this order:

1. reject if off screen;
2. reject if the **previous** frame's index texel there is not equal in all four channels to
   **this** frame's index at the center;
3. reject on a **relative** depth test: `abs(stored_depth - expected_depth) / max(expected_depth,
   0.001) >= depth_tolerance`, `depth_tolerance` = **0.02**, a fork constant pushed from C++ with no
   setting behind it. Relative rather than metric so distant geometry — where depth precision and
   reprojection error are both worse — is not rejected purely for being far away.

Survivors take the ordinary bilinear weights and the sum is divided by the weight that survived, so
partial rejection still yields an unbiased history. Nothing survives = disocclusion: history length
stays zero, alpha comes out 1, the pixel takes this frame's raw trace. Filtering by hand rather than
by the sampler is mandatory — channel assignments are per pixel and cannot be interpolated.

### The clamp

Authoritative account: the comment at the moment gather in `rt_shadow_temporal.glsl`. The surface
test only asks whether the same surface is still here; it cannot see a shadow move *across* a
surface. The floor under a moving blocker reprojects perfectly, passes every test, and hands back a
shadow that is no longer there — with a 32-frame window, trailing for half a second. So measure what
this frame sees nearby and clamp the history into that range, over a `moment_radius` neighborhood,
skipping taps whose index differs from the center's:

```
moment_radius = (sample_count < 4.0 && clamp_sigma <= 1.0) ? 2 : 1      // 5x5 or 3x3
trials        = max(taps * sample_count, 1)
corrected     = (moment1 * trials + 2) / (trials + 4)                   // 2 pseudo-counts
var_mean      = corrected * (1 - corrected) / (trials + 4)              // uncertainty in the mean
var_sampling  = corrected * (1 - corrected) / max(sample_count, 1)      // per-tap binomial noise
var_measured  = max(moment2 - moment1^2, 0)
var_spatial   = max(var_measured - var_sampling, 0)
sigma         = sqrt(var_spatial + var_mean)
clamped       = clamp(history, moment1 - sigma*clamp_sigma, moment1 + sigma*clamp_sigma)
```

| Term | Why |
| --- | --- |
| The decomposition | the neighborhood's spread is part signal (the penumbra really does vary across these taps) and part binomial noise (each tap is a count of blocked rays out of `sample_count`). Charging the noise to the signal — the raw spread — makes two sigma wider than the valid range at one ray per light, so the clamp never fires at all. Binomial noise is predictable, so it is subtracted rather than out-sampled. Derivation and the measured 3x3/5x5 table: `docs/HISTORY.md` |
| The `var_mean` floor | stops the window collapsing to zero where a handful of binary taps agree; without it the history is pinned to a binary answer and the tails of every penumbra disappear |
| The gather-width gate | a real trade taken only where it is already paid. The clamp is **centered** on `moment1`, so once the window is tight the accumulated value essentially *is* that mean, noise and bias both; 25 binary taps make a quieter mean than 9 but also straddle a narrow penumbra's shoulder. At the shipped `clamp_sigma` 2.0 the pixel is not pinned hard to the mean, so widening would buy quiet at a shoulder cost nothing asked for; at 1.0 and below it *is* pinned, the 3x3 already pays most of that cost, and the quieter mean makes the trade affordable |
| **The choice cannot be made per pixel** | at one ray a shoulder and a flat penumbra are the same measurement — half the taps deterministically 0 and half deterministically 1 has exactly the variance of every tap being an independent p = 0.5 draw, so the decomposition subtracts all of it and reports no structure to gate on |

`lag` and the window shortening:

```
lag            = clamp(max over channels of abs(clamped - history), 0, 1)   // clamp block
history_length = history_length * (1 - lag)                                 // clamp block
history_length = history_length > 0 ? min(history_length + 1, max_history) : 1
alpha          = max(1 / history_length, lag * lag_response)
accumulated    = mix(history, current, alpha)
store to dest_history_length: history_length / max(max_history, 1)          // normalized
```

- How far the clamp had to move the history measures how wrong it was, and a history that wrong has
  no business keeping a long window. The worst of the four channels is taken deliberately: they
  share one window and being late is worse than being brief.
- **Shortening alone is far too gentle**, hence `lag_response` — the shader's worked example: at one
  ray in a covered umbra the window is the binomial floor alone and a fully lit history is pulled
  only to its near edge, a lag around 0.8, leaving about six frames and an alpha of 0.135
  (arithmetic). The pixel keeps six sevenths of a value just established as wrong by four fifths,
  and with the history now inside the window the clamp never fires again: the rest decays as
  `6/(6+n)`, still visibly moving a third of a second later.
- Letting the clamp's own measure set the blend spends it instead of a fifth of it, floored at the
  clamp's window edge so it can never weight the new sample more heavily than this frame's
  neighborhood supports. Both are inert wherever the clamp did not fire, i.e. every pixel in the
  steady state; `lag_response = 0` restores the previous behavior exactly. Tuning:
  `docs/features/rt-shadows.md`.

### The store dither

```
dither = fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))))    // IGN
dither = fract(dither + float(frame) * 0.61803399) - 0.5
store  = VIS_ENCODE(accumulated) + dither / 255.0
```

An 8-bit accumulator that re-reads its own rounded output must round stochastically. Once the step
it wants is under half a quantization level it stops moving, and not symmetrically: in the lit end
of a penumbra at one ray the occasional blocked ray is a step down large enough to land while the
many lit rays each ask for a step up too small to, so the value ratchets darker and the soft edge
creeps outward — exactly the softening the traced answer exists to avoid. Costs one hash and no
memory.

### A-trous

`rt_shadow_atrous.glsl`. Bindings: 0 source visibility, 1 raw hit distance, 2 depth, 3
normal/roughness, 4 history length, 5 `dest_visibility`, 6/7/9 the three forward-carried history
images, 8 source index (the **trace's** index, constant through the denoiser). Reach, per channel,
in pixels:

```
penumbra_pixels = MAX_PENUMBRA_PIXELS * (max hit_distance over the 3x3 index-matching taps)
has_penumbra    = step(1e-4, penumbra_pixels)
history_boost   = 1 - clamp(history_length, 0, 1)
fill_pixels     = history_boost * min(MAX_PENUMBRA_PIXELS, penumbra_pixels * HISTORY_FILL_SCALE)
floor_pixels    = max(min_filter_pixels, fill_pixels)
reach_pixels    = max(penumbra_pixels, has_penumbra * floor_pixels)
```

| Term | Why |
| --- | --- |
| The **neighborhood max** is required | at one sample a ray that misses reports *no* penumbra, having had no blocker to measure to, so sizing from the center alone smooths the shadowed half of a penumbra and leaves the lit half speckled. At a real contact edge every neighbor also reports zero, so it costs nothing there |
| Both floors apply only where a penumbra was measured (`has_penumbra`) | a pixel a light reaches but no ray hit has no blocker to measure to; floor it anyway and it is dragged into the tap loop at up to the eight pixels the setting allows for 31 frames — what every camera turn would do to the newly revealed screen edge. Restricted correctly its reach is zero and the early-out skips it; in a sunlit frame that is most of the screen |
| `HISTORY_FILL_SCALE` = 4.0 | full reach for any penumbra of eight pixels or more, folded away entirely at a contact edge. The decay spreads over the whole accumulation window rather than a few frames, because at one sample the noise it hides outlives the first handful of frames |
| **Early-out** `if (all(lessThanEqual(reach_pixels, vec4(step_size))))` | a tap's weight is `clamp(1 - tap_pixels / reach_pixels)` and every tap lands at least one kernel step out, so a channel whose reach does not survive one step contributes nothing from anywhere; where that holds for all four, the loop is 24 taps fetching four textures each that provably resolve to the center value. The exit **still writes all three forward-carried history textures**, with the pixel's real view distance and history length — not the shared early-out's zeroed meta, these being real surfaces the temporal pass reprojects onto. Two cases land here: a pixel a light reaches but no ray hit, and a contact shadow at the `min_filter_pixels` floor, whose default 1.0 is exactly the first pass's step. Raising it buys those pixels filtering and fringes every contact edge in the same move; ladder in `docs/features/rt-shadows.md` |

Tap weight, 5x5 stepped by `step_size`. A tap is dropped outright, before any of this, if its depth
is zero or its index differs from the center's. The center tap takes `KERNEL[0] * KERNEL[0]` and
none of the other three terms.

| Term | Value |
| --- | --- |
| kernel | `KERNEL[abs(x)] * KERNEL[abs(y)]`, `KERNEL = {0.375, 0.25, 0.0625}` — the 5-tap B3 spline row |
| depth | `exp(-depth_error / depth_sigma)`, `depth_error = abs(tap_depth - center_depth) / max(center_depth, 1e-6)`, `depth_sigma = 0.02` |
| normal | `pow(max(dot(center_normal, tap_normal), 0), normal_sigma)`, `normal_sigma = 64.0` |
| reach, per channel | `clamp(1 - length(vec2(x, y)) * step_size / reach_pixels, 0, 1)` |

- Three terms are shared by all four channels because they describe the surface; only reach is per
  channel, describing each light's penumbra. `depth_sigma` and `normal_sigma` are fork constants
  pushed from C++ with no project setting behind them, because the reach term is what the look is
  tuned with.
- The depth term runs on **raw reverse-Z depth buffer values, no plane fit, no linearization**:
  reverse-Z is proportional to the reciprocal of view distance, so a relative depth difference is
  already a relative distance difference for every projection of this family and no tap is
  reconstructed. Orientation is the separate normal power beside it. **Do not swap this for the
  occlusion denoise's test or vice versa** — that one reconstructs each tap and weights it by
  distance from the shaded point's plane, because a relative depth difference has no notion of
  orientation and on a plane seen at a glancing angle would discard neighbors lying on the very
  plane being shaded (`docs/internals/ambient-occlusion.md`). Normals here are compared only against
  the center's, so the pre-pass encoding (`xyz * 2 - 1`) is used directly and never needs the
  trace's world-space rotation.
- **There is no variance term and no variance buffer.** The filter's width comes from the traced
  occluder distance, a measurement of the penumbra rather than an estimate of the noise, so nothing
  corresponds to SVGF's variance channel. The one spread this system measures — the clamp's moments
  — belongs to the temporal pass.
- **The history write is the temporal pass's output, not this pass's.** Feeding the filtered result
  back re-filters an already-filtered signal every frame, and with a filter that never fully
  collapses that compounds without bound: a two-pixel kernel arrives on screen as a twenty-pixel
  smear, and contact hardening is the first thing it destroys.

## 6. The directional path

A sun takes a row in the same light buffer and competes for a pixel's four channels on the same
terms as every lamp, reinterpreting four fields. `light_type` is the discriminator and the trace
branches on it once, never on a sentinel in another field.

### Caster volume

`renderer_scene_cull.cpp`, one volume and one geometry-index query per directional light, skipped
entirely when `is_raytraced_directional_available()` is false. Iterate
`scenario->directional_lights`, not the culled light list. Skip a sun that is invisible, outside
`p_visible_layers`, or has shadows off.

| Step | Detail |
| --- | --- |
| `far_distance` | re-derived **exactly as the engine's directional cascade setup does**: the main projection's `z_far`, clamped by `LIGHT_PARAM_SHADOW_MAX_DISTANCE` only when that is `> 0` **and** the camera is not orthogonal, then `MAX(..., z_near + 0.001)`. A max distance of zero means "as far as the camera sees"; treating it as a literal zero collapses the volume to a millimeter and gathers nothing, silently. Getting the orthogonal test backwards fails the same way |
| The volume | the frustum box **merged with a copy of itself swept toward the light**: `near_extents = main_projection.get_viewport_half_extents()` (half extents at the *near* plane); `far_extents = is_orthogonal ? near_extents : near_extents * (far_distance / MAX(z_near, 0.001))`, an orthogonal frustum not widening with distance; eight view-space corners `(±ex, ±ey, -z_near)` and `(±ex, ±ey, -far_distance)` each through the camera transform, world AABB of the eight; then copy the box, translate the copy by `far_distance * caster_distance_scale` along the light basis's normalized **+Z** column — toward the light, opposite the direction the light travels — and merge back |
| Both halves are load-bearing | the swept copy alone holds occluders and no receivers; the untranslated box alone holds nothing that is not already on screen, so no ridge or wall behind the camera casts into view |
| **Sweeping the wrong way is the quiet failure** | it still gathers plenty: the volume fills with geometry down-sun of the visible frustum, which cannot occlude anything, so the scene keeps its self-shadowing and loses every shadow thrown in from off screen — reading as a lighting bug rather than a culling one |

### Record reinterpretation and the two fades

Filled in `update_light_buffers`:

| Field | Value and why |
| --- | --- |
| `position` | the **camera's** world position, what the sun's receiver range is measured from |
| `radius`, `fade_from` | `MAX(-light_data.fade_to, 0.001)` and `MAX(-light_data.fade_from, 0)` — both the **negation of the fade the cascade path just computed** (it stores them negative for its own comparison), which keeps traced fade and cascade fade from drifting apart |
| `direction` | `light_transform.basis.xform(Vector3(0,0,1)).normalized()` — **toward** the light, the opposite sense to a lamp's spot axis, and world space, not the view-space `light_data.direction` |
| `size` | `tan(deg_to_rad(LIGHT_PARAM_SIZE)) * softness_scale`. Read straight off `light_angular_distance` with no default of its own — the same number the cascade path turns into `softshadow_angle`, so at the default scale the two agree and the inspector value is what is traced. The scale reaches the trace only; `light_data.size`, the sky's sun disk and any lightmap bake keep the authored angle |
| `max_ray_length` | `radius * (1 + caster_distance_scale)`. A receiver sits at most `far_distance` from the camera and the volume reaches a further `caster_distance_scale * far_distance` up-sun, so that product is the whole reach the sweep bought. `radius` gets there indirectly and deliberately — it is the negation of the cascade path's `fade_to`, which is the last cascade's split offset, which the cascade setup set to the same `far_distance` this stage swept; recomputing `far_distance` here would work today and drift the first time an input changes on one side only |
| `normal_bias` | `shadow_normal_bias * 0.0075`, **half** the lamp scale of `0.015`, because `DirectionalLight3D` defaults that property to 2.0 where a lamp defaults to 1.0 — a default that exists to clear a cascade's depth texels, which a ray has none of. At the raw scale the sun's rays start twice as far off the surface and contact shadows lift off their casters, the very shadow-map artifact raytracing exists to remove |

Everything the culler did not gather has to be faded out **inside the trace**, keyed on view depth:
the trace treats every non-sky pixel as a receiver, but casters were gathered only as far as the
shadow distance, so a surface past it traces an empty region and comes back confidently **lit** — a
hard seam across the landscape at exactly the shadow distance. Two tests prevent it, both reading
the same last-cascade split offset the cascade fade reads: per pixel the selection stage drops a
directional light whose `radius` is less than the fragment's view depth, and inside the window the
trace multiplies its answer toward fully lit by `smoothstep(fade_from, max(radius, fade_from +
0.0001), view_depth)` and skips the rays once that reaches 1.0. The `+ 0.0001` guards against equal
smoothstep edges; the CPU side's guard is clamping the fade-start fraction to 0.999. Fading here
rather than in the forward pass keeps the mask continuous, which is what the denoiser filters and
reprojects.

Directional ray directions sweep a cone of *directions*, not a disk at a place: the unit vector is
offset perpendicularly by `tan(angle)` and renormalized, sweeping exactly the cone it subtends
wherever the receiver is.

### Forward pass: three blocks where upstream has one

`shaders/forward_clustered/scene_forward_clustered.glsl`. Upstream wraps the cascade chain, the
lightmap shadowmask handling, the distance fade and the vertex-lighting apply in a single `if
(shadow_opacity > 0.001)`. Split in three, same `0.001` threshold everywhere:

| Block | Condition | Body |
| --- | --- | --- |
| mask | `rt_slot < RT_SLOT_NONE && RT_MASK_ANSWERS_HERE` | set `rt_shadowed = true`; then, only if `shadow_opacity > 0.001`, `shadow = rt_shadow_lookup(rt_slot)`. **Raw visibility** |
| cascades | `!rt_shadowed && shadow_map_opacity > 0.001` | upstream's chain unchanged, with the `#undef` of `BIAS_FUNC` moved inside it |
| tail | `rt_shadowed \|\| shadow_opacity > 0.001` | lightmap shadowmask branches, the fade, the vertex-lighting apply |

- `RT_SLOT_NONE` is `255.0` and the slot is a float, so that is a float compare.
- **The mask arm hands over raw visibility.** The second directional loop already applies
  `shadow_opacity` unconditionally to the byte the first loop packed, and the cascade chain hands
  over raw for the same reason; applying it here too made a shadowed pixel lose light as opacity
  *squared* — invisible at the default 1.0 because `mix(1, s, 1)` is `s`, wrong at every value below
  (`docs/HISTORY.md`). Two consumers between lookup and pack also want raw: the contact shadow
  combined with `min()`, and the lightmap shadowmask crossfade blending against a raw `shadowmask`.
  Under `USE_VERTEX_LIGHTING` the second loop is compiled out and `shadow_opacity` is lost — but
  lost identically for the cascade path upstream, and the two agreeing is worth more.
- **The mask arm is chosen on the slot alone, never on `shadow_opacity`.** `rt_shadowed` means "the
  mask is this light's answer here", not "the mask shadowed this fragment": a sun holding a slot
  with zero opacity sets the flag, leaves `shadow` at 1.0 and skips the cascade block, which is what
  zero opacity means. Folding the opacity test into the flag sends that light down the cascade path
  to sample an atlas rect it does not own. The tail's gate is `shadow_opacity`, not
  `shadow_map_opacity`, for the mirror reason: a raytraced sun has `shadow_map_opacity` of zero
  unless asked to keep a map, and the tail still has to run for it — what the `rt_shadowed` disjunct
  is for.

**The fade is hoisted out of the cascade block** so a raytraced sun can still hand over to a baked
shadowmask, and all three arms are `rt_shadowed`-aware:

| Arm | Raytraced form |
| --- | --- |
| plain | `if (!rt_shadowed) shadow = mix(shadow, 1.0, sun_fade)`. The trace already applied it over the negation of the same two numbers, and must, because what has to be continuous is the mask |
| REPLACE | `shadow` is already `mix(raw, 1, sun_fade)` and this branch wants `mix(raw, shadowmask, sun_fade)`; they differ by exactly `sun_fade * (1 - shadowmask)`, so the raytraced arm is `clamp(shadow - sun_fade * (1 - shadowmask), 0, 1)` — no division, no recovery of the raw value. Left alone it crossfades toward fully lit and then toward the bake, showing a lit band across the window on ground shadowed in both |
| OVERLAY | `shadow = shadowmask * (rt_shadowed ? shadow : mix(shadow, 1.0, sun_fade))` |

The contact shadow term, where it runs, is `contact = mix(1.0, sss_shadow_lookup(), sss_strength)`
then `shadow = min(shadow, contact)`. On the raytraced path `contact` is additionally faded by
`sun_fade` first, because the cascade path fades the combined term further down and that block is
skipped — and the march has no world-space range limit of its own, so nothing else would bound it
(`docs/internals/screen-space-shadows.md`).

### Demotion

`_light_directional_effective_shadow_mode()` and `_apply_directional_shadow_size()`.

| Rule | Why |
| --- | --- |
| Keyed on whether the light **could** be raytraced (`_light_uses_raytraced_shadows`), not on whether it was this pass | the cascade count must be one answer for the culler, the atlas layout and the light buffer, which run at three different points; a disagreement puts cascades in the wrong atlas rects. The two settings behind it are snapshotted once per frame by `RaytracingScene::update_frame_settings()` for the same reason |
| **Both readings of the shadow mode must move together** | `update_light_buffers` read `light->directional_shadow_mode` directly, so overriding the accessor alone left the culler emitting two cascades while the buffer computed `limit == 3` — split offsets `(s0, s1, 0, 0)`, a `fade_to` of negative zero, and a smoothstep with equal edges |
| The authored mode is left untouched on the `Light` | it still round-trips through the editor; only what the renderer asks for changes. `directional_shadow.requested_size` is kept separately from `.size`, so the full size comes back if raytracing goes away. The atlas is shared, so the cap applies to **every** directional light, raytraced or not |
| **Safe only on top of the cascade-slot fill** | every cascade ladder in the shaders ends in an `else` reading slot 3; with fewer cascades that slot holds a default-constructed `ShadowTransform` — identity projection, zero far plane, zero split. Surface shading and fog hide it because the distance fade bleaches the result at exactly that depth, but **subsurface transmittance has no fade**: it scales its sampled depth and its own by slot 3's far plane, so zero far plane means zero thickness means full light through a solid object. The zero in `shadow_split_offsets.w` is also the denominator of the last PCF blur factor, `shadow_split_offsets.x / shadow_split_offsets.w` — a division by zero for every fragment past the last real split, blend splits on or off. The fix is `const int src = MIN(j, limit)` applied to the matrix, ranges, biases, uv scales and atlas rect, not only to `split` (all GLES3 already clamped). At four splits `limit` is 3 and nothing changes |

### Fog

A froxel is not a visible surface and has no pixel in the mask, so it traces its own ray.
`volumetric_fog_process.glsl`, `USE_RAYTRACED_SHADOWS` variants only, TLAS in **set 2 binding 0**.

| Rule | Detail |
| --- | --- |
| Directional only | positional lights get no ray and a raytraced lamp lights the fog unshadowed; the TLAS is left null unless a directional light took a slot (`p_settings.tlas` is only set when `has_raytraced_directional_shadows()`) |
| World position | `world_pos = mat3(cam_rotation) * view_pos + cam_position.xyz`. `cam_rotation` only rotates, so `cam_position` had to be added to the params UBO **and** mirrored as a `vec4` in the std140 block at the identical position — half-applying this garbles `cam_rotation`, `to_prev_view` and `radiance_inverse_xform` |
| One ray per froxel | so the sun's angular size is spread across **frames**: the ray is offset within the cone by the same `halton_map[temporal_frame]` value that jitters the froxel position, under the same `reproject_amount > 0` guard, so it stays a global jitter rather than per-froxel noise. Halton is already stratified over the 16-frame cycle, mapped to the disk by area (`radius = sqrt(h.x) * rt_softshadow_angle`) to keep that stratification |
| Ray length | `max(-fade_to, 0.001)` — **not** the trace's `radius * (1 + caster_distance_scale)`: a froxel gives up occluders beyond the shadow distance for a shorter traversal |
| Flags | `OPAQUE \| TERMINATE_ON_FIRST_HIT`: a binary answer with no penumbra to size |
| Cull mask | `rt_caster_mask`, the pre-folded 8-bit `shadow_caster_mask`, **not** `mask`, which is `cull_mask` at full width and which `rayQueryInitializeEXT` would silently truncate to its low byte. `rt_softshadow_angle` is likewise separate from `softshadow_angle`, which keeps the authored angle for the cascade path's PCSS branch |
| Opacity | the ray arm uses `shadow_opacity`, the cascade arm below it `shadow_map_opacity`, and `answered_by_ray` keeps them exclusive |

**Also the reusable pattern for adding a ray-query variant to an existing shader at no cost to
projects that never use it.** All five parts are required: (1) give the raytracing variants a
`ShaderRD` group of their own (`SHADER_GROUP_BASE_RAYTRACED` offsets); (2) **do not create their
pipelines at init** — skip those indices, because `version_get_shader` on a disabled group returns a
placeholder; (3) `enable_group()` lazily, the first frame something needs them
(`Fog::_ensure_raytraced_density_pipelines()`); (4) put the structure in a **uniform set of its
own** that only those variants declare, so every other variant's uniform set is byte-for-byte
unchanged; (5) guard the `#extension` and the `accelerationStructureEXT` declaration behind the
variant's own define, so non-tracing variants emit SPIR-V requesting no raytracing capability. The
deferred subsurface-transmittance work should use it, with the structure declared inside `#ifdef
LIGHT_TRANSMITTANCE_USED`.

## 7. Reading the mask in the forward pass

`rt_shadow_lookup(float p_slot)` lives in **`scene_forward_lights_inc.glsl`**, not
`scene_forward_clustered_inc.glsl`: it reads `gl_FragCoord`, which does not exist in the vertex
stage that also includes the latter, so putting it there fails every Forward+ vertex variant to
compile and **the symptom is the editor appearing to hang on the splash screen** with the CPU at
90-120 ms and the GPU idle. `scene_forward_lights_inc.glsl` is shared with the mobile renderer, so
every block added to it needs `#ifndef USING_MOBILE_RENDERER`.

| Detail | Why |
| --- | --- |
| The lookup | return 1.0 if `p_slot >= RT_SLOT_NONE`; bounds-check `gl_FragCoord.xy` against `textureSize(rt_shadow_index)`; fetch the index texel, fetch and square the mask texel; return whichever of `slots.r/g/b/a` equals the slot, else 1.0 (more raytraced lights reach this pixel than the mask has channels and this one was not among the strongest — leaving the weakest unshadowed is the least visible way to run out of room) |
| The bounds check is not defensive tidiness | with no raytraced set in the render buffers these two bindings fall back to a 1x1 index texture and the shared 4x4 white texture, and `texelFetch` ignores the sampler's clamp by definition, so every pixel but the first few is an out-of-range read — zero under image robustness, undefined without it. A zero index makes `slots.r == slot` true for slot 0 and a zero mask reads as fully shadowed, so the failure is a light putting out its own shadow everywhere |
| Combined sampler | `texelFetch` on a bare `texture2D` requires `GL_EXT_samplerless_texture_functions`, which these shaders do not enable, so the lookup builds `sampler2D(rt_shadow_mask, SAMPLER_NEAREST_CLAMP)` as `ssil_buffer` and `ssr_buffer` do |
| **Bindings 37 and 38** | appended to `RENDER_PASS_UNIFORM_SET` (set 1); upstream's highest was 36, and screen space shadows added 39. They must be pushed on **every** path through `_setup_render_pass_uniform_set`, reflection-probe and no-render-buffer renders included: `DEFAULT_RD_TEXTURE_WHITE` for the mask, and `rt_shadow_index_fallback` — a 1x1 all-`0xFF` `R8G8B8A8_UINT` texture the fork creates, no shared default texture being integer-formatted |

### The alpha pass

`RT_MASK_ANSWERS_HERE`. The mask is traced from the depth pre-pass, so it only describes fragments
that are in it. A genuinely alpha-blended fragment is not: reading the mask at its pixel returns the
visibility of whatever opaque surface lies behind it — a confident wrong answer rather than a
missing one.

- "Am I in the alpha pass" is not quite the question. Alpha-to-coverage and `depth_prepass_alpha`
  materials are drawn in the transparent list but **do** write pre-pass depth, so the mask describes
  them correctly; those are known at compile time (`USE_OPAQUE_PREPASS` /
  `ALPHA_ANTIALIASING_EDGE_USED`) and collapse the macro to a constant `true`. Alpha scissor and
  alpha hash go through the pre-pass like anything opaque and were never affected.
- The runtime half is a **scene-data flag, not a shader variant**: a bool on `RenderSceneDataRD` set
  true only across the transparent pass's own scene-data setup call — the one building that pass's
  uniform buffer, before the list is drawn — and cleared immediately, so only that buffer carries
  the bit. Packed as `SCENE_DATA_FLAGS_IN_ALPHA_PASS`, mirrored in `scene_data_inc.glsl`. The
  fallback guards moved from `shadow_opacity` to `shadow_map_opacity` at the same time.

### Three consumers that read shadow-map state a raytraced light no longer has

| Consumer | Behavior |
| --- | --- |
| Subsurface transmittance | falls back to the material's own transmittance depth — a screen-space mask cannot give a depth from the light's point of view. Gated on `shadow_map_opacity > 0.001`; the fallback is what remains. Known gap |
| Volumetric fog | traces its own ray for a sun (above); a raytraced lamp lights the fog unshadowed |
| Light projectors | a fix rather than a fallback: the cookie is projected with the light's shadow matrix, which upstream fills only on the shadow-map branch, while the atlas rect it samples comes from the decal atlas and was never tied to the shadow map — so only the matrix has to be recovered. For a raytraced light with `!has_shadow_map`, in `update_light_buffers`: **omni** = `(inverse_transform * light_transform).inverse()` stored as a transform (the shader normalizes it, so only the rigid transform matters); **spot** = that modelview with a rebuilt cascade-zero projection in front, `bias * (depth_correction * cm) * modelview`, using `set_light_bias()` and `set_depth_correction(false, true, false)` — z reversal only, no y flip, no z remap |

- `cm.set_perspective(spot_angle * 2.0, 1.0, MIN(0.025, radius), radius)` — the same four numbers
  the culler uses for that spot's cascade-zero transform, which is what makes the recomputed matrix
  interchangeable. FOV and aspect place the cookie together with the bias: the projector divides by
  w and reads only x and y, and neither the bias nor the depth correction mixes the z row into those
  two. Near and far live in the z row, which nothing reads on this path — wrong values are invisible
  until something starts reading depth from this matrix, so take them from the map path anyway.
- `shadow_opacity` (what multiplies the traced visibility) and `shadow_map_opacity` (what the
  cascade-sampling effects multiply by, and what they test to know whether a map exists) must stay
  strictly distinct. The wrong way round produces a scene that looks right until you add fog.
- Skipping a raytraced light's shadow-map **render** must not skip
  `light_instance_set_shadow_transform()`: those per-cascade split distances are what
  `fade_from`/`fade_to` are derived from, and the raytraced path reads them. Set the transforms for
  every cascade, skip only the render-list merge.

## Data contracts

`docs/PORTING.md`, "Reference values", is the single copy of these, each with a file and line: the
64-byte light record (`RTShadows::LightParams` in `effects/rt_shadows.h` with its
`static_assert(sizeof == 64)`, mirrored by GLSL `RTLight` in `rt_shadow_trace.glsl` — keep the two
in one commit) and the four fields a directional row reinterprets; the caster record
`RendererSceneRender::RaytracingInstance`; the `RB_SCOPE_RT_SHADOWS` texture formats; the push
constant sizes (`TracePushConstant` 120 bytes, `TemporalPushConstant` 112, `AtrousPushConstant` 48,
`RaytracingScene::DequantizePushConstant` 32); the fork's fixed constants; and the interfaces this
fork widens. Read it before changing any of them — a mismatch there is silent.

Six things about them the mechanism above depends on:

| Contract | Why |
| --- | --- |
| RT textures are single-layer (this path is never multiview), created at the render buffer's **internal** size (`docs/internals/dlss.md`), cleared to zero at creation | the denoiser reads its own buffers back before it has ever written them: zeroed history reads as "no usable history", reprojection comparing against a stored view distance of zero and rejecting it. The mask is the exception, cleared white on frames the trace does not run |
| Raw hit distance must always be its own target | the trace writes it and visibility in one dispatch, so aliasing them makes the second write clobber the first |
| `LightData` / `DirectionalLightData` (`light_storage.h` ↔ `light_data_inc.glsl`) are hand-maintained mirrors with no `static_assert` between them | the fork **consumed existing trailing padding** rather than growing them — `DirectionalLightData`'s pad changed from `uvec2` to two floats deliberately, the shader comparing `rt_slot` as a float against `255.0`. Growing either struct moves every offset after the change silently, and lighting goes subtly wrong rather than crashing |
| `RenderSceneDataRD` gains an `alpha_pass` bool reaching the shader as a scene data flag; `_uses_raytraced_shadows()` must be a **separate virtual** on `RendererSceneRenderRD` | the RT objects live on the shared RD base class — without it the Mobile renderer looks capable and its lights lose their shadow maps without gaining a mask |
| `SHADER_VERSION_COLOR_PASS` is **10** and is an invariant, not a value | the screen space caster-mask depth variant pushed it from 9, and a newer Godot adding a depth version of its own silently mis-indexes every color pipeline. Arithmetic and failure: `docs/PORTING.md` |
| Include directions upstream does not otherwise have | `storage_rd` → `environment` (`mesh_storage.cpp` includes `rt_scene.h`), and `environment` → a generated shader header in `effects/` |

## Instrumentation

`GODOT_RT_DEBUG=1` in the environment; cached on first use in `RaytracingScene::debug_enabled()`.
Each line prints only when its text changes, so a steady scene prints once.

| Line | Emitted by | Reads |
| --- | --- | --- |
| `RT_DEBUG cull:` | `renderer_scene_cull.cpp` | scenario instances, rt lights, index nodes visited, non-casters, casters, multimeshes, TLAS entries, skinned count |
| `RT_DEBUG update:` | `rt_scene.cpp` | input instances, TLAS instances, BLAS cache size, skipped surfaces, deferred surfaces, whether it rebuilt |
| `RT_DEBUG pre_opaque:` | `render_forward_clustered.cpp` | render buffers present, availability, `rt_lights` count, **new slots this frame**, TLAS valid |
| `RT_DEBUG shadows:` | `renderer_scene_cull.cpp` | positional lights, raytraced count, shadow maps still rendered |
| `RT_DEBUG cpu over N frames:` | `_rt_report_cpu_cost` | gather and build, averages and peaks, every 120 frames |

- `new_slots=N` on the first frame and `new_slots=0` on every frame after — including while walking
  through a ring of lamps that fully reorders the light buffer — is the check that slot stickiness
  works. `rt_lights=1 new_slots=1 tlas=1` on `pre_opaque` is the mask being written.
- `skipped_surfaces>0` on `update:` means geometry was rejected as un-raytraceable — non-triangle,
  2D or empty vertex arrays, or no vertex buffer.
- `pre_opaque`'s `rt_lights=N` is the **input to the per-pixel light selection**. Watch it while
  walking into a lamp-dense area: that is where the four-per-pixel and 128-per-tile ceilings begin
  to bind (`docs/features/rt-shadows.md`).
