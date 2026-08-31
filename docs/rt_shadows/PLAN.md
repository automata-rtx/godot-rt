# Raytraced Shadows for Godot Forward+ (Vulkan)

> **HISTORICAL — do not treat this as a description of the shipped code.**
>
> This is the design and viability study written *before* implementation. It is kept for the
> reasoning behind the approach and for the survey of what the engine already provided, both of
> which are still useful. But the system was built by discovering things the study did not know,
> and several of its decisions were changed or abandoned along the way — the per-light shadow mode
> enum, the slot count, and the denoiser plan among them.
>
> For what the code actually does now, read **`FORK_GUIDE.md`** in this directory. For how it hooks
> into the engine and how to re-apply it to a newer Godot, read **`PORTING.md`**. Where this
> document and those two disagree, they are right and this is out of date.
>
> An audit against the shipped code found these specific statements to be false. They are listed
> because the document is detailed and confident enough to mislead a reader who does not know:
>
> - **§10.1, §11 and D9** say alpha-tested foliage casts *no* shadow. It casts a **wrong** one — the
>   shadow of its whole uncut quad, because rays are traced with `gl_RayFlagsOpaqueEXT`. This is the
>   likeliest authoring bug in a project built on this fork, and the document argues from the
>   opposite premise.
> - **D8** proposes a `Light3D.shadow_mode` enum (`AUTO`/`OFF`/`SHADOW_MAP`/`RT_ONLY`). Abandoned.
>   What shipped is one bool, `Light3D.shadow_map_enabled`.
> - **D3** proposes 8 denoised slots plus an inline ray-query overflow path in the forward shader.
>   What shipped is 4 per-pixel channels with **no** overflow path.
> - **D7** proposes replacing the hand-rolled denoiser with NVIDIA NRD SIGMA. That did not happen;
>   three of SIGMA's ideas were adopted into the existing denoiser instead.
> - **D9** says the feature cannot be enabled without raytracing hardware. It can — the engine warns
>   and falls back to shadow maps.
> - **§7.1**'s project-setting names are fictional, and its claim that they are live-toggleable is
>   false: every setting is read once at startup.
> - **§10.1 and §11** say directional lights are not covered. They shipped.
> - **§11** says area lights are covered from Phase 3. `AreaLight3D` is not covered at all.
> - **§10.4, "What will not change for existing projects"**, is the most misleading page here.
>   Nearly every bullet is now false, starting with the node defaults.
>
> D1, D2, D5, D6, D8b and D10 are the decisions that survived intact.

**Design & viability document**
Target: Godot 4.8-dev (this fork) · Vulkan only · Forward+ (`forward_clustered`) only · 3D only

---

## 0. Read this first (plain-language verdict)

**Short answer: yes, this is viable, and the groundwork in your fork is better than expected.**

Godot 4.7/4.8 shipped a complete hardware-raytracing layer inside `RenderingDevice`
— acceleration structures, ray pipelines, shader binding tables, ray-query support,
barrier handling. What it did *not* ship is any *user* of that layer. Nothing in the
renderer calls it. It is a fully-built engine with nothing bolted to it.

That is actually the good news. It means:

* We are not fighting an existing half-finished shadow-raytracing design.
* Every hard, fiddly, driver-level piece (extension loading, feature detection,
  memory, scratch buffers, synchronization) is already done and already debugged.
* The work in front of us is *renderer* work, in C++ and GLSL, at a layer that is
  well-understood and well-isolated.

Four findings shape the entire plan. Each was verified by reading the source, and
each is spelled out with file and line numbers later in this document.

1. **Inline ray tracing works today.** Godot compiles shaders to SPIR-V 1.4 targeting
   Vulkan 1.1, `VK_KHR_ray_query` is enabled, and acceleration structures can be bound
   to a shader as a uniform. This means we can trace rays from an ordinary compute
   shader. We do *not* need the much heavier ray-pipeline machinery. This is the single
   biggest simplification available to us.

2. **Animated characters are the easy case, not the hard case.** Godot already skins
   meshes in a compute pre-pass into a persistent, double-buffered vertex buffer, and
   Godot's importers already *disable* vertex compression for skinned and morph-target
   meshes. So skinned geometry is already sitting in GPU memory in exactly the format
   raytracing wants. Character shadows are close to free.

3. **Static imported meshes are the hard case.** Godot's importers compress vertex
   positions to a 16-bit format by default. That format is *not legal* as raytracing
   geometry input in Vulkan. This is the one genuine blocker in the whole project, and
   it needs a small conversion pass. It is solvable, it is bounded, and Section 4.2
   explains exactly how.

4. **Your "shadows from things behind the player" requirement is already supported.**
   Godot keeps a spatial index of every object in the scene that is *not* frustum-culled.
   We can query it by region. This is precisely the right source for the raytracing
   scene, and it is existing, battle-tested code.

The riskiest item in your wish-list is **DLSS**, and not for the reason you would
expect. It is not a graphics problem — it is a plumbing problem, described in
Section 8.3. **NRD denoising and RTAO are both comfortably reachable.** DLSS Super
Resolution needs one new piece of engine plumbing first. DLSS Ray Reconstruction needs
that same piece plus considerably more.

**What "done" looks like for you:** you tick one box in Project Settings. Every
OmniLight3D and SpotLight3D in your game starts casting a correct, contact-accurate,
un-peter-panning shadow, in the editor viewport and in the exported game, with no
shadow-map resolution to tune, no bias to fight, no atlas to size. Lights you do not
want casting shadows get one checkbox unticked. On a GPU without raytracing, the game
silently uses the shadow maps it uses today.

---

## 0.5 Design philosophy (revised — this supersedes earlier caution)

The first draft of this document treated shadow maps as the substrate and RT as a cautious
override. **That is inverted.** The project targets RT-capable hardware exclusively, and the
governing rule is now:

> **Raytraced shadows are the shadow system for every non-directional light. A local light
> falling back to a shadow map is a defect, not a degradation.**

Everything below follows from that. Concretely, it deletes more of the design than it adds:

| First draft | Revised | Why |
|---|---|---|
| Silent fallback to shadow maps on unsupported GPUs | **Deleted.** RT-capable hardware is a requirement | No fallback to maintain, no dual-path testing, no "why does it look different on my friend's PC" |
| Purity gate demoting whole lights to shadow maps | **Deleted.** Ineligible geometry simply casts no RT shadow | The gate was the single biggest risk in the plan and it existed only to protect a fallback we no longer want |
| 64 m residency radius around the camera | **Deleted.** Residency follows light influence volumes | A light inside the world should shadow correctly regardless of camera distance |
| Budgets that cap work and demote lights | **Diagnostic only.** Never silently reduce quality | Cost should be visible and fixed in content, not hidden by the renderer |
| 4 RT-shadowed lights per pixel, rest on shadow maps | **8 denoised slots + inline ray-traced overflow** | No pixel ever falls back to a shadow map |
| Soft shadows as a feature to add | **Soft with contact hardening is the default.** Hard shadows are opt-in | This is the actual reason to use RT over shadow maps |

The one thing this philosophy cannot delete is **volumetric fog** (§7.7), which samples the
shadow atlas directly in its own shader and cannot read the screen-space mask. That is a
genuine structural dependency, not caution, and it is called out separately.

---

## 1. What actually exists today (verified)

Everything in this section was confirmed by reading the source in this fork. File and
line references are from the current `master` (`b56a91878`).

### 1.1 The RenderingDevice raytracing layer

`servers/rendering/rendering_device.h` exposes a complete, coherent API:

```cpp
struct AccelerationStructureGeometry {
    BitField<AccelerationStructureGeometryFlagBits> flags;
    RID        vertex_buffer;
    uint32_t   vertex_offset, vertex_stride, vertex_count;
    DataFormat vertex_format;
    RID        index_buffer;
    uint32_t   index_offset, index_count;
};

struct AccelerationStructureInstance {
    Transform3D transform;
    uint32_t    id;                 // -> gl_InstanceCustomIndexEXT
    uint8_t     mask;               // -> ray cull mask
    HitShaderBindingTableRange hit_sbt_range;
    BitField<AccelerationStructureInstanceFlagBits> flags;
    RID         blas;
};

RID   blas_create(Span<AccelerationStructureGeometry>, BitField<AccelerationStructureFlagBits>);
RID   tlas_create(uint32_t p_max_instance_count, BitField<AccelerationStructureFlagBits>);
Error blas_build(RID p_blas);
Error tlas_build(RID p_tlas, Span<AccelerationStructureInstance> p_instances);
```

Supporting detail worth noting:

* `UNIFORM_TYPE_ACCELERATION_STRUCTURE` exists (`rendering_device_commons.h:663`), so a
  TLAS can be bound to a compute shader like any other resource.
* The TLAS keeps an internal ring of CPU-writable instance buffers
  (`AccelerationStructure::InstanceBuffer`, with a `frame_used` stamp and a mapped
  `data_ptr`). The API was *designed* for a full per-frame instance upload. That is
  exactly the usage pattern we need.
* `AccelerationStructureInstanceFlagBits` includes
  `TRIANGLE_FACING_CULL_DISABLE_BIT` and `TRIANGLE_FLIP_FACING_BIT` — which we need for
  double-sided materials and for negatively-scaled instances respectively.
* Build flags include `ALLOW_UPDATE`, `ALLOW_COMPACTION`, `PREFER_FAST_TRACE`,
  `PREFER_FAST_BUILD`, `LOW_MEMORY`.

**Known gap:** `ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT` exists as a flag, but there is
no `blas_update()` entry point — `blas_build()` always performs a full build
(`rendering_device.cpp:445`). For animated characters we want a cheap *refit*. Adding
`blas_update()` is a small, self-contained addition to `RenderingDevice` and the Vulkan
driver (`vkCmdBuildAccelerationStructuresKHR` with
`VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR`). This is on the critical path and is
budgeted in Phase 2.

### 1.2 Hardware support and the Vulkan driver

`drivers/vulkan/rendering_device_driver_vulkan.cpp:584-589` registers all four
raytracing extensions as **optional**:

```cpp
_register_requested_device_extension(VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME, false);
_register_requested_device_extension(VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME, false);
_register_requested_device_extension(VK_KHR_RAY_TRACING_PIPELINE_EXTENSION_NAME, false);
_register_requested_device_extension(VK_KHR_RAY_QUERY_EXTENSION_NAME, false);
```

Optional means a GPU without raytracing still initializes normally — there is no
hardware regression risk from this feature merely existing. Support surfaces upward as
two separate capabilities (`rendering_device_commons.h:1036-1037`):

```cpp
SUPPORTS_RAY_QUERY,
SUPPORTS_RAYTRACING_PIPELINE,
```

and `SUPPORTS_RAY_QUERY` correctly requires *both* acceleration-structure and ray-query
support (`rendering_device_driver_vulkan.cpp:7462-7463`). The barrier code already
special-cases the ray-query-in-compute-shader case
(`rendering_device_driver_vulkan.cpp:3012`), which is a strong signal that inline
raytracing from compute was an intended use of this layer.

There are no `TODO`/`FIXME`/stub markers anywhere in the raytracing code paths.

### 1.3 Shader compilation — inline ray tracing is available now

This was the make-or-break question, and the answer is favorable on all four counts:

| Requirement | Status | Evidence |
|---|---|---|
| glslang understands ray query | Yes | vendored glslang; all RT stages wired in `modules/glslang/register_types.cpp:56-64` |
| SPIR-V ≥ 1.4 | Yes — 1.4 exactly | `rendering_shader_container_vulkan.cpp:103-105` |
| Vulkan ≥ 1.1 client | Yes — 1.1 | `rendering_shader_container_vulkan.cpp:99-101` |
| AS bindable as uniform | Yes | `UNIFORM_TYPE_ACCELERATION_STRUCTURE` |

`GL_EXT_ray_query` requires SPIR-V 1.4 and Vulkan 1.1. Godot targets exactly that — but
there is a fifth requirement that is easy to miss and that Godot does **not** currently
meet:

> **glslang gates the `rayQueryEXT` keyword (`Scan.cpp:1110`) and every `rayQuery*EXT`
> builtin prototype (`Initialize.cpp:5327`) on GLSL `#version >= 460`. All 82 shader files
> in `renderer_rd/shaders/` are `#version 450`. None is 460.**

So our RT shaders must be the first `#version 460` files in the tree. This is not a build
system change — `ShaderRD::_build_variant_code` injects defines at the `#VERSION_DEFINES`
chunk, i.e. *after* the `#version` line (`shader_rd.cpp:280-300`), so a 460 header plus the
`#extension` directive at the top of the file just works.

There is a nasty asymmetry worth knowing in advance: `accelerationStructureEXT` has **no**
version gate (`Scan.cpp:1091-1097`), so the TLAS uniform declaration compiles fine at 450
and the failure only surfaces later at the first `rayQueryEXT`. Expect to lose an afternoon
to this if it is not written down.

It also means ray query **cannot** be made conditional inside an existing `#version 450`
shader behind an `#ifdef` or specialization constant — the keyword is rejected at scan
time regardless of preprocessor branches. Ray query lives in its own 460 file. This is an
additional reason for decision D2.

### 1.4 Where shadows are computed today

Local-light shadowing lives in
`servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl`. Inside
`light_process_omni_light()` the shadow term is initialized at line 499:

```glsl
half shadow = half(1.0);
if (omni_attenuation > HALF_FLT_MIN && omni_lights.data[idx].shadow_opacity > 0.001) {
    // ... ~110 lines of shadow-atlas sampling, PCF, penumbra estimation ...
}
```

That single variable is the entire integration point. Everything downstream multiplies
by it. Substituting a raytraced value there is a genuinely local change.

