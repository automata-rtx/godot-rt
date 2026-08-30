# Re-applying raytraced shadows to a newer Godot

This document exists so the system in this fork can be rebuilt on a later version of Godot, by
someone — or something — that was not here when it was written the first time.

It is deliberately **not** a diff. On a newer engine the line numbers will be wrong, some functions
will have been renamed, and some structures will have gained fields. What survives that is the
*shape* of the integration: which upstream thing each piece hooks into, what kind of hook it is, and
— the part that breaks quietly — what the hook assumes about the engine around it.

Read `FORK_GUIDE.md` first for what the system does. This document is about how it attaches.

Upstream base for the original work: `b56a91878e7c94977e4af978968e41d0670c0a8b` (Godot 4.8-dev).
To see any piece as it was written: `git diff b56a91878..HEAD -- <path>`.

---

## 1. The one fact that makes this tractable

Godot 4.7/4.8 already shipped a complete hardware-raytracing layer inside `RenderingDevice` —
acceleration structure creation and building, ray-query feature detection, an acceleration-structure
uniform type, barrier handling — with **no user of it anywhere in the renderer**.

So this fork is not fighting an existing design. Every driver-level piece was already there and
already debugged; all of the work is renderer work in C++ and GLSL. If a newer Godot still has that
layer, the port is a re-integration, not a reimplementation. **Check this first.** If the API has
changed shape, that is the largest single risk in the whole port, and it is worth establishing
before touching anything else.

The specific things relied on:

- `RD::SUPPORTS_RAY_QUERY` as a device feature query.
- `RD::UNIFORM_TYPE_ACCELERATION_STRUCTURE` bindable in an ordinary compute shader's uniform set.
- BLAS/TLAS create and build entry points on `RenderingDevice`.
- Shaders compiled to SPIR-V at a version that permits `SPV_KHR_ray_query`.

Two toolchain quirks that cost time to discover:

- **glslang gates `rayQueryEXT` and every `rayQuery*EXT` builtin on `#version 460`.** Any shader that
  traces must be 460, not Godot's usual 450. This is why `rt_shadow_trace.glsl` carries a comment
  saying it is the only 450 exception, and why `volumetric_fog_process.glsl` was bumped wholesale.
- **Godot's `re-spirv` specialization-constant optimizer does not understand `OpTypeRayQueryKHR`.**
  It prints `OpTypeRayQueryKHR is not supported yet.` and returns false, and the unoptimized SPIR-V
  is used instead. This is harmless and expected — do not chase it as an error. It is also a useful
  signal: counting those lines tells you exactly how many ray-query modules a run compiled.

---

## 2. The seams, by subsystem

For each: the upstream thing it attaches to, what kind of attachment, and what it assumes.

### 2.1 Acceleration structure — `rt_scene.{h,cpp}` (new files)

Wholly new, so there is nothing to merge; the question is only where it is called from.

| Hooks into | Kind | Assumes |
| --- | --- | --- |
| `RendererSceneRenderRD` (owns a `RaytracingScene`) | new member + call-in | that there is one scene-render singleton per renderer |
| `MeshStorage::mesh_surface_get_format` / `_get_primitive` | reads | the `ARRAY_FLAG_COMPRESS_ATTRIBUTES`, `ARRAY_FLAG_USE_2D_VERTICES`, `ARRAY_FLAG_USES_EMPTY_VERTEX_ARRAY` flags keep their meaning |
| Vertex buffer layout | **fragile** | that a surface's positions are the first attribute, and that compressed positions are 16-bit normalized within the surface AABB |

**The vertex format is the most fragile thing in the port.** Godot revises mesh formats between
versions. `rt_dequantize.glsl` exists solely because compressed positions are not a legal
acceleration-structure vertex format and must be expanded to `R32G32B32_SFLOAT`. If a newer Godot
changes the compression scheme, that shader and the format tests around it are what needs rewriting.
Everything else in this file is bookkeeping: a per-surface BLAS cache, a TLAS rebuilt when it stops
describing the scene, and per-frame build budgets.

To re-find it on a new engine: search for where the renderer decides a surface's vertex format, and
for `ARRAY_FLAG_COMPRESS_ATTRIBUTES`.

### 2.2 Skinning — `mesh_storage.{h,cpp}`

| Hooks into | Kind | Assumes |
| --- | --- | --- |
| The skinning compute pre-pass's output buffer | added usage flags | that skinned vertices land in a persistent GPU buffer, double-buffered, uncompressed |
| `mesh_instance_check_for_update` / `update_mesh_instances` | inserted call | that marking an instance and then flushing produces this frame's pose |

Godot's importers already disable vertex compression for skinned and morph-target meshes, so skinned
geometry is *already* in the format raytracing wants. This is why characters were the easy case.

