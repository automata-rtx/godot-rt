# Raytraced Shadows for Godot Forward+ (Vulkan)

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
  memory, scratch buffers, synchronisation) is already done and already debugged.
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

Optional means a GPU without raytracing still initialises normally — there is no
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

This was the make-or-break question, and the answer is favourable on all four counts:

| Requirement | Status | Evidence |
|---|---|---|
| glslang understands ray query | Yes | vendored glslang; all RT stages wired in `modules/glslang/register_types.cpp:56-64` |
| SPIR-V ≥ 1.4 | Yes — 1.4 exactly | `rendering_shader_container_vulkan.cpp:103-105` |
| Vulkan ≥ 1.1 client | Yes — 1.1 | `rendering_shader_container_vulkan.cpp:99-101` |
| AS bindable as uniform | Yes | `UNIFORM_TYPE_ACCELERATION_STRUCTURE` |

`GL_EXT_ray_query` requires SPIR-V 1.4 and Vulkan 1.1. Godot targets exactly that.
**We can write `rayQueryEXT` in a normal `.glsl` compute shader with no changes to the
shader build system.**

### 1.4 Where shadows are computed today

Local-light shadowing lives in
`servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl`. Inside
`light_process_omni_light()` the shadow term is initialised at line 499:

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

`_pre_opaque_render()` is where SSAO and SSIL run, which means **depth and
`normal_roughness` are already resolved and available there** — the exact inputs a
screen-space raytraced shadow pass needs. Our pass slots in alongside SSAO with no
reordering of anything that exists.

`RB_TEX_NORMAL_ROUGHNESS` is allocated on demand via `ensure_normal_roughness_texture()`
(`render_forward_clustered.cpp:63-68`); we simply add RT shadows to the list of features
that request it.

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
us "everything within RT shadow distance, on-screen or not".

Also relevant: `light_get_shadow_caster_mask()` is already respected during shadow
caster gathering (`renderer_scene_cull.cpp:2430`), alongside `layer_mask` and the
geometry's `can_cast_shadows` flag. The RT path must honour the same three, which maps
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

### D3 — Mask format: 4 lights per pixel, R8G8B8A8, with an index remap

**Decision.** A single `R8G8B8A8_UNORM` texture at internal resolution. Each channel is
the visibility term for one light. A small per-pixel index table maps channel → light.

**Why.** Real scenes have many lights but few *shadow-casting* lights affecting any
given pixel. Godot's clustered light culling already gives us the per-cluster light
list. Budgeting four RT-shadowed lights per pixel covers the overwhelming majority of
cases at 4 bytes/pixel. Lights beyond the budget fall back to their existing shadow map
— which is safe, correct-looking, and invisible in practice.

**Rejected.** One full-resolution texture per light (unbounded VRAM); a packed 1-bit
bitmask (cannot be denoised — denoising needs continuous values); a texture array sized
to the light count (allocation churn as lights come and go).

**Note.** This is the decision I am least certain about, and it is the one most likely
to be revised after profiling. It is deliberately isolated behind a single function in
the shader so revising it is cheap. See §10.

### D4 — Specialization constant, not a shader variant

**Decision.** `sc_use_rt_shadows()` on a free bit of `sc_packed_1`.

**Why.** §1.5: zero new variants, works in ubershader mode, no compile-time or stutter
regression. When the bit is clear, the compiler removes the RT branch entirely and the
shader is byte-for-byte the behaviour you have today.

### D5 — TLAS instances come from the scenario geometry index, not the render list

**Decision.** Source casters from `Scenario::indexers[INDEXER_GEOMETRY].aabb_query()`
with a box centred on the camera, sized by the RT shadow distance.

**Why.** The render list is frustum-culled; using it would break your explicit
requirement that walls behind the player still cast shadows. The geometry indexer is
not frustum-culled, is maintained every frame anyway, and supports exactly the spatial
query we want. This is reuse, not new infrastructure.

**Rejected.** A second parallel scene structure maintained by the RT system — duplicated
state, duplicated bugs, and a new class of "why is this object's shadow wrong"
failure that would be invisible to the user.

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
(shadow visibility is a scalar in [0,1] with known temporal behaviour) and Godot's
compute infrastructure is entirely adequate for it. Shipping our own first means
Phase 3 is usable; NRD then becomes a quality upgrade rather than a prerequisite.

**Rejected.** NRD as a hard dependency of the first working version — it would put a
large, uncertain porting task on the critical path of a feature that can work without it.

### D8 — `Light3D.rt_shadow_mode` tri-state, not a flipped `shadow` default

**Decision.** Add `Light3D.rt_shadow_mode` with values `AUTO` (default), `ALWAYS`,
`DISABLED`. Leave `Light3D.shadow`'s default at `false`, untouched.