The `LightData` UBO struct (`light_data_inc.glsl`) carries `float pad[2]` — two unused
floats. We can carry per-light raytracing state there without changing the struct size,
alignment, or any existing field offset.

### 1.5 Shader variants — no combinatorial explosion

Forward+ gates shadow *quality* through packed specialization constants, not shader
variants (`forward_clustered/scene_forward_clustered_inc.glsl:64-146`):

```glsl
layout(constant_id = 0) const uint pso_sc_packed_0 = 0;
layout(constant_id = 1) const uint pso_sc_packed_1 = 0;

bool sc_use_light_soft_shadows() { return ((sc_packed_0() >> 2) & 1U) != 0; }
uint sc_soft_shadow_samples()    { return (sc_packed_0() >> 8) & 63U; }
```

`sc_packed_0` is fully allocated (bits 0-31). **`sc_packed_1` uses only bits 0-6 —
bits 7-31 are free.** An `sc_use_rt_shadows()` bit costs one bit of `sc_packed_1` and
adds *zero* new shader variants. It also works in ubershader mode, where the constants
come from draw-call push constants instead.

This is a significant win: it means enabling RT shadows does not double shader compile
times or worsen pipeline-compilation stutter.

### 1.6 Frame structure — where an RT pass belongs

In `render_forward_clustered.cpp`, `_render_scene()` runs:

```
Render Depth Pre-Pass                    (:2138)
Resolve Depth Pre-Pass (MSAA)            (:2159)
_pre_opaque_render(...)                  (:2195)   <-- shadows, SSAO, SSIL, GI, fog
Process Pre Opaque Compositor Effects    (:2185 def)
Render Opaque Pass                       (:2201)
```

`_pre_opaque_render()` is where SSAO and SSIL run, and it is the right slot for an RT
shadow pass. But its inputs are **not** free, and this is the correction most likely to
waste a week if taken on trust:

* **Depth** is available at internal resolution only if `depth_pre_pass` is true
  (`render_forward_clustered.cpp:2126`) — and that is a user-disableable project setting.
  Under MSAA it is only *resolved* if the pass adds itself to the `finish_depth`
  disjunction at `:2152`. Neither happens automatically. Reading an unwritten depth buffer
  is the silent failure mode.
* **Normal-roughness is not produced by default.** `depth_pass_mode` initializes to
  `PASS_MODE_DEPTH` (`:1844`) and is only upgraded to `PASS_MODE_DEPTH_NORMAL_ROUGHNESS`
  by the SSR/SDFGI/SSAO/SSIL/compositor chain at `:1938-1952`. RT shadows must add their
  own term to that chain, which costs an extra `R8G8B8A8_UNORM` attachment in the prepass
  and, under MSAA, the heavier `resolve_gi` path.
* Do **not** gate on `rb_data->has_normal_roughness()`. It is backed by
  `global_surface_data.normal_texture_used`, a sticky global that is set once
  (`render_forward_clustered.h:682`, `:4190`) and never reset — so the texture can exist
  with nothing ever rendered into it.
* The contents are view-space, best-fit-24 encoded into 8 bits, with a dynamic/static flag
  folded around 0.5 in the roughness channel
  (`scene_forward_clustered.glsl:3090-3097`). It must be decoded, not read raw.
* **Reflection probe renders take the `is_reflection_probe` branch with no `rb_data`** —
  the RT pass must skip them entirely.

So the concrete work is: add `using_rt_shadows` to the `depth_pass_mode` upgrade chain and
to `finish_depth`; either force `depth_pre_pass` on when RT shadows are enabled (mirroring
`force_depth_pre_pass = scene_state.used_opaque_stencil` at `:2125`) or disable RT shadows
when the prepass is off (mirroring `using_ssao = depth_pre_pass && ...` at `:2131`).

Given the encoding loss, reconstructing a geometric normal from depth derivatives inside
the RT shader is a legitimate alternative to depending on `normal_roughness` at all — and
it is the cheaper starting point for Phase 1.

Dispatch position within `_pre_opaque_render` matters too: after `update_light_buffers`
(`:1680`), because earlier the light indices do not exist, and before `:2213`, because
later the render-pass uniform set is already built.

### 1.7 Mesh geometry — the one real blocker

Godot stores vertex positions in a **contiguous block at the start of the vertex
buffer**, with normals/tangents in a second region after it
(`mesh_storage.cpp:1507`: `offset = i == ARRAY_NORMAL ? position_stride * s->vertex_count : 0`).
Position format depends on compression (`mesh_storage.cpp:1340-1355`):

| Case | Format | Stride | Legal as BLAS input? |
|---|---|---|---|
| Uncompressed 3D | `R32G32B32_SFLOAT` | 12 | **Yes — zero-copy** |
| Compressed 3D (`ARRAY_FLAG_COMPRESS_ATTRIBUTES`) | `R16G16B16A16_UNORM` | 8 | **No** |
| 2D vertices | `R32G32_SFLOAT` | 8 | N/A (not 3D geometry) |

Vulkan's legal acceleration-structure vertex formats are `SFLOAT` and `SNORM` variants
only. **`UNORM` is not among them, in any width.** And compression is the *default* for
glTF, Collada and OBJ imports (`gltf_document.cpp:1454`,
`editor_import_collada.cpp:915`, `resource_importer_obj.cpp:412`).

So the majority of static scene geometry in a real project cannot be handed to
`blas_create()` as-is. Section 4.2 covers the fix.

### 1.8 Deforming meshes — better than expected

`MeshStorage::MeshInstance::Surface` (`mesh_storage.h:188-197`):

```cpp
struct Surface {
    RID      vertex_buffer[2];      // double-buffered: current + previous
    RID      uniform_set[2];
    uint32_t current_buffer  = 0;
    uint32_t previous_buffer = 0;
    uint64_t last_change     = 0;
    ...
};
```

Godot performs skinning **and** blend shapes in a compute pre-pass (`skeleton.glsl`,
driven by `MeshStorage::update_mesh_instances()`, `mesh_storage.cpp:1179-1294`) that
writes deformed vertices into that persistent buffer. Two consequences:

* **The deformed geometry we need for character shadows already exists in GPU memory.**
  We point a BLAS at `vertex_buffer[current_buffer]` and refit it.
* The buffer is **double-buffered for motion vectors** — so previous-frame deformed
  positions are also available, which is what NRD and DLSS Ray Reconstruction need for
  correct temporal reprojection of animated geometry.

And crucially, the format problem from §1.7 **does not apply here**. The deformed-buffer
vertex format is generated with `p_instanced_surface = true`, which bypasses the
compression branch entirely (`mesh_storage.cpp:1347`) — deformed positions are always
`R32G32B32_SFLOAT`. Independently, Godot's importers already force compression off for
any mesh with joints or morph targets (`gltf_document.cpp:1812-1813`):

```cpp
if (p_state->force_disable_compression || is_mesh_2d || !a.has("POSITION") ||
    !a.has("NORMAL") || mesh_prim.has("targets") ||
    (a.has("JOINTS_0") || a.has("JOINTS_1"))) {
    flags &= ~RSE::ARRAY_FLAG_COMPRESS_ATTRIBUTES;
}
```

Two small changes are needed: the deformed buffer is currently created with only
`BUFFER_CREATION_AS_STORAGE_BIT` (`mesh_storage.cpp:1094`) and must also carry
`BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT`; and we need the
`blas_update()` refit entry point from §1.1.

**Hazard — this one is important.** `update_mesh_instances()` is only invoked for
instances that survived frustum culling or that were gathered for a shadow-map pass
(`renderer_scene_cull.cpp:3473-3475`, and :2445/:2528). An off-screen character would
therefore have a *stale* deformed vertex buffer, and would cast a frozen, wrong shadow
— exactly the failure your "no frustum culling" requirement is meant to prevent. The RT
caster set must therefore also drive `mesh_instance_check_for_update()`. Section 4.4
handles this.

### 1.9 Enumerating casters without frustum culling

`RendererSceneCull::Scenario` holds (`renderer_scene_cull.h:328-334`):

```cpp
enum IndexerType { INDEXER_GEOMETRY, INDEXER_VOLUMES, INDEXER_MAX };
DynamicBVH indexers[INDEXER_MAX];
```

`DynamicBVH` provides `aabb_query(const AABB &, QueryResult &)`
(`core/math/dynamic_bvh.h:315`). `INDEXER_GEOMETRY` contains **every geometry instance
in the scenario**, independent of the camera frustum.

This is exactly the enumeration source we need, and it is existing, well-tested code
used by the culling system every frame. Querying it with a box around the camera gives
us every caster a light can reach, on-screen or not. Under the revised design (§4.4) the
query is driven by each light's influence volume rather than by a camera radius.

Also relevant: `light_get_shadow_caster_mask()` is already respected during shadow
caster gathering (`renderer_scene_cull.cpp:2430`), alongside `layer_mask` and the
geometry's `can_cast_shadows` flag. The RT path must honor the same three, which maps
naturally onto the 8-bit TLAS instance `mask`.

### 1.10 Debug draw modes and editor plumbing

Adding a viewport debug mode is a mechanical 8-file change. Tracing
`DEBUG_DRAW_MOTION_VECTORS`:

| # | File | What |
|---|---|---|
| 1 | `servers/rendering/rendering_server_enums.h:595` | `VIEWPORT_DEBUG_DRAW_*` enum |
| 2 | `servers/rendering/rendering_server.cpp:3016` | `BIND_ENUM_CONSTANT` |
| 3 | `scene/main/viewport.h:186` | `Viewport::DebugDraw` enum |
| 4 | `scene/main/viewport.cpp:5515` | `BIND_ENUM_CONSTANT` |
| 5 | `editor/scene/3d/node_3d_editor_viewport.cpp:4707` | View-menu entry |
| 6 | `servers/rendering/renderer_rd/renderer_scene_render_rd.cpp:1028,1151` | Render handling |
| 7 | `servers/rendering/renderer_viewport.cpp:1124` | Buffer requirements |
| 8 | `doc/classes/Viewport.xml`, `doc/classes/RenderingServer.xml` | Documentation |

`RendererRD::DebugEffects::draw_shadow_frustum()` already renders wireframe boxes from
line arrays over the final image — a direct template for drawing instance bounds.

### 1.11 Project settings and the editor viewport

The pattern, traced through `positional_shadow/atlas_size`:

* **Definition:** `GLOBAL_DEF(PropertyInfo(...), default)` in `scene/main/scene_tree.cpp:2163`,
  applied to the root viewport at startup.
* **Editor mirror:** `editor/scene/3d/node_3d_editor_viewport.cpp:3138` reads it back via
  `GLOBAL_GET` and applies it to the editor's own 3D viewport.
* **Docs:** `doc/classes/ProjectSettings.xml`, with `.mobile`-style per-platform overrides
  supported for free.

That editor mirror is precisely how RT shadows reach the editor viewport, and it is the
same mechanism the existing shadow settings already use. Your "must be visible in the
editor" requirement costs us one `GLOBAL_GET` call.

---

## 2. Architectural decisions

You asked me to make the calls. Here they are, with reasoning and the rejected
alternative. These are the decisions the rest of the document builds on.

### D1 — Inline ray query in a compute shader, not a ray-tracing pipeline

**Decision.** Trace shadow rays with `rayQueryEXT` from a dedicated compute shader that
writes a screen-space shadow mask. Do **not** use raygen/miss/closest-hit pipelines or
the shader binding table.

**Why.** Ray pipelines require SBT management, hit-group records per material, a second
shader-compilation path, and a whole parallel material system. Ray query needs none of
that: it is ordinary GLSL in an ordinary compute shader that Godot's existing build
system already compiles. For opaque-only shadow visibility we never need a hit shader —
we only need "did the ray hit anything before reaching the light", which
`rayQueryEXT` answers with `gl_RayQueryCommittedIntersectionNoneEXT` and the
`TERMINATE_ON_FIRST_HIT` flag. The SBT machinery in `RenderingDevice` stays unused for
now; it becomes relevant only if we later want alpha-tested shadows or RT reflections.

**Rejected.** Ray-tracing pipelines — strictly more work for strictly less benefit at
this scope, and they would force the material system into the design on day one.

### D2 — Screen-space shadow mask, not shadow terms inline in the forward shader

**Decision.** The RT pass runs before the opaque pass and writes an off-screen texture.
The forward shader samples that texture instead of the shadow atlas.

**Why.** The forward pass runs per-fragment with heavy register pressure and shades
overlapping geometry repeatedly; tracing rays there would be wasteful and would put an
acceleration-structure binding into the main scene uniform sets. A compute pass at
internal resolution traces exactly one visible sample per pixel, is trivially profilable
as its own timestamp, can be quality-scaled independently, and — decisively — produces
exactly the input a denoiser needs. Denoising *requires* a separable pass; inline
tracing forecloses NRD entirely.

**Rejected.** Inline `rayQueryEXT` in `scene_forward_lights_inc.glsl`. Simpler to
prototype, but incompatible with denoising, which is a stated goal.

### D3 — 8 denoised slots, plus inline ray tracing for overflow

**Decision.** Two `R8G8B8A8_UNORM` textures at internal resolution — **8 denoised
visibility slots per pixel** — with a per-pixel index table mapping slot to light. Any light
beyond the 8th affecting a pixel is traced **inline, in the forward shader**, with a
`rayQueryEXT` call in a `SHADER_GROUP_RAYTRACING` variant. **No pixel ever falls back to a
shadow map.**

**Why.** The budget is about per-pixel *overlap*, not total light count: a scene with 300
lights is fine as long as no pixel is reached by more than 8 shadow-casters. Eight covers
essentially all real content; the inline path exists so the ninth is still correct rather
than being a policy exception. The overflow rays are unfiltered and therefore noisier than
the denoised slots — but noisy RT is closer to correct than a shadow map, and it degrades in
the direction of the design's own goal.