The one non-obvious requirement: the skeleton pass normally only runs for instances that survived
frustum culling. Raytraced casters are deliberately *not* frustum-culled, so each off-screen caster
must be marked for skinning explicitly, and the flush must happen **before** the structure is built —
otherwise a character behind the camera casts the pose it held when it was last on screen.

### 2.3 Caster gathering — `renderer_scene_cull.cpp`

| Hooks into | Kind | Assumes |
| --- | --- | --- |
| `Scenario::indexers[INDEXER_GEOMETRY]`, queried by AABB | inserted query | that a spatial index of non-frustum-culled geometry exists and can be queried by region |
| The per-light shadow loop | new branch | that light instances are set up before shadow passes are decided |
| `InstanceGeometryData::can_cast_shadows` and the material caster test | reads | that the same test the shadow map path uses is reachable here |

This is the piece that makes "shadows from things behind the player" work, and it rests entirely on
that geometry indexer being present and region-queryable. It has been stable in Godot for a long
time; if it is gone, this is a redesign, not a port.

Also here: the gate that **skips rendering a shadow map** for a raytraced light, and the sun's
swept-frustum caster volume. Note the ordering constraint recorded in `FORK_GUIDE.md` — the
per-instance directional caster cull currently runs before the raytraced decision.

### 2.4 Light data — `light_storage.{h,cpp}`, `light_data_inc.glsl`

| Hooks into | Kind | Assumes |
| --- | --- | --- |
| `LightData` / `DirectionalLightData` GPU structs | **new struct fields** | that the C++ struct and the GLSL struct stay byte-identical |
| `RendererLightStorage` abstract interface | new virtual methods | that dummy and GLES3 backends must also implement them |
| `_light_instance_setup_directional_shadow` | new branch | cascade setup, `shadow_split_offsets`, and `fade_from`/`fade_to` derivation |

**The struct correspondence is maintained by hand.** `rt_slot` and `shadow_map_opacity` were added
to both sides. If a newer Godot adds a field to `LightData`, the two will silently disagree and
lighting will be subtly wrong rather than crash. There is a `static_assert(sizeof(LightParams) == 64)`
guarding the trace shader's own record — add the same discipline to any struct you extend.

Two semantic distinctions to preserve, because they are easy to collapse by accident:

- `shadow_opacity` — the light's authored shadow strength. Used by anything reading the mask.
- `shadow_map_opacity` — zero for a raytraced light with no map. Used by anything sampling cascades.

Getting these the wrong way round produces a scene that looks right until you add fog.

Also here: `_light_directional_effective_shadow_mode`, which demotes a raytraced sun's cascade
count. It is keyed on whether the light *could* be raytraced rather than whether it *was* this pass,
because the culler, the atlas layout and the light buffer run at different points and must agree.
Getting that wrong puts cascades in the wrong atlas rectangles.

### 2.5 Frame structure — `render_forward_clustered.cpp`

| Hooks into | Kind | Assumes |
| --- | --- | --- |
| `_pre_opaque_render` | inserted call | depth is resolved and light buffers are filled by this point |
| `force_depth_pre_pass`, `finish_depth`, `depth_pass_mode` | new branch | that a normal/roughness pre-pass output exists |
| `_update_volumetric_fog` call site | new argument | that the TLAS is valid at that point in the frame |

The ordering is the load-bearing part: the trace needs resolved depth, resolved normals, and the
frame's mask slot assignments, and it must complete before the opaque forward pass reads the mask.
On a newer engine, re-find the insertion point by looking for where the depth pre-pass is resolved
and where screen-space effects that consume depth+normals are dispatched.

### 2.6 Forward shading — `scene_forward_lights_inc.glsl` and friends

| Hooks into | Kind | Assumes |
| --- | --- | --- |
| `light_process_omni` / `_spot` / the directional loop | new branch | the shadow term is computed in one identifiable place per light type |
| Uniform set bindings | **new bindings** | that the indices claimed here stay free |
| `SCENE_DATA_FLAGS_IN_ALPHA_PASS` | new scene-data flag | that the transparent pass has its own `_setup_environment` call |

`scene_forward_lights_inc.glsl` is **shared with the mobile renderer**, so every raytraced block is
inside `#ifndef USING_MOBILE_RENDERER`. Forget that and the mobile renderer stops compiling.

The alpha-pass flag exists because the mask holds one answer per pixel and it belongs to the opaque
surface behind the glass; `RT_MASK_ANSWERS_HERE` is the predicate that decides whether a fragment may
trust the mask.

### 2.7 The shader-group technique — `fog.{h,cpp}`

Worth reading even if you do not care about fog, because it is the reusable pattern for **adding a
ray-query variant to an existing shader without costing anything to projects that never use it**:

1. Give the raytracing variants a `ShaderRD` group of their own, not the group the normal variants
   are in.