**Why.** This one is subtle and worth understanding, because the obvious approach has a
nasty side effect. Godot's scene serializer only writes properties that differ from
their C++ default. If we changed `shadow`'s default to `true` when the project setting
is on, then the *meaning of every existing `.tscn` file* would change depending on a
project setting — lights that were deliberately left non-shadowing would start casting,
and scene files would no longer be portable between projects. That is a genuine
correctness problem, not just a cosmetic one.

A separate `AUTO`-defaulted property gives you exactly what you asked for — every light,
however it is created, casts RT shadows once the project setting is on — while keeping
`.tscn` semantics stable and per-light opt-out a single click.

**Consequence you should know about:** with the project setting on, a light that
currently has `shadow = false` *will* start casting an RT shadow. That is the intended
behaviour and it is what you asked for, but it is a visible change to an existing scene,
and it is the one place where "nothing changes" is not literally true. It is gated
behind a setting that is off by default, so no existing project is affected until its
author opts in. `DISABLED` restores the old look per light.

### D9 — Fallback is silent and automatic, at three levels

**Decision.**

1. **No hardware RT** (`SUPPORTS_RAY_QUERY == false`) → the feature disables itself
   entirely; shadow maps run exactly as today. A one-line note in the log, nothing in
   the UI, no error.
2. **Per-light budget exceeded** (more than 4 RT-shadowed lights on a pixel) → the
   overflow lights use their shadow map.
3. **Per-instance ineligible** (non-triangle primitive, unsupported geometry) → that
   instance is absent from the TLAS but still renders into shadow maps normally.

**Why.** Every one of these must be invisible to a novice. The critical property is that
the shadow-map path is never removed or disabled — it remains the substrate, and RT
shadows are an override on top of it. That is what makes "it just works" achievable, and
it is why nothing existing can break.

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
* Amortised across all instances of the mesh.
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

Per-instance fields are filled as:

| Field | Source |
|---|---|
| `transform` | `Instance::transform` |
| `id` | index into a parallel instance table (used by the debug view) |
| `mask` | derived from `layer_mask`, `shadow_caster_mask`, `cast_shadows` |
| `flags` | `TRIANGLE_FACING_CULL_DISABLE` for double-sided; `TRIANGLE_FLIP_FACING` for negative-determinant transforms |
| `blas` | from the BLAS cache |

**Negative scale matters.** A mesh with a negatively-scaled transform has inverted
winding. The raster path handles this in its culling state; the RT path must set
`TRIANGLE_FLIP_FACING_BIT` or such objects will self-shadow incorrectly. This is a
classic RT porting bug and is called out here so it is not rediscovered later.

**`SHADOWS_ONLY` and `SHADOWS_OFF`** map naturally: `SHADOWS_OFF` geometry is excluded
from the TLAS; `SHADOWS_ONLY` geometry is included in the TLAS but excluded from the
render list, exactly as it is today.

### 4.4 Residency, streaming and the deforming-mesh hazard

Residency is driven by a single user-facing number, **RT shadow distance** (default
`64 m`), and one internal VRAM budget.

Each frame:

1. Query `Scenario::indexers[INDEXER_GEOMETRY].aabb_query()` with a box of
   `rt_shadow_distance` around the camera. **No frustum culling** — this is what makes
   walls behind the player cast shadows.
2. For each hit instance: mark its surfaces' BLAS entries used this frame; queue
   `UNBUILT` ones.
3. **If the instance is skinned or morphed, call
   `mesh_instance_check_for_update()` on it.** This is the fix for the §1.8 hazard —
   without it, off-screen characters cast frozen shadows. It is one line, and it is the
   single most important correctness detail in this section.
4. Refit dynamic BLASes whose `last_change` advanced.
5. Evict: BLAS entries unused for N frames (default 120) are freed, oldest-first, until
   the VRAM budget is met.

Eviction hysteresis (unused for *120 frames*, not 1) prevents thrashing when the player
turns around or paces back and forth across a boundary.

**Deforming meshes.** Skinned and morphed surfaces are marked `is_dynamic`. Their BLAS
is built once with `ALLOW_UPDATE | PREFER_FAST_BUILD` and thereafter **refitted**, not
rebuilt, via the new `blas_update()`. Refit is roughly an order of magnitude cheaper
than a rebuild. Refit quality degrades if the pose drifts far from the one the BLAS was
built in, so a full rebuild is forced every N frames (default 60) or when a heuristic on
AABB growth trips. Unlike static meshes, a dynamic BLAS is per *MeshInstance*, not per
surface — each animated character has its own pose and therefore its own BLAS.

### 4.5 Budgets — never stall the frame

Every expensive operation is budgeted per frame, with a configurable ceiling:

| Operation | Default budget |
|---|---|
| New BLAS builds | 8 per frame |
| Dequantise dispatches | 4 per frame |
| BLAS VRAM | 256 MB |
| TLAS instances | 65,536 |

Exceeding a budget defers work to the next frame; it never drops geometry silently in a
visible way. During the frames before a BLAS is ready the instance is simply absent from
the TLAS, and that light falls back to its shadow map for those frames — so a streaming
scene degrades to *today's behaviour* briefly rather than to a missing shadow. This is
the property that makes level loading and fast teleporting safe.

If the VRAM budget cannot be met even after eviction, the system logs once and reduces
`rt_shadow_distance` adaptively rather than failing.

---

## 5. Tracing and shading

### 5.1 The ray-tracing compute pass

`rt_shadows.glsl`, dispatched at internal resolution, one thread per pixel.

```glsl
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
            gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT,
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

Volumetric fog and SDFGI also consume shadows, and they run from their own shaders
against the shadow atlas. **They keep using the shadow atlas.** RT-shadowed lights
therefore still allocate a shadow map for fog/GI purposes in Phase 1-3; the saving in
shadow-map rendering comes later, in Phase 4, once fog and GI have their own RT paths.
This is a deliberate ordering choice: it means fog and GI cannot visually regress.

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
rendering/lights_and_shadows/raytraced_shadows/enabled            bool   false
rendering/lights_and_shadows/raytraced_shadows/quality            enum   Medium
rendering/lights_and_shadows/raytraced_shadows/distance           float  64.0
rendering/lights_and_shadows/raytraced_shadows/max_lights_per_pixel int  4
rendering/lights_and_shadows/raytraced_shadows/denoising          bool   true
rendering/lights_and_shadows/raytraced_shadows/vram_budget_mb     int    256
```

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
    ├── Enabled              (existing, unchanged)
    ├── RT Shadow Mode       AUTO | ALWAYS | DISABLED     ** NEW **, default AUTO
    └── ... existing shadow properties ...