**How the inline path compiles.** `ShaderRD` already supports conditional shader **groups**
with per-group SHA and per-group cache files (`shader_rd.h:64-66`, `:146`), used today for
`SHADER_GROUP_MULTIVIEW` and `SHADER_GROUP_ADVANCED`. Add `SHADER_GROUP_RAYTRACING`, enabled
via `shader.enable_group()` only when the project setting is on. `scene_forward_clustered.glsl`
bumps to `#version 460` — harmless for existing variants, since 460 is a superset of
everything Godot uses — and the ray-query code sits behind an `#ifdef` so
`OpCapability RayQueryKHR` is emitted **only** in the RT group's variants. Projects with RT
off never compile a ray-query shader.

**Rejected.** Four slots (too tight once every local light casts); one texture per light
(unbounded VRAM); a 1-bit mask (undenoisable); a variable per-tile list (scales better in
theory, but is materially harder to denoise, and 8-plus-inline already removes the hard cap).

**Cost.** 8 bytes/pixel of mask. At 1440p internal that is ~29 MB, plus hit-distance and
denoiser history buffers.

### D4 — Specialization constant, not a shader variant

**Decision.** `sc_use_rt_shadows()` on a free bit of `sc_packed_1`.

**Why.** §1.5: zero new variants, works in ubershader mode, no compile-time or stutter
regression. When the bit is clear, the compiler removes the RT branch entirely and the
shader is byte-for-byte the behavior you have today.

### D5 — TLAS instances come from the scenario geometry index, not the render list

**Decision.** Source casters from `Scenario::indexers[INDEXER_GEOMETRY].aabb_query()`
with the influence bounds of each RT-shadowing light (§4.4) — not a camera-centred radius.

**Why.** The render list is frustum-culled; using it would break your explicit
requirement that walls behind the player still cast shadows. The geometry indexer is
not frustum-culled, is maintained every frame anyway, and supports exactly the spatial
query we want. This is reuse, not new infrastructure.

**Where the code lives matters.** `Scenario`, `Instance` and `DynamicBVH` are **not
reachable from `forward_clustered`** — the renderer only sees `RenderGeometryInstance*`.
The TLAS instance list must therefore be built in `RendererSceneCull` and passed down
through a new `render_scene` parameter, mirroring how `RenderShadowData::instances` already
works. Reuse the existing per-instance shadow-caster filter verbatim
(`renderer_scene_cull.cpp:2584`: visible, geometry mask, `can_cast_shadows`,
`layer_mask & light_get_shadow_caster_mask`, inactive-particle rejection) rather than
inventing a parallel one.

Two API notes: do **not** use the public `RenderingServer::instances_cull_aabb` — it returns
`ObjectID`s rather than instances, silently skips instances with a null object id, and is
marshaled through the RS command queue. Use the internal `DynamicBVH::aabb_query` with a
collecting functor, copying the `instance_shadow_cull_result` pattern at `cpp:2406-2419`.
And note BVH AABBs are motion-quantised and expanded for moving objects (`cpp:1746-1757`),
so a region query returns a conservative superset — fine for a TLAS, but do not assume tight
bounds.

**Rejected.** A second parallel scene structure maintained by the RT system — duplicated
state, duplicated bugs, and a new class of "why is this object's shadow wrong"
failure that would be invisible to the user. Also rejected: sourcing from the forward render
list, which loses not only off-screen casters but occlusion-culled casters,
visibility-range-faded casters, and **all `SHADOWS_ONLY` geometry even when fully on
screen** (`cpp:2990`).

### D6 — A dedicated RT position buffer, built lazily, shared across instances

**Decision.** Introduce a per-*surface* (not per-instance) `float32x3` position buffer
used solely as BLAS input. Populate it three ways depending on the source:

| Source geometry | How the RT position buffer is produced | Cost |
|---|---|---|
| Uncompressed static | **Not created** — alias the existing vertex buffer at offset 0, stride 12 | Zero |
| Compressed static | One-time dequantise compute dispatch | 12 B/vertex, once |
| Skinned / morphed | Alias `MeshInstance::Surface::vertex_buffer[current]` | Zero |

**Why.** This is the minimum-surface-area answer to §1.7 that does not change how meshes
import, does not increase memory for meshes that do not need it, and does not touch the
raster path at all. Because it is keyed per surface, a thousand instances of one rock
mesh share one buffer and one BLAS.

**Rejected.** Forcing `ARRAY_FLAG_COMPRESS_ATTRIBUTES` off globally — this would silently
increase every project's mesh memory and change import output, which is exactly the kind
of "workflow change" you asked to avoid. Also rejected: decoding via the BLAS
`transformData` matrix — the `UNORM` *format* is illegal regardless of any transform.

### D7 — NRD SIGMA for denoising, with a hand-rolled fallback shipped first