2. Do not create their pipelines at init — skip them in the pipeline loop.
3. Call `enable_group()` lazily, the first frame something actually needs them.
4. Put the acceleration structure in a **uniform set of its own** that only those variants declare,
   so every other variant's uniform set is byte-for-byte unchanged.
5. Guard the `#extension GL_EXT_ray_query` and the `accelerationStructureEXT` declaration behind the
   variant's own `#define`, so non-tracing variants compile to modules that ask the device for no
   raytracing capability at all — which is what keeps them working on hardware without ray query.

This was verified rather than assumed: with fog on and raytracing off, zero ray-query modules
compile and the render is byte-identical to the pre-change engine.

The same pattern is what the deferred subsurface-transmittance work should use, with the declaration
inside `#ifdef LIGHT_TRANSMITTANCE_USED`.

### 2.8 Node and settings surface

| Hooks into | Kind | Assumes |
| --- | --- | --- |
| `Light3D::_bind_methods`, constructors | new property, **changed defaults** | — |
| `RenderingServer` / `RenderingServerDefault` | new method | that adding one requires touching the dummy and GLES3 stubs too |
| `ProjectSettings::ProjectSettings()` | new registrations | that settings must exist before the rendering device is created |
| `doc/classes/*.xml` | generated | that `--doctool` is run and committed |

The settings are registered in `project_settings.cpp` rather than near their consumer specifically so
they exist before the rendering device is constructed. They are then resolved once into statics on
`RaytracingScene` — which is also why they are all effectively restart-required.

---

## 3. Rebuilding it, in an order that works

The 41 commits in this branch are in the order the work was *discovered*, which includes false starts
and later corrections. Do not follow that order. Follow this one; each stage ends somewhere you can
check before continuing.

| # | Stage | Ends when |
| --- | --- | --- |
| 1 | Settings, availability detection, a naive acceleration structure over the whole scenario | `GODOT_RT_DEBUG=1` prints a non-zero TLAS instance count |
| 2 | The trace pass and mask, hard shadows, forward shader reads it | One omni light casts a visibly correct hard shadow |
| 3 | Per-pixel top-four light selection and the light buffer plumbing | Many overlapping lights each shadow correctly |
| 4 | Denoiser: temporal reprojection first, then the à-trous passes | One ray per frame looks as good as sixteen did |
| 5 | Skinned and multimesh geometry | An animated character casts a correct shadow, including off-screen |
| 6 | Caster culling by light volume instead of the whole scenario | TLAS instance count stops scaling with level size |
| 7 | Stop rendering shadow maps for raytraced lights | `shadow_maps_rendered=0` with `raytraced=N` |
| 8 | Directional light in the same light pool | The sun casts a raytraced shadow |
| 9 | Demote the sun's shadow map | Zero directional atlas allocations for a fully raytraced sun |
| 10 | Quality: contact hardening, blue noise, sqrt encoding, variance clamp, nearest occluder | RMSE against a high-sample reference stops improving |
| 11 | Consumers: the alpha-pass fix, then volumetric fog | Sun shafts survive with no shadow map |

**Pitfalls that cost real time the first time.** Each of these was a bug that shipped and had to be
found again later:

- Unused cascade slots must be filled from the last real one. Fewer cascades otherwise means the
  shaders' final `else` reads an identity matrix.
- A shadow ray that stops at the *first* occluder rather than the *closest* gives the right
  visibility but the wrong penumbra width, and the denoiser over-blurs contact shadows.
- Temporal history needs a variance clamp, or a shadow moving across a stationary surface trails: the
  surface has no motion of its own for reprojection to follow.
- The denoiser's history must be decoded from sqrt space *everywhere* it is read. One missed decode
  lightens every umbra and is nearly invisible unless you measure it.
- Skipping the shadow map render must not also skip `set_shadow_transform` — the cascade split
  distances are derived from it, and the raytraced path reads those.

---

## 4. How to verify a port

Nothing here needs a real GPU. The original work was validated on **lavapipe** (Mesa's software
Vulkan) under Xvfb, rendering to PNG and comparing with a small Python script.

Be aware of what that setup distorts: lavapipe traverses the BVH on the CPU, so it **overstates**
rasterisation cost and **understates** the benefit of ray early-out. Treat its frame times as
directional only. Image comparisons are trustworthy, and reproducible to the byte.

The technique that settled most questions was RMSE against a high-sample, denoiser-off render of the
same scene — one-sample-plus-denoiser versus sixteen-sample ground truth. Edge-width metrics were
tried first and proved unreliable, because they were confounded by the two images having different
noise levels.

For "this change costs nothing when unused", the standard is byte-identical output: build the engine
with the change, render; stash the change, rebuild, render the same scene; compare checksums.