```

Resolution table:

| Project setting | `rt_shadow_mode` | Result |
|---|---|---|
| off | any | Shadow maps, exactly as today |
| on | `AUTO` (default) | **RT shadows** |
| on | `ALWAYS` | RT shadows |
| on | `DISABLED` | Shadow maps (per-light opt-out) |
| on, no RT hardware | any | Shadow maps, silently |

Because the default is `AUTO`, a light created any way at all — dragged into the scene,
instanced from a `PackedScene`, or `OmniLight3D.new()` in a script — casts RT shadows
with no further action. That is your "must default to casting" requirement, satisfied
without touching serialization semantics (D8).

`ALWAYS` exists for a light you want RT-shadowed even if a future heuristic would
demote it. It is an escape hatch, not something a novice ever needs.

### 7.3 What the user never has to do

* Size a shadow atlas, or discover that their shadows are blocky because 12 lights are
  sharing one.
* Tune shadow bias, normal bias, or split distances.
* Think about which meshes are in the BVH, or mark anything as a shadow caster.
* Rebuild, bake, or refresh anything after moving an object or editing a mesh.
* Change how they import models.
* Do anything different for animated characters than for static walls.

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

An important honesty point first: **the hardware BVH itself cannot be visualised.**
Once `vkCmdBuildAccelerationStructuresKHR` runs, the internal node layout is opaque,
vendor-specific, driver-private data. There is no API in Vulkan — or in Godot — to read
it back. Anything claiming to show "the RT BVH" is showing a proxy.

What we *can* show is genuinely useful, and arguably more useful than raw BVH nodes:

* **Wireframe bounds of every TLAS instance**, colour-coded by state:
  green = resident and built · yellow = queued/building · blue = dynamic (refit each
  frame) · red = ineligible (non-triangle geometry, etc.).
* **The residency boundary** — a wireframe box showing the RT shadow distance, so it is
  immediately obvious why a distant object stopped casting.
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

## 8. Prerequisites, and the long-term goals

### 8.1 Gaps in the existing RT layer that we must close

The `RenderingDevice` raytracing layer is complete enough to *use*, but it was built as a
scripting-facing API and never driven hard by an engine subsystem. Four things need
adding or fixing before Phase 2, and one is a latent bug worth fixing regardless.

**(a) BLAS refit — required, Phase 2.**
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

**(e) Not needed now, but worth knowing.** There is no acceleration-structure compaction
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

* Startup capability probe (§8.1d): build a two-triangle BLAS and TLAS, trace one ray
  from a compute shader, verify the result. This single test de-risks the entire project.
* `RD::has_feature(SUPPORTS_RAY_QUERY)` wrapped in `VULKAN_RAYTRACING_ENABLED`.
* Project settings registered and documented; nothing reads them yet.
* Debug overlay skeleton.

**Exit:** a `--rt-selftest` flag prints pass/fail on your GPU.

### Phase 1 — Static geometry, one light
*The smallest thing that produces a real raytraced shadow.*

* `RaytracingSceneRD`: BLAS cache, TLAS build, residency (§4).
* Dequantise pass for compressed meshes (§4.2) — the main unknown in this phase.
* `rt_shadows.glsl` for a single OmniLight3D. No denoiser; expect visible noise.
* Debug view showing TLAS instance bounds.

**Exit:** a static scene with one omni light shows a correct, noisy raytraced shadow in
the editor viewport, and toggling the setting off restores today's rendering exactly.

### Phase 2 — Deforming meshes and multiple lights
* `blas_update()` refit (§8.1a); BLAS dirty-tracking that does not trust `invalidated`
  (§8.1b).
* Dynamic BLASes for skinned/morphed `MeshInstance`s.
* **`mesh_instance_check_for_update()` on off-screen RT casters (§4.4 step 3)** — without
  this, off-screen characters cast frozen shadows.
* Up to 4 lights per pixel, channel packing, spot lights, soft shadows from `light_size`.

**Exit:** an animated character casts a correct shadow while off-screen behind the camera.

### Phase 3 — Denoising and quality
* Temporal + spatial shadow denoiser (§6.1); hit-distance-guided penumbra filtering.
* Blue-noise sampling, TAA/FSR2 interaction handling.
* Quality presets wired to the `quality` setting.
* Full debug view: state colour-coding, residency boundary, ray-cost heatmap, stats.

**Exit:** production-quality shadows. **The project setting becomes user-facing here.**

### Phase 4 — Integration and optimisation
* Skip shadow-map rendering for fully-RT-shadowed lights — the actual performance win.
* RT shadows for volumetric fog and SDFGI so nothing regresses when atlases go away.
* Multi-view/XR support or an explicit gate.
* Async BLAS builds, LOD proxy selection, eviction tuning.

**Exit:** RT shadows are net-faster than shadow maps in light-heavy scenes.

### Phase 5 — Extensions
* **RTAO** (§8.2) — highest value per unit effort of anything remaining.
* NRD SIGMA evaluation (§6.2).
* Directional-light (sun/moon) RT shadows.

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
* **RT-capable GPU required** — RTX 20-series and newer, RDNA2 and newer, Arc. Everything
  else silently uses shadow maps.
* **Opaque triangle geometry only.** Alpha-tested foliage casts a solid shadow of its
  quads. This is the single most likely thing to look wrong in a real project, and it is a
  deliberate scope exclusion you named. It needs any-hit shaders and material binding to
  fix properly.
* **Non-triangle primitives** (points, lines, strips) never participate.

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

### 10.3 Things I am not certain about
Stated plainly, since you are relying on my judgement:

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

### 10.4 What will not change for existing projects
* With the setting off (the default), the engine is byte-for-byte what it is today. The
  specialization-constant bit is clear, the RT branch compiles out, no acceleration
  structures are created, no memory is allocated.
* Shadow maps are never removed. RT shadows are an override layered on top, which is why
  every fallback path degrades to *today's behaviour* rather than to something broken.
* No import settings change; no mesh re-import is needed; `.tscn` semantics are unchanged
  (D8).
* The one intentional behaviour change is D8's: with the setting **on**, a light that had
  `shadow = false` will start casting an RT shadow. That is the requested behaviour, it is
  opt-in at project level, and `rt_shadow_mode = DISABLED` restores the old look per light.

---

## 11. Summary

**Viability: high.** The RenderingDevice raytracing layer is real and usable; inline ray
query from compute works today with no shader-build changes; the "hard" case of animated
characters is already solved by Godot's existing skinning pipeline; and the non-frustum-culled
caster enumeration you require already exists as `Scenario::indexers[INDEXER_GEOMETRY]`.

**The one genuine blocker** is that Godot's default compressed vertex format is illegal as
raytracing input. It is solved by a one-time-per-surface dequantise pass, and it should be
prototyped first (Phase 1) because it is the largest remaining unknown.

**Four small additions to the RT layer** are prerequisites: BLAS refit, dirty-tracking that
does not trust the `invalidated` flag, render-thread discipline for AS creation, and a
startup capability probe that does not trust `has_feature()`.

**Ease of use is achievable as specified.** One project setting; every light defaults to
casting; a one-click per-light opt-out; automatic acceleration-structure management with
streaming and eviction; works identically in the editor viewport and in exported games;
silent fallback to today's shadow maps on unsupported hardware.

**Of the long-term goals:** RTAO is cheap and should be next. NRD is worthwhile but is a
quality upgrade, not a prerequisite. DLSS SR and RR are both gated behind one missing piece
of engine plumbing — native command-buffer access — which is best scoped as its own project
rather than smuggled into this one.