**Decision.** Phase 3 ships a purpose-built spatiotemporal shadow denoiser written in
Godot's own GLSL. Phase 5 evaluates replacing it with NRD's **SIGMA** denoiser
specifically (NRD's shadow-dedicated denoiser), not the general ReBLUR/ReLAX path.

**Why.** NRD is open source and technically portable, but its shaders are HLSL and its
integration layer assumes a native resource-binding model. Godot has no
precompiled-SPIR-V ingestion path, so adopting NRD means either porting its shaders or
building that path — a substantial project in its own right, and one that would block
shipping *any* working shadows. A shadow-only denoiser is a well-understood problem
(shadow visibility is a scalar in [0,1] with known temporal behavior) and Godot's
compute infrastructure is entirely adequate for it. Shipping our own first means
Phase 3 is usable; NRD then becomes a quality upgrade rather than a prerequisite.

**Rejected.** NRD as a hard dependency of the first working version — it would put a
large, uncertain porting task on the critical path of a feature that can work without it.

### D8 — `Light3D.shadow_mode`: AUTO / OFF / SHADOW_MAP / RT_ONLY

**Decision.** Replace the first draft's separate `rt_shadow_mode` property with a single
shadow-casting mode on `Light3D`, superseding the `shadow_enabled` bool:

| Value | Meaning |
|---|---|
| `AUTO` | Serialization default. Resolves from the legacy `shadow_enabled` bool (below) |
| `OFF` | No shadows, ever |
| `SHADOW_MAP` | Classic shadow map. The only mode directional lights use today |
| `RT_ONLY` | **Raytraced shadows only.** If RT is unavailable or disabled, this light casts *no* shadow — it never falls back to a shadow map |

`RT_ONLY` is self-describing, and that is the point: it encodes your requirement that the
setting must not carry over when RT shadows are switched off. A project with RT disabled
shows lights with no shadows, which is loud and obvious, rather than silently reverting to
shadow-map behavior you did not ask for.

**Newly created non-directional lights get `RT_ONLY` in the constructor** when the project
setting is on — so a light dragged into the scene, instanced from a `PackedScene`, or created
with `OmniLight3D.new()` all cast RT shadows with no further action. Directional lights get
`SHADOW_MAP`.

**Why `AUTO` exists, and why it is not redundant.** This is the subtle part, and getting it
wrong silently changes how existing scenes render.

Godot's scene serializer only writes properties that differ from their C++ default.
`Light3D::shadow` defaults to `false` (`scene/3d/light_3d.h:73`), so an existing `.tscn`
contains `shadow = true` for shadow-casting lights and **nothing at all** for the rest. There
is no stored value distinguishing "deliberately off" from "never touched".

So a new `shadow_mode` property whose default is `RT_ONLY` would turn on shadows for every
light in every existing scene — including ones deliberately left dark. And a default of `OFF`
would mean newly created lights need their mode set by some other mechanism, which
deserialization would then overwrite.

`AUTO` resolves both. It is the serialization default, so old scenes carry it implicitly, and
it resolves at load from the legacy bool:

```
AUTO + shadow_enabled == true   ->  RT_ONLY      (auto-upgrade, your choice)
AUTO + shadow_enabled == false  ->  OFF          (stays dark, as authored)
```

New lights write `shadow_mode = RT_ONLY` explicitly, so it is a real stored value rather than
an inherited default and survives any future change to what `AUTO` means.

**Consequence, stated plainly.** With the project setting on, every light in your existing
scenes that already cast shadows switches to RT. Lights you left dark stay dark. That is the
auto-upgrade behavior you asked for, and it *is* a visible change to existing scenes — which
is correct here, because it is the entire point of the feature.

**Rejected.** Flipping the default of `shadow_enabled` — it would make the meaning of every
`.tscn` depend on a project setting, so scene files would stop being portable between
projects. A separate parallel `rt_shadow_mode` property (the first draft's answer) — two
properties governing one behavior is worse UX than one property with four values, and it
made "RT off means no shadows" awkward to express.

### D8b — Raise the default `light_size`; keep 0 meaning "point light"

**Decision.** Change the constructor default `set_param(PARAM_SIZE, ...)` from `0` to
**`0.05`** (5 cm) for `OmniLight3D` and `SpotLight3D`. `AreaLight3D` keeps its existing
`0.5`. `light_size` remains a pure physical quantity — the emitter radius in meters — and
`0` continues to mean an ideal point light, and therefore hard shadows.

There is **no** `rt_hard_shadows` property. Hard shadows are expressed the way they always
were: set the radius to zero.

**Why not "0 means automatic softness".** An earlier draft reinterpreted `light_size == 0` as
"derive a sensible softness from the light's range". That was wrong on four counts, and it is
recorded here because it is a tempting mistake:

* `0` is not a missing value — it is a meaningful one. Overloading it as a sentinel destroys
  the ability to express a true point light.
* Recovering that meaning then required a *second* property (`rt_hard_shadows`). Two
  properties to express one concept is a design smell.
* It made RT and raster disagree about the same value: `light_size = 0` would give hard
  shadows with RT off and soft shadows with RT on.
* Range is physically unrelated to emitter size. A 5 cm bulb in a warehouse has a tiny radius
  and a huge range, so deriving softness from range is a guess, not physics.

Raising the default achieves the same goal — realistic softness with no configuration — while
keeping one property with one meaning, visible and tunable in the inspector.

**What this changes in existing scenes.** `0` was the old default, so no existing `.tscn`
serializes `light_size`; every existing light therefore picks up the new default. Two visible
effects, both intended under the revised philosophy:

* Shadows soften. Under RT this is the point. Under the raster path it also softens PCSS.
* **Specular highlights widen.** `light_size` is passed as the area term `A` into
  `light_compute()` (`scene_forward_lights_inc.glsl:732`, `:934`), where it drives the
  spherical-area-light approximation. This is a *lighting* change, not only a shadow change.
  It is arguably a correctness fix — a light with a real emitter radius should have a broader
  highlight — and it is gated behind the same `sc_use_light_soft_shadows()` constant that
  gates soft shadows, so it does not apply at the lowest quality setting.

**Why 0.05 and not larger.** Emitter radius is directly a **noise budget** for RT. The cone
sample in §5.1 spreads over a solid angle proportional to `light_size / distance`, so a larger
radius means higher variance at one sample per pixel and more work for the denoiser. A radius
of `0` is free — a single deterministic ray with zero variance. 5 cm gives shadows that are
sharp within 10–20 cm of contact and visibly soften over a couple of meters, which reads as
realistic without being expensive or mushy. Treat it as a tuning value, not a constant of
nature.

**Contact hardening is not a separate feature.** It falls out of the cone sampling: the
penumbra widens with distance from the blocker because the ray cone does, and the denoiser
uses hit distance to filter at the matching width. This is the single most visible quality
difference over shadow maps, which is why it is on by default rather than being a knob.

**Upstream note.** A changed constructor default is a divergence from upstream Godot and will
show up as a behavioral difference if this fork ever merges or is compared against it. It is
one line, and it is deliberate.

### D9 — RT is required; there is no shadow-map fallback for local lights

**Decision.** Replaces the three-level fallback of the first draft.

1. **No hardware RT** → the project setting cannot be enabled. The startup probe (§8.1d)
   reports a clear, actionable message rather than silently downgrading. This is a hardware
   requirement of the game, like any other.
2. **More than 8 shadow-casting lights on a pixel** → overflow lights are traced inline
   (D3). Never a shadow map.
3. **Ineligible geometry** (non-triangle, alpha-tested, particles, `ImmediateMesh`) → that
   geometry casts **no shadow**, is listed in the debug view, does not demote its light, and
   does not resurrect a shadow map.

**Why.** Each of these was previously justified by protecting a fallback path. With the
fallback gone they collapse into one rule — RT or nothing — which is simpler to implement,
simpler to reason about, and removes the dual-path testing burden that would otherwise have
doubled the QA surface for the life of the feature.

**The cost of item 3, stated plainly.** Alpha-tested foliage and particles cast no shadow at
all. In an outdoor scene with grass or foliage cards this is visible. Three paths out, in
increasing order of effort, none of which reintroduces a shadow map:

* **Screen-space contact shadows** — a short screen-space ray-march (the technique Bend
  Studios used in *Days Gone*) covering exactly the small, near-field detail alpha geometry
  provides. Composes cleanly: RT handles inter-object shadowing, the march fills in grass and
  foliage contact. Cheapest fill-in; planned as a Phase 4 item.
* **Geometry-based foliage** — sidesteps the problem entirely by making foliage real
  triangles, which are BVH-eligible. A content decision rather than an engine one.
* **Any-hit alpha testing** — the proper fix. Requires either a raytracing pipeline with hit
  groups or ray-query candidate handling, plus material and texture binding inside the ray
  path. This is the one item that would pull the material system into the RT design, which is
  why it is sequenced last rather than first.

### D10 — DLSS Super Resolution is Phase 6, and needs engine plumbing first

**Decision.** Not attempted before Phase 6, and explicitly gated on adding native
command-buffer access to `RenderingDevice`. See §8.3 for the full analysis.

---

## 3. System overview

One new subsystem, one new render pass, and small edits to existing code.

```
                      ┌─────────────────────────────────────────┐
                      │ RendererSceneCull  (existing)           │
                      │  Scenario::indexers[INDEXER_GEOMETRY]   │
                      └───────────────────┬─────────────────────┘
                                          │ aabb_query(camera box)
                                          ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │ RaytracingSceneRD                             ** NEW **          │
   │                                                                  │
   │  BLAS cache      surface -> { RID blas, RT position buffer,      │
   │  (per surface)                 state, last_used_frame }          │
   │                                                                  │
   │  Residency       build / refit / evict against a VRAM budget     │
   │  TLAS            rebuilt each frame from the resident set        │
   │  Instance map    TLAS instance id -> Godot instance (debug view) │
   └───────────────────────────────┬──────────────────────────────────┘
                                   │ TLAS RID + per-light data
                                   ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │ RaytracedShadows (compute)                    ** NEW **          │
   │   in:  depth, normal_roughness, TLAS, light list, blue noise     │
   │   out: shadow mask (RGBA8) + per-pixel light index table         │
   │        + hit-distance buffer (for the denoiser)                  │
   └───────────────────────────────┬──────────────────────────────────┘
                                   ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │ ShadowDenoiser (compute)                      ** NEW **          │
   │   temporal reprojection + variance-guided spatial filter         │
   └───────────────────────────────┬──────────────────────────────────┘
                                   ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │ scene_forward_lights_inc.glsl                 ** EDITED **       │
   │   if (sc_use_rt_shadows() && light has an RT channel)            │
   │       shadow = texelFetch(rt_shadow_mask, ...)[channel];         │
   │   else                                                           │
   │       <existing shadow-atlas path, unchanged>                    │
   └──────────────────────────────────────────────────────────────────┘
```

### Frame timeline

Additions marked `NEW`. Nothing existing is reordered.

```
  RendererSceneCull::_render_scene
    ├─ gather visible instances                          (existing)
    ├─ NEW  gather RT caster set (non-frustum-culled)
    ├─ NEW  mesh_instance_check_for_update() on RT set     <-- fixes §1.8 hazard
    ├─ update_mesh_instances()   [skinning compute]      (existing)
    └─ RenderForwardClustered::_render_scene
         ├─ NEW  RaytracingSceneRD::update()
         │        ├─ build/refit dirty BLASes
         │        └─ tlas_build(instances)
         ├─ Render Depth Pre-Pass                        (existing)
         ├─ Resolve Depth Pre-Pass (MSAA)                (existing)
         ├─ _pre_opaque_render()                         (existing)
         │    ├─ shadow-map passes (RT-shadowed lights skipped)
         │    ├─ NEW  RaytracedShadows::render()
         │    ├─ NEW  ShadowDenoiser::process()
         │    ├─ SSAO / SSIL / GI / volumetric fog       (existing)
         │    └─ ...
         └─ Render Opaque Pass                           (existing, reads mask)
```

Two constraints fix that placement. First, `blas_build()`/`tlas_build()` **hard-fail if
any draw, compute or raytracing list is active** (`rendering_device.cpp:448-450`,
`:469-471`), so the acceleration-structure update cannot live inside
`_pre_opaque_render()` alongside the compute effects — it must run before the frame's
lists open. Second, Godot's render graph assigns acceleration-structure builds priority 6
and raytracing lists priority 7 in its `PriorityTable` (`rendering_device_graph.cpp:2680`),
the two highest values, which means RT work is deliberately batched *late* in command
recording regardless of where we issue it. So we should not assume the build overlaps the
depth pre-pass; the realistic expectation is that AS builds and the ray dispatch land
adjacent to each other. This is a reason to keep per-frame build work small and budgeted
(§4.5) rather than to rely on driver overlap.

### New files

```
servers/rendering/renderer_rd/environment/raytracing_scene.h/.cpp     BLAS/TLAS manager
servers/rendering/renderer_rd/effects/raytraced_shadows.h/.cpp        RT shadow pass
servers/rendering/renderer_rd/effects/shadow_denoiser.h/.cpp          denoiser
servers/rendering/renderer_rd/shaders/effects/rt_shadows.glsl         ray query
servers/rendering/renderer_rd/shaders/effects/rt_shadow_denoise.glsl  denoiser
servers/rendering/renderer_rd/shaders/effects/rt_dequantize_pos.glsl  §D6 conversion
servers/rendering/renderer_rd/shaders/effects/rt_debug_bvh.glsl       debug view
```

### Modified files

| File | Change | Risk |
|---|---|---|
| `storage_rd/mesh_storage.cpp/.h` | RT position buffer; AS-input usage bit on deformed buffers | Low |
| `renderer_scene_cull.cpp/.h` | RT caster gathering; skinning for off-screen casters | **Medium** |
| `forward_clustered/render_forward_clustered.cpp` | Invoke RT passes in `_pre_opaque_render` | Low |
| `shaders/scene_forward_lights_inc.glsl` | Sample mask instead of atlas | **Medium** |
| `shaders/light_data_inc.glsl` | Use `pad[2]` for RT channel + flags | Low |
| `shaders/forward_clustered/scene_forward_clustered_inc.glsl` | `sc_use_rt_shadows()` | Low |
| `storage_rd/light_storage.cpp/.h` | Per-light RT state; skip atlas alloc for RT lights | **Medium** |
| `scene/3d/light_3d.cpp/.h` | `rt_shadow_mode` property | Low |
| `servers/rendering/rendering_device.cpp/.h`, Vulkan driver | `blas_update()` refit | Low |
| `scene/main/scene_tree.cpp` | Project settings | Low |
| Debug-view files (§1.10, 8 files) | New debug draw mode | Low |
| `doc/classes/*.xml` | Documentation | Low |

The two "medium" shader/storage risks are the places where an existing, working code
path is being conditionally bypassed. They need the most careful review, and they are
the reason Phase 1 ships behind a default-off setting.

---

## 4. The acceleration structure system

This is the heart of the feature and the part you specifically asked to be invisible.

### 4.1 BLAS cache — keyed per surface, not per instance

Each `Mesh` surface that participates in raytracing gets **one** BLAS, shared by every
instance of that mesh. A forest of 5,000 trees built from 4 meshes is 4 BLASes and 5,000
TLAS instances — the TLAS instance is 64 bytes, so that scene costs ~320 KB of instance
data plus 4 BLASes.

```cpp
struct BlasEntry {
    RID      blas;
    RID      rt_position_buffer;   // null if aliasing the source buffer (§D6)
    uint32_t vertex_count, index_count;
    uint64_t last_used_frame;
    uint32_t vram_bytes;
    enum State { UNBUILT, QUEUED, READY, INELIGIBLE } state;
    bool     is_dynamic;           // skinned/morphed -> refit each frame
};
```

Eligibility is decided once, at first sight of the surface:

* Primitive type must be `PRIMITIVE_TRIANGLES` (points, lines and strips are skipped —
  they cannot be raytraced geometry and they do not sensibly cast shadows anyway).
* Vertex count > 0, and the surface must have a position stream.
* If compressed, a dequantised buffer is scheduled (§D6).

Anything ineligible is marked `INELIGIBLE` once and never re-examined. It continues to
render and to cast shadow-map shadows exactly as today.

### 4.2 Handling compressed vertices

The one genuine blocker from §1.7. A compute shader
(`rt_dequantize_pos.glsl`) reads the `R16G16B16A16_UNORM` position block and writes
`float32x3`, applying the per-surface AABB decode that the vertex shader applies today
(the same `vertex_scale`/`vertex_offset` the raster path already uses, so the geometry
is bit-comparable to what you see on screen).

* Runs **once per surface**, not per frame, not per instance.
* Amortized across all instances of the mesh.
* Cost: 12 bytes per vertex. A 50,000-vertex mesh costs 600 KB.
* Dispatched in batches during the RT update, budgeted (§4.5) so a level load does not
  produce a single enormous stall.

For an uncompressed mesh, no buffer is allocated at all — the BLAS points directly at
the existing vertex buffer at offset 0 with stride 12.

One change is required on the mesh side: buffers used as BLAS input must be created with
**both** `BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT` **and**
`BUFFER_CREATION_DEVICE_ADDRESS_BIT`. The second is easy to forget and fails badly:
`blas_create()` performs no usage-flag validation, but the Vulkan driver calls
`buffer_get_device_address()` on the vertex and index buffers unconditionally
(`rendering_device_driver_vulkan.cpp:6355`, `:6364`), and the driver-level version of that
call omits the flag check that the RD-level one has. A missing bit therefore produces a
bad address rather than a clean error. For newly-created RT position buffers this is free.
For *aliased* buffers (uncompressed static meshes and deformed buffers) both flags must be
added at creation. Since we do not know at mesh-creation
time whether a mesh will participate in raytracing, the pragmatic choice is:

> When the RT shadows project setting is enabled, add the AS-input usage bit to mesh
> vertex buffers and deformed vertex buffers at creation time.

The bit is essentially free on desktop drivers (it does not change allocation size or
layout), and gating it on the project setting means projects that never enable RT
shadows are byte-for-byte unaffected.

### 4.3 TLAS — rebuilt every frame

Full rebuild, every frame, from the resident set. This is not merely convenient — it is
**required**. `blas_build()` calls `_blas_remove_tlas_dependencies()`, which sets
`invalidated = true` on every TLAS referencing that BLAS and severs the link
(`rendering_device.cpp:461`). Since we refit dynamic character BLASes every frame, the
TLAS is invalidated every frame by construction. There is also no partial-update or
instance-buffer API: `tlas_build(RID, Span<AccelerationStructureInstance>)` is the only
way to populate a TLAS, and it CPU-writes the whole array.

The cost is acceptable: TLAS builds over a few thousand instances are sub-millisecond on
any GPU that supports raytracing, and `RenderingDevice` already maintains a ring of
persistently-mapped instance buffers for exactly this pattern. A full rebuild also
sidesteps an entire category of incremental-update bugs — stale instances, mismatched
indices, transforms that lag by a frame.

Two implementation constraints follow from how that ring works
(`rendering_device.cpp:486-523`). Each ring entry is `instance_size * max_instance_count`
bytes and is **never shrunk**, so `max_instance_count` must be chosen deliberately — at
our 65,536 default that is ~4 MB per entry, a few times over. And calling `tlas_build()`
more than once per frame allocates an additional full-size entry, so **the TLAS must be
built exactly once per frame**.

`max_instance_count` is also **frozen at `tlas_create()`** (`rendering_device.cpp:436`) and
exceeding it is a hard failure (`:475`). Growth therefore means destroying and recreating
the TLAS, which invalidates any uniform set holding it. The policy: size generously at
creation, and on overflow drop the lowest-priority instances for that frame while
scheduling a TLAS recreate for the next — never fail the build.

**One quirk to plan for.** `tlas_build()` rejects any instance whose `hit_sbt_range` is
zero (`rendering_device.cpp:543`), even though a ray-query-only path has no shader binding
table at all. The range is encoded as `(count << 32) | offset`, so passing a synthetic
`(offset = 0, count = 1)` — the literal `0x1_0000_0000` — satisfies the check and writes
`instanceShaderBindingTableRecordOffset = 0`, which ray query never reads. No raytracing
pipeline, no SBT, and no engine patch required. Without this the design would need a dummy
ray pipeline purely to pass validation.

**Scratch memory is not pooled.** `_acceleration_structure_scratch_buffer_create()`
(`rendering_device.cpp:252-275`) allocates a scratch buffer *per acceleration structure*
and keeps it alive. N BLASes therefore means N permanent scratch allocations on top of the
BLASes themselves. Static builds must release scratch immediately after building; only
deformed entries, which rebuild every frame, should retain it.

Per-instance fields are filled as:

| Field | Source |
|---|---|
| `transform` | `Instance::transform` |
| `id` | index into a parallel instance table (used by the debug view) |
| `mask` | derived from `layer_mask`, `shadow_caster_mask`, `cast_shadows` |
| `flags` | `TRIANGLE_FACING_CULL_DISABLE` for double-sided; `TRIANGLE_FLIP_FACING` for negative-determinant transforms |
| `blas` | from the BLAS cache |

**Facing: disable triangle culling on every instance, unconditionally.**
Vulkan flips triangle facing for TLAS instances with a negative-determinant transform, and
a mirrored prop (`scale.x = -1`) is extremely common. The raster shadow pass compensates
through `flip_cull`, driven both by the dual-paraboloid flip *and* by
`light_get_reverse_cull_face_mode` (`render_forward_clustered.cpp:2866-2877`).

That per-light compensation is **structurally impossible** to reproduce in RT:
`shadow_reverse_cull_face` is a per-light property, but the TLAS is per-scenario and shared
by every light. There is no per-light BLAS.

The only answer that survives negative scale, per-light reverse-cull and a shared TLAS
simultaneously is to set `ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT`
on **every** instance. Shadow rays do not need facing — an occluder occludes from either
side. Consequences to write down: the `DOUBLE_SIDED → CULL_DISABLE` mapping becomes a
no-op and should not be implemented, and `shadow_reverse_cull_face` becomes a documented
no-op for RT-shadowed lights.

**`SHADOWS_ONLY` and `SHADOWS_OFF`** map naturally: `SHADOWS_OFF` geometry is excluded
from the TLAS; `SHADOWS_ONLY` geometry is included in the TLAS but excluded from the
render list, exactly as it is today. Note that `SHADOWS_ONLY` geometry is *absent* from the
forward render list by construction (`renderer_scene_cull.cpp:2990`) — one more reason the
TLAS cannot be sourced from it.

**Ray flags and geometry opacity.** Set `ACCELERATION_STRUCTURE_GEOMETRY_OPAQUE_BIT` on
every geometry and trace with
`gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT`.
If geometry is not marked opaque, `rayQueryEXT` yields *candidate* intersections that the
shader must confirm in a proceed loop; the naive single-`Proceed`-then-check-committed
pattern then returns **no hit at all**, i.e. no shadows anywhere. That failure reads
exactly like "residency is broken" and will cost days to diagnose.

**Instance mask is 8 bits; Godot's layer masks are 32.** `VkAccelerationStructureInstanceKHR::mask`
is 8-bit, so the 32-bit `layer_mask & shadow_caster_mask` test cannot be represented
exactly. Fold groups of four layers into each mask bit with an OR — conservative in the
safe direction (an extra caster, never a missing one). A project using layers 9-32 for
shadow-caster filtering will see RT and raster disagree about which objects cast. There is
no fix short of extending the mask semantics, which Vulkan does not permit. Document it on
the property and surface it in the debug view.

### 4.4 Residency — driven by light volumes, not camera distance

The first draft kept a 64 m radius around the camera. That is deleted. **Residency follows
the lights.**

> A caster is resident if its bounds intersect the influence volume of any RT-shadowing
> light. A light keeps its casters resident for as long as the light exists in the scenario.

There is no `rt_shadow_distance` setting. A light 300 m away lighting a room you can see
across a valley shadows that room correctly, because its own range — not the camera — decides
what it needs. Casters leave the acceleration structure when the last light that reaches them
is removed from the scene, and at no other time.

Each frame:

1. For every light in the scenario with `shadow_mode == RT_ONLY`, query
   `Scenario::indexers[INDEXER_GEOMETRY].aabb_query()` with the light's influence bounds.
   **No frustum culling** — this is what makes walls behind the player cast shadows.
2. Mark hit surfaces' BLAS entries used this frame; queue unbuilt ones.
3. **If the instance is skinned or morphed, call `mesh_instance_check_for_update()`.**
   Without this, off-screen characters cast frozen shadows. One line, and the single most
   important correctness detail in this section.
4. Refit dynamic BLASes whose pose advanced.
5. Evict entries no light has referenced for 120 frames.

**The one bounded relaxation, and it needs your sign-off.** Taken literally, "as long as the
light exists" means a light 10 km away in a streamed open world keeps its casters resident
forever, and a large level ends up fully resident. The obvious bound is to skip lights whose
influence volume lies entirely outside the camera's far distance — such a light contributes
nothing to any pixel, so its shadows cannot be observed.

That is a real bound and I recommend it, but it is a bound, and you asked not to lose shadows
to distance. It differs from the deleted 64 m radius in the way that matters: the test is
*"can this light affect anything on screen at all"*, not *"is this light near the camera"*.
A light at the far plane still shadows fully. If you would rather have no bound whatsoever,
say so — it costs only memory, and per §4.5 memory is now a diagnostic rather than a limit.

**Deforming meshes.** Skinned and morphed surfaces are marked `is_dynamic`. Their BLAS is
built once with `ALLOW_UPDATE | PREFER_FAST_BUILD` and thereafter **refitted** via the new
`blas_update()` — roughly an order of magnitude cheaper than a rebuild. Refit quality degrades
as the pose drifts from the build pose, so force a full rebuild every 60 frames or on an
AABB-growth heuristic. Unlike static meshes, a dynamic BLAS is per `MeshInstance`, not per
surface: each animated character has its own pose and therefore its own BLAS.

### 4.5 Budgets are diagnostics, not limits

The first draft capped work per frame and demoted lights when over budget. Demotion meant
shadow maps, which is now a defect, so **the caps are gone.**

Build everything the lights touch. Report cost prominently rather than hiding it:

| Reported in the debug view | Why it matters |
|---|---|
| BLAS count, triangles, estimated VRAM | The number you fix in content when it gets large |
| Builds and refits this frame | Spot a mesh churning every frame |
| Ray cost heatmap | Find the one over-tessellated mesh eating the frame |
| Oversized BLAS warnings | A 2 M-triangle merged level mesh is worth knowing about |
| Ineligible casters in range, by reason | The list of things silently not casting (§D9) |

Two mechanical safeguards remain, because they are about *smoothness*, not quality:
spread new builds across frames so a level load does not stall on one enormous batch, and
always build at least one item per frame regardless of size, so a single oversized mesh is
never starved.

**Build failure is still not an error to retry.** There is no acceleration-structure size
query at any level, and AS backing buffers bypass RD's `buffer_memory` accounting, so
`get_memory_usage()` under-reports and our bytes-per-triangle figure is an estimate. A failed
`blas_create` returns its entry to the queue at lowest priority and logs once. After N
consecutive failures, log a clear out-of-memory diagnostic — do not silently retry every
frame, and do not silently drop the geometry.

### 4.6 Ineligible geometry (the purity gate, deleted)

The first draft proposed a *purity gate*: a light with any ineligible caster in range would be
demoted to a shadow map, so nothing lost its shadow. That mechanism is **deleted**. It existed
solely to protect a shadow-map fallback, it was the single largest risk in the plan — it would
have fired on every GridMap and every scatter scene — and under the revised philosophy its own
remedy is the defect it was avoiding.

The replacement rule is blunt and predictable:

> Ineligible geometry casts no shadow. Its light is unaffected. Everything else in that
> light's volume gets a correct RT shadow.

Ineligible means: non-triangle primitives; `ARRAY_FLAG_USE_2D_VERTICES` and
`ARRAY_FLAG_USES_EMPTY_VERTEX_ARRAY` surfaces; alpha-tested and alpha-antialiased materials;
`GPUParticles3D`; `ImmediateMesh`. Every instance in this category is listed in the debug
view with its reason, so "why is that not casting" is one glance rather than an investigation.

**MultiMesh is emphatically not in that list.** GridMap is 100% MultiMesh
(`grid_map.cpp:769-812`) and scatter/foliage systems are too, so MultiMesh support is a
**Phase 2** requirement rather than a later nicety. Its transform data is already CPU-side for
`data_cache`-backed multimeshes and the layout is byte-identical to `VkTransformMatrixKHR`
(`mesh_storage.cpp:1928-1940`) — a memcpy plus one TLAS instance per element.

**CSG churn.** `modules/csg/csg_shape.cpp:606-638` calls `root_mesh.instantiate()` on every
`_update_shape`, so dragging a CSG node in the editor produces a **new mesh RID every frame**.
A BLAS cache keyed on mesh RID sees an unbounded stream of new keys, and churn heuristics
based on "mesh was cleared" never fire, because nothing is cleared. Key churn detection on
`instance_set_base` frequency per `Instance`, with a cap on new BLAS keys accepted from one
instance per second.

**LOD.** BLASes are built at LOD 0 and never re-selected, because camera-dependent LOD would
make residency flicker. The consequence: a distant object rasterized at LOD 3 casts a LOD 0
shadow, so its shadow silhouette will not match its outline. If that proves objectionable, the
mitigation is a *camera-independent* LOD chosen once at build time against the owning light's
radius and cached — never re-evaluated per frame.

## 5. Tracing and shading

### 5.1 The ray-tracing compute pass

`rt_shadows.glsl`, dispatched at internal resolution, one thread per pixel.

```glsl
#version 460                       // REQUIRED — rayQueryEXT is gated on >= 460
#extension GL_EXT_ray_query : enable

layout(set = 0, binding = 0) uniform accelerationStructureEXT tlas;
// depth, normal_roughness, light indices, blue noise, outputs...

void main() {
    float d = texelFetch(depth_buffer, ivec2(gl_GlobalInvocationID.xy), 0).r;
    if (d == 0.0) return;                       // sky: nothing to shadow

    vec3 world_pos = reconstruct_world_position(gl_GlobalInvocationID.xy, d);
    vec3 N         = decode_normal(...);

    // Offset along the geometric normal to avoid self-intersection.
    vec3 origin = world_pos + N * ray_bias(world_pos, N);

    vec4 visibility = vec4(1.0);
    for (uint c = 0u; c < active_light_count; c++) {
        LightRT L = rt_lights.data[c];

        vec3  to_light = L.position - world_pos;
        float dist     = length(to_light);
        if (dist > L.range) continue;

        vec3 dir = to_light / dist;
        if (dot(N, dir) <= 0.0) { visibility[c] = 0.0; continue; }  // back-facing

        // Cone-sample the light's radius for a soft, physically-plausible penumbra.
        dir = sample_light_cone(dir, L.size / dist, blue_noise(...));

        rayQueryEXT rq;
        rayQueryInitializeEXT(rq, tlas,
            gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT
              | gl_RayFlagsSkipClosestHitShaderEXT,
            L.cull_mask, origin, 0.001, dir, dist - 0.001);
        rayQueryProceedEXT(rq);

        bool hit = rayQueryGetIntersectionTypeEXT(rq, true)
                     != gl_RayQueryCommittedIntersectionNoneEXT;
        visibility[c]   = hit ? 0.0 : 1.0;
        hit_distance[c] = hit ? rayQueryGetIntersectionTEXT(rq, true) : dist;
    }
    imageStore(rt_shadow_mask, ivec2(gl_GlobalInvocationID.xy), visibility);
    // hit distance is written too — the denoiser needs it for penumbra-aware filtering
}
```

Points worth drawing out:

* `TERMINATE_ON_FIRST_HIT` + `OPAQUE` is the cheapest possible ray configuration. No hit
  shaders are invoked, no SBT is consulted. This is why D1 is such a large simplification.
* **One ray per light per pixel per frame.** Temporal accumulation in the denoiser
  supplies the rest of the quality. This is what makes the cost predictable.
* `sample_light_cone` with `Light3D.light_size` gives genuinely soft area-light shadows
  — sharp at contact, widening with distance. This is the visual payoff over shadow maps
  and it comes almost for free, because the ray direction is perturbed rather than the
  ray count increased.
* Blue-noise + a per-frame temporal offset makes the single-sample noise *denoisable*.
  White noise would not be.
* Ray bias scales with distance and grazing angle. Because we start from a
  reconstructed G-buffer position rather than an interpolated shadow-map depth, the bias
  needed is far smaller than shadow-map bias — which is the direct cause of peter-panning
  disappearing.

### 5.2 Light selection

Per frame, on the CPU: collect Omni/Spot lights whose `rt_shadow_mode` resolves to on,
sort by screen-space influence (a cheap projected-radius heuristic), and assign the top
four to mask channels. Lights past the budget keep their shadow map for that frame.

To avoid a light "popping" between RT and shadow-map appearance as the ranking shifts,
channel assignment is sticky: a light keeps its channel until it leaves the set entirely.

### 5.3 The forward shader edit

In `light_process_omni_light()` (and its spot equivalent), replacing the block at
`scene_forward_lights_inc.glsl:499`:

```glsl
half shadow = half(1.0);
if (sc_use_rt_shadows() && omni_lights.data[idx].rt_channel < 4u) {
    shadow = half(texelFetch(rt_shadow_mask, ivec2(gl_FragCoord.xy), 0)
                  [omni_lights.data[idx].rt_channel]);
    shadow = mix(half(1.0), shadow, half(omni_lights.data[idx].shadow_opacity));
} else if (omni_attenuation > HALF_FLT_MIN &&
           omni_lights.data[idx].shadow_opacity > 0.001) {
    // ... existing shadow-atlas path, character-for-character unchanged ...
}
```

`rt_channel` lives in the existing `float pad[2]` of `LightData` (§1.4), so the UBO
layout does not change. When `sc_use_rt_shadows()` is false the specialization constant
folds the branch away and the generated code is identical to today's.

Three delivery details, all verified:

* **`scene_forward_lights_inc.glsl` is `#include`d by `forward_mobile` as well as
  `forward_clustered`.** Every RT read must sit inside `#ifndef USING_MOBILE_RENDERER` or
  the mobile renderer breaks. This is the concrete reason "Mobile is untouched" holds.
* The mask binds as one new texture at `set = 1, binding = 37` — the first free binding in
  the render-pass uniform set — declared in both the `USE_MULTIVIEW` (`texture2DArray`) and
  mono (`texture2D`) branches. Model the C++ block byte-for-byte on the SSAO `ao_buffer`
  block at `render_forward_clustered.cpp:3647-3654`, defaulting to
  `DEFAULT_RD_TEXTURE_WHITE` (white = unshadowed) so the six `p_render_data == nullptr`
  call sites stay valid. No uniform-set restructuring is needed.
* `LightData` has exactly 8 free bytes and this design consumes all of them. Any future
  per-light RT field grows the struct from 224 to 240 bytes, which must be mirrored by hand
  across `light_storage.h` and `light_data_inc.glsl` — there is no `static_assert` tying
  them together today. **Add one as part of this work.**

**The shadow atlas keeps running, and the per-light toggle must never be implemented by
clearing `light->shadow`.** Three consumers read the atlas independently of the fragment
shader: volumetric fog reimplements the atlas UV math with its own exponential fade
(`volumetric_fog_process.glsl:499-523`), SDFGI/VoxelGI check `light_has_shadow()` and
raymarch, and the atlas is the fallback image any RT-to-raster cross-fade blends toward.
Clearing `light->shadow` would silently kill GI shadowing — a bug that would take months to
attribute to this feature.

So the honest framing of the first shipping milestone is **better quality at higher cost**:
we pay for both shadow maps and rays for the same lights. Cost recovery is a later phase and
is conditional — suppress atlas rendering only for a light that has been fully RT-engaged
for 30 consecutive frames with no pending BLAS builds, *and* only when volumetric fog is
disabled on that viewport, *and* only when no transmittance/SSS material is affected by it
(§5.4). Retain the atlas slot and its last-rendered contents even then, so a withdrawal
cross-fades into a stale-but-plausible image rather than popping.

There will be pressure to skip hardening and jump straight to cost recovery. It should be
resisted: correctness first, then the saving.

### 5.4 Preserving the shadow contract

The atlas path does more than return a visibility term, and every one of those behaviors
is a thing an existing project may already depend on. Enumerating them *before* writing the
shader removes an entire class of "why does this look wrong" bugs.

**Area lights are a first-class light type in this fork, and the plan must not ignore
them.** `RSE::LIGHT_AREA` has its own SSBO (`set = 0, binding = 5`), its own cluster element
type, its own shadow block (`scene_forward_lights_inc.glsl:1006-1126`), and its own atlas
allocation path. Critically, `AreaLight3D::AreaLight3D()` sets `PARAM_SIZE = 0.5`
(`scene/3d/light_3d.cpp:747`) — **every area light in every project has soft shadows on by
default.** Its composite site is also structurally different from omni/spot: the shadow term
multiplies into *two* variables, `light_attenuation_ltc` and `light_attenuation`
(`:1125-1126`).

Decision: **area lights are excluded from RT slot candidacy until Phase 3.** They neither
burn budget nor engage. The reason is 5.4's next point, not squeamishness — and the
exclusion must be visible in the debug view, because a room lit by one omni and one area
light showing two different shadow techniques on the same wall is worse than a room showing
one technique consistently.

**Soft shadows are a behavior to preserve, not a feature to add.** Today,
`sc_use_light_soft_shadows() && soft_shadow_size > 0.0` gives PCSS penumbras (`:520`,
`:822`, `:1027`). Replacing that with a 1-sample-per-pixel hard shadow makes carefully tuned
lights visibly **worse**. Combined with the area-light default above — and with D8b raising the
Omni/Spot default to 0.05 m — a naive Phase 2 would make *every* light in *every* scene look
wrong, not merely the tuned ones. There is no "hard shadows first, soft later" milestone
available to us.

Decision: **Phase 2 ships the cone-sampled soft path from §5.1 from the start**, reusing the
existing Vogel `penumbra_shadow_kernel` and the existing
`quick_hash(gl_FragCoord.xy + taa_frame_count * 5.588238)` rotation, at 4-8 taps. Noise is
acceptable until the Phase 3 denoiser; a silent downgrade to hard shadows is not. The
alternative — restricting Phase 2 to lights with `soft_shadow_size == 0.0` — is honest but
shrinks the audience to almost nothing.

**`shadow_opacity` must survive.** Every atlas site ends with
`mix(half(1.0), shadow, half(...shadow_opacity))` (`:606`, `:626`, `:871`, `:880`, `:1105`,
`:1121`). It is a user-facing `Light3D` property that artists routinely dial down. If the
RT path returns raw visibility without it, **any light with `shadow_opacity < 1` goes fully
black the moment RT engages.** The composite in §5.3 keeps it; it must not be dropped when
a cross-fade blend factor is added alongside it.

**Transmittance re-reads the atlas and RT cannot replace it.** Under
`LIGHT_TRANSMITTANCE_USED` the shader independently re-samples the atlas at three sites
(`:637-665`, `:891-905`, `:1227-1247`) to compute `transmittance_z` — a blocker *distance*
difference, not a visibility term. The mask cannot supply it. Harmless while the atlas is
retained (§5.3), but it means any future atlas suppression must also exclude lights
affecting transmittance/SSS materials.

There is an opportunity here worth recording rather than rediscovering:
`rayQueryGetIntersectionTEXT` gives blocker distance for free. A second R16 channel in the
mask would supply `transmittance_z` **better** than the atlas does — no quantisation, no
paraboloid seam.

**`blur_shadow()` is a dead stub.** `scene_forward_lights_inc.glsl:1435-1451` is `#if 0`
with a "will investigate later" comment. There is no working shadow post-filter hook, so it
cannot be used as a cheap smoothing fallback for hard-shadow aliasing.

---

## 6. Denoising

One ray per pixel per light is noisy. The denoiser is what turns it into an image.

### 6.1 Phase 3 — our own shadow denoiser

Shadow visibility is a much easier denoising problem than general path-traced radiance:
it is a scalar in [0,1], it is spatially coherent, and we know the hit distance, which
tells us how wide the penumbra should be. A well-understood three-stage filter suffices:

1. **Temporal reprojection.** Reproject last frame's denoised mask using the existing
   velocity buffer. Reject history on depth/normal mismatch. Accumulate with a variable
   alpha (fast when history is rejected, slow when stable).
2. **Variance estimation.** Track per-pixel variance of the accumulated signal to know
   where to filter hard.
3. **Spatial filter.** A separable à-trous edge-stopping blur, guided by depth, normal,
   variance, and hit distance — so contact shadows stay sharp and distant penumbrae blur
   wide, which is physically what should happen.

This is a self-contained compute pass in Godot's own GLSL, using buffers that already
exist. No third-party dependency, no build-system change, no licensing question.

**Interaction with TAA/FSR2.** A temporally-accumulated shadow signal feeding into a
temporal upscaler can double-accumulate and produce smearing on moving objects. The
denoiser's history rejection must be *more* aggressive than TAA's, and the mask must be
denoised before the opaque pass so the upscaler sees an already-converged signal. This is
a known interaction and is why hit distance is carried through — it lets us clamp
history by expected penumbra width rather than by colour alone.

### 6.2 Phase 5 — NRD SIGMA

NVIDIA's NRD contains **SIGMA**, a denoiser built specifically for raytraced shadows
(as distinct from ReBLUR/ReLAX, which target diffuse/specular radiance and are far
heavier). If we adopt NRD, SIGMA is the piece we want, and only it.

The obstacles are practical rather than conceptual:

* **NRD's shaders are HLSL.** Godot's shader pipeline is GLSL → SPIR-V via glslang at
  build time (`glsl_builders.py`). There is no ingestion path for precompiled SPIR-V.
  Adopting NRD means either adding one, or porting SIGMA's shaders to GLSL.
* **NRD's integration layer expects a native binding model** it would not get from
  `RenderingDevice` without the same native-handle work DLSS needs (§8.3).
* Licensing is *not* a problem — NRD is MIT-ish and source-available, unlike DLSS.

The honest assessment is that SIGMA is a quality upgrade of maybe 10-20% over a
competent hand-rolled shadow denoiser, at the cost of a significant integration project.
That is why D7 sequences it after a working denoiser rather than before one. If §8.3's
native-handle work lands for DLSS anyway, NRD becomes considerably cheaper and should be
revisited then.

---

## 7. User experience

The whole point. Everything here is designed so that a novice never has to think about
any of it.

### 7.1 Project settings

```
rendering/lights_and_shadows/raytraced_shadows/enabled              bool  false
rendering/lights_and_shadows/raytraced_shadows/quality              enum  High
rendering/lights_and_shadows/raytraced_shadows/denoising            bool  true
rendering/lights_and_shadows/raytraced_shadows/denoised_light_slots enum  8     (4 or 8)
rendering/lights_and_shadows/raytraced_shadows/inline_overflow      bool  true
```

`distance` and `vram_budget_mb` are **gone**: residency follows light volumes (§4.4) and
memory is a diagnostic (§4.5). `max_lights_per_pixel` became `denoised_light_slots`, which is
a quality/memory trade rather than a cap — lights past it are still raytraced, just inline
and unfiltered.

Only the first is `Basic`; the rest are `Advanced`. The intended interaction is: tick
`enabled`, done. `quality` maps to ray count, denoiser strength and internal resolution
scale — a single knob to trade quality for frame time.

Registered via `GLOBAL_DEF` in `scene/main/scene_tree.cpp` alongside the existing
`positional_shadow/*` settings, documented in `doc/classes/ProjectSettings.xml`, and
mirrored into the editor viewport with `GLOBAL_GET` in
`editor/scene/3d/node_3d_editor_viewport.cpp` — exactly the pattern the existing shadow
settings use (§1.11). Per-platform overrides (`.mobile`, etc.) come for free.

`enabled` is live-toggleable. Turning it off frees all acceleration structures and
returns to shadow maps within a frame; turning it on begins streaming BLASes and
converges over a few frames. No restart, in the editor or at runtime.

### 7.2 Per-light control

```
Light3D
└── Shadow
    ├── Mode                 OFF | SHADOW_MAP | RT_ONLY   ** NEW **
    │                        (new non-directional lights: RT_ONLY)
    │                        (new directional lights:     SHADOW_MAP)
    ├── Light Size           default 0.05 m  ** CHANGED, was 0 **
    │                        physical emitter radius; 0 = point light = hard
    └── ... existing shadow properties ...
```

Resolution table:

| Project setting | `shadow_mode` | Result |
|---|---|---|
| on | `RT_ONLY` (new-light default) | **Raytraced shadows** |
| on | `SHADOW_MAP` | Classic shadow map — the escape hatch |
| on | `OFF` | No shadows |
| **off** | `RT_ONLY` | **No shadows** — the setting does not carry over |
| off | `SHADOW_MAP` | Shadow map, exactly as today |
| no RT hardware | any | Project setting cannot be enabled (§D9) |

A light created any way at all — dragged into the scene, instanced from a `PackedScene`, or
`OmniLight3D.new()` in a script — gets `RT_ONLY` and casts RT shadows with no further action.
Existing scenes auto-upgrade per D8: lights that already cast shadows become `RT_ONLY`, lights
that were dark stay dark.

The `RT_ONLY` + project-setting-off row is the important one. It is deliberately *not* a
fallback: switching RT off leaves those lights unshadowed, loudly, rather than quietly
reverting to shadow-map behavior you did not author. `SHADOW_MAP` remains available per light
as a deliberate escape hatch for the rare case where RT is genuinely wrong for one light.

### 7.3 What the user never has to do

* Size a shadow atlas, or discover that their shadows are blocky because 12 lights are
  sharing one.
* Tune shadow bias, normal bias, or split distances.
* Think about which meshes are in the BVH, or mark anything as a shadow caster.
* Rebuild, bake, or refresh anything after moving an object or editing a mesh.
* Change how they import models.
* Do anything different for animated characters than for static walls.

### 7.3b The expectation gap you need to know about

This is the most important honesty point in the document, and it is a scoping consequence
rather than a technical one.

**Every default Godot 3D scene contains exactly one light: a `DirectionalLight3D`.** This
plan defers directional RT shadows to Phase 5. So a user who creates a new project, ticks
the box, and looks at their scene will see **nothing change — ever.**

"Just works" cannot ship against content where it demonstrably does nothing. Three things
follow, and none is optional:

1. The project setting's own description text must say that RT shadows apply to
   OmniLight3D and SpotLight3D (and, from Phase 3, AreaLight3D) — not to directional lights.
2. The debug view must state it directly when it is true: *"0 RT-capable lights in this
   scene — RT shadows apply to Omni/Spot lights only."*
3. Phase 2's success criterion must be framed honestly: it is shippable for scenes with
   shadow-casting local lights, which is a minority of projects and a smaller minority of
   beginner projects — precisely the audience this feature is for.

If that trade is unacceptable, the alternative is to pull directional RT shadows forward.
That is a real option and a defensible one; it is simply a different plan, with cascaded
shadow-map parity as its hard part rather than acceleration-structure management.

### 7.4 Editor integration

RT shadows appear in the editor 3D viewport the moment the setting is ticked, through
the `GLOBAL_GET` mirror in §1.11. The BLAS/TLAS system is per-`Scenario`, and the editor
viewport has its own scenario, so editor and game acceleration structures are naturally
independent — no cross-talk, and closing the running game does not disturb the editor.

Budgets (§4.5) keep the editor responsive while a large scene streams in: BLAS builds
are spread across frames rather than blocking, so opening a big level does not freeze the
editor.

### 7.5 The BVH debug view

New viewport debug mode: **"RT Acceleration Structure"**, added via the 8-file checklist
in §1.10.

An important honesty point first: **the hardware BVH itself cannot be visualized.**
Once `vkCmdBuildAccelerationStructuresKHR` runs, the internal node layout is opaque,
vendor-specific, driver-private data. There is no API in Vulkan — or in Godot — to read
it back. Anything claiming to show "the RT BVH" is showing a proxy.

What we *can* show is genuinely useful, and arguably more useful than raw BVH nodes:

* **Wireframe bounds of every TLAS instance**, colour-coded by state:
  green = resident and built · yellow = queued/building · blue = dynamic (refit each
  frame) · red = ineligible (non-triangle geometry, etc.).
* **Light influence volumes** — wireframe spheres and cones for every RT-shadowing light,
  which together *are* the residency region (§4.4). If something is not casting, it is either
  outside every volume or on the ineligible list.
* **The ineligible-caster list** — every instance in range that cannot be raytraced, with its
  reason (alpha-tested material, particles, non-triangle, 2D vertices). This replaces the
  deleted purity gate as your diagnostic surface.
* **An overlay readout**: instance count, BLAS count, VRAM used vs budget, builds this
  frame, refits this frame.
* **A ray-cost heatmap** toggle: per-pixel traversal cost, which is how you find the one
  over-tessellated mesh that is eating the frame.

Implementation reuses `DebugEffects::draw_shadow_frustum()`'s line-array approach
(§1.10) — it already draws wireframe boxes over the final image.

This view is where "invisible" becomes debuggable. When a shadow looks wrong, this
answers why in one glance: the object is red (ineligible), or outside the boundary, or
still yellow (streaming).

---

### 7.7 Volumetric fog — the one structural shadow-map dependency

This is the only place your "no shadow maps" goal collides with the engine rather than with
my caution, so it needs a decision rather than a reassurance.

`volumetric_fog_process.glsl` binds the shadow atlas directly
(`:27 layout(set = 0, binding = 1) uniform texture2D shadow_atlas`) and samples it per froxel
for **omni** (`:504-521`), **spot** (`:579-586`) and **area** (`:674`) lights, reimplementing
the atlas UV math with its own exponential fade. It runs over a 3D froxel grid, not over
screen pixels, so **it cannot read our screen-space mask** — the mask has no value for a
froxel behind a wall or outside the depth buffer.

SDFGI and VoxelGI are *not* a problem, despite also calling `light_has_shadow()`: they
raymarch their own SDF and occlusion volumes rather than sampling the atlas
(`sdfgi_direct_light.glsl:402-421`). Only fog reads it.

So: with volumetric fog enabled on a viewport, an RT-shadowed local light must still render a
shadow map, purely for fog. Four ways out:

| Option | What it costs | Result |
|---|---|---|
| **A. Fog keeps its shadow map** (per-light, only when fog is on) | A shadow-map pass per fog-affected light | Fog looks exactly as today; shadow maps survive in one narrow case |
| **B. Ray-trace fog shadows** — one ray per froxel per light | Real GPU cost; a 160×90×64 grid is ~920 k froxels | Fog shadows become *better* than today: no atlas resolution limit, no paraboloid seam |
| **C. Fog ignores local-light shadows** | Nothing | Light shafts pass through walls. Very visible; not recommended |
| **D. Sparse/temporal RT fog shadows** — trace a subset of froxels per frame, reproject | Moderate; needs its own temporal filter | B's quality at a fraction of the cost, with some latency in moving light shafts |

**My recommendation: A now, D later.** Fog is off by default in Godot and is a per-viewport
opt-in, so option A confines shadow maps to a case you may never enable — and if you never
turn fog on, you already have zero shadow maps for local lights. Option D is the principled
end state and is a natural Phase 5 companion to RTAO, since both are "trace a sparse volume
and denoise it". Option B is the same work as D without the optimization and is worth
measuring before committing.

If you intend to use volumetric fog heavily, tell me and I will move D forward — it changes
the phase ordering but not the architecture.

## 8. Prerequisites, and the long-term goals

### 8.1 Gaps in the existing RT layer that we must close

The `RenderingDevice` raytracing layer is complete enough to *use*, but it was built as a
scripting-facing API and never driven hard by an engine subsystem. Four things need
adding or fixing before Phase 2, and one is a latent bug worth fixing regardless.

**(a) BLAS refit — required, Phase 2.**
Note on API compatibility: `misc/extension_api_validation/` is a real gate, and changing
`blas_build(RID)` to `blas_build(RID, bool)` alters a bound method's arity — **not
additive**, even with a default argument. Add `blas_build_update()` as a separate method
instead. The same check applies to any new `tlas_create` flag bit and to a new
`light_set_shadow_raytraced` virtual.

`build_info.mode` is hard-coded to `VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR`
(`rendering_device_driver_vulkan.cpp:6380`, `:6428`) and `srcAccelerationStructure` is
never set. `ALLOW_UPDATE` is forwarded correctly to Vulkan (the flag bits are
`static_assert`-ed 1:1 at `:6323-6331`), so only the plumbing is missing. Adding
`blas_update()` means: a mode parameter through `RenderingDevice::blas_build()`, setting
`srcAccelerationStructure = dstAccelerationStructure`, and an update-sized scratch buffer.
This is a contained change to two files.

**(b) The `invalidated` flag never re-arms — required, Phase 2.**
`AccelerationStructure::invalidated` starts `true` and is cleared by a successful build,
but is **never set back to true when the underlying vertex data changes**. A skinned mesh
whose deformed buffer was rewritten by the skinning pass leaves its BLAS looking valid
while being stale, with no diagnostic. Our BLAS cache must therefore track dirtiness
itself, keyed on `MeshInstance::Surface::last_change`, rather than trusting the RD flag.

**(c) Thread-safety asymmetry — required, Phase 1.**
This is the sharpest trap in the layer. `blas_build`, `tlas_build` and every
`raytracing_list_*` call take `ERR_RENDER_THREAD_GUARD`. But `blas_create`, `tlas_create`,
`hit_sbt_create` and `raytracing_pipeline_create` take **neither** a render-thread guard
nor `_THREAD_SAFE_METHOD_`, even though the equivalent `compute_pipeline_create` does
(`rendering_device.cpp:5096`). They touch `frames[frame].buffers_to_dispose_of`,
`buffer_memory` and `RDG::resource_tracker_create()` unguarded. The `RID_Owner`s are
thread-safe; nothing else in those functions is.

Consequence for us: **all acceleration-structure creation must happen on the render
thread**, in the render step, never from scene-cull code running on another thread. Since
BLAS creation is naturally triggered from scene traversal, this needs an explicit queue —
scene cull *records* what needs building, the render step *does* the building. Our design
already has that queue (§4.5); this is the reason it is not optional. Adding the missing
guards upstream would be a good separate contribution.

**(d) `SUPPORTS_RAY_QUERY` can lie — required, Phase 1.**
Raytracing is compiled out entirely on macOS and iOS
(`#define VULKAN_RAYTRACING_ENABLED 0`, `rendering_device_driver_vulkan.cpp:50-55`, due to
MoltenVK limitations). Every implementation body is guarded by that macro — but the
extension registration at `:584-589` and the `has_feature()` cases at `:7462-7465` are
**not**. So on a macOS Vulkan build against a MoltenVK that advertises the extensions,
`SUPPORTS_RAY_QUERY` returns `true` while `blas_create()` returns a null ID and
`RenderingDevice` then reports "Failed to create BLAS."

For D9's silent fallback to actually be silent, capability detection must not trust
`has_feature()` alone. We will **probe at startup**: attempt to create and build a
two-triangle BLAS, and enable the feature only if that succeeds. Wrapping the two
`has_feature` cases in the macro is a one-line upstream fix worth making too.

**(e) Two `get_driver_resource` cases are outright broken.**
`DRIVER_RESOURCE_BUFFER` returns a pointer to Godot's internal `BufferInfo` struct rather
than the `VkBuffer` handle, and `DRIVER_RESOURCE_UNIFORM_SET` likewise returns a
`UniformSetInfo *` rather than a `VkDescriptorSet`. Passing either to a Vulkan or NGX call
is using a host pointer as a handle. Both are one-line fixes worth upstreaming, and they
matter the moment any external SDK enters the picture (§8.3).

**(f) Not needed now, but worth knowing.** There is no acceleration-structure compaction
(`ALLOW_COMPACTION` is forwarded but no compaction query pool or copy exists), no host or
deferred builds (`VK_KHR_deferred_host_operations` is enabled but never used), no indirect
tracing, no AABB/procedural geometry, and no per-geometry transform. Compaction's absence
means our BLAS memory will run perhaps 30-50% above optimal — which is why §4.5 has a VRAM
budget. The absence of AABB geometry is what makes parallax-occlusion self-shadowing
(§8.5) a larger project than it first appears.

### 8.2 RTAO — the cheapest follow-on

Once §4's acceleration-structure system exists, RTAO is a second compute shader against
the same TLAS: cosine-hemisphere rays of short length, occlusion accumulated, denoised
with the same filter. No new scene management, no new BLAS work, no new light plumbing —
and it drops into the existing SSAO slot in `_pre_opaque_render()` as a peer of
`_process_ssao()`.

Realistically this is a fraction of the effort of shadows, and it is why the acceleration
structure system in §4 is deliberately written as a general `RaytracingSceneRD` rather
than as something shadow-specific. **This is the right second feature.**

### 8.3 DLSS Super Resolution — the real obstacle

This needs to be stated plainly, because it is the item most likely to disappoint.

**Why FSR2 works in Godot.** Godot does not link AMD's FSR2 as a black box. It vendors
FSR2's *open-source* CPU orchestration code (`thirdparty/amd-fsr2/ffx_fsr2.cpp`), then
implements FSR2's backend interface against `RenderingDevice`, with **every FSR2 shader
ported to GLSL** in Godot's own shader tree
(`servers/rendering/renderer_rd/shaders/effects/fsr2/*.glsl`). That is only possible
because FSR2 is open source down to the shaders.

**Why DLSS cannot work the same way.** NVIDIA NGX ships as a closed binary. It cannot be
ported, and it does not accept abstract resource handles — `NVSDK_NGX_VULKAN_EvaluateFeature`
requires a real `VkCommandBuffer` to record into, plus real `VkImage`s.

Godot's `DriverResource` enum (`rendering_device_commons.h:944-971`) exposes
`VULKAN_DEVICE`, `VULKAN_PHYSICAL_DEVICE`, `VULKAN_INSTANCE`, `VULKAN_QUEUE`,
`VULKAN_QUEUE_FAMILY_INDEX`, `VULKAN_IMAGE`, `VULKAN_IMAGE_VIEW`, `VULKAN_SAMPLER`,
`VULKAN_DESCRIPTOR_SET`, `VULKAN_BUFFER`, and the two pipeline types.

**There is no `DRIVER_RESOURCE_COMMAND_BUFFER`.** That single omission is what blocks
DLSS. Godot's render graph owns command recording and reorders commands, so handing out
the current command buffer is not merely an enum addition — it needs a sanctioned
"external pass" escape hatch that flushes the graph, yields the command buffer to foreign
code, and resumes with correct resource state.

**Verdict.** DLSS SR is achievable but is genuinely a separate engine feature — call it
"native interop for `RenderingDevice`" — and it should be scoped and sequenced as such,
not as a sub-task of RT shadows. It also brings redistribution obligations (shipping
`nvngx_dlss.dll`/`.so` per platform) and a per-vendor code path, since it runs on NVIDIA
hardware only.

**Practical recommendation.** FSR2 already exists in Godot, works on all vendors, and
composes with RT shadows today with no new work. Use FSR2 for Phases 1-5. Treat the
native-interop work as its own project, and note that landing it also makes NRD (§6.2)
much cheaper — the two share the same prerequisite.

### 8.4 DLSS Ray Reconstruction — furthest out

DLSS RR replaces the denoiser *and* the upscaler with one network, consuming raw noisy
radiance plus a G-buffer of guide buffers. It requires everything in §8.3, plus feeding it
guide buffers in NVIDIA's exact layout, plus restructuring so our denoiser can be bypassed
entirely.

It is a legitimate long-term goal and the architecture here does not preclude it — keeping
the denoiser as a discrete, swappable pass (§6) is precisely what keeps that door open,
and carrying hit distance through the pipeline is one of the things RR wants. But it is
correctly sequenced last, after §8.3 and after RT shadows are mature.

### 8.5 Parallax-occlusion self-shadowing

Worth a brief note since you raised it: POM self-shadowing is *not* naturally a hardware-RT
problem. POM displacement exists only in the fragment shader — there is no geometry in the
BVH to intersect. Doing this "properly" with hardware RT would need procedural/AABB
geometry with intersection shaders, and §8.1(e) notes that `blas_create()` hard-codes
triangle geometry, so AABB BLASes cannot currently be built at all.

The pragmatic version — ray-marching the height map along the light direction in the
fragment shader — is a well-trodden technique that needs none of this and would compose
fine with RT shadows (RT handles inter-object shadowing, the march handles intra-surface).
That is the version I would recommend, and it is independent of everything else here.

---

## 9. Implementation phases

Each phase is independently shippable and leaves the engine in a working state. The
project setting stays default-off through Phase 3.

### Phase 0 — Foundations
*Prove the plumbing works before building on it.*

* **Shader compile smoke test**: push a minimal `#version 460` + `GL_EXT_ray_query` source
  through `RD::shader_compile_spirv_from_source` and assert success. Closes the
  `#version 460` unknown (§1.3) before any real shader is written.
* Startup capability probe (§8.1d): build a two-triangle BLAS and TLAS, trace one ray
  from a compute shader, verify the result. This single test de-risks the entire project.
* `RD::has_feature(SUPPORTS_RAY_QUERY)` wrapped in `VULKAN_RAYTRACING_ENABLED`.
* **A CI job running the gate scene under `--gpu-validation`, with any validation error
  treated as blocking.** No engine code has ever built an acceleration structure in this
  tree — our first run is the first run these paths have had. `blas_create` does no usage
  validation, AS barriers are hand-rolled buffer barriers with a stage-mask workaround, and
  there is a known same-frame instance-buffer aliasing bug. This is not hygiene; it is the
  only thing between us and shipping driver-dependent corruption.
* **Write the full shader contract (§5.4) before writing the shader.** Enumerate every read
  of `shadow` in `scene_forward_lights_inc.glsl` and state per site what RT does with it.
  One afternoon; removes an entire class of wrong-image bugs.
* Project settings registered and documented; nothing reads them yet.
* Debug overlay skeleton — shipped **before** any shadow code, so purity-gate engagement
  (§4.6) can be measured on real projects while it is still cheap to rescope.

**Exit:** a `--rt-selftest` flag prints pass/fail on your GPU, and the debug view reports
how much geometry in a representative scene is RT-ineligible, and where.

### Phase 1 — Static geometry, one light
*The smallest thing that produces a real raytraced shadow.*

* `RaytracingSceneRD`: BLAS cache, TLAS build, residency (§4).
* Dequantise pass for compressed meshes (§4.2) — the main unknown in this phase.
* `rt_shadows.glsl` for a single OmniLight3D, soft-sampled from the start. No denoiser yet;
  expect visible noise.
* Debug view showing TLAS instance bounds.

**Exit:** a static scene with one omni light shows a correct, noisy raytraced shadow in
the editor viewport, and toggling the setting off restores today's rendering exactly.

### Phase 2 — Deforming meshes and multiple lights
* `blas_update()` refit (§8.1a); BLAS dirty-tracking that does not trust `invalidated`
  (§8.1b).
* Dynamic BLASes for skinned/morphed `MeshInstance`s.
* **`mesh_instance_check_for_update()` on off-screen RT casters (§4.4 step 3)** — without
  this, off-screen characters cast frozen shadows.
* Eight denoised slots (two RGBA8), slot packing, spot lights.
* `Light3D.shadow_mode` with `AUTO` resolution and the auto-upgrade path (D8).
* **Cone-sampled soft shadows from the start** (§5.4) — not deferred. With the raised
  `light_size` default (D8b) every light is soft, so a hard-shadow first pass would look
  wrong everywhere rather than only on tuned lights.
* **MultiMesh support** (§4.6) — moved forward from a later phase. GridMap is 100% MultiMesh
  and scatter/foliage systems are too, so without it every GridMap level and every scattered
  scene would silently cast no shadows.
* Ineligible-geometry classification and its debug listing (§4.6) — no purity gate,
  no demotion.

**Exit:** an animated character casts a correct shadow while off-screen behind the camera,
and a GridMap level engages rather than demoting.

### Phase 3 — Denoising and quality
* Temporal + spatial shadow denoiser (§6.1); hit-distance-guided penumbra filtering.
* Blue-noise sampling, TAA/FSR2 interaction handling.
* Quality presets wired to the `quality` setting.
* **Area light support** (§5.4) — three composite sites, and the LTC path needs checking.
  Area lights already default to `light_size = 0.5`, so they are the best early proof that
  contact hardening looks right.
* **Inline overflow path**: `SHADER_GROUP_RAYTRACING`, `scene_forward_clustered.glsl` to
  `#version 460`, ray query for the 9th+ light on a pixel (D3).
* Full debug view: state colour-coding, light influence volumes, ray-cost heatmap, memory
  and build stats, the ineligible-caster list with reasons, and the "0 RT-capable lights"
  notice (§7.3b).

**Exit:** production-quality shadows. **The project setting becomes user-facing here.**

### Phase 4 — Integration and optimization
* **Delete the local-light shadow-map pass entirely**, except where volumetric fog requires
  it (§7.7). This is the performance win and the point of the whole exercise.
* **Screen-space contact shadows** (§D9) to fill in grass and foliage that alpha-tested
  geometry can no longer cast — the *Days Gone* approach, composing with RT rather than
  replacing it.
* Transmittance/SSS: either keep a shadow map for affected lights or move
  `transmittance_z` onto a second mask channel from `rayQueryGetIntersectionTEXT` (§5.4),
  which is strictly better than the atlas.
* Multi-view/XR support or an explicit gate. Note the existing FSR2 integration in this fork
  shares one temporal context across both eyes — a latent defect the denoiser must not
  inherit.
* Async BLAS builds, eviction tuning.

**Exit:** RT shadows are net-faster than shadow maps in light-heavy scenes.

### Phase 5 — Extensions
* **RTAO** (§8.2) — highest value per unit effort of anything remaining.
* **Volumetric fog RT shadows**, sparse + temporally reprojected (§7.7 option D). Shares its
  machinery with RTAO: both trace a sparse volume and denoise it.
* Directional-light (sun/moon) RT shadows — after which shadow maps are gone from the
  renderer entirely.
* NRD SIGMA evaluation (§6.2).
* **Any-hit alpha testing**, if screen-space contact shadows prove insufficient and foliage
  has not moved to real geometry.

### Phase 6 — Native interop
* `RenderingDevice` external-pass mechanism and command-buffer access (§8.3).
* DLSS Super Resolution.
* DLSS Ray Reconstruction (§8.4).

---

## 10. Limitations, risks, and honest caveats

### 10.1 Hard limitations
* **Vulkan only.** D3D12 and Metal stub every RT entry point (`d3d12:5601-5655`,
  `metal:2363-2417`) and report no RT support. macOS/iOS are excluded by
  `VULKAN_RAYTRACING_ENABLED = 0`.
* **Forward+ only.** Mobile and Compatibility renderers are untouched.
* **RT-capable GPU required** — RTX 20-series and newer, RDNA2 and newer, Arc. This is now a
  hard requirement of the game, not a quality tier: without it the project setting cannot be
  enabled and local lights have no shadows.
* **Opaque triangle geometry only.** Alpha-tested foliage, particles and `ImmediateMesh`
  cast **no shadow at all** (§D9) — not a wrong shadow, no shadow. This is the most visible
  consequence of the revised philosophy and the thing most likely to need attention in an
  outdoor scene. Three exits, none reintroducing a shadow map: screen-space contact shadows
  (Phase 4), geometry-based foliage (content), or any-hit alpha testing (Phase 5).
* **Non-triangle primitives** (points, lines, strips) never participate. 2D-vertex surfaces
  (`ARRAY_FLAG_USE_2D_VERTICES`) and surfaces with `ARRAY_FLAG_USES_EMPTY_VERTEX_ARRAY` must
  be excluded explicitly — the 2D format is legal-but-degenerate as AS input and would
  silently produce a flat BLAS.
* **Directional lights (sun/moon) are not covered until Phase 5** — see §7.3b. In a default
  Godot scene, which contains only a `DirectionalLight3D`, this feature does nothing at all.
* **`shadow_reverse_cull_face` becomes a no-op** for RT-shadowed lights (§4.3). It is
  per-light; the TLAS is per-scenario.
* **Shadow-caster layer masks above layer 8 lose precision** (§4.3). The 8-bit TLAS instance
  mask is an OR-fold of Godot's 32-bit masks — conservative, but RT and raster can disagree
  about which objects cast.
* **Shadow LOD is always LOD 0** (§4.6), so distant shadow silhouettes will not match
  LOD-reduced geometry outlines.

### 10.2 Things that will need care
| Risk | Mitigation |
|---|---|
| Compressed vertices (§1.7) — the main unknown | Prototype the dequantise pass in Phase 1 before anything else |
| Off-screen skinned meshes go stale (§1.8) | Explicit `mesh_instance_check_for_update()`; regression test with an off-screen animated character |
| Thread-safety of AS creation (§8.1c) | Queue from scene cull, create on the render thread, never the reverse |
| `SUPPORTS_RAY_QUERY` false positives (§8.1d) | Startup probe, not just `has_feature()` |
| VRAM growth, no compaction (§8.1e) | Budget + eviction + adaptive distance |
| BLAS build stutter on level load | Per-frame budgets; degrade to shadow maps meanwhile |
| Denoiser × TAA/FSR2 double-accumulation | Aggressive history rejection; denoise before opaque |
| Negative-scale winding (§4.3) | `TRIANGLE_FLIP_FACING_BIT` on negative-determinant transforms |
| Shadow-map path bit-rot as RT becomes default | CI scenes rendered both ways every build |
| Purity gate fires everywhere, feature does nothing | Ship the debug view in Phase 0 and measure on real content before committing scope |
| Ray query silently rejected at `#version 450` | Phase 0 compile smoke test |
| First-ever use of these AS code paths | `--gpu-validation` CI job, errors blocking |
| CSG mesh-RID churn exhausting the BLAS cache | Key churn detection on `instance_set_base`, cap new keys per instance per second |
| Oversized single mesh never scheduled | Always build at least one item per frame |
| `blas_build` arity change breaks GDExtension API compat | Add `blas_build_update()` as a new method rather than changing the signature |

### 10.3 Things I am not certain about
Stated plainly, since you are relying on my judgment:

* **The 4-lights-per-pixel budget (D3)** is an educated guess. It may want to be 2 (cheaper)
  or 8 (two textures). It is isolated behind one function so revising it is cheap, but
  expect to revise it after profiling.
* **Whether RT shadows are net faster than shadow maps** depends heavily on scene
  composition. Many local shadow-casting lights → RT very likely wins. A handful of lights
  over dense geometry → shadow maps may still win. The fallback design means this is a
  tuning question, not a correctness one.
* **The real cost of per-frame BLAS refits for many characters** is unmeasured. Twenty
  skinned characters at 30k vertices each is a meaningful per-frame cost, and §4.4's
  rebuild-every-60-frames heuristic is a starting point, not a tuned value.
* **NRD's actual quality delta** over a competent hand-rolled shadow denoiser is something
  I would want measured before committing to the integration (§6.2).
* **How visible the missing alpha-geometry shadows will be.** This replaces the purity gate
  as the design's main open risk, and it is a much better risk to have: it is a *visual*
  question answerable by looking at your own content, not a systemic one that could silently
  switch the feature off. Build a representative outdoor scene early and judge it.
* **Whether 8 denoised slots is the right number.** It is an educated guess at per-pixel
  overlap. The inline overflow path means being wrong costs quality, not correctness, so this
  is safe to tune late — but expect to tune it.
* **The cost of unbounded residency.** With no distance cap, a large level with many lights
  can hold a great deal of geometry resident. Whether that is tens or hundreds of megabytes
  depends entirely on your content, and per §4.5 the renderer will tell you rather than
  silently trimming.
* **Ray bias constants are unvalidated.** Shadow acne and peter-panning are the two failure
  modes a novice notices instantly, and the exact things RT is meant to fix. Compressed
  vertices add roughly `aabb_size / 65535` of positional error on top of depth
  reconstruction error, so the bias floor cannot be zero. These want empirical tuning
  against a stress scene, not derivation.
* **BLAS memory accounting has no ground truth.** There is no AS size query at any level and
  AS backing buffers bypass RD's `buffer_memory`, so `get_memory_usage()` under-reports. Our
  bytes-per-triangle figure is an estimate; if the constant is wrong the budget protects
  nobody. Calibrating it per vendor at startup is a plan, not a solution.
* **The refit drift period** (rebuilding every 60 frames) is a guess. Refitting for hundreds
  of consecutive frames develops progressively worse node overlap: trace cost climbs with no
  visible artifact and no error. The debug view's ray-cost counter drifting upward over a
  minute of playback is the signal to watch.

### 10.4 What will not change for existing projects
* With the setting off (the default), the engine is byte-for-byte what it is today. The
  specialization-constant bit is clear, the RT branch compiles out, no acceleration
  structures are created, no memory is allocated.
* Shadow maps are never removed. RT shadows are an override layered on top, which is why
  every fallback path degrades to *today's behavior* rather than to something broken.
* No import settings change; no mesh re-import is needed; `.tscn` semantics are unchanged
  (D8).
* **One unavoidable exception:** adding a binding to `scene_forward_clustered_inc.glsl`
  changes that file's hash, which invalidates **every** shader group's cache
  (`shader_rd.cpp:167-180`). Every user upgrading gets a full scene-shader recompile of every
  material on first run — even with RT shadows off. A one-time cost, but it must be budgeted
  and communicated rather than discovered.
* The one intentional behavior change is D8's: with the setting **on**, a light that had
  `shadow = false` will start casting an RT shadow. That is the requested behavior, it is
  opt-in at project level, and `rt_shadow_mode = DISABLED` restores the old look per light.

---

## 11. Summary

**Viability: high.** The RenderingDevice raytracing layer is real and usable; inline ray
query from compute works today (in a `#version 460` shader — the one thing Godot does not
already have); the "hard" case of animated characters is largely solved by Godot's existing
skinning pipeline; and the non-frustum-culled caster enumeration you require already exists
as `Scenario::indexers[INDEXER_GEOMETRY]`.

**The one genuine technical blocker** is that Godot's default compressed vertex format is
illegal as raytracing input. It is solved by a one-time-per-surface dequantise pass, and it
should be prototyped first (Phase 1) because it is the largest remaining unknown.

**The one genuine design risk is now visual rather than systemic.** Alpha-tested geometry,
particles and `ImmediateMesh` cast no shadow at all (§D9). How much that matters depends
entirely on your content, and it is answerable by building a representative outdoor scene and
looking at it — not by argument. Three exits exist, none of which reintroduces a shadow map:
screen-space contact shadows, geometry-based foliage, or any-hit alpha testing.

This replaced a much worse risk. The first draft's *purity gate* would have demoted whole
lights to shadow maps whenever any ineligible caster was in range — which, given GridMap and
scatter systems are MultiMesh-based, would have fired almost everywhere. Deleting the
shadow-map fallback deleted the gate along with it.

**Five additions to the RT layer** are prerequisites: BLAS refit (as a new method, not a
signature change), dirty-tracking that does not trust the `invalidated` flag, render-thread
discipline for AS creation, a startup capability probe that does not trust `has_feature()`,
and a `#version 460` compile smoke test.

**Ease of use is achievable as specified.** One project setting; every new non-directional
light casts RT shadows by default; existing shadow-casting lights auto-upgrade; a per-light
escape hatch; soft contact-hardened shadows without configuration; automatic
acceleration-structure management driven by light volumes; identical in the editor viewport
and in exported games.

**Two caveats worth restating.** Until Phase 5 this covers Omni, Spot and (from Phase 3) Area
lights, not directional — and a default Godot scene contains only a `DirectionalLight3D`, so
the setting's description and the debug view must say so plainly. And alpha-tested geometry
casts nothing until screen-space contact shadows land in Phase 4.

**Shadow maps end up confined to exactly two places:** directional lights, and volumetric fog
where it is enabled. Phase 5 removes the first; §7.7 option D removes the second. After that
the renderer has no shadow-map path for local lights at all — which is the goal.

**Of the long-term goals:** RTAO is cheap and should be next. NRD is worthwhile but is a
quality upgrade, not a prerequisite. DLSS SR and RR are both gated behind one missing piece
of engine plumbing — native command-buffer access — which is best scoped as its own project
rather than smuggled into this one.
