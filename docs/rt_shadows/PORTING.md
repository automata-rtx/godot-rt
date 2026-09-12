# Re-applying raytraced shadows to a newer Godot

This document exists so the system in this fork can be rebuilt on a later version of Godot, by
someone -- or something -- that was not here when it was written the first time.

It is deliberately **not** a diff. On a newer engine the line numbers will be wrong, some functions
will have been renamed, and some structures will have gained fields. What survives that is the
*shape* of the integration: which upstream thing each piece hooks into, what it assumes about the
engine around it, and what the failure looks like when that assumption stops holding.

Most of the value here is in the **pitfalls**. Nearly every one is a bug that actually shipped and
had to be found again later, usually by measurement rather than by reading. They are recorded with
their symptoms because the symptom is rarely a crash -- it is a picture that looks slightly wrong.

Read `FORK_GUIDE.md` first for what the system does. This is about how it attaches.

Upstream base for the original work: `b56a91878e7c94977e4af978968e41d0670c0a8b` (Godot 4.8-dev).
To see any piece as it was written: `git diff b56a91878..HEAD -- <path>`.

---

## Stage 0 -- Preflight: is the raytracing layer still there?

Godot 4.7/4.8 shipped a **complete hardware-raytracing layer inside `RenderingDevice`** -- BLAS/TLAS
create and build, `UNIFORM_TYPE_ACCELERATION_STRUCTURE`, `SUPPORTS_RAY_QUERY` and
`SUPPORTS_BUFFER_DEVICE_ADDRESS` feature queries, AS-aware buffer creation bits, render-graph
barrier tracking -- with **no consumer anywhere in the renderer**. This fork is a re-integration, not
a reimplementation. If that layer has changed shape, that is the single largest risk in the port and
you must know it before writing anything else.

The one thing the fork *added* to `RenderingDevice`: **`acceleration_structure_is_valid(RID)`**,
mirroring the existing `*_is_valid` queries. It exists because an acceleration structure is freed
implicitly when a buffer it was built from is freed, and the owning mesh can be destroyed first -- a
cache that outlives its source meshes must be able to ask whether a handle is still live. A dead
handle takes the whole `tlas_build` down.

**Done when:** a throwaway `#version 460` compute shader with `#extension GL_EXT_ray_query : enable`,
an `accelerationStructureEXT` at set 0 binding 0 and a `rayQueryInitializeEXT`/`ProceedEXT` loop
compiles and links through Godot's own shader build, and a one-triangle BLAS plus one-instance TLAS
report true from the new validity query.

**Pitfalls:**

- **glslang gates the `rayQueryEXT` keyword and every `rayQuery*EXT` builtin on `#version 460`.**
  Every other shader in `renderer_rd` is 450. `accelerationStructureEXT` itself has *no* version
  gate, so a 450 shader compiles the uniform fine and only fails at the first `rayQueryEXT` -- the
  error reads like a shader-specific bug rather than a version problem. Ray query also cannot be
  hidden behind a preprocessor branch in a 450 shader; the whole file must go to 460.
- **Godot's `re-spirv` optimizer does not understand `OpTypeRayQueryKHR`.** It prints
  `OpTypeRayQueryKHR is not supported yet.` and falls back to unoptimized SPIR-V. Harmless and
  expected -- do not chase it. It is also the cheapest instrument available: counting those lines
  counts exactly how many ray-query modules a run compiled.
- **`tlas_build` rejects a zero `hit_sbt_range`** even for ray-query-only use with no shader binding
  table anywhere. Pass a synthetic `HitShaderBindingTableRange(int64_t(1) << 32)`.
- A TLAS's `max_instance_count` is frozen at create time; scratch buffers are per-structure and
  never pooled; build-input buffers need `DEVICE_ADDRESS` as well as the AS-input bit.
- **There is no refit or compaction entry point.** Every "update" of a BLAS is a full `blas_build`
  on the same RID.
- The Vulkan container targets SPIR-V 1.4 with a Vulkan 1.1 client -- exactly the minimum
  `GL_EXT_ray_query` needs. Check `RenderingShaderContainerFormatVulkan::get_shader_spirv_version`.
- **Creating an acceleration structure is not thread-safe; building one is guarded.** `blas_build`
  takes `ERR_RENDER_THREAD_GUARD` (`rendering_device.cpp:445`), but `blas_create` (`:302`) and
  `tlas_create` (`:423`) take neither that nor `_THREAD_SAFE_METHOD_`, where the equivalent
  `compute_pipeline_create` (`:5092`) does. They touch the frame's disposal lists and the render
  graph's resource tracker unguarded. So **every structure creation has to happen on the render
  thread**: scene cull records what needs building and the render step builds it.
- **`AccelerationStructure::invalidated` never re-arms.** It starts true and is cleared by a
  successful build (`rendering_device.cpp:460`, `:566`), but nothing sets it back when the vertex
  data underneath it changes. A skinned mesh whose deformed buffer was just rewritten leaves a BLAS
  that looks valid and is stale, with no diagnostic. The BLAS cache here tracks staleness itself
  rather than trusting the flag -- keep that if you port it.
- **`SUPPORTS_RAY_QUERY` can return true where every implementation body is compiled out.**
  Raytracing is `#define VULKAN_RAYTRACING_ENABLED 0` on macOS and iOS
  (`rendering_device_driver_vulkan.cpp:56`), but the feature query at `:7479` sits outside that
  guard. On a MoltenVK build advertising the extensions the query says yes and `blas_create()` then
  returns a null RID. `has_feature()` alone is not the capability test.
- **`misc/extension_api_validation/` treats a changed arity as non-additive**, default argument or
  not. Widening a bound method -- `blas_build(RID)` to `blas_build(RID, bool)` -- fails that gate;
  add a separate method instead. This is why the fork's one addition is a new
  `acceleration_structure_is_valid(RID)` rather than a widened existing call.

---

## The rebuild order

The commits in this branch are in the order the work was *discovered*, which includes false
starts and later corrections. Do not follow that order; follow this one. Each stage ends somewhere
you can check before continuing.

### 1. Settings and availability

Register the setting family, stand up `RaytracingScene` as a settings-plus-capability object with an
empty `update()`, thread the renderer-agnostic virtuals from `RendererSceneRender` down to
`RenderForwardClustered`, and widen mesh buffer creation bits. **Nothing traces yet and no pixel
changes.**

**Done when:** the engine boots with the setting on and off, a startup line reports whether
raytracing is *active* (the setting being on and the device being able to trace are different
questions and only the second matters), every frame is byte-identical to the unmodified engine, and
with the setting on a mesh's vertex buffer is created with `DEVICE_ADDRESS` and AS-build-input usage.

- The settings must be registered in `ProjectSettings`' own constructor, not near their consumer.
  `mesh_add_surface` decides buffer creation bits at upload time, **before the `RaytracingScene`
  object that would otherwise own them exists** -- which is also exactly why the master setting is
  restart-required. The RenderingDevice itself is up by then, which is what lets the predicate ask
  it for feature support.
- **Latch only the settings that genuinely cannot change; read the rest through
  `GLOBAL_GET_CACHED`.** The fork's first version resolved the whole family once behind a
  `settings_registered` flag, which quietly made every tuning knob restart-required while the editor
  advertised only two of them as such -- so turning the denoiser off in the inspector did nothing at
  all, with no feedback. `GLOBAL_GET_CACHED` keeps a typed copy keyed on `ProjectSettings`' version
  counter, so a live read costs an integer compare and the value reaches the renderer on the next
  frame. Only `enabled` truly has to be latched, for the buffer-bits reason above. Clamp on read
  rather than on registration: a live value arrives with no validation beyond the property hint, and
  several hints allow `or_greater`.
- **Widening the buffer bits is one predicate, one flag word, and two call sites.** The predicate --
  the fork calls it `_raytracing_buffers_required()` -- is the latched master setting AND
  `SUPPORTS_RAY_QUERY` AND `SUPPORTS_BUFFER_DEVICE_ADDRESS`. Ray query has to be tested even though
  nothing traces yet: testing only the setting and device address gave every mesh buffer AS usage
  nothing could consume on D3D12, whose `has_feature()` has no `SUPPORTS_RAY_QUERY` case and returns
  false. The flag word is `DEVICE_ADDRESS | ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY |
  AS_STORAGE`, and it is OR-ed in whole rather than decided per buffer. That is deliberate. Nothing
  ever checks a buffer's usage against what a structure build needs: `blas_create` validates counts,
  offsets and formats and then reports only that it failed, no message names a missing bit, and the
  fork's own message on that path blames the restart-required setting. Giving a buffer usage it never
  exercises is far cheaper than discovering at build time which ones needed it.

  | Allocation | Bits it gets | Why |
  | --- | --- | --- |
  | A surface's vertex, attribute, skin and index buffers, in the surface upload entry point (`mesh_add_surface`) | all three, OR-ed into whichever bits that code already computed | the vertex and index buffers are build input; the other two ride along in the same word |
  | That surface's LOD index buffers | none -- left at the default | only LOD 0 is ever traced, so a LOD buffer is never build input |
  | The per-mesh-instance vertex buffer that the skeleton and blend-shape compute pass writes into (`_mesh_instance_add_surface_buffer`) | device address and AS build input only | upstream already creates it with storage usage, since that pass writes it |

- **`AS_STORAGE` on the vertex buffer is the bit upstream would not have set, and it is not optional.**
  Upstream grants storage usage only to a surface that has skin data, has blend shapes, or asked for
  it through `ARRAY_FLAG_USE_STORAGE_BUFFER` -- a plain static mesh gets none of those. But the
  dequantize pass binds the mesh's *own* vertex buffer as a storage buffer to expand compressed
  positions, and that happens for static unskinned casters too. Strictly only the vertex buffer needs
  it; the attribute, skin and index buffers get it because it travels in the same word.

- **The second call site is the one that gets missed, and its failure mode is a decoy.** A skinned
  caster's structure is not built from the mesh's rest-pose buffer but from the per-instance buffer
  the deform pass wrote, so that buffer needs the same usage. Widen only the surface upload and every
  static caster works while every skinned one fails at `blas_create` -- and because that failure
  prints the message about mesh buffers uploaded before the setting was on, it reads as a stale
  setting. Restarting does not fix it. Note also that the helper is called again when a second buffer
  index is allocated for motion vectors, so both buffers of the pair must come from it.

  One further buffer takes the same rule but does not exist until stage 2: the expanded `float32x3`
  position buffer the dequantize pass writes is created with the device address and AS-build-input
  bits, because it, not the compressed source, is what the build reads.
- `_uses_raytraced_shadows()` must be a separate virtual, because the RT objects live on the shared
  RD base class. Without it the Mobile renderer looks capable, and its lights lose their shadow maps
  without gaining a mask.
- New include directions upstream does not otherwise have: `storage_rd` → `environment`
  (`mesh_storage.cpp` includes `rt_scene.h`), and `environment` → a generated shader header in
  `effects/`.
- clang `-Werror` rejects unused private fields; GCC and MSVC do not implement the diagnostic. A
  leftover flag cost a CI round.

### 2. Acceleration structure

One BLAS per mesh surface, one TLAS per frame, from a caster list gathered in the culler by querying
the geometry index with each candidate light's bounds. Includes the dequantize pass. **Build the
light-volume gather directly** -- the fork started with a whole-scenario walk, which ties cost to
level size and had to be replaced anyway.

**Done when:** `GODOT_RT_DEBUG=1` prints a non-zero TLAS entry count, and the count follows the
lights' reach rather than the level size. On a 400 m level of 2000 props lit by four ten-metre
lamps, the structure held seven casters, reached by visiting nineteen nodes of the geometry index.

- **The vertex format is the most fragile thing in the whole port.** Godot's default compressed
  positions (`ARRAY_FLAG_COMPRESS_ATTRIBUTES`, `R16G16B16A16_UNORM` normalized into the surface
  AABB) are not a legal AS vertex format; `rt_dequantize.glsl` exists only to expand them to
  `R32G32B32_SFLOAT`. Decode is `position.xyz * aabb.size + aabb.position`. If the newer engine
  changed the scheme, that shader and the format tests are what must be rewritten. **Re-find it** by
  grepping `_mesh_surface_generate_version_for_input_mask` for
  `offset = i == RSE::ARRAY_NORMAL ? position_stride * s->vertex_count : 0` -- if positions are no longer
  a contiguous `float32x3` block at offset 0 ahead of the attribute block, the zero-copy path is gone.
- Uncompressed surfaces are zero-copy: point at the surface buffer with offset 0, stride 12.
  Classify ineligible surfaces once (non-`PRIMITIVE_TRIANGLES`, `ARRAY_FLAG_USE_2D_VERTICES`,
  `ARRAY_FLAG_USES_EMPTY_VERTEX_ARRAY`, zero vertices) rather than retesting per frame.
- Use the surface's **LOD-0** index buffer; a LOD silhouette does not match the shadow the raster
  path would have cast.
- Set `ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT` on every instance.
  `shadow_reverse_cull_face` is per-light while the TLAS is per-scenario, so flip-facing cannot be
  honored at all.
- TLAS instance sourcing must live in `RendererSceneCull` -- `render_forward_clustered` cannot reach
  `Scenario` or `Instance`. Gather before the shadow loops; skip entirely for reflection-probe renders.
- Report each failure kind separately. `blas_create` failure almost always means the mesh was
  uploaded before the setting was on, which is the thing that makes the setting restart-required.
- Deduplicate with a per-`Instance` pass stamp: one instance is returned by every light that touches it.

### 3. Light slot pipeline

Give each raytraced light a stable index into a GPU light buffer and carry that index plus a second
opacity down to the shaders, **with nothing reading either yet**. Its own stage because it isolates
the highest-risk quiet breakage in the port.

**Done when:** `GODOT_RT_DEBUG` prints `new_slots=N` on the first frame and `new_slots=0` on every
frame after, including while walking through a ring of eight lamps that fully reorders the light
buffer. The render is still byte-identical.

- **`LightData` / `DirectionalLightData` are hand-maintained mirrors of the GLSL structs.** The fork
  *consumed the existing trailing pad* rather than growing them -- `float pad[2]` became
  `float rt_slot; float shadow_map_opacity;` on both sides. Do not grow either struct, or every
  offset after the change moves silently and lighting goes subtly wrong rather than crashing.
  **If the newer Godot has repurposed that padding, find two other slots and update both sides
  together, keeping `sizeof` identical.**
- `DirectionalLightData`'s pad changes type from `uvec2` to two floats deliberately -- the shader
  compares `rt_slot` as a float against `255.0`.
- **Slots must be sticky** (a light keeps its index while it keeps casting, plus a four-frame grace
  period). The denoiser's temporal history records which light each mask channel carried, so a light
  that changes index invalidates the whole screen's history. Assigning in light-buffer order -- which
  is sorted by distance to camera -- re-rolls every index as the camera moves.
- The buffer is therefore **sparse**: a slot may belong to a light outside this pass. Zero the gaps
  and let the trace skip them by `radius <= 0`. That is also why a live light's radius must stay
  positive whatever its type.
- **Grant a slot only when a built TLAS exists this frame.** A slot with nothing behind it makes the
  forward shader skip the shadow atlas *and* read "fully lit" from the mask: the light casts no
  shadow from any source, which is strictly worse than not enabling the feature.
- The ray cull mask each light traces with folds from its own **`shadow_caster_mask`**, not its cull
  mask -- this is the per-light mask, distinct from the per-instance `layer_mask` folded where the
  TLAS instance is written
  (which decides what the light *lights*). Fold 32 bits to 8 by OR-ing the four bytes --
  conservative, never under-inclusive -- and promote a zero fold to `0xFF`.

### 4. Trace and mask

First raytraced shadow on screen: the trace compute shader, the mask and its companion index
texture, the forward-pass read, and the depth prerequisites. **Build the per-pixel top-four
selection from the start**; the fork's first design was a global channel-per-light mask, which caps
a scene at four lights and was thrown away.

**Done when:** an omni light over a box casts a correct traced shadow with the setting on and the
stock shadow map with it off; a room of many overlapping lamps each shadow correctly; a project with
the setting off renders byte-identically.

- **`rt_shadow_lookup()` must live in `scene_forward_lights_inc.glsl`** (fragment-only), *not* in
  `scene_forward_clustered_inc.glsl`, which the `#[vertex]` stage also includes. `gl_FragCoord` does
  not exist there, every Forward+ vertex variant fails to compile, and **the symptom is the editor
  appearing to hang on the splash screen** with the CPU at 90-120 ms and the GPU idle.
  `scene_forward_lights_inc.glsl` is the one shared with the mobile renderer, so every block added to
  *that* file needs `#ifndef USING_MOBILE_RENDERER`.
- `texelFetch` on a bare `texture2D` requires `GL_EXT_samplerless_texture_functions`, which these
  shaders do not enable. Build a combined sampler -- `sampler2D(rt_shadow_mask, SAMPLER_NEAREST_CLAMP)` --
  the way `ssil_buffer` and `ssr_buffer` do.
- Reconstruct world position with `scene_data->get_cam_projection()` / `get_cam_transform()`, which
  carry the reverse-Z + Y-flip correction and the TAA jitter the depth buffer was written with.
  Using the raw members collapses every pixel to ~0.1 units from the camera and the mask comes out
  black wherever geometry was drawn.
- Read the real view-space normal from the normal/roughness pre-pass and rotate it to world space
  with a **quaternion** in the push constant. A normal crossed from two neighboring depth taps
  fringes every silhouette; the camera basis will not fit in 128 bytes beside the inverse
  view-projection.
- `normal_roughness` is not produced by default -- that is why `depth_pass_mode` is forced.
  `has_normal_roughness()` is a sticky global and must not be used as a gate. Reflection-probe
  renders have no `rb_data` at all.
- **Bindings 37 and 38** are appended to `RENDER_PASS_UNIFORM_SET` (set 1); upstream's highest was
  36. They must be added on **every** path through `_setup_render_pass_uniform_set`, including
  reflection-probe and no-render-buffer renders, with fallbacks: `DEFAULT_RD_TEXTURE_WHITE` for the
  mask and a new 1×1 all-`0xFF` `R8G8B8A8_UINT` texture for the index -- none of the shared default
  textures are integer-formatted. **On a newer engine, find the highest binding in that set and
  renumber both the C++ pushes and the GLSL declarations in lockstep.**

**Light selection is two stages, and only the second ranks.** The trace's workgroup is one 8×8 tile
of pixels -- `TILE_SIZE` 8, so `local_size` is 8×8×1 and 64 threads. The tile exists so the sweep over
the light buffer happens once per 64 pixels rather than once per pixel: what the shader is handed is
the whole sparse slot table, sized to the highest live slot and capped at `MAX_RT_LIGHTS`, with
nothing narrowing it per view or per tile, so each thread walks every sixty-fourth row of it, twice.
The tile stage only admits or rejects, into an unordered list. The per-pixel stage is the only place
anything is compared against anything else.

**Tile stage.** Each thread reconstructs its own world position from depth and the 64 of them reduce
a world-space bounding box in shared memory with `atomicMin` / `atomicMax`. Shared-memory atomics are
integer only, so a float is first mapped onto a uint whose unsigned order matches the float's:
invert all thirty-two bits when the sign bit is set, otherwise set the sign bit, and undo that on
read. Only threads with a surface contribute -- in bounds *and* reverse-Z depth greater than zero, so
sky and the ragged edge past the screen are excluded, and a tile contributes anywhere from zero to
sixty-four positions. Initialize the min to `0xFFFFFFFF` and the max to `0`, which that encoding
places above and below every real coordinate; then `min[0] <= max[0]` is the entire test for "this
tile has geometry" and no separate flag is needed. Both claim passes below sit behind it, so a tile
of pure sky claims nothing and its candidate list stays empty.

A lamp is admitted when its sphere meets the box: `closest = clamp(light.position, bounds_min,
bounds_max)`, and it meets it if `dot(closest - light.position, closest - light.position) <= radius * radius`.
Rows with `radius <= 0` are the sparse buffer's gaps and are skipped before that. **There is no cone
test here.** Narrowing a spot light to its cone at tile level would be sound, but it is the wrong way
to be wrong: an extra candidate costs one rejected distance test in the per-pixel stage, a missing
one costs a shadow.

**Directional lights are claimed in a pass of their own, ahead of the lamps, with a `barrier()`
between the two passes.** They get no geometric test at all: a sun reaches every surface there is,
and its only range question -- is the receiver inside the view *depth* range the culler gathered
casters for -- is per pixel. Do not substitute a sphere around the camera, which answers a different
question: radial distance is always at least the view depth, so it rejects tiles the per-pixel check
accepts and the corners of the frame lose the sun before its fade was meant to start. The ordering is
what makes the sun outrank every lamp under overflow, and the barrier is what makes the ordering
real -- without it a fast thread's lamp can take a low slot ahead of a slow thread's sun. That pass
can never fill the list by itself, because upstream caps a pass at eight directional lights:
`MAX_DIRECTIONAL_LIGHTS` on the base scene-render interface, which is where the scene culler stops
gathering them and what sizes the directional light uniform buffer.

**Overflow drops before ranking, and drops completely.** Both passes claim with `atomicAdd` on a
shared counter and store only where the returned slot is below `MAX_TILE_LIGHTS` (128); the counter
keeps climbing past that, and the per-pixel loop reads `min(count, MAX_TILE_LIGHTS)`. A light whose
claim lands at slot 128 or beyond is therefore never scored, never compared, and has no shadow-map
fallback -- it renders fully unshadowed across that whole tile. Which lights lose is decided by the
order the atomics happened to resolve in, so it is arbitrary and can differ between adjacent tiles.
This is a second, coarser ceiling above the per-pixel four, and it is the one that has no graceful
degradation, which is exactly why the sun is taken out of the race.

**Per-pixel stage.** Every pixel with a surface walks its tile's candidate list, discards what does
not reach it, scores what does, and keeps the best four. The four discards, in order: a directional
light whose `view_depth` exceeds its `radius`; a lamp at more than `radius` or nearer than 1e-4; a
spot light where `dot(-L, axis) < cos_spot_angle` -- outside the cone it contributes nothing, so
leaving it lit and letting ordinary attenuation handle it is correct; and finally anything scoring
zero, which after the range tests can only mean the surface faces away.

The score is
`max(energy, 1e-4) * falloff² * max(dot(N, L), 0)`, with `falloff` a flat `1.0` for a directional
light and `max(1 - distance / max(radius, 1e-4), 0)` for a lamp. `N` is the pre-pass normal rotated
to world space, not the normal-mapped one; `L` is the unit vector toward the light, which for a
directional light is the record's own direction. Each term is there for a reason and none is
decorative. The falloff is squared because it stands in for irradiance. `dot(N, L)` is what stops
the lamps *behind* a surface -- in a room lit from every side, most of them -- from taking channels
from the ones in front of it, since a light below the horizon is fully shadowed by the surface
anyway. `energy` is floored rather than used raw so that a light left at zero energy still outranks
an empty channel instead of quietly losing its shadow; that floor is also why fading a muzzle flash's
energy to zero releases neither its channel nor its rays, and `visible = false` is what does. A
directional light does not attenuate, so it scores flat and outranks a lamp on any surface the lamp
is not close to, which is the right way round outdoors -- and it costs nothing to lose the channel at
the far end of its range, because the shadow has faded out by then anyway. **There is no colour or
luminance term**, and the record carries no colour: a channel is worth the same whatever the light's
hue.

Insert by strict `>` into a four-entry array held in descending score, the displaced entry cascading
down it. Strict rather than `>=` so that a candidate which merely ties the entry it meets leaves the
array alone instead of reshuffling it for nothing; the tie then falls to whichever light the tile's
candidate list reached first, and since that list is shared memory walked in one order, every pixel
in the tile settles it the same way.

**Then sort the four survivors by ascending light index.** A bubble sort over four entries is the
whole of it, and it sorts the index array only; the scores are not read again. This is not cosmetic.
Both denoiser stages compare the *entire* four-index vector for equality to decide whether a sample
may be blended -- the temporal stage rejects a history tap whose vector differs, the à-trous stage
rejects a spatial tap whose vector differs -- and ranking order is not canonical, since it turns on
distance and normal and so changes across a surface and between frames. An equality test over a
non-canonical order rejects nearly every tap, and the result collapses back to the center pixel with
its single ray of noise intact. Sorting by index makes the *set* the only thing that matters. It also
packs the live channels into the low channels for free, because `SLOT_NONE` is 255 and slot indices
stop at 254 (`MAX_RT_LIGHTS` is 255), so the sentinel always sorts last.

Two structural rules the shader depends on. Every invocation must reach every `barrier()`, so the
early return for threads off the right or bottom edge of the screen goes *after* the last tile
barrier, not at the top of the shader. And every pixel that is on screen writes all three images
unconditionally -- whether or not it has a surface, and whether or not any light reached it -- with
fully lit visibility, zero hit distance and four `SLOT_NONE` channels. Nothing clears those three on
a frame the trace runs: they are cleared once at creation, and the white fallback clear covers only
the frames the trace does not run at all. Both denoiser stages decide there is nothing here to do
with `depth <= 0 || index == all SLOT_NONE`, and the forward pass matches its own light's slot
against that same index texel. A lit surface no raytraced light reached is exactly the pixel where
only the index half of that test can fire, so a texel left unwritten there is read as a real light
assignment carrying last frame's visibility.

### 5. Denoiser

Temporal accumulation plus an edge-stopping a-trous filter, both keeping their own history so the
feature does not depend on the image's TAA.

**Done when:** after ninety frames of camera movement the denoised result is byte-identical to a
converged render from the same pose, and a camera orbiting at 3.4°/frame lands within 2/255 of a
static converged render.

**The chain.** One temporal pass, then `spatial_passes` a-trous iterations with a doubling step of
`1 << i` -- at the default of three that is 1, 2 and 4 pixels, so the outermost tap of the last pass
sits eight pixels out. The temporal pass reads the trace's mask and writes ping-pong buffer A; each
a-trous iteration reads one ping-pong buffer and writes the other, except the last, which writes the
mask itself, so the forward pass reads the same one texture whether the denoiser ran or not. Only
the **first** a-trous iteration writes history, and what it writes is its own *input* -- the temporal
accumulation -- never its output.

**Four history textures, two of which look like one quantity stored twice.** They are not, and
the split is what lets an 8-bit accumulator work at all.

| Texture | Format | Written by | Read by |
| --- | --- | --- | --- |
| history visibility | `R8G8B8A8_UNORM` | first a-trous iteration | temporal, next frame |
| history index | `R8G8B8A8_UINT` | first a-trous iteration | temporal, next frame |
| history meta | `R16G16_SFLOAT` | first a-trous iteration | temporal, next frame |
| history length | `R8_UNORM` | temporal | a-trous, **same** frame |

History **length** carries the accumulation count sideways within one frame, from the temporal pass
to the a-trous pass, which needs it to widen a freshly disoccluded pixel's filter. History **meta**
carries that same count plus the depth forward to the next frame: R is a raw linear view distance,
G is the count. Both store the count **normalized to the accumulation window** (`temporal_frames`,
32 by default), because the length texture is eight bits and cannot hold a raw frame count; meta
stores the normalized value it was handed rather than re-deriving one, and **the temporal pass is
the only place that multiplies back up by the window**. Getting that asymmetry wrong -- writing
normalized and reading raw anywhere in the loop -- pins the blend factor at 1 and throws the history
away every frame, which reads as a denoiser that simply does not work rather than as a bug with a
location.

**The surface test, exactly.** For each of the four bilinear taps around the reprojected position,
in this order: reject the tap if it falls off screen; reject it if the **previous** frame's index
texel there is not equal in all four channels to **this** frame's index at the center; then reject
it on a **relative** depth test,

    abs(stored_depth - expected_depth) / max(expected_depth, 0.001) >= 0.02

where `expected_depth` is the reprojected `w` multiplied by this pixel's own linear view depth. The
tolerance is relative rather than in meters so that distant geometry, where depth precision and
reprojection error are both worse, is not rejected purely for being far away; `0.02` is a fork
constant, not a setting. Taps that survive are weighted by the ordinary bilinear weights and the sum
is divided by the weight that actually survived, so a partial rejection still yields an unbiased
history. If nothing survives, that is the disocclusion path: the history length stays zero, the
accumulator's alpha comes out 1, and the pixel takes this frame's raw trace.

- **Reproject with the camera, not motion vectors.** The velocity buffer is written by the opaque
  colour pass, which runs *after* the mask is needed, so it is a frame stale; under MSAA it is only
  resolved when TAA or an upscaler asks. Camera reprojection is exact for static geometry, and
  geometry that moved on its own is then rejected by the surface test rather than smeared.
- The `w` of a reprojected position is the previous clip position scaled by the reciprocal of view
  depth -- **a ratio, not a distance**, which is why the test above scales it back up. Compare it
  against a tolerance in meters instead and every tap is rejected every frame; the failure is
  silent, because the accumulation simply never builds and the only visible sign is a spatial filter
  that never narrows -- the a-trous goes on widening pixels it believes were just disoccluded. Store
  the history's depth as a raw view distance.
- **Feed the temporal stage back its own output as history, never the a-trous result.** Filtering
  inside the loop compounds without bound -- a two-pixel kernel arrives on screen as a twenty-pixel
  smear.
- Channel assignments are per pixel and **cannot be interpolated**: filter the temporal history by
  hand, accepting or rejecting each bilinear tap on its own, and reject a-trous taps whose index
  assignment differs from the centre's.
- **Both passes return early on the same two tests, and neither one looks at the visibility
  values.** A depth of zero is sky under reverse-Z; an index of `SLOT_NONE` in all four channels
  means no raytraced light reaches the pixel, which the trace leaves fully lit in every channel.
  Both paths pass the value straight through. The sky half is a must-not: filtering there would pull
  neighboring geometry into the sky, and a history left behind bleeds into whatever moves in front
  of it later. The unreached half is free -- in an outdoor scene it is most of the screen, and any
  neighbor that passes the index-equality test is unreached too and therefore also fully lit, so
  the twenty-four taps provably resolve to the center value. Do **not** write this test as "the mask
  is fully lit in all four channels". A pixel a light does reach and that happens to read fully lit
  is one noisy sample inside a region that still needs filtering, and skipping it leaves speckle.
- **Every early return in the history-writing iteration must still write all three forward-carried
  history textures**, or next frame reprojects against the frame before last. The two exits write
  deliberately different meta. The shared early-out above -- sky, or a pixel no raytraced light
  reaches -- writes zeroed meta, and a stored zero fails the relative depth test against any real
  distance, so nothing reprojects onto it. The reach early-out that stage 6 adds writes the pixel's
  real view distance and history length, because that pixel is a surface the temporal pass will
  reproject onto.
- Multiview is not a fallback inside the denoiser; the whole raytraced path is off. The availability
  query that gates the mask returns false unless the view count is one, so a stereo render traces
  nothing, warns once, and every light keeps its shadow map. A stereo pair would need its own trace
  and its own full set of history per eye, and none of these passes are layered.

### 6. Denoiser quality

Make one ray per light per frame match a sixteen-sample reference: penumbra-driven filter width,
blue-noise rotation with a jittered radius, sqrt-encoded mask, temporal variance clamp with a
binomial floor, dithered accumulator stores, closest-occluder distance.

**Done when:** the 10-90 penumbra width matches a closed-form ground truth across a contact
hardening curve, not merely when an RMSE stops improving. Build the reference from the geometry
rather than from another render: a lamp of known radius over a post of known size, with a
perspective camera, and confirm the model first by checking that the 50% crossing of the shadow
edge lands within a pixel of the analytic edge at every distance. RMSE against a rendered reference
will not catch any of the three defects below, because all three are present in the reference too.

Recover the shadow term before measuring, and do it in linear light. Linearize both frames first,
then divide the render by an occluder-free render of the same scene: in linear light that cancels the
falloff and the lambert term and leaves visibility, which is the quantity the geometry predicts.
Dividing the encoded frames instead cancels the falloff and the lambert term but not the transfer --
the quotient is visibility still encoded, so a 10-90 read off it crosses the real visibility at
roughly 0.006 and 0.79 under a 2.2 power law, a far wider band than the geometry predicts. A 10-90
measured on pixel values with no division at all is a 10-90 of a
tonemapped product and does not correspond to anything.

Three defects each squeeze or stretch the penumbra, and each is invisible without that ground truth:

- **No pair of rays can early out for a disk.** Probing the emitter with two rays and stopping when
  they agree is a large saving, but two points on the rim, opposite each other, still both read lit
  over the whole outer half of a penumbra -- where a fifth of the emitter is covered they agree a
  third of the time -- and the binary answer pulls that pixel to fully lit. The umbra side goes the
  same way. It cost 28% of the penumbra's width at sixteen samples per light and less at lower
  counts, so the shadow got *sharper* as the sample count rose. Trace every sample. Skipping settled
  work is still worth having, but it has to learn the penumbra is absent from somewhere other than
  the rays it is trying to avoid.
- **A variance clamp needs a floor.** With a handful of rays per pixel the 3x3 neighborhood used for
  the clamp agrees outright in the shallow ends of a penumbra -- at one ray per light and a true
  visibility of 0.95, about two frames in three -- so the measured spread is exactly zero and the
  history is pinned to that binary answer. It removed a third of every penumbra. Floor the spread
  with the standard error the ray counts carry, with two pseudo-counts so the floor cannot collapse
  with the spread.
- **An 8-bit accumulator that re-reads its own output must round stochastically.** Once the step the
  accumulator wants is under half a quantization level it stops moving, and not symmetrically: rare
  large steps land and frequent small ones do not, so the value ratchets. It made the stock penumbra
  15% too wide. Dither the store by a per-pixel, per-frame fraction of a step.

**The a-trous tap weight, exactly.** A 5x5 tap set, stepped by the iteration's step size. Three
terms are shared by all four channels because they describe the surface, and one is per channel
because it describes each light's penumbra:

| Term | Value |
| --- | --- |
| kernel | `KERNEL[abs(x)] * KERNEL[abs(y)]`, `KERNEL = {0.375, 0.25, 0.0625}` -- the 5-tap B3 spline row |
| depth | `exp(-depth_error / depth_sigma)`, `depth_error = abs(tap_depth - center_depth) / max(center_depth, 1e-6)`, `depth_sigma = 0.02` |
| normal | `pow(max(dot(center_normal, tap_normal), 0.0), normal_sigma)`, `normal_sigma = 64.0` |
| reach, per channel | `clamp(1 - length(vec2(x, y)) * step_size / reach_pixels, 0, 1)` |

The center tap takes `KERNEL[0] * KERNEL[0]` and none of the other three; a tap is dropped outright,
before any of this, if its depth is zero or its index differs from the centre's. `depth_sigma` and
`normal_sigma` are fork constants pushed from C++ with no project setting behind them, because the
reach term is what the look is tuned with.

The depth term runs on **raw reverse-Z depth buffer values, with no plane fit and no
linearisation**. Reverse-Z is proportional to the reciprocal of view distance, so a relative
difference in depth is already a relative difference in distance for every projection of this
family, and no tap has to be reconstructed into view space to find out. Orientation is not folded
into that term; it is the separate normal power beside it. Do not assume this is the same test as
the one in this fork's occlusion denoise and swap either for the other: that filter reconstructs
each tap and weights it by its distance from the shaded point's own plane, for the reason its own
header comment gives -- a relative depth difference has no notion of orientation, so on a plane seen
at a glancing angle it discards neighbors lying on the very plane being shaded. Normals here are
compared only against the centre's, so the pass can use the pre-pass encoding (`xyz * 2 - 1`)
directly and never needs the world-space rotation the trace does.

**There is no variance term and no variance buffer.** The filter's width comes from the traced
occluder distance, which is a measurement of the penumbra rather than an estimate of the noise, so
there is nothing here corresponding to SVGF's variance channel. The one spread this system does
measure -- the 3x3 moments -- belongs to the temporal clamp, not to the spatial filter.

**The noise source is baked into the trace shader.** A 32x32 void-and-cluster (Ulichney) blue noise
mask, as `const uint BLUE_NOISE[256]`, four 8-bit values packed per 32-bit word. There is no
texture, no binding and no generation step, so it costs nothing to have and cannot be lost in a
port. A value is read as:

    index = (pos.y & 31) * 32 + (pos.x & 31)
    value = float((BLUE_NOISE[index >> 2] >> ((index & 3) * 8)) & 0xFF) / 255.0

The two sampling dimensions are the same function read at two positions, the pixel and the pixel
offset by `(13, 7)` -- far enough apart to give two well-spread values that are not copies of each
other. Blue noise is load bearing rather than decorative: its energy sits at high spatial
frequencies and almost none at low ones, and the spatial filter downstream removes high frequency
error well and low frequency error hardly at all. White noise here does not resolve at one ray.

**Advance the pattern additively by the R2 lattice pair `vec2(0.7548776662, 0.5698402910)`**, as
`fract(spatial + float(frame) * R2)`. Not a golden-ratio step, and not a shift of the sampling
position: shifting the position re-rolls the pattern every frame and gives each pixel an independent
sequence that can revisit nearly the same point, whereas adding an irrational increment spreads a
single pixel's own sequence as evenly as any sequence can -- and the temporal accumulation is
averaging exactly that sequence. The two increments are R2's pair rather than two independently
chosen irrationals, because R2 is the construction that stays evenly spread *jointly* and not merely
one dimension at a time. The first output becomes the disk's rotation (times 2π), the second its
radial jitter. Do not confuse this with the temporal pass's store dither, which is a different
generator for a different purpose -- interleaved gradient noise plus a `frame * 0.61803399` advance
-- and which is the golden-ratio step in this system.

**Jitter the Vogel disk's radius; do not pin it to the stratum center.** The sample is
`r = sqrt((index + radial_jitter) / count)` at `theta = index * 2.39996323 + phi`. At the shipped
default of one sample per light, a fixed 0.5 puts that single ray at `sqrt(0.5)` of the emitter
radius on every frame, and with only the angle moving the temporal average converges on the shadow
of a **ring at 0.707r** rather than of the disk. The width barely moves, because a ring at 0.707r
spans nearly the same 10-90 as the disk containing it -- which is why a width metric alone does not
catch it -- but the shape does: a ring's projection piles up at its two extremes where a disk's
bulges in the middle, so the falloff comes out S-shaped where it should be smooth. Jittering makes
that same one ray sweep the whole emitter with the correct area weighting; at higher counts it is
ordinary jittered stratification and is still the better estimator.

- **Decode out of sqrt space everywhere it is read.** Averaging roots and squaring darkens every
  penumbra by Jensen's inequality; one missed decode lightens every umbra almost invisibly unless
  you measure it. (NVIDIA's SIGMA filters *in* sqrt space on purpose; this system does not.)
- `min_filter_pixels` below 1.0 is meaningless and above it grays everything: the kernel's nearest
  tap sits at exactly 1.0 px, so a floor of 1.5 leaves it at a third weight and turns a perfect step
  edge into 0.863/0.137 -- a two-pixel fringe on every contact shadow.
- At one sample a ray that misses reports **no** penumbra, so sizing the filter from the center pixel
  alone smooths the shadowed half of a penumbra and leaves the lit half speckled. Take the widest
  penumbra any immediate neighbor reports; at a real contact edge every neighbor reports zero and
  it costs nothing.
- **Do not set `gl_RayFlagsTerminateOnFirstHitEXT` by default.** Visibility is identical either way,
  but the reported distance becomes whichever occluder traversal reached first rather than the
  nearest, which mis-sizes the penumbra and over-blurs crisp shadows. Keep the flags in the push
  constant, not a define, so the trade costs no second pipeline. Decide it per light rather than per
  dispatch: a light of zero size sets the flag whatever the setting says, because both penumbra
  formulas multiply by the emitter size and throw the distance away, so the accuracy it bought
  cannot reach the picture.
- Both floors (`min_filter_pixels` and the history-fill widening) must apply **only where a penumbra
  was actually measured**, or a pixel a light reaches but no ray hit is dragged into the tap loop at
  that floor -- up to the eight pixels the setting allows -- and takes
  thirty-one frames to recover -- every camera turn does that to the newly revealed screen edge.
  The a-trous also skips the whole tap loop where no channel's reach survives a single step, which
  catches two common cases at once: a pixel a light reaches but no ray hit, so there is no blocker
  to measure a penumbra to, and a contact shadow sitting at the default one-pixel floor, where the
  first pass's step already equals the reach.
- Ray offsets come from the light's own bias properties **scaled down** -- a shadow map's bias clears
  a depth texel, a ray only clears the error in a position reconstructed from depth. A directional
  light defaults normal bias to 2.0 where a lamp defaults to 1.0, so it needs half the scale or the
  sun's contact shadows lift off their casters.

### 7. Deforming casters

Skinned and blend-shaped meshes cast their current pose, on screen or not.

**Done when:** a two-bone skeleton bending a bar casts a straight shadow at rest and a bent one at
0.7 rad, differing over 8.7% of the frame -- and still does with the caster above the top of the
frustum.

- `update_mesh_instances()` only runs the skeleton pass for instances that survived frustum culling,
  and raytraced casters are deliberately **not** frustum culled. Without an explicit second
  mark-and-flush *before* the structures are built, a character behind the camera is frozen at
  whatever pose it last held on screen.
- **Key the cache on the skinned vertex buffer, not the mesh.** That buffer is already unique per
  (instance, surface), and the skeleton pass double-buffers it when motion vectors are on, so keying
  on the buffer gives each side of the pair its own BLAS rebuilt in place rather than recreated as
  the pair alternates. A surface with a mesh instance but no deformation falls back to the mesh's
  shared BLAS. `mesh_instance_get_last_change()` is the staleness version.
- Godot's importers already disable vertex compression for skinned and morph-target meshes, so
  skinned geometry is already in the format the AS wants -- this is why characters were the easy
  case, and it is worth re-checking on the newer engine.
- No refit, so each pose is a full `blas_build` (which does reuse the existing scratch allocation).
  Per-instance structures need eviction -- the fork evicts after 60 unused frames -- or every
  character that ever existed keeps one alive.

### 8. MultiMesh casters

Expanded CPU-side into one TLAS entry per element sharing one BLAS.

**Done when:** a GridMap interior stops leaking light into the next room; twelve pillars in one
MultiMesh become twelve TLAS entries backed by one built BLAS.

- A multimesh is one instance in the scene's spatial index and many in the structure. Every element
  shares the mesh, so they share its BLAS and differ only by transform, which is exactly what a top
  level structure is for. The expansion belongs to the culler: the caster record has no multimesh
  field, and the renderer sees one record per element whose transform is the instance transform
  times the element transform.
- **Iterate the visible element count, not the allocated one**, whenever the multimesh reports one --
  it reports `-1` for "all", so the test is on the sign, and the visible count is then clamped to the
  allocation in case it was set larger. Elements past the visible count still hold whatever transform
  was last written there. Tracing against them while drawing nothing from them puts a shadow in the
  scene with no object under it, which is the hardest kind of shadow bug to attribute.
- Reject a multimesh whose mesh is null, and reject 2D transforms before asking for any element
  transform: `multimesh_uses_3d_transforms` is the query the fork adds to mesh storage for this, and
  a 2D element transform is not the matrix the structure needs.
- **Test every element against the light bounds.** A multimesh instance's own AABB covers the whole
  field, so without a per-element test a single large GridMap octant fills the structure with
  elements no light can reach. Bound each element by putting the shared mesh's own AABB through the
  composed transform, and intersect that against the lamp bounds the gather queried with. A
  directional light's swept volumes are consulted only as a second chance, and only when
  `scatter_casters` allows it; stage 12 has the order of the two tests and what each value of that
  setting admits.
- The per-element test consults the **whole** lamp bounds list, including the lamps the gather itself
  skipped because a directional volume already enclosed them -- which is why stage 12 partitions
  those to the back of the list rather than dropping them. Drop them and the bug shows up as
  scattered props missing their shadows only near a lamp, only with a sun in the scene.
- Because a raytraced light has no shadow-map fallback, an unsupported caster type is an **absent**
  shadow, not a degraded one -- and turning the feature off brings the shadows back, which reads as
  the feature being broken. Bound the total at `MAX_RT_CASTERS`, which is **65536**, and warn once
  when the bound is hit rather than truncating silently. The bound has to be re-checked inside the
  element loop as well as around the instance loop, or one multimesh can overrun it on its own.

### 9. Caster eligibility

Only surfaces that can actually write a shadow enter the structure, decided per surface.

**Done when:** a pane of glass in front of a lamp costs one fewer structure entry and stops casting
a solid shadow.

- Compute the mask where upstream already computes its instance-level shadow-casting answer: the
  dirty-instance update that walks an instance's per-surface materials, appends each to the instance
  uniforms and registers each as a dependency of the instance. Store it on the instance's geometry
  data beside `can_cast_shadows`. Invalidation is then free -- the material dependency that already
  re-dirties the instance when a material is swapped at runtime recomputes the mask in the same pass
  -- and no new bookkeeping exists to get wrong.
- The mask starts all ones and a bit is only ever cleared, for a surface whose material is
  *definitely* unable to write a shadow. A surface with no material casts. A `material_override`
  replaces every surface, so an override that cannot cast zeroes the whole mask at once. Surfaces at
  index 32 and beyond have no bit and always cast. A multimesh's surfaces are read from the shared
  mesh's own materials, so one mask covers every element of it.
- It arrives as a new **pure virtual** on the shared material storage interface,
  `material_shadow_casting_disabled` -- true when the material's shader blends rather than writing
  depth, or reads the screen, depth or normal texture, none of which a shadow pass has. The RD,
  dummy and GL backends each need an implementation before the engine will link; the last two return
  `false`, since nothing outside Forward+ consults it.
- **This is not the negation of upstream's `material_casts_shadows`.** That predicate errs toward
  yes: a material whose shader cannot cast and which has no `next_pass` still answers true, so the
  instance stays in the shadow render list and each draw decides for itself with the material in
  hand. A raytraced caster is decided once, as it enters the structure, and needs the exact answer.
  That terminal case is precisely where the two differ, and it is the common one -- a pane of glass.
  Write `!material_casts_shadows` instead and the mask is all ones forever, which looks like the
  stage working. Both walk `next_pass` the same way, so a later pass that does cast rescues one that
  does not.
- The mask sits **on top of** upstream's instance-level answer, which the caster gather still tests
  before an instance is considered at all. That is what handles `material_overlay`, `cast_shadows`
  set to Off, and everything else upstream already folds in; the mask deliberately does not repeat
  any of it. Two tests, two questions: may this instance cast, and which of its surfaces.
- Alpha-scissor and alpha-hash materials **do** cast, with the cutout ignored -- a leaf card throws
  the shadow of its whole quad. Upstream marks both as casting because the depth prepass gives them
  a depth to write, this predicate agrees, and the structure has no way to honor the cutout. That
  is a documented limitation, not something this predicate fixes.

### 10. Structure lifetime and budgets

**Done when:** dragging a `BoxMesh`'s size in the inspector no longer prints `Parameter blas is null`
at frame rate, and shadows survive the session.

- **The cache key is `SurfaceKey { RID source; uint32_t surface; }`, and only `source` varies by case.**
  `surface` is the index in the walk over the mesh's surface count, and it is what separates the
  surfaces of one mesh that share a `source`. `source` is the per-instance skinned vertex buffer when
  the caster record carries a mesh instance and mesh storage's per-surface skinned-buffer accessor
  returns one -- stage 7 has why -- and the **mesh RID** in every other case. Every other case is the
  common one: the culler fills that field only on the single-mesh path, so every static mesh and every
  multimesh element keys on the mesh, and one built structure per surface serves all of them. That is
  what makes the multimesh expansion in stage 8 cheap, since an element contributes a transform and
  nothing else.
- **Do not key a static entry on the surface's own vertex buffer, even though that is what it builds
  from.** The mesh RID is valid for every caster the gather can hand over -- the walk skips a record
  with a null mesh -- and it stays valid across a surface being cleared and re-added, so every surface
  gets a distinct, non-null key whether or not it currently has a buffer to build from. That is what
  lets a surface that can never build be *remembered* as ineligible under its own key instead of being
  re-attempted every call.
- Every `PrimitiveMesh` clears its mesh and re-adds surface zero whenever a property changes, and
  `ArrayMesh.clear_surfaces()` does the same. That frees the vertex buffer, and the structure was
  registered as a dependent of that buffer when it was created, so the structure goes with it. **A
  cache keyed on the mesh RID hands out a freed handle forever after**, and one dead handle fails
  the whole TLAS build rather than one shadow.
- The guard is to compare, on every cache hit, the buffer the surface would build from *now* against
  the one the entry was built from, and to **erase** the entry when they differ rather than skip it
  for the frame -- a skipped entry is handed out again next frame. That comparison is exact for a
  mesh-keyed entry, which is the case it exists for: being freed with its buffer is the only way one of these structures
  disappears without the cache doing it, and the RID allocator stamps a fresh validator into every
  RID it hands out, so a buffer RID that still compares equal is the same buffer and its dependents
  are still alive. A surface that has gone away entirely answers with a null RID, which also fails
  the comparison. Asking the rendering device whether the structure is still valid is the obvious
  alternative and was rejected here: that query takes the device lock, and this path would take it
  once per surface per frame. It is still what guards the free and teardown paths, where it runs
  once per entry actually released; and the check before the TLAS build must stay a state check on
  the cache entry rather than a device call per surface. `FINDINGS.md` has what the device-lock
  version cost.
- **The key is not the quantity the guard above compares, and that gap is what makes the guard work.**
  For a mesh-keyed entry the key and the recorded buffer are different objects: the key survives
  `clear_surfaces()`, so the dead entry is still found and can be erased, while the buffer does not,
  so the comparison fails. Key on the buffer instead and the dead entry is never looked up again --
  no crash, it just sits there until eviction while a second entry is built beside it. For a
  buffer-keyed skinned entry the two are the same RID by construction, so the comparison can never
  fail; it does not need to, because when that buffer goes away the key goes with it and the entry
  leaves through eviction holding a handle the device already freed, which is what the release path's
  validity check is for. Nothing tells this cache that a mesh or an instance went away, so the guard
  and the sweep are the only two ways an entry ever leaves.
- **An entry has three states and only `BLAS_READY` is ever re-examined.** `BLAS_UNBUILT` is the
  initial value of a fresh record and is never stored -- a surface that loses to the build budget has
  no entry inserted at all, so it is simply reached again by the next call's walk. `BLAS_INELIGIBLE`
  is a cached verdict, and it is permanent for the life of the key: the used-this-frame stamp is
  refreshed before the state is looked at, and the buffer comparison above is scoped to ready entries,
  so an ineligible surface that stays in range of a light neither re-tests nor ages out. Cache the
  verdict -- stage 2's reason for classifying once stands -- but know that a failure of the device
  calls that allocate and then build the structure is cached exactly as permanently as a non-triangle
  primitive is.
- The build budget gates **first-time builds only**. Check it after the cache lookup has already
  returned, so that a skinned surface whose pose moved is refreshed regardless of how many new
  surfaces the frame is also building -- a deferred pose is a visibly wrong shadow, where a deferred
  first build is only a late one. A surface that loses to the budget contributes **no TLAS entry at
  all** rather than an unbuilt handle. The list is simply shorter, and because the instance count
  seeds the contents hash that alone reads as a change, so the frame of the deferral still rebuilds;
  the frame the build finally lands, the build flag below forces the rebuild anyway.
- Spend a build slot before attempting the build, including for a surface that turns out ineligible,
  and charge triangles only on success with a saturating subtract. A mesh larger than the entire
  triangle budget therefore builds in one frame and zeroes the remainder. That asymmetry is
  deliberate: a predictive "would this fit" test would defer such a mesh forever.

  | Constant | Value | Why it is that |
  | --- | --- | --- |
  | `MAX_BLAS_BUILDS_PER_FRAME` | 64 | a level streaming in can bring hundreds of surfaces into range at once; without a ceiling that is a visible stall |
  | `MAX_BLAS_BUILD_TRIANGLES_PER_FRAME` | 1 << 20 | sixty-four small surfaces and sixty-four large ones are not the same frame, so the budget has two halves |
  | frames until eviction | 60 | skinned structures are per instance, so without eviction every character that ever existed keeps one alive |
  | frames between eviction sweeps | 8 | finding entries nothing asked for means walking the whole cache, which in a scene of many distinct meshes costs more than it saves; an entry is not eligible for sixty frames anyway, so sweeping every eighth costs it at most seven more |
  | minimum TLAS capacity | 64, doubling | capacity is fixed at creation, so exceeding it means recreating; powers of two stop that happening every frame |

- Hash the TLAS contents by **summing** per-instance hashes, not chaining them: a ray query reads
  nothing that depends on where an instance sits in the array, so two orderings of the same
  instances describe the same scene and the spatial index's iteration order must not read as a
  change. Seed the accumulator with the instance count, and put each per-instance hash through the
  32-bit finaliser (`hash_fmix32`) before adding it, or the sum degenerates into an additive
  collision.
- Hash exactly three fields of each instance record, in this order: the **BLAS handle**, the **8-bit
  instance mask**, and the **full transform** (nine basis components, then the three origin
  components). The mask belongs in it because it is the only thing that catches a `layers` change
  with nothing moving. Leave out the instance's own index in the array -- including it would defeat
  the order independence the sum exists for, and it is safe to leave out because nothing in the
  trace reads it -- and leave out the geometry flags and the hit-shader-binding-table range, which
  are the same constant for every instance.
- Two things force a rebuild whatever the hash says. Any BLAS built or refreshed this frame
  invalidates the bounds the TLAS cached for it, so track that as a per-frame flag and set it in
  both places. And a freshly created or resized TLAS describes nothing yet, so clear the
  "has been built" flag whenever the structure is recreated. Keep that flag distinct from the
  per-frame "may trace against it" flag: one outlives a frame, the other does not.
- **The expanded position buffer belongs to the entry, not to the build**, and only a compressed
  source has one. The entry holds the source buffer, its stride and the surface AABB beside it so that
  a skinned refresh can re-expand the new pose into the *same* allocation: the geometry description
  was fixed when the structure was created and cannot be re-pointed, so the refresh rewrites the
  buffer in place and never touches mesh storage again. Free it on every path that drops an entry,
  ineligible ones included -- it is allocated before the build is attempted, so a surface that failed
  to create its structure still owns one.
- **Every "frame" in this stage is an `update()` call, not a rendered frame.** The frame counter and
  both budgets are reset at the top of that call, and the culler makes it once per camera render that
  is not a reflection probe. Two viewports therefore build up to 64 structures each per rendered
  frame, sweep twice as often, and cut the sixty-frame grace period to thirty rendered frames. They
  also pay a TLAS rebuild each: the structure is one process-wide object, and each camera rebuilds it
  from its own caster list, which differs from the other camera's as soon as a directional light is in
  the scene, because that light's caster volume is the camera's own frustum swept towards it. Each
  camera still traces against a structure built for it moments earlier, so this costs rebuilds, not
  correctness.
- **A second entry ceiling lives here**, on the TLAS instance list rather than on the gather stage 8
  bounds: **65536**, tested before each push, and unlike the gather's it warns about nothing. The two
  count different things -- the gather counts casters, this counts caster surfaces -- so any scene of
  multi-surface meshes reaches this one first. It also breaks only the current instance's surface
  loop, so the walk continues past it and later instances still refresh their cache stamps and can
  still spend build budget on structures nothing will trace this frame.

### 11. Drop the shadow maps

A raytraced light stops claiming an atlas quadrant and stops having a map rendered. Add
`Light3D.shadow_map_enabled` here.

**Done when:** `GODOT_RT_DEBUG` prints `shadow_maps_rendered=0` alongside `raytraced=N`, and a
spotlight with a projector cookie still projects with no atlas quadrant.

- **Decide in one place, before anything acts on it**, and make the culler ask exactly the question
  the renderer will later ask itself. The fork's split decision -- culler skipping on light
  eligibility, renderer granting channels only when it would produce a mask -- meant that under
  multiview every omni and spot was skipped by the culler and then denied a channel, and rendered
  with **no shadow at all**. The same happened to any light past the 255 the mask can address.
- Split the question in two, and keep the third part out of both. A *candidate* test asks only about
  the light: shadows enabled, and the type is omni or spot (area lights keep their maps), or it is
  directional, which additionally needs the directional setting on and a renderer that can trace at
  all -- the same question the culler asks before it sweeps directional casters, so a sun cannot
  give up its map with nothing gathered for it. A *can use* test adds that this renderer is one that
  samples the mask and that the structure currently holds a build this frame may trace against;
  saying yes without either leaves the light unshadowed rather than falling back. Whether *this
  pass* has a mask is the third part and belongs to the caller: the culler ANDs in that this is not
  a reflection probe render and that the mask is available for these render buffers. None of the
  three depends on anything that changes during a pass, which is what lets the culler, the atlas
  layout and the light buffer visit lights in three different orders and still agree.
- The culler decides the pass's raytraced lights itself, **directional lights first** -- they are not
  in the culled positional light list, having no bounds to cull against -- and counts as it goes, so
  it is the culler that enforces the 255-light ceiling. That ceiling is load-bearing twice: it stops
  a light being skipped by the culler and then denied a channel, and it is what lets the slot
  allocator evict the least recently seen slot knowing the victim cannot be a light in this pass.
- Multiview is the boundary. A stereo pair would need a trace and a full set of denoiser history per
  eye, so the mask is declared unavailable whenever the render buffer holds more than one view, and
  every light keeps its map. A reflection probe render is excluded on the same test for a different
  reason: it has none of the depth and normal data the mask is written from.
- **Skipping the shadow-map render must not skip `light_instance_set_shadow_transform`**, the
  per-cascade call that hands the light instance a cascade's projection, transform, far plane and
  split distance: those split distances are what `fade_from`/`fade_to` are derived from, and the
  raytraced path reads them. Set the transforms for every cascade and skip only the render list
  merge.
- Keep `shadow_opacity` (what multiplies the traced visibility read from the mask) and
  `shadow_map_opacity` (what the effects sampling cascades multiply by) strictly distinct. The
  second doubles as the flag those effects test to know whether a map exists at all, so getting them
  the wrong way round produces a scene that looks right until you add fog.
- `Light3D.shadow_map_enabled`, with a `RenderingServer` setter and a light-instance query beside it
  that answers "does this light still need a map rendered", buys a light its map back. Both the
  directional and the positional shadow loop test it in the same shape: skip the render when the
  light is raytraced **and** was not asked for a map anyway.
- Three consumers read shadow-map state a raytraced light no longer has. **Subsurface transmittance**
  must fall back to the material's own transmittance depth, because a screen-space mask cannot give a
  depth from the light's point of view; gate it on `shadow_map_opacity` and the fallback is what
  remains. **Volumetric fog** lights unshadowed until stage 16, because a froxel is not a visible
  surface and has no mask pixel. **Light projectors** are the one that gets a fix rather than a
  fallback, below.
- A cookie is projected with the light's shadow matrix, which upstream fills in only on the
  shadow-map branch. The atlas rectangle the cookie samples comes from the decal atlas and was never
  tied to the shadow map, so only the matrix has to be recovered, and it must be recomputed on the
  raytraced branch for a light that got no map:

  | Light | Matrix |
  | --- | --- |
  | Omni | the light's transform relative to the camera, inverted, stored as a transform. The shader normalizes the result, so nothing but the rigid transform matters. |
  | Spot | that same modelview, with a rebuilt cascade-zero projection composed in front of it: `bias * (depth_correction * projection) * modelview`, using upstream's own light-bias matrix (clip space into `[0,1]`) and its depth correction with z reversal only, no y flip and no z remap. |

  Build the spot's projection with a **vertical FOV of twice the spot angle in degrees**, **aspect
  1**, **near `MIN(0.025, radius)`** and **far `radius`**, where `radius` is the light's range as the
  surrounding light-buffer code already floored it at 0.001. Those are the same four numbers the
  culler uses to build that spot's cascade-zero shadow transform, which is what makes the recomputed
  matrix interchangeable with the one the map path would have produced. Of those, the FOV and the
  aspect are what place the cookie, together with the bias matrix: the projector divides by w and
  reads only x and y, and neither the bias nor the depth correction mixes the z row into those two --
  the bias only rescales x and y from `[-1,1]` into `[0,1]`, which is why it is load-bearing here. Near and far
  live in the z row, which on this path nothing reads, so getting them wrong is invisible until some
  later change starts reading depth from this matrix. Take them from the map path anyway.

### 12. Directional casters

Bound the sun's caster set behind its own setting, and fix the cascade-slot fill.

**Done when:** with props every ten meters out to 400 m and a 100 m shadow distance, sweeps of
0.5×/1×/2×/4× gather 17/22/32/42 casters, each landing exactly where the geometry says.

- **Iterate the scenario's own list of directional lights** rather than the culled light list.
  Directional lights are never in the culled list, because the engine reports an empty AABB for a
  light with no range and the culler indexes lights by bounds. Skip a sun that is invisible, outside
  the pass's visible layer mask, or has shadows off, and skip all of them when the directional
  feature gate is off -- the same gate that decides whether a sun may take its shadow from the mask
  at all, so that a sun never gives up its map with nothing gathered to trace against.

- **Re-derive `far_distance` exactly as the engine's directional cascade setup does**: the main
  projection's `z_far`, clamped by the light's shadow max distance parameter only when that is `> 0`
  **and** the camera is not orthogonal, then `MAX(..., z_near + 0.001)`. A max distance of zero
  means "as far as the camera sees"; treating it as a literal zero collapses the volume to a
  millimeter and gathers nothing, silently. Getting the orthogonal test backwards fails the same
  way.

- **The volume is the frustum box merged with a copy of itself swept toward the light.** Take the
  projection's viewport half extents, which are the half extents at the *near* plane. The far half
  extents are those unchanged for an orthogonal camera and `near_extents * (far_distance /
  MAX(z_near, 0.001))` for a perspective one, because an orthogonal frustum does not widen with
  distance. That gives eight view-space corners, `(±ex, ±ey, -z_near)` and `(±ex, ±ey,
  -far_distance)`; transform each by the camera transform and take the world AABB of the eight.
  Then copy the box, translate the copy by `far_distance * caster_distance_scale` along the light
  basis's normalized **+Z** column -- toward the light, which is the opposite sense to the direction
  the light travels -- and merge the copy back into the original.

  Both halves are load-bearing. The swept copy alone holds occluders and no receivers; the
  untranslated box alone holds nothing that is not already on screen, so no ridge or wall behind the
  camera casts into view. Sweeping the wrong way is the quiet failure, because it still gathers
  plenty: the volume fills with geometry down-sun of the visible frustum, which cannot occlude
  anything, so the scene keeps its self-shadowing and loses every shadow thrown in from off screen.
  That reads as a lighting bug rather than a culling one.

  One volume per directional light, one geometry-index query per volume. `caster_distance_scale` is
  a setting rather than a constant because how far a ridge or a building should reach is a look
  decision and a cost decision at once; it defaults to 2.0 and is clamped to non-negative on read.

- **The ray's `tmax` comes from the same pair, and the light buffer must not re-derive it.** A
  directional row's `max_ray_length` is `radius * (1 + caster_distance_scale)`. A receiver sits at
  most `far_distance` from the camera and the volume reaches a further `caster_distance_scale *
  far_distance` up-sun, so that product is the whole reach the sweep bought, and anything longer is
  traversal spent on space the culler deliberately left empty. `radius` gets there indirectly and
  deliberately: it is the negation of the `fade_to` the cascade path just computed, which is the
  last cascade's split offset, which the cascade setup sets to the same `far_distance` this stage
  swept. Recomputing `far_distance` a second time in the light buffer instead would work today and
  drift the first time one of the inputs changes on one side only.

- **Multimesh and GridMap elements are gated for the sun separately, and the order of the two tests
  matters.** A multimesh contributes one structure entry per element, so a scattered field under a
  light that reaches the whole level is the one case that can flood the structure. Each element's
  bounds -- the mesh AABB through the instance transform times the element transform -- is tested
  against every lamp volume first and unconditionally. Only if that finds nothing is the directional
  volume consulted, and only when `scatter_casters` is not `Disabled`; `Near Camera` additionally
  requires the element bounds' **center** to be within `scatter_distance` of the camera position,
  and `Full Distance` admits it outright. Note what `Disabled` therefore means: a raytraced sun
  casts no shadow from any multimesh or GridMap at all, since only a lamp can then admit an element.
  That is easy to misread as the acceleration structure being broken.

- **Lights whose bounds a directional volume already encloses are partitioned to the back of the
  query list, not dropped.** Querying such a lamp descends the geometry index a second time over
  ground the sun's volume already covered, and the per-instance pass counter throws every duplicate
  away at the leaf, so skipping the query changes which casters are gathered not at all -- and it is
  the common case, since a sun's volume swallows every lamp in an interior or a street, so those
  queries account for most of the index visits. Partition with a swap -- walk the array, swap each
  non-enclosed entry to the front, and query only that prefix -- because the per-element multimesh
  test above asks a **different** question of the same array and iterates it whole. Erasing the
  enclosed entries instead loses exactly the elements those lamps were the only reason to include.

- **Filling unused cascade slots from the last real one is a prerequisite for stage 14, not a
  tidy-up.** The cascade ladders in the shaders end in a branch that reads slot 3; with fewer
  cascades that slot holds a default-constructed `ShadowTransform` -- identity projection, zero far
  plane, zero split. Surface shading and fog hide it because the distance fade bleaches the result
  at exactly that depth, but **subsurface transmittance has no fade**: it scales both its sampled
  depth and its own by slot 3's far plane, so zero far plane means zero thickness means full light
  through a solid object. The zero in `shadow_split_offsets.w`, slot 3's split distance, is also the
  denominator of the last blur factor in the PCF ladder, `shadow_split_offsets.x /
  shadow_split_offsets.w` -- a division by zero for every fragment past the last real split, with
  blend splits on or off, since the blend ladder computes the same quotient. GLES3 already clamps
  the source index for the split offsets alone -- extend it to the matrix, ranges, biases, uv scales
  and atlas
  rect.

### 13. Directional trace

The sun takes a slot in the same mask and competes for a pixel's four channels on the same terms as
every lamp, reusing the 64-byte light record with four fields reinterpreted.

**Done when:** pillars of increasing height give a 10–90% shadow edge width of 0/3/6 px against the
cascade map's uniform 0/1/1 -- the traced sun's penumbra grows with the gap it crosses.

- **The forward directional loop becomes three blocks where upstream has one.** Upstream wraps the
  cascade chain, the lightmap shadowmask handling, the distance fade and the vertex-lighting apply
  in a single `if (shadow_opacity > 0.001)`. Split it in three, keeping that same `0.001` threshold
  everywhere:

  | Block | Condition | Body |
  | --- | --- | --- |
  | mask | `rt_slot < RT_SLOT_NONE && RT_MASK_ANSWERS_HERE` | set `rt_shadowed = true`; then, only if `shadow_opacity > 0.001`, sample the mask. Hand over RAW visibility -- do NOT fade it here |
  | cascades | `!rt_shadowed && shadow_map_opacity > 0.001` | upstream's chain unchanged, with the `#undef` of the loop's own per-cascade bias macro (`BIAS_FUNC`, which offsets the shading position along the light and the geometric normal) moved inside it |
  | tail | `rt_shadowed \|\| shadow_opacity > 0.001` | the lightmap shadowmask branches, the fade, and the vertex-lighting apply |

  `RT_SLOT_NONE` is `255.0` and the slot is a float in the light record, so that is a float compare.
  `RT_MASK_ANSWERS_HERE` is the stage 15 macro, constant-`true` wherever the material writes
  pre-pass depth.

- **The mask arm hands over raw visibility, and applying `shadow_opacity` there is a bug.** The
  second directional loop already applies it, unconditionally, to whatever byte the first loop
  packed; the cascade chain knows this and hands over raw visibility too. This fork shipped the
  extra `mix()` for several months. It is invisible at the default opacity of 1.0, because
  `mix(1, s, 1)` is `s`, and wrong at every value below it -- the light a shadowed pixel loses goes
  as opacity SQUARED. Measured in linear light before the fix, a raytraced sun took away 0.25 of its
  full-shadow light at an opacity of 0.5 where a shadow-mapped one took away 0.50.

  Two consumers sitting between the lookup and the pack want the raw value for the same reason: the
  screen space contact shadow is combined with `min()`, and the lightmap shadowmask crossfade blends
  against a raw `shadowmask`. Fading early hands both of them an operand in the wrong space.

  Under `USE_VERTEX_LIGHTING` the second loop is compiled out entirely, so that path ends up
  ignoring `shadow_opacity` -- but it already does so for the cascade chain, upstream included, and
  the two agreeing is worth more than the raytraced path alone being right. Omni and spot keep their
  own `mix()` and must not be changed to match: they compute and consume the value inside one
  function, with no pack and unpack, so theirs is the only application.
  `shadow_validation/opacity.gd` in the docs tree is the regression test -- it fits the exponent of
  `lost(o)/lost(1) = o^k` and must read 1.00, with a shadow-map control that must read 0.500.

- **The mask arm is chosen on the slot alone, never on `shadow_opacity`.** `rt_shadowed` means "the
  mask is this light's answer here", not "the mask shadowed this fragment". A sun that holds a slot
  with `shadow_opacity` at zero therefore sets the flag, leaves `shadow` at 1.0, and skips the
  cascade block -- which is what zero opacity means. Folding the opacity test into the flag instead
  sends that light down the cascade path to sample an atlas rect it does not own. The tail's gate is
  `shadow_opacity` and not `shadow_map_opacity` for the mirror-image reason: a raytraced sun has
  `shadow_map_opacity` of zero unless it was asked to keep a map, and the tail still has to run for
  it. That is what the `rt_shadowed` disjunct is there for.

- **The fade is hoisted out of the cascade block, but only two of its three arms are shared.**
  Hoisting is required -- a raytraced sun must still hand over to a baked shadowmask -- but the
  arms do not all apply to both paths:

  - The two lightmap arms, REPLACE and OVERLAY, keep their `smoothstep(fade_from, fade_to,
    vertex.z)` unguarded and run for both paths. Both end at the baked `shadowmask` rather than at
    fully lit, and the trace knows nothing about a shadowmask.

    **This is a known defect, reproduced deliberately so that a port matches the shipped engine
    rather than diverging from it.** The trace has already faded its own visibility to lit across
    this identical window, which is exactly why the plain arm below is guarded with `!rt_shadowed`,
    so under a raytraced sun these two arms fade the dynamic term a second time and a lightmapped
    surface mid-window reads lighter than the cascade path does. It is confined to the fade window
    and reachable only with `USE_LIGHTMAP` plus a shadowmask plus a raytraced sun, which is why it
    has not been fixed. If you fix it, guard both arms' dynamic term the same way the plain arm is
    guarded, and fix it in the engine rather than only in the port.
  - The plain arm's `mix(shadow, 1.0, smoothstep(...))` must be wrapped in `if (!rt_shadowed)`. The
    trace has already applied it, over the negation of these same two numbers, and it must: the
    thing that has to be continuous is the mask, which the denoiser filters and reprojects. Running
    it again in the forward pass only reaches the same 1.0 sooner.

- **Everything the culler did not gather has to be faded out inside the trace, keyed on view depth.**
  The trace treats every non-sky pixel as a receiver, but casters were gathered only as far as the
  shadow distance, so a surface past it traces against an empty region and comes back confidently
  **lit** -- a hard seam across the landscape at exactly the shadow distance. Two tests prevent it,
  both on view depth and both reading the same last-cascade split offset the cascade fade reads, so
  they cannot drift. Per pixel, the light-selection pass drops a directional light whose `radius` is
  less than the fragment's view depth. Inside the window, the trace multiplies its own answer toward
  fully lit by `smoothstep(fade_from, max(radius, fade_from + 0.0001), view_depth)`, and skips the
  rays entirely once that reaches 1.0. The `+ 0.0001` is the trace's guard against equal smoothstep
  edges; the CPU side's is clamping the fade-start fraction to 0.999.

- **Do not tile-cull directional lights with a sphere around the camera.** Radial distance is always
  at least the view depth the fade is keyed on, so such a test rejects tiles the per-pixel check
  accepts and the corners of the frame lose the sun well before the fade starts. Admit every
  directional light with no geometric test at all, and claim them before the lamps so that a crowded
  tile -- one past the 128-candidate shared-memory list -- drops lamps rather than the sun. There
  can be at most eight directional lights, so that pass cannot fill the list by itself.

- **Softness follows the `softshadow_angle` convention so both paths agree at the default
  `softness_scale`** -- the trace carries the same tangent of the angular radius, scaled only by
  that setting. Note that a nonzero angular distance also puts the **cascade** path onto its PCSS
  branch and widens every cascade's extents, visible in projects that never enable raytracing. The
  node carries `0.25` itself rather than the trace hiding a default behind zero, so the inspector
  value is what is traced and zero means genuinely hard.

### 14. Directional demotion

Cut the sun's remaining shadow map down to what still reads it, as two settings rather than constants.

**Done when:** instrumented, a raytraced sun allocates the directional atlas **zero** times where a
non-raytraced scene allocates it once -- 2 MiB at the demoted size, 32 MiB at Godot's default.

- **Both readings of the shadow mode must move together.** `update_light_buffers` read
  `light->directional_shadow_mode` *directly* rather than through the accessor, so overriding the
  accessor alone leaves the culler emitting two cascades while the buffer still computes
  `limit == 3` -- split offsets of `(s0, s1, 0, 0)`, a `fade_to` of negative zero, and a smoothstep
  with equal edges.
- Leave the authored shadow mode untouched on the `Light` so it still round-trips through the
  editor; only what the renderer asks for changes. Keep `requested_size` separately so the full size
  comes back if raytracing goes away.
- Only safe on top of the cascade-slot fill from stage 12.

### 15. Alpha-pass correctness

Stop an alpha-blended fragment reading the mask at its own pixel and wearing the visibility of the
opaque surface behind it.

**Done when:** a horizontal sheet of glass above a floor in full shade goes from mean luminance 31.6
to 180.3, and every opaque test scene renders identically.

- "Am I in the alpha pass" is not quite the question. Alpha-to-coverage and `depth_prepass_alpha`
  materials are drawn in the transparent list but **do** write pre-pass depth, so the mask describes
  them correctly -- those are known at compile time (`USE_OPAQUE_PREPASS` /
  `ALPHA_ANTIALIASING_EDGE_USED`) and must skip the runtime test entirely. Alpha scissor and alpha
  hash go through the pre-pass like anything opaque and were never affected.
- The runtime half of the test is a scene-data flag rather than a shader variant: a bool on
  `RenderSceneDataRD` set true only across the transparent pass's own scene-data setup call -- the one
  that builds that pass's uniform buffer, before the list is drawn -- and cleared again immediately,
  so that only that buffer carries the bit, packed into the scene data flags as
  `SCENE_DATA_FLAGS_IN_ALPHA_PASS` and mirrored in `scene_data_inc.glsl`. The shader wraps both
  halves in one macro so each mask read is a single condition, and so the compile-time exemptions
  above collapse it to a constant `true` where they apply.
- The fallback guards move from `shadow_opacity` to `shadow_map_opacity` at the same time.
- **Demonstrating this needs a horizontal pane.** A vertical one edge-on to the sun receives almost
  no direct light, the shadow term is multiplied by nearly nothing, and the bug is invisible. Three
  test scenes each looked like evidence the fix did nothing.

### 16. Fog: the zero-cost variant pattern

Volumetric fog traces its own directional shadow ray per froxel. **This stage is also the reusable
pattern for adding a ray-query variant to an existing shader at no cost to projects that never use
it** -- the deferred subsurface-transmittance work should use it, with the structure declared inside
`#ifdef LIGHT_TRANSMITTANCE_USED`.

**Done when:** on a row of slats lit from behind, the fog's luminance at the darkest point of the
shadow reads 74.9 against the shadow-mapped render's 75.4 (it read 183.8 with the shafts missing).

All five parts of the pattern are required:

1. Give the raytracing variants a `ShaderRD` **group of their own**.
2. **Do not create their pipelines at init** -- skip those indices in the loop, because
   `version_get_shader` on a disabled group returns a placeholder.
3. `enable_group()` **lazily**, the first frame something needs them.
4. Put the acceleration structure in a **uniform set of its own** that only those variants declare,
   so every other variant's uniform set is byte-for-byte unchanged.
5. Guard the `#extension` and the `accelerationStructureEXT` declaration behind the variant's own
   define, so non-tracing variants emit SPIR-V requesting no raytracing capability.

Other pitfalls:

- `cam_rotation` only rotates; the structure is world space, so the froxel's view-space position
  needs the camera translation too -- hence `cam_position` in the params UBO and the mirrored `vec4`
  in the std140 block **at the identical position**. Half-applying this garbles `cam_rotation`,
  `to_prev_view` and `radiance_inverse_xform`.
- One ray per froxel is the whole budget, so spread the sun's angular size across **frames**: offset
  the ray within the cone by the same `halton_map[temporal_frame]` value that already jitters the
  froxel position, under the same reprojection guard, so it stays a global jitter rather than
  per-froxel noise.
- A froxel has no pixel in the mask, so positional lights get no ray and a raytraced lamp lights the
  fog unshadowed. Leave the TLAS null unless a directional light actually took a slot.

### 17. Docs, defaults and CI

Small, but three separate CI rounds were burned on it the first time.

**Done when:** `godot --headless --doctool .` produces no diff and the style hooks pass.

- **`--doctool` emits `ProjectSettings` members sorted by name.** Hand-placing new entries next to
  related ones fails the class-reference check; apply the doctool output verbatim.
- Changed node defaults propagate into the XML whether or not you edit it, because doctool computes
  the attribute from the real registered default.
- A new top-level directory that no `CODEOWNERS` rule matches fails `validate-codeowners --unowned`,
  and that gates every platform build.
- `codespell` rewrites British spellings in prose *and* in shader comments, and its write-changes
  mode makes the hook exit non-zero.
- If CI is narrowed to one platform, the dropped Linux jobs take the `--doctool` class-reference
  check, the GDExtension API compatibility check and the export tests with them -- but check what
  the surviving platform still runs before claiming a check is gone; this fork's Windows job runs
  the unit tests, and the guide wrongly said otherwise for a while.
- **A green static-check run on a push says nothing about the same check on the pull request.** The
  workflow passes `--from-ref` to pre-commit, and that ref differs by event: a push run compares
  against the previous commit, so it sees only what that push touched, while a pull-request run
  compares against the base branch and therefore re-checks *every* file the branch has changed. A
  fixer hook -- `codespell` here, with `write-changes = true` -- will happily flag a file from a
  commit twenty pushes ago, and pre-commit fails whenever a hook modifies the tree. Run the hooks
  yourself over `git diff --name-only <base>..HEAD` before opening the PR.
- When you run those hook scripts by hand to reproduce a failure, **filter the file list the way the
  hook config does**. They are fixers, not linters: handing `copyright_headers.py` an unfiltered
  list prepends C-style banners to XML files, and the resulting mess looks exactly like a second and
  third CI failure. `file` reporting a `.xml` as "C source" is the giveaway.

### 18. Ground truth ambient occlusion

Independent of everything above -- it touches no raytracing and can be ported on its own, or left
out. Five new files plus about a dozen small hooks.

**The estimator.** Five dispatches, in order. The slice geometry is Jimenez et al's GTAO (2016);
what a slice remembers is the visibility bitmask of Therrien, Levesque and Gilet (2023), reduced to
the occlusion term. `gtao_gather.glsl` cites both. Every number below belongs to the fork and is
exact -- the estimator is a closed piece of arithmetic, and a rebuild that reproduces its shape but
guesses at its constants is wrong in ways that read as the effect working.

**Two projection terms, folded once.** Every pass that turns a screen position back into a view
position uses the same pair, computed on the CPU from the **raw** projection rather than the
depth-corrected one, and expressed for a UV in zero to one rather than an NDC position:

    uv_to_view_mul = ( 2 / P[0][0], -2 / P[1][1] )
    uv_to_view_add = ( -1 / P[0][0],  1 / P[1][1] )

    view = (uv_to_view_mul * uv + uv_to_view_add) * z, and z in the z component
    (orthographic: the same without the * z)

`z` throughout is linear view depth, positive going away from the camera. `P[0][0]` and `P[1][1]`
are the camera projection's x and y scale terms, so `uv_to_view_mul.x` is `2 * tan(fovy/2) * aspect`
and `uv_to_view_mul.y` is `-2 * tan(fovy/2)`: the view space width and height of the frustum at unit
depth, the y term negated because a UV runs down the screen while view space y runs up. Both the
gather and the two filter passes must reconstruct **identically**, because the filter judges a
gather texel by plane-fitting the point that texel claims to describe; a half-pixel disagreement
makes the filter reject the gather's own samples along every slope.

1. **Prefilter** -- build a five-level depth pyramid at **full internal resolution**, `R32_SFLOAT`,
   linearized with the same two terms the other screen space effects fold out of the projection
   (under an orthographic projection, the raw near and far planes instead). Each level takes a
   weighted mean of four, biased toward the **farthest**: with `furthest` the maximum of the quad,
   the weights are `clamp((furthest - d) * falloff_mul + falloff_add, 0, 1)` with
   `falloff_mul = -1 / max(ssao_radius, 0.0001)` and `falloff_add = 1`. The farthest therefore
   always weighs exactly 1, and the `total > 0.0001` guard that returns it whole is there for a
   degenerate quad rather than for anything ordinary geometry produces. Farthest is the conservative
   choice for an occlusion query: a coarse texel that reports the nearest of its four dilates thin
   geometry across its whole footprint, and a march that reads one such texel early keeps that
   horizon for every step after it. That falloff is a depth-continuity threshold, not the march's
   reach, which under distance scaling follows the depth instead. Full resolution at mip 0 is why
   this cannot reuse the legacy estimator's pyramid, which is half resolution, deinterleaved into
   array slices a straight-line march cannot address, and filtered toward the nearest. It stays full
   regardless of `half_size` and the shading rate, both of which reduce the GATHER and not this.
   Sampled with a **nearest** sampler, which forces detail 1 below. The reduction runs one thread
   per 2x2 over a 16x16 tile in shared memory, with both barriers outside the live-thread
   conditional.

2. **Gather** -- one invocation per gather texel. The full resolution pixel it answers for supplies
   the depth, the normal and every world-space quantity below, which is what makes the reduced rate
   change only how many pixels get their own answer.

   **The fade is evaluated before the march and can end the invocation.**
   `fade = clamp(1 - (z - fadeout_from) * fade_inv_span, 0, 1)` with
   `fade_inv_span = 1 / max(fadeout_to - fadeout_from, 0.0001)`. At zero it writes
   `(1.0, z)` and returns. There is no sky test anywhere in the estimator; the sky takes this branch
   because the far plane linearizes past `fadeout_to`. The depth goes into the green channel on this
   path as on every other, because the denoise and the upsample plane-fit against it and an
   unwritten texel would let a neighbor be accepted straight across a silhouette.

   **The radius is one quantity read from two ends, and `ssao_radius` scales both ends together.**
   With `scale_radius_with_distance` on, which is the shipped default:

       screen_radius_px = ssao_radius * screen_radius * full_height
       world_radius     = ssao_radius * screen_radius * |uv_to_view_mul.y| * z

   With it off:

       world_radius     = ssao_radius
       screen_radius_px = (world_radius / max(|uv_to_view_mul.x| * z, 0.0001)) * full_width

   then `screen_radius_px = clamp(screen_radius_px, 2, full_width)` either way. The two describe the
   same march -- the pixel span is what the steps walk, the world radius is a hard `dist >
   world_radius` rejection -- so `ssao_radius` must multiply both. Scale only one and raising the
   radius widens a cutoff the steps never walk far enough to reach, while lowering it truncates the
   march while still spreading its steps across the full span. Note the distance-scaled branch is
   anchored to `uv_to_view_mul.y` and so to screen **height**, for the viewport-shape reason set out
   further down this stage; the fixed branch is already aspect invariant and must not be given an
   aspect correction.

   **`thickness` is a fraction of the effect radius, not a distance.** `thickness * world_radius`,
   pushed along the shaded point's **own** view ray. Following the radius is the point: a march that
   reaches ten times further at distance would otherwise push every back face into the same shallow
   shell and the mask would read as almost solid.

   **The dither is one hash of the gather texel and carries no frame counter.**

       a = fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))))   -> slice angle
       b = fract(float((pos.x ^ pos.y) * 1103515245u % 1024u) * (1.0 / 1024.0))      -> first step

   Interleaved gradient noise for the slice, an xor-hash times an LCG multiplier for the step
   offset. The omission of a frame index is deliberate and load-bearing: nothing downstream is
   temporal, so an animated pattern has nothing to resolve it and reads as a crawl, where a fixed
   one reads as a still texture. There is no frame counter in the push constant to reintroduce one
   with.

   **Per slice.** `phi = (slice + a) * pi / slices`, and `slice_dir = (cos phi, sin phi)` -- a real
   trig call per slice, once. The basis for the slice plane is probed **8 full-resolution pixels**
   along `slice_dir`, unprojected at the shaded point's own depth, and orthonormalized with two
   cross products: `bitangent = normalize(cross(in_plane, view_dir))`, `tangent = cross(view_dir,
   bitangent)`. Both halves matter. Stepping along the slice at constant depth gives a direction
   lying in the plane but not perpendicular to the view direction under perspective, so elevations
   measured against it are measured against a skewed axis; and the probe steps in PIXELS because
   that is what the march walks in, so a UV-sized step points somewhere else entirely on a
   non-square viewport. The normal is then projected into the plane, and a slice whose projected
   length falls below 0.0001 is **dropped from both sums** below rather than counted as open -- it
   has no arc to integrate over, and letting the others answer is more honest than voting the whole
   hemisphere open. `n_angle` is the signed angle of that projected normal away from the view
   direction, `atan(dot(n_p, tangent), dot(n_p, view_dir))`.

   **The march: even spacing, both directions.** For each of the two sides and each of
   `steps_per_slice` steps, `t = (step + b) / steps_per_slice` and
   `offset_px = max(t * screen_radius_px, 1.0)` -- **uniform in t, deliberately not geometric or
   quadratic**. A horizon march can crowd its steps near the shaded point because one early hit
   stands in for everything behind it; a mask cannot, because an occluder falling between two steps
   is not approximated, it is absent, and the far half of a crowded march is where the gaps get wide
   enough for a whole box to fall through one. Spreading the same eight steps evenly roughly halved
   the error; see `FINDINGS.md`. Leaving the screen **breaks** the ray rather than skipping the
   step. The pyramid level is `clamp(floor(log2(offset_px)) - 3, 0, 4)`, the 4 being the top level
   written literally: mip 0 holds until a step reaches 16 pixels, then one level per doubling, so
   coarser texels are read only once the full resolution ones they stand for could not have
   mattered.

   Each sample is then, in order:

   - **reconstructed at the center of the texel its depth came from**, not at the position the step
     asked for. See detail 1 below; this is not optional.
   - rejected when `dist < 0.0001` or `dist > world_radius`.
   - rejected when `dot(delta, normal) < dist * ANGLE_BIAS`, `ANGLE_BIAS = 0.03`. At or below the
     shaded plane a sample cannot occlude the hemisphere above it, and a coplanar neighbor
     reconstructs to either side of that plane at random, so the half landing above marks sectors
     and a flat floor occludes itself.
   - given a **back face**, `back_delta = delta - view_dir * thickness`. Everything between front
     and back is solid, everything beyond it is open again. This is the entire reason the estimator
     handles thin geometry, and the reason two occluders with sky between them stay two occluders.
   - measured **inside the slice plane**, signed, as `atan2` of the sample resolved onto the slice
     tangent and the view direction -- once for `delta`, once for `back_delta`. An unsigned 3D angle
     against the view direction puts a sample lying flat on the shaded surface, where the elevation
     is zero and it should occlude nothing, into the middle of the arc, and darkens every flat plane
     uniformly.
   - mapped into the slice's own coordinate as `(angle - n_angle + pi/2) / pi` clamped to `[0,1]`,
     so 0 and 1 are the ends of the half turn centered on the projected normal; then
     `first = floor(lo * 32)`, `count = ceil((hi - lo) * 32)` clamped into range, and that run of
     bits is OR'd into a 32-bit occupancy mask (a count of 32 or more sets all bits).

   **Open sectors.** With the bitmask on, `open = ~occupancy`, and that is the whole difference from
   horizon marching. With it off, the fallback walks outward from the normal -- from sector 15 down
   to 0 and from 16 up to 31 -- stopping at the first occupied sector on each side, keeping only the
   unbroken open run around the normal. Getting that fallback inverted, so it closes the arc between
   the outermost occluders instead of outside the innermost ones, is an easy mistake and measured
   0.63 too dark.

   **The sector weight is the load-bearing piece and it is not a share of the arc.** Sweeping the
   slice about the view direction turns each sector into a ring whose circumference goes with the
   sine of the angle from the view axis, so a sector pointing back at the camera sweeps almost no
   solid angle and one at the edge of the arc sweeps the most. A sector's worth is the integral of
   `cos(t - n) * |sin t|` across it, `t` measured from the view direction. That has a closed form,
   so cumulative weight is evaluated at each sector boundary and differenced:

       A(t)   = -cos(2t - n)/4 + t*sin(n)/2         antiderivative where sin t >= 0
       W(t)   = A(b0) - A(t)                        for t <= 0   (the integrand folds at t = 0)
              = A(t) - 2*A(0) + A(b0)               for t >  0
       b0     = n - pi/2,  A(b0) = cos(n)/4 + b0*sin(n)/2,  A(0) = -cos(n)/4

   Boundaries are `b_i = n - pi/2 + i*pi/32` for `i = 0..32`: **33 of them**, with `W(b0) = 0`
   carried as the running `prev_weight` rather than evaluated. Sector `i` is worth
   `W(b_{i+1}) - W(b_i)`; the open ones accumulate into the slice's open arc and `W(b32)` is its
   total. Only the trig term `cos(2t - n)` has to be re-evaluated per boundary, and stepping `t` by
   `pi/32` steps `2t - n` by `pi/16`, so it advances by one fixed rotation instead of a trig call:
   `ROT_COS = 0.98078528040`, `ROT_SIN = 0.19509032201`, initialized to `(-cos n, -sin n)` because
   `2*b0 - n = n - pi`. **These two constants belong to the sector weight, not to the slice
   rotation.** Dropping the `|sin t|` Jacobian and weighting by angular width instead counted the
   two sectors either side of the normal -- which on a surface facing the camera are the two lying
   on the view axis -- about ten times too heavily. That error is wrong everywhere anything is
   occluded, does not average out, and does not shrink with more samples.

   **The resolve is a ratio of two sums, not a mean of per-slice fractions and not a population
   count.** Each surviving slice adds `projected_len * open_arc` to one sum and
   `projected_len * total_arc` to the other, taken from the same running accumulation so the two
   cannot disagree, and visibility is `open_sum / total_sum` where `total_sum > 0.000001` and 1.0
   otherwise. The projected length is what makes slices through the steep direction of a tilted
   surface matter more than slices across it. Weighting each slice into both sums is what makes a
   surface with nothing above it come out at exactly one whatever its orientation and whatever the
   dither picked.

   **Then the strength curve, entirely here, because there is no later stage to hang it on:**

       visibility = clamp(open_sum / total_sum, 0.0, 1.0);
       open       = pow(visibility, ssao_power);
       visibility = open / max(open + (1.0 - open) * intensity, 0.0001);
       visibility = mix(1.0, visibility, fade);
       store (visibility, z)

   Shape first, strength second, and strength as a **ratio** rather than a subtraction. See detail 3
   below. At an intensity of 1 the ratio is the identity, which is what the validation harness
   measures, and its slope at white matches the subtractive form's, so the curve asks nothing new of
   an artist's tuning -- but it approaches zero without arriving, so a corner stays a gradient. The
   `intensity` reaching the shader is already `Environment.ssao_intensity * intensity_scale`.

3. **Denoise, twice** -- separable, across then down, at the gather's own resolution, ping-ponging
   between the two `R16G16_SFLOAT` buffers. The width is derived on the CPU from the march's
   on-screen reach and the slice count, because those are the two things the gather's variance
   follows:

       reach         = scale_radius_with_distance ? screen_radius * max(ssao_radius, 0) : 0.05
       filter_radius = clamp(round((reach * 4 / max(slices, 1)) / 0.06), 1, 3)

   A fixed width cannot serve a radius setting spanning a hundred to one: 3x3 is right at the bottom
   of the range where extra width only costs contact detail, and at the top a filter that narrow
   absorbs about a third of what it is handed. Note the second branch -- with distance scaling off
   there is no on-screen reach to read, a constant stands in, and at the shipped four slices the
   width comes out at 1, so turning distance scaling off **narrows** the filter rather than holding
   it. The tap weight is a tent times a plane term:

       kernel = filter_radius + 1 - |i|
       plane  = max(1 - |dot(n_c, p_tap - p_c)| / max(0.02 * z_c, 0.0001), 0)

   `p_tap` is reconstructed from the tap's own stored depth and the full-resolution pixel that
   gather texel answers for, so the filter needs the view normal and the projection terms bound to
   it as well as the AO buffer. Weighting on distance from the shaded point's **plane** rather than
   on depth difference is what lets a surface seen at a glancing angle keep its own neighbors while
   a shallow silhouette still separates; a depth-difference test gets both backwards. The green
   channel passes through from the center tap untouched.

4. **Upsample** -- into the shared occlusion buffer, judging each candidate gather texel against the
   **full resolution** depth and normal of the pixel being filled rather than the nearest gather
   texel's, which would quantize every silhouette to the coarse grid. On the quarter-resolution
   grid it is a 2x2 bilinear weighted by the same plane term; where the weights sum to 0.0001 or
   less -- every candidate rejected -- it takes the tap the fractional position rounds to, whole,
   because a floor mixed into the weights instead would drag a silhouette's own value toward
   whatever lies across it. On the checkerboard it is a different filter -- an exact copy for the
   shaded half and a plane-weighted average of four one-pixel neighbors for the rest; see detail 4
   below. At
   matching resolutions every weight collapses onto the pixel's own texel and the pass degenerates
   to a copy.

**Known gaps, both silent.** `_use_gtao` answers false above one view, so a stereo or XR pair keeps
the legacy estimator with no warning; the gather has no notion of a second view and the occlusion
buffer is a layer per eye. Orthographic projection is **not** correct, in three separate places, and
a port should either fix all three or gate on it: the gather's orthographic view direction is
`(0, 0, 1)` where the perspective branch's `normalize(-center_pos)` points the opposite way along z,
which inverts every elevation angle and pushes the thickness back face toward the camera instead of
away; the distance-scaled radius branch multiplies by depth with no orthographic guard, though the
fixed branch has one; and the filter shader has no orthographic path at all -- its push constant
carries no such flag -- so both denoise passes and the upsample plane-fit against wrong positions.
The prefilter's linearization and the gather's UV-to-view do handle it.

- Six details are load-bearing, and every one was wrong before it was measured. Each is a steady
  bias that reads as the effect working rather than as a bug, so none will be caught by looking.
  `FINDINGS.md` has the measurements; the first four are described where the estimator is, above,
  and are gathered here so a port can check them off.
  1. Reconstructing a sample at the center of the texel its depth came from, not at the position the
     step asked for, because the pyramid is sampled **nearest**.
  2. The `|sin t|` Jacobian in the per sector weight, which is the integral of `cos(t - n) * |sin t|`
     over the sector and not the sector's share of the arc.
  3. The strength curve scaling occlusion as a **ratio**. Subtracting a multiple of the distance
     from white has a hard floor and clips a third of the tonal range to black inside the gather,
     where no filter can recover it. The one-step test: put a flawless traced occlusion through the
     curve and see whether the artifact survives.
  4. **The checkerboard is the shipped shading rate whenever half resolution is on**, and items 5
     and 6 below describe the quarter resolution grid, which is now the fallback rung. A port that
     reproduces only the grid ships a renderer whose default occlusion path does not exist. It packs
     pixel `(2u + (y & 1), y)` into gather texel `(u, y)`, so the gather is half width and full
     height rather than half of both; reconstruction is the upsample's four-neighbor filter above,
     weighted by the same plane term, with an off-screen neighbor skipped rather than clamped so an
     edge pixel blends two or three, and the first on-screen neighbor taken whole where the weights
     sum to 0.0001 or less. One detail is load bearing: at an odd width the last texel of an odd row
     is clamped and no full resolution pixel maps back to it, so the upsample never reads it -- but
     the horizontal denoise walks the gather's own grid and does, so it must still be written.
  5. The half resolution stride is **passed** in a push constant. `gather_size_for` rounds up and
     integer division rounds down, so recovering it in the shader gives 2 at every even width and 1
     at every odd one, and at an odd width the gather then answers only for the top left quadrant.
     Do not "fix" it by rounding the gather size down instead; that drops the last column at widths
     like 1281.
  6. The upsample inverts the gather's sampling position as `pos / stride`. Applies to the quarter
     resolution grid only; the checkerboard takes its own branch and never reads the stride. The obvious
     `(pos + 0.5) * scale - 0.5` assumes the gather texel represents the center of its block and is
     wrong by half a full resolution pixel on each axis.
- One quantity is a function of viewport shape and must be anchored deliberately. Under
  `scale_radius_with_distance` the world reach comes from `uv_to_view_mul`, which on the x axis is
  `2 * tan(fovy/2) * aspect`; a camera holds the VERTICAL field fixed, so anchoring a screen space
  fraction to width makes the effect reach 1.8x further on a 16:9 viewport than on a square one.
  Anchor to height. The fixed-world-radius branch is already aspect invariant and must be left
  alone.

---

### 19. Screen space contact shadow for the sun

A contact shadow for one `DirectionalLight3D`, marched over the depth pre-pass buffer, for geometry
that is deliberately absent from the acceleration structure. Independent of stages 2--14: it needs no
ray query, no TLAS and no light slot, it can be enabled with raytraced shadows switched off, and it
can be ported on its own. What it does need is a depth pre-pass, which is why it forces one.

**Files:**

- `thirdparty/bend_sss/bend_sss_cpu.h` and `LICENSE.txt` -- Bend Studio's dispatch list builder,
  vendored with no changes but the line endings and trailing whitespace this repository normalizes.
  Header only, so no `SCsub` entry; it needs an entry in `thirdparty/README.md` and one in
  `COPYRIGHT.txt` that covers the ported shader as well (`COPYRIGHT.txt` lists both paths under one
  `Files:` stanza).
- `servers/rendering/renderer_rd/shaders/effects/screen_space_shadow.glsl` -- the march, a port of
  Bend's HLSL. Picked up by the `Glob("*.glsl")` in `shaders/effects/SCsub`; nothing to register.
- `servers/rendering/renderer_rd/effects/screen_space_shadows.{h,cpp}` -- the pass driver.
- Hooks: `renderer_scene_render_rd.{h,cpp}` (`get_screen_space_shadows`, and the `memdelete` in
  `~RendererSceneRenderRD`), `forward_clustered/render_forward_clustered.{h,cpp}`,
  `forward_mobile/render_forward_mobile.cpp`, `storage_rd/light_storage.{h,cpp}`,
  `shaders/light_data_inc.glsl`, `shaders/scene_forward_lights_inc.glsl`,
  `shaders/forward_clustered/scene_forward_clustered_inc.glsl` and `scene_forward_clustered.glsl`,
  `core/config/project_settings.cpp`, `doc/classes/ProjectSettings.xml`.

**Done when:** `docs/rt_shadows/shadow_validation/run.sh field_thin` -- 15,000 grass blades at
`cast_shadow = Off` under a 26 degree sun, scored in linear light against a render of the same field
put back into the acceleration structure -- reports `hardness` 1 at 1.149 of the trace's darkness for
0.830 of its mass over 0.722 of its area, and `hardness` 0 at 0.864 / 0.468 / 0.541, against a
reference of 132,257 shadowed pixels removing 0.1044 per pixel. `run.sh field` and `run.sh probe`
have their own targets in that directory's README. Run with `--verbose`: **no pixel of any variant
may be lighter than the frame with the pass off**, which is the check that the composition can only
darken.

- **One predicate answers for the whole feature, and it is asked twice per frame.**
  `RenderForwardClustered::_using_screen_space_shadows` is consulted in `_render_scene` to build
  `force_depth_pre_pass`, and again in `_pre_opaque_render`, which runs later in the same function,
  to decide both what `update_light_buffers` is told and whether `_render_screen_space_shadows` runs.
  The first site is reached before the light buffers exist, so **the predicate must not consult the
  light**: it tests the project setting, the reflection probe, the render buffers, the view count,
  the projection and whether the effect could be built, and nothing else. Give it a term only the
  second site can evaluate -- "is there a shadow casting sun" -- and the two answers disagree, the
  pre-pass is not forced, and the march reads a depth buffer that was never written this frame. The
  cost of the honest version is a forced pre-pass for a scene that turns out to have no sun.

- **Enabling it forces the depth pre-pass on and forces its MSAA resolve.** Exactly two variables in
  `RenderForwardClustered::_render_scene`, both of which already carry a term for raytraced shadows:
  `force_depth_pre_pass` (`scene_state.used_opaque_stencil || is_raytracing_scene_available() ||
  using_screen_space_shadows`) and, inside the `if (depth_pre_pass)` block, `finish_depth`, whose
  `else if (finish_depth)` branch is what calls `resolve_effects->resolve_depth` into
  `rb->get_depth_texture()`. Miss the first and the setting does nothing at all in a project that has
  not turned the pre-pass on by hand. Miss the second and the feature works with MSAA off and
  produces nothing, or last frame's shadows, with MSAA on -- which reads as an MSAA bug rather than a
  missing term. This is the one feature in the fork that forces both with raytracing off, so neither
  term can be folded into `is_raytracing_scene_available()`.

- **The pass runs from `_pre_opaque_render`, after `update_light_buffers` and beside the raytraced
  block rather than inside it.** `_render_screen_space_shadows` reads
  `LightStorage::get_sss_light()`, which `update_light_buffers` fills a few lines above; put the call
  before it and `light.valid` is always false and the mask is never written. The dispatch site is
  `if (rb_data.is_valid() && using_screen_space_shadows)` -- `rb_data` is what actually excludes probe
  renders, and the predicate is the belt over it. It is deliberately not gated on
  `is_raytracing_scene_available()`.

- **`update_light_buffers` gains two parameters, and the mobile renderer calls it too.** The
  signature in `light_storage.h` is `..., bool p_using_shadows, bool p_use_raytraced_shadows, bool
  p_use_screen_space_shadows, ...`, and `RenderForwardMobile::_render_scene` passes `false, false`
  for the last two. Forget that call site and the build fails; insert the new argument in the wrong
  position and `using_shadows` silently lands in the raytraced slot instead.

- **`_ensure_screen_space_shadow_mask` creates the target and clears it white on creation.**
  `RB_SCOPE_SCREEN_SPACE_SHADOWS` / `RB_TEX_SCREEN_SPACE_SHADOW_MASK`, `R8_UNORM` at the render
  buffer's **internal** size, one layer, usage `SAMPLING | STORAGE | CAN_COPY_TO | CAN_COPY_FROM` --
  and `ScreenSpaceShadows::is_target_format_supported()` queries the first three. `CAN_COPY_TO` is
  what the two `texture_clear` calls need; a storage-only texture fails the clear, not the dispatch.
  White is fully lit, and an uncleared mask is a screen of arbitrary darkness on the frame the
  buffers are reconfigured. Keep this clear **and** the one inside `render()`: they cover different
  frames.

- **A light is marked with `sss_strength` only when a mask is genuinely written for it that pass.**
  In `LightStorage::update_light_buffers`, `sss_available = p_using_shadows &&
  p_use_screen_space_shadows`, where the second term is the caller's predicate above. The first
  directional light with `light->shadow` set and a non-zero `shadow_opacity` takes it:
  `sss_light.valid`, `sss_light.direction` and `light_data.sss_strength = 1.0` are written together,
  and every other directional light keeps `sss_strength = 0.0`. The 1.0 was a
  `screen_space_shadows/strength` setting until that was removed as a second, undocumented off
  switch -- port it as a constant, and note that the field is a name tag rather than a strength, so
  it cannot be folded away even though it is now always 0.0 or 1.0. That single float is the whole of how the forward shader learns which light
  the one-channel mask belongs to; there is no companion index texture as there is for the raytraced
  mask. **Marking a light whose mask never arrives is not a missing shadow, it is a black one.**
  Binding 39 falls back to `DEFAULT_RD_TEXTURE_WHITE`, which is 4x4, and `sss_shadow_lookup`
  `texelFetch`es at `gl_FragCoord` -- past the fourth pixel that is an out of range fetch, which
  returns zero under image robustness and is undefined without it. Zero is fully shadowed, so the sun
  goes out across the frame. The lookup carries a `textureSize` guard returning 1.0 in that case;
  since the fallback is opaque white, the guard turns that failure into no contact shadow anywhere
  rather than a dark screen. Keep the guard, and keep the invariant that makes it unreachable.

- **A pass with no light selected does not run at all, rather than running and multiplying by
  zero.** `_render_screen_space_shadows` returns at `!light.valid` and never enters `render()`. This
  is why the fork removed its own `strength` setting: a zero there was a second, undocumented way to
  switch the whole feature off. The mask therefore keeps whatever it last held, which is harmless precisely because no
  light is marked to read it -- the "must not leave last frame's shadows standing" invariant below
  belongs to the returns *inside* `render()`, where a light already is marked. The pre-pass is still
  forced, because the predicate cannot see the strength.

- **`DirectionalLightData` gains a whole `vec4`, not a spare float.** `sss_strength` plus three
  more slots, placed after `volumetric_fog_energy` and before `shadow_bias`. The fields ahead of it
  sum to exactly 80 bytes, so `sss_strength` opens a fresh 16 byte slot and the rest close it: the
  `vec4` array that follows needs its alignment, and adding one bare float shifts every shadow matrix
  in the struct by four bytes on one side only. Two of the three have since been claimed -- a
  `uint rt_caster_mask` and a `float rt_softshadow_angle`, both for the fog's own sun ray -- leaving
  one `pad_sss` float, which a fourth consumer takes without changing `sizeof`. **Anything added
  here must be written UNCONDITIONALLY**, beside the field it derives from rather than inside a
  branch: the array is persistent and indexed by light count, so a field written only on some frames
  holds whichever light last occupied that index on the others. `light_data_inc.glsl` is included by
  `forward_clustered/scene_forward_clustered_inc.glsl`,
  `forward_mobile/scene_forward_mobile_inc.glsl`, `environment/volumetric_fog.glsl` and
  `environment/volumetric_fog_process.glsl`, so the edit reaches all four; keeping the `vec4` intact
  is what stops the fog shaders reading shifted shadow matrices.

- **`sss_strength` is also the name of Godot's own subsurface scattering local** in
  `scene_forward_clustered.glsl` and `scene_forward_mobile.glsl`, and the symbol appears in
  `material.cpp`, `shader_types.cpp` and the GLES3 shaders for that reason. Grepping it to find this
  seam returns mostly false hits; the ones that matter are qualified,
  `directional_lights.data[i].sss_strength`.

- **The direction handed to the pass is view space, and the projection is projection-only.**
  `update_light_buffers` builds a directional light's `direction` as
  `inverse_transform.basis.xform(light_transform.basis.xform(Vector3(0, 0, 1))).normalized()` -- the
  light basis's **+Z**, pointing back toward the light, where omni and spot lights store -Z, then
  taken into view space and normalized. `SSSLight::direction` is a copy of it, and
  `ScreenSpaceShadows::render` takes it as `p_light_direction_view` and passes it through with no
  negation, because the march runs from each pixel toward the light and the point it converges on is
  the light's vanishing point. Bend's own comment above `BuildDispatchList` asks for `float4(light,
  0) * ViewProjectionMatrix`; follow that literally with a world-space direction and the corrected
  camera projection and the result is plausible-looking and wrong. The invariant is written out on
  `LightStorage::SSSLight` -- copy it. Negate the vector and the shadows radiate away from the sun
  instead of toward it, which reads as a lighting setup rather than a bug.

- **The projection handed in must be `scene_data->get_cam_projection()`**, the corrected and
  **jittered** one the depth buffer was rasterized with, not the raw `cam_projection` member. The raw
  one puts the light's screen position up to half a pixel out every frame and the whole shadow field
  crawls with the TAA jitter.

- **Two coordinate conventions the port had to invert, both of which fail silently.**
  1. **Clip Y handedness.** `Bend::BuildDispatchList` maps clip Y to a pixel row with
     `* -0.5f + 0.5f`, which is right for a clip space whose `+1` is the top row. Godot's corrected
     projection already negates Y (`Projection::set_depth_correction` sets `m[5] = -1` under
     `flip_y`, against a positive height Vulkan viewport), so its `-1` is the top row and applying
     Bend's negation as well flips the light to its own vertical mirror. The fix is in
     `ScreenSpaceShadows::render`: build `light_projection` with `-light_clip.y` and leave the
     vendored file alone. It is exactly equivalent, because that is the only place Y is read. **When
     it is wrong the pass still runs and still draws shadows** -- they point away from the sun's
     vertical mirror image, so on a high sun they read as a low one; the Wave Index debug view makes
     it obvious, its pattern converging on a point mirrored about the screen's horizontal center
     line.
  2. **The signedness of the wave offset.** In `compute_wavefront_extents`,
     `ivec2 xy = ivec2(gl_WorkGroupID.yz) * WAVE_SIZE + params.wave_offset;`. `gl_WorkGroupID` is a
     `uvec3` and `WaveOffset_Shader` is routinely negative -- Bend writes `-bounds[2]` and
     `-bounds[3]` for two of the four quadrants around the light. The cast to signed has to happen
     before the add, or the sum is computed unsigned and wraps, and **the two quadrants left of and
     above the light fill with garbage** in a pattern that looks like a wrong light coordinate rather
     than an integer one. The two quadrants below and right of the light staying correct is the tell.

- **Which renders decline, and which of them warn.** `_using_screen_space_shadows` returns false, in
  order, for: the project setting off (silent); a reflection probe render or absent render buffers
  (silent -- a probe has no buffers of its own to hold a mask, and its camera is not the one any mask
  was written for); `rb->get_view_count() > 1` (**warns once** -- stereo needs a dispatch and a mask
  per eye, and the depth buffer is a 2D array the pass's `sampler2D` cannot be handed); an
  orthographic camera (**warns once**, see below); and an effect that could not be built (the
  constructor has already printed why, except for the `_render_buffers_can_be_storage()` case, which
  is silent and unreachable in Forward+). The two warnings exist because the setting is on and
  nothing will come of it.

- **Orthographic declines because a clip `w` of exactly zero is read two ways that disagree.**
  `Projection::set_orthogonal` leaves `columns[2][3]` at the 0 its opening `set_identity()` wrote --
  the element `Projection::is_orthogonal()` tests and the one `xform()` builds `w` from -- so a
  direction vector, which goes in with `w = 0`, comes out with `w` exactly zero. `BuildDispatchList`
  clamps the magnitude up to `+FP_limit` when it places `LightCoordinate_Shader[0..1]`, putting the
  light on the side the sun really is, but takes the march direction from
  `inLightProjection[3] > 0 ? 1 : -1`, where `0 > 0` is false and yields -1, meaning "behind the
  camera". The coordinate says march toward the sun and the sign says march away from it, and a sun
  in front produces byte-identical output to a sun behind. Forcing the sign fixes that half and
  leaves the rest wrong: the march divides every stored depth by its distance along the ray
  (`stored_depth = (shadowing_depth[i] - light_coordinate.z) / sample_distance[i]`) to make the
  light's rays parallel, which is what a perspective projection needs and an orthographic one, whose
  rays are already parallel and whose depth is linear, does not. Declining is the honest answer, and
  it is why the editor's Top/Front/Side views show no contact shadow.

- **The effect is built on first use and its failure is sticky.**
  `RendererSceneRenderRD::get_screen_space_shadows` sets `screen_space_shadows_unavailable = true`
  before constructing and clears it only on success, so a device that cannot run the pass is not
  retried every frame. Four things can fail in the constructor, each with its own message: `R8_UNORM`
  not usable as a storage image (not in Vulkan's guaranteed set without
  `shaderStorageImageExtendedFormats`, and widening the format to four times the bandwidth silently
  is worse than saying so), a shader variant that will not compile (the in-code note names the
  subgroup vote as the likely cause -- fine on every Vulkan 1.1 device, and the comment asserts the
  D3D12 backend's SPIR-V to DXIL path does not handle it), pipeline creation, and **the border
  sampler**. The build is not done in the constructor because the feature is off by default and
  compiles three variants. `~RendererSceneRenderRD` must `memdelete(screen_space_shadows)`, and
  `~ScreenSpaceShadows` frees `depth_sampler` and `shader_version` -- the latter frees the pipelines
  built from it.

- **One compiled variant per quality tier, and the sample count cannot be a uniform.** The sample
  loops are unrolled and the shared array is sized from the count
  (`READ_COUNT = SAMPLE_COUNT / WAVE_SIZE + 2`), so the tiers arrive as version defines: 32/60/96
  samples with 5/8/12 fade-out samples. `HARD_SHADOW_SAMPLES` stays at Bend's 4 in every tier -- it
  is what grounds a blade against the surface it stands on and is the last thing to trade for speed.
  `WAVE_SIZE` is 64 and is the shader's `local_size_x`, a **workgroup** size rather than a hardware
  wave size: on a 32-wide device the workgroup spans several hardware waves, which is what the
  `lds_early_out` path with its two `memoryBarrierShared(); barrier();` pairs exists for. Reduce it
  to `gl_SubgroupSize` and the wavefront geometry no longer matches what the CPU builder laid out.

- **Push constant: 76 bytes**, with a `static_assert` on the size; the field order and the alignment
  rule that holds it together are in the push constant table in the reference section. The
  consequence of a mismatch is worth restating because this pass fails into a value that
  looks intentional: under `DEBUG_ENABLED` RenderingDevice rejects the push and then refuses the
  dispatch for having none, so the mask keeps the white it was cleared to and **the feature reads as
  "the setting does nothing"** -- in the editor, where it is fatal, and not in a release build, where
  neither check is compiled. `wave_offset` is the only field that changes between dispatches;
  everything else, including `light_coordinate`, is the same for all of them.

- **The dispatch loop.** `BuildDispatchList` is given the negated-Y clip vector, the viewport size,
  and full screen **inclusive** bounds (`{0, 0}` to `{p_size.x - 1, p_size.y - 1}`); a directional
  light has no on-screen volume to bound, and bounding it would cost dispatches without saving any
  because the shader reads and writes up to `2 * WAVE_SIZE` pixels outside whatever it is given. It
  returns at most 8 dispatches. `compute_list_begin()` / `compute_list_end()` wrap the whole loop with
  one pipeline bind and one uniform set bind outside it; each iteration sets `wave_offset` and
  dispatches `dispatch.WaveCount[0..2]` -- **`compute_list_dispatch`, not
  `compute_list_dispatch_threads`**. `WaveCount[0]` is `inWaveSize` workgroups, which is how the
  wavefronts step along their rays; dividing it by the local size runs a sixty-fourth of the work and
  produces a thin wedge of shadow near the light and nothing else. The dispatches write disjoint
  pixels and read only the depth buffer, so they need no barrier between them -- splitting the loop
  into one compute list per dispatch puts those barriers back.

- **The output is cleared to white ahead of every *remaining* early return in `render()`.** Two
  returns precede the clear -- an invalid effect or a null depth or output texture, and a
  non-positive size -- and everything after it clears first: the degenerate direction, and a dispatch
  list that came back empty. A rejected pixel is a pixel no dispatch writes, so the target must start
  from a known value rather than last frame's, and a frame that bails out after the clear must not
  leave the previous frame's shadows standing while the light is already marked with a strength.

- **The depth sampler is point-filtered on all three filters and clamped to a transparent black
  border, not to the edge.** The march reads off screen on purpose and those reads have to come back
  as "nothing here". Under this renderer's reverse-Z, red reading back as 0.0 is the far plane, which
  is exactly that. `SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE` instead smears the border texel outward and
  **produces shadows that stream in from the sides of the screen**, strongest where the frame edge
  cuts through geometry.

- **Reverse-Z is expressed entirely in two push constant fields.** `far_depth_value = 0.0`,
  `near_depth_value = 1.0`, and the shader derives its `z_sign` from their relationship; nothing else
  in the port assumes a direction. `depth_bounds` is `(0, 1)`, which is what makes the early-out cull
  the sky -- those pixels sit exactly at the far value. The early-out is on, and Bend's suggestion to
  also skip pixels an existing shadow pass already found occluded is deliberately not taken: the
  raytraced mask is available at this point in `_pre_opaque_render`, but this pass has to work with
  raytraced shadows off, and a second code path is not worth a partial early-out.

- **`surface_thickness` is floored at `1e-6` in the driver**, not only ranged in the project setting.
  It is the divisor in the shader's `depth_scale` (`min(sample_distance[0] + direction, 1.0 /
  params.surface_thickness) * sample_distance[0] / depth_thickness_scale[0]`), so a zero is a
  divide-by-zero across the whole frame. The setting's range starts at 0.0001; the floor is the guard
  against `ProjectSettings.set_setting()`, which the range does not constrain.

- **`hardness` is the fork's own control and is not part of Bend's technique.** The bulk of the march
  accumulates into four buckets by `shadow_value[i & 3] = min(...)`, and Bend average the four, so a
  pixel needs four samples' worth of agreement before it is fully shadowed. That is the right call
  when a stray sample is likelier than a genuine one, and it is why only the first
  `HARD_SHADOW_SAMPLES` are trusted alone. Grass inverts the assumption: a blade narrower than the
  march's one-pixel sample spacing **is** a one-sample occluder, and neither `surface_thickness` nor
  `contrast` can close the gap -- thickness buys darkness only by widening the shadow until it is
  visibly too wide, and contrast saturates. The final combination is
  `mix(dot(shadow_value, vec4(0.25)), min(min(x, y), min(z, w)), hardness)` followed by
  `min(hard_shadow, result)`: `0.0` is Bend's behavior exactly, the default `1.0` takes the darkest
  of the four, and it costs three `min()` for the whole march. Measured against the trace it moves
  darkness 2.1x while moving area 5%, so it and `surface_thickness` are independent -- hardness sets
  how dark, thickness sets how wide. Score both in linear light; every ratio in this area was first
  published from gamma-space differences and had to be re-derived.

- **The composition is `min()`, and where it sits in the directional loop matters.** In
  `scene_forward_clustered.glsl`, immediately after the `} // shadows` brace that closes both the
  mask path and the cascade path, and **before** the `if (rt_shadowed || shadow_opacity > 0.001)`
  tail:

      if (directional_lights.data[i].sss_strength > 0.0 && RT_MASK_ANSWERS_HERE) {
          shadow = min(shadow, mix(1.0, sss_shadow_lookup(), directional_lights.data[i].sss_strength));
      }

  `min()` rather than a multiply: an occluder that is both in the acceleration structure and on
  screen is described by both terms, so multiplying darkens it twice -- stage 20 argues that case in
  full. Placement is the other half: put it after the tail and a baked shadowmask's replace/overlay
  branch overwrites it, and the `USE_VERTEX_LIGHTING` apply never sees it. `RT_MASK_ANSWERS_HERE`
  applies unchanged -- this mask is marched over the pre-pass depth too, so it describes exactly the
  fragments that pre-pass contains and a genuinely alpha-blended fragment must not read it.

- **`sss_shadow_lookup()` goes in `scene_forward_lights_inc.glsl`, inside the `#ifndef
  USING_MOBILE_RENDERER` block**, for the same reason as `rt_shadow_lookup()` in stage 4: it reads
  `gl_FragCoord`, which the vertex stage that includes `scene_forward_clustered_inc.glsl` does not
  have, and that file is shared with the mobile renderer. The mask is stored **linearly**, unlike the
  raytraced mask's square root: this is a contact term whose interesting range is the whole of zero
  to one rather than a visibility that is mostly one, so the sqrt trick would spend its eight bits in
  the wrong place. Squaring it here silently lightens every contact shadow.

- **Binding 39 in `RENDER_PASS_UNIFORM_SET`.** Appended after the raytraced mask and index of stage
  4, declared as `texture2D sss_shadow_mask` in `scene_forward_clustered_inc.glsl` **inside the
  `#else` half of that file's `#ifdef MODE_RENDER_SDF`**, next to 37 and 38 -- not at file scope,
  where the SDF variant would then declare a binding it has no uniform for. Plain 2D in every
  variant, multiview included, because the pass is single view. As with 37 and 38 it must be added on
  **every** path through `_setup_render_pass_uniform_set`, including reflection probe and
  no-render-buffer renders, defaulting to `DEFAULT_RD_TEXTURE_WHITE`. A path that skips it fails the
  uniform set validation for the whole pass rather than for this feature.

- **`#include <thirdparty/bend_sss/bend_sss_cpu.h>` -- angle brackets, and placed after the engine
  includes** in `screen_space_shadows.cpp`. `validate-includes` and `clang-format` want different
  things here and are satisfied only by meeting both conventions at once; getting it wrong broke the
  build once.

- **`debug_view` is how to bring the pass up, and each mode answers one question.** All three
  suppress the early-out, so they paint the sky as well and the pattern covers the frame; all three
  are written into the mask rather than over the screen, so read them on a sunlit surface with
  a sunlit surface rather than in shadow.
  - **Wave Index** (`fract(float(gl_WorkGroupID.x) / float(WAVE_SIZE))`) draws the compute wavefront
    layout, which must fan out from the sun's screen position and track it as the camera turns. This
    is the first one to reach for: if the pattern converges on the wrong point, the light's projected
    coordinate is wrong -- the Y negation, the direction sign, or the wrong projection -- and nothing
    else is worth tuning.
  - **Thread Index** (`float(gl_LocalInvocationID.x) / float(WAVE_SIZE)`) is a ramp along the 64
    threads of one workgroup, which are laid out along a single light ray. It shows the ray direction
    itself, which is what separates a light-coordinate error from a wave-offset error.
  - **Edge Mask** paints white where the two depths of a bilinear pair differ by more than
    `depth_thickness_scale[i] * bilinear_threshold` and black elsewhere, which is the only sane way
    to tune that threshold.
  Scale `bilinear_threshold` whenever `surface_thickness` is scaled, in the same direction.

- **The settings, all under `rendering/lights_and_shadows/screen_space_shadows/` in
  `project_settings.cpp`, are all live.** `enabled` (bool, false), `quality`
  (enum Low/Medium/High, 1), `surface_thickness` (float, 0.005), `bilinear_threshold` (float, 0.02),
  `hardness` (float, 1.0, clamped 0--1), `restrict_casters` (bool, false), `ignore_edge_pixels`
  (bool, false), `debug_view` (enum, 0). Bend's `contrast` and this fork's own `strength` were
  settings and are now constants (4.0 and 1.0) -- both were measured to have exactly one correct
  value, and `strength`'s zero doubled as an off switch.
  Unlike the raytraced master flag of stage 1, `enabled` is `GLOBAL_DEF_BASIC` and **not**
  restart-required and must not be marked so: it is read through `GLOBAL_GET_CACHED` every frame and
  the effect is built lazily, so it takes effect the next frame. `enabled` is read in
  `_using_screen_space_shadows`; the rest are read in `_render_screen_space_shadows`. Leave `ignore_edge_pixels` off: it thins genuine shadows at
  silhouettes, which is exactly the geometry the feature serves.

- **Run `godot --headless --doctool .` and commit the result**, per stage 17 -- nine new
  `ProjectSettings` members, sorted by name by the tool.

- Stage 20 adds, on top of this: a third uniform (`binding = 2`, the caster mask) and its white
  fallback; two flag bits (`FLAG_RESTRICT_CASTERS`, `FLAG_DEBUG_CASTER_MASK`); a fourth `debug_view`
  entry, Caster Mask, which must join the early-out suppression list beside the other three or the
  visualization is culled out of the sky; the `may_cast[]` array in the shader; the
  `restrict_casters` project setting and its doc member; `_using_restricted_sss_casters` with its
  MSAA decline; `PASS_MODE_DEPTH_NORMAL_ROUGHNESS_SSS_CASTER` and the advanced shader group it
  enables; `RB_TEX_SSS_CASTER` and `ensure_sss_caster_texture`; and `set_screen_space_shadow_caster`
  across `renderer_geometry_instance.{h,cpp}`, `renderer_scene_cull.cpp` and
  `rasterizer_scene_dummy.h`. None of that changes the push constant's size or layout, and before it
  is applied the shader's `may_cast[i]` is uniformly true and every surface casts.

---

### 20. Restricting what casts a screen space shadow

Make only geometry the raytracing acceleration structure will **not** hold cast a screen space
contact shadow, by writing one byte per pixel during the depth pre-pass and consulting it at the
march's caster reads.

**Files:**

- `core/config/project_settings.cpp` -- the `restrict_casters` `GLOBAL_DEF`, and `Caster Mask`
  appended to the `debug_view` `PROPERTY_HINT_ENUM` string.
- `doc/classes/ProjectSettings.xml` -- the `restrict_casters` member and the extra sentence on
  `debug_view`. Generate it with `godot --headless --doctool .` (stage 17); no surviving CI job
  catches a stale one.
- `docs/rt_shadows/FORK_GUIDE.md` -- section 10.6 and its row in the screen space settings table.
- `servers/rendering/renderer_scene_cull.cpp` -- `_is_screen_space_shadow_caster()` and its three
  call sites.
- `servers/rendering/renderer_geometry_instance.{h,cpp}` --
  `RenderGeometryInstance::set_screen_space_shadow_caster()`,
  `RenderGeometryInstanceBase::Data::screen_space_shadow_caster`.
- `servers/rendering/dummy/rasterizer_scene_dummy.h` --
  `GeometryInstanceDummy::set_screen_space_shadow_caster()`.
- `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.{h,cpp}` --
  `RB_TEX_SSS_CASTER`, `ensure_sss_caster_texture()`, `DEPTH_FB_ROUGHNESS_SSS_CASTER`,
  `PASS_MODE_DEPTH_NORMAL_ROUGHNESS_SSS_CASTER`, `INSTANCE_DATA_FLAG_SSS_CASTER`,
  `_using_restricted_sss_casters()`.
- `servers/rendering/renderer_rd/forward_clustered/scene_shader_forward_clustered.{h,cpp}` --
  `SHADER_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_AND_SSS_CASTER`,
  `PIPELINE_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_AND_SSS_CASTER`, and the renumbered
  `SHADER_VERSION_COLOR_PASS`.
- `servers/rendering/renderer_rd/shaders/forward_clustered/scene_forward_clustered{,_inc}.glsl` --
  `MODE_RENDER_SSS_CASTER`, `INSTANCE_FLAGS_SSS_CASTER`.
- `servers/rendering/renderer_rd/effects/screen_space_shadows.{h,cpp}` -- the `p_caster_mask`
  parameter of `render()`, `FLAG_RESTRICT_CASTERS`, `FLAG_DEBUG_CASTER_MASK`,
  `DEBUG_VIEW_CASTER_MASK`, and a new `#include
  "servers/rendering/renderer_rd/storage_rd/texture_storage.h"` for the white default texture --
  without it the file does not compile.
- `servers/rendering/renderer_rd/shaders/effects/screen_space_shadow.glsl` -- `caster_mask_texture`
  and the `may_cast` array.

**Done when:** with a grass `MultiMesh` at `cast_shadow = Off` on a ground plane under a raytraced
sun, `restrict_casters` on and `debug_view = Caster Mask`, the grass reads white and the ground
reads black, and the run prints no null-pipeline errors from `ShaderData::_create_pipeline`. The
rendered frame difference is **not** the test: on the grass-on-a-plane rigs in
`docs/rt_shadows/shadow_validation/` the toggle moves a single pixel, because the only structure
geometry there is a flat plane and a flat plane cannot occlude itself from a 38 degree sun
(`shadow_validation/README.md`).

**It ships off, and a port must not flip it.** `GLOBAL_DEF(".../restrict_casters", false)`. That is
a settled decision, not work in flight: `surface_thickness` and `hardness` were calibrated with
every opaque pixel casting, and the restriction moves the quantity they were tuned against. The
reason and the one experiment that would justify a different default are in section 10.6 of
`docs/rt_shadows/FORK_GUIDE.md`.

**Why it is a correctness change and not an optimization.** The screen space term and the light's
own shadow are combined with `min()` (stage 19). Everything in the acceleration structure already
has an exact traced shadow from the same light, so for those pixels the screen space term can only
ever darken *past* the traced answer -- its near-field truncation and its one pixel of rasterization
overshoot both push one way, and `min()` keeps whichever is darker. On grass the screen space term
is the best answer available. On a wall it is a wrong dark smudge laid over a right one.

**The predicate, and the invariant nothing enforces.** `_is_screen_space_shadow_caster()` is a
file-scope `static _FORCE_INLINE_` helper near the top of `renderer_scene_cull.cpp`. It is three
tests and it is the **exact complement** of `CullRTCasters::operator()` inside
`RendererSceneCull::_render_scene`:

- `p_instance->cast_shadows == RSE::SHADOW_CASTING_SETTING_OFF`, or
- `base_type` is neither `RSE::INSTANCE_MESH` nor `RSE::INSTANCE_MULTIMESH`, or
- the `InstanceGeometryData` is null or `!geom->can_cast_shadows`.

Any one of those true means the structure rejects the instance, so it is a screen space caster.

- **The two must be kept in step by hand.** Each carries a comment naming the other; nothing checks
  them. Drift is silent and one-directional in its damage: an instance the structure rejects but the
  predicate misses casts *no* shadow at all once the restriction is on -- no traced one because it
  is not in the structure, no contact one because the mask says it may not cast. It does not warn,
  does not appear in `GODOT_RT_DEBUG` output, and reads as geometry that has simply lost its shadow.
- `CullRTCasters` additionally rejects `!instance->visible`, a null `base`, and repeats via
  `instance->rt_caster_pass`. The predicate deliberately omits all three: an invisible instance
  rasterizes no pre-pass pixel, and the pass counter is per-query bookkeeping rather than an
  eligibility test. Adding them changes nothing; omitting the *first three* does.
- **`can_cast_shadows` is the engine's own answer**, computed in `_update_dirty_instance` from
  `material_casts_shadows()` over every surface plus the material overlay. This is what puts
  alpha-scissor foliage on the wrong side of the line -- see the cost below.

**Three call sites, all required.** The flag is pushed at the instance, never polled:

1. `instance_set_base()`, beside the other `geometry_instance->set_*` calls, where the geometry
   instance is first created. Miss it and a newly instanced object carries whatever the default is
   until something else dirties it.
2. `instance_geometry_set_cast_shadows_setting()`, beside the existing
   `set_cast_double_sided_shadows()` call. This is the one that matters at runtime: setting
   `GeometryInstance3D.cast_shadow = Off` on a grass field is exactly how this feature is meant to
   be authored, and a field switched off during play must start casting in the same frame.
3. `_update_dirty_instance()`, after `geom->shadow_caster_surface_mask` and
   `geom->material_is_animated` are stored. **Place it outside the `if (can_cast_shadows !=
   geom->can_cast_shadows)` guard above it.** Inside that guard it only runs when the answer
   changes, and a material swap that leaves `can_cast_shadows` alone can still be the first time
   this instance's flag is ever computed.

**Instance level on purpose.** The predicate does not see the per-surface
`shadow_caster_surface_mask`, per-element multimesh culling, light range, or the BLAS budget. All of
those make the structure hold *less* than the instance-level test assumes, so ignoring them can only
**over-include** -- a pixel that describes itself in both terms, which `min()` absorbs by
construction. Only under-inclusion loses a shadow, and this never under-includes. A port that
"improves" the predicate by consulting the per-surface mask starts under-including and starts losing
shadows.

**Getting the flag to the GPU.**

- `set_screen_space_shadow_caster(bool)` is a **pure virtual** on `RenderGeometryInstance`.
  `RenderGeometryInstanceBase` implements it, so Forward+, Mobile and GLES3 inherit it;
  `GeometryInstanceDummy` derives `RenderGeometryInstance` directly and needs its own empty override
  or the dummy rasterizer fails to build as an abstract class, with an error naming a class this
  stage otherwise never touches. It is on the "Shared interfaces this fork widens" table for that
  reason.
- **The base implementation must call `_mark_dirty()`.** It writes
  `data->screen_space_shadow_caster` and nothing else reads that field until
  `_geometry_instance_update` rebuilds `base_flags`. Without the dirty mark the value sits in `data`
  forever, `INSTANCE_DATA_FLAG_SSS_CASTER` is never set, the mask comes back zero everywhere, and
  with the setting on **the screen space shadow disappears from the whole frame**. It compiles, it
  runs, and it reads as the setting breaking the feature rather than as a missing line.
- `INSTANCE_DATA_FLAG_SSS_CASTER = 1 << 0` in `RenderForwardClustered`'s instance flag enum; bits 0
  and 1 were free in the enum this fork inherited, and the rest of it starts at `1 << 2`. It is set
  in `_geometry_instance_update` **after** `ginstance->base_flags = 0`, in `base_flags` rather than
  the per-frame flags, so an instance's caster status costs no CPU work per frame. That is the
  point: this geometry was taken out of the structure precisely to stop paying a per-frame CPU cost
  for it. `_fill_render_list` seeds `flags` from `base_flags`, stores it in `flags_cache`, and
  `_fill_instance_data` copies that to `instance_data.flags`, so the flag arrives whatever pass mode
  the pre-pass ends up in.
- Mirror it as `INSTANCE_FLAGS_SSS_CASTER (1 << 0)` in `scene_forward_clustered_inc.glsl`, read by
  `scene_forward_clustered.glsl` under `MODE_RENDER_SSS_CASTER` to write `sss_caster_output_buffer`.
  The two enums are matched only by a comment.

**The pre-pass attachment.**

- `ensure_sss_caster_texture()` creates `RB_TEX_SSS_CASTER` (`SNAME("sss_caster")`) as
  **`RD::DATA_FORMAT_R8_UNORM`**, usage `SAMPLING | COLOR_ATTACHMENT | CAN_COPY_FROM`, at the
  buffers' internal size (`create_texture`'s default size). **There is deliberately no MSAA twin**
  -- see the refusals below. `get_sss_caster()` beside it is an unused accessor; it has no caller
  and a port can leave it out.
- Note the name. `sss` throughout this feature means *screen space shadow*, not subsurface
  scattering, and it collides with Godot's own SSS naming in the same files (`get_specular` carries
  subsurface scatter in its alpha; `DirectionalLightData::sss_strength` is this fork's screen space
  shadow marker). Do not wire either into the other.
- `DEPTH_FB_ROUGHNESS_SSS_CASTER` in `get_depth_fb()` builds depth + normal/roughness + caster,
  three attachments, and selects the MSAA normal/roughness twin exactly as the other cases do. Since
  there is no MSAA caster texture to pair with it, a port that drops the MSAA refusal below hands
  `RenderingDevice` a framebuffer mixing sample counts and it is rejected outright: *"if an
  attachment is marked as multisample, all of them should be multisample and use the same number of
  samples."* That is the second, harder reason the MSAA refusal is a refusal.
- `PASS_MODE_DEPTH_NORMAL_ROUGHNESS_SSS_CASTER` needs three additions, and each is a different
  failure if missed:
  - a `case` in `_render_list()` that instantiates `_render_list_template<>` for it. Its `default:`
    is a comment and nothing else, so a missing case is a pre-pass that draws nothing, with no
    message;
  - a `case` in `_render_list_template()` setting `pipeline_key.version`, with `ERR_FAIL_COND_MSG`
    on `view_count > 1` -- there is no multiview twin, and the screen space pass declines stereo
    anyway;
  - two `depth_pass_clear` entries in the `switch` on `depth_pass_mode`, one per color attachment.
    Zero means "not a caster", so the sky and any pixel the pre-pass does not draw cannot cast.
- The fourth site, `_fill_render_list()`'s dynamic-instance condition, is **dead code kept for
  symmetry** and a port can skip it without losing anything. `_fill_render_list` is never called
  with any `PASS_MODE_DEPTH_NORMAL_ROUGHNESS*` mode: its call sites pass `PASS_MODE_COLOR` (the main
  list), `PASS_MODE_SHADOW*`, `PASS_MODE_DEPTH_MATERIAL` and `PASS_MODE_SDF`. The depth pre-pass
  reuses `render_list[RENDER_LIST_OPAQUE]`, filled under `PASS_MODE_COLOR`, which the condition
  already covers -- as it does for the existing `PASS_MODE_DEPTH_NORMAL_ROUGHNESS` and
  `..._VOXEL_GI` terms beside it.
- **Ordering of the `depth_pass_mode` chain matters.** `using_voxelgi` is tested first and wins; the
  restricted branch comes next, before `is_raytracing_scene_available()`. Put the restricted branch
  after the raytracing branch and it is unreachable, the mask is never written, and the setting
  reads as doing nothing. The VoxelGI precedence is structural rather than a preference:
  `sss_caster_output_buffer` and `voxel_gi_buffer` are both `layout(location = 1)` under
  `MODE_RENDER_NORMAL_ROUGHNESS` in `scene_forward_clustered.glsl` and no variant defines both.
- **That precedence leaves a hole this stage does not close, and a port should know it is inheriting
  it.** `_using_restricted_sss_casters()` does not test `using_voxelgi`, so on a frame where a
  VoxelGI is in view the pre-pass writes no mask while `_render_screen_space_shadows` still binds
  `RB_TEX_SSS_CASTER` -- it guards only on `has_texture()`, and the texture persists once any
  earlier frame created it. The result is the **previous** frame's mask applied to this frame's
  depth: contact shadows lagging or sticking to the wrong surfaces as the camera moves. The comment
  beside that bind claims the two cannot disagree, which is true of the setting and of the sun and
  not of VoxelGI. Closing it means either adding `!using_voxelgi` to
  `_using_restricted_sss_casters()` or binding the mask only when the pass mode that actually ran
  wrote one.

**The shader group, and the bug that reads as "the setting does nothing".** The variant is pushed
with group `SHADER_GROUP_ADVANCED` and `default_enabled` false, last in the depth block of
`SceneShaderForwardClustered::init()`, after the `base_define` the loop prepends:

    "\n#define MODE_RENDER_DEPTH\n#define MODE_RENDER_NORMAL_ROUGHNESS\n#define
    MODE_RENDER_SSS_CASTER\n"

**A disabled group is not an error condition.** `ShaderRD::_allocate_placeholders` fills every
variant of a disabled group with `RD::shader_create_placeholder()` -- a valid RID with no stages. So
`get_shader_variant()` returns non-null, `ShaderData::_create_pipeline` gets past its
`ERR_FAIL_COND(shader_rid.is_null())`, `render_pipeline_create` fails, and the only engine-side
message is the bare `ERR_FAIL_COND(pipeline.is_null())` on the next line, which says nothing about
shader groups. In `_render_list_template` the pipeline lookup returns null, the ubershader retry
hits the same placeholder (both copies of the variant sit in the same group), `pipeline_valid` stays
false, and every surface is skipped. **The entire depth pre-pass draws nothing** -- no depth, no
normal/roughness, no caster mask -- and the march reads a cleared depth buffer.

The fix is one line, in `_render_scene`, inside the same branch that selects the pass mode:

    scene_shader.enable_advanced_shader_group(p_render_data->scene_data->view_count > 1);

Enable the group where the pass mode is chosen, not at init: enabling it unconditionally compiles
the whole advanced set for every project.

**The variant numbering invariant.** `ShaderVersion`'s constants are not an enum -- they are the
**indices at which `init()` pushes each `VariantDefine`**, and the depth block is pushed twice, once
per value of `ubershader`. The invariant is:

> `SHADER_VERSION_COLOR_PASS` must equal the number of depth variants pushed per iteration of the
ubershader loop.

Adding this variant made that ten, so `SHADER_VERSION_COLOR_PASS` went from 9 to 10. Two things in
`_get_shader_version()` depend on it: `ubershader_base = SHADER_VERSION_COLOR_PASS`, and the color
pass index `SHADER_VERSION_COLOR_PASS * 2 + shader_flags`.

**A violation produces no error of any kind.** With ten depth variants pushed and the constant left
at 9, every index stays inside the array (`VERTEX_INPUT_MASKS_SIZE` is derived from the same
constant, so it shrinks in step), the lookup succeeds, and the wrong shader is bound: every
ubershader depth request is shifted down one slot -- version 0 lands on the non-ubershader variant
at index 9, and every higher version lands on the previous ubershader depth variant -- while every
color pass index is shifted down two, so the first two land *inside* the ubershader depth block and
get a `MODE_RENDER_DEPTH` shader bound for a color draw. There is no assert, no validation message,
and no clue pointing at the constant. Push the new variant **last** in the depth block and bump the
constant in the same edit.

`PIPELINE_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_AND_SSS_CASTER` goes in `PipelineVersion`
before `PIPELINE_VERSION_COLOR_PASS`; that enum is hashed rather than packed, so its ordering is
free, but it needs a `case` in `_get_shader_version()` **and** in `_create_pipeline()`'s blend state
switch, where it shares `blend_state_depth_normal_roughness_giprobe` -- `create_disabled(2)`, two
color attachments, which is what this pass has as well. Fall through to the one-attachment state and
pipeline creation fails against the render pass, silently, through the same null-pipeline path as
above.

**The pipelines for this pass mode are not precompiled, and that is the feature's real cost.** The
pre-warm bitfield `GlobalPipelineData` carries `use_normal_and_roughness`, `use_voxelgi` and
`use_sdfgi` and has no bit for this pass mode; the test that sets `use_normal_and_roughness` names
`PASS_MODE_DEPTH_NORMAL_ROUGHNESS` only, and `_mesh_compile_pipelines_for_surface` has no block for
the new pipeline version. `_get_depth_framebuffer_format_for_pipeline(p_can_be_storage, p_samples,
p_normal_roughness, p_voxelgi)` has no parameter that would produce this framebuffer format either,
and the VoxelGI format cannot stand in for it -- an `R8_UNORM` second attachment is not the VoxelGI
`R32UI` one. So with the setting on, every material compiles its pre-pass pipeline the first time it
is drawn: `get_pipeline` misses, the specialized request is queued, the ubershader retry is compiled
with `p_wait_for_compilation` true and stalls the render thread. It is a hitch on first sight of new
geometry rather than a per-frame cost, and it is a shortcoming of the implementation rather than of
the idea, but it is there today and it is a large part of why the setting ships off. A port either
reproduces it knowingly or adds the bit, the compile block and the framebuffer format parameter.

**The march.**

- `layout(set = 0, binding = 2) uniform sampler2D caster_mask_texture` in
  `screen_space_shadow.glsl`, bound in `ScreenSpaceShadows::render()` with the **same
  `depth_sampler`** the depth texture uses: nearest, `CLAMP_TO_BORDER`, transparent-black border.
  Sharing it is deliberate -- an off-screen mask read returns 0, "not a caster", which agrees with
  the off-screen depth read returning the far plane, "no occluder". A repeat or clamp-to-edge
  sampler here casts from the screen's edge texels.
- When no mask is bound, the uniform takes `DEFAULT_RD_TEXTURE_WHITE` and `FLAG_RESTRICT_CASTERS` is
  left clear, so the shader's `!has_flag(FLAG_RESTRICT_CASTERS) ||` short-circuits and no fetch
  happens at all. Unlike the shadow mask, the 4x4 default is safe at any size here because the read
  is a normalized `textureLod` rather than a `texelFetch`.
- **Only the caster side is restricted.** In the read loop, `may_cast[i]` is fetched at the same
  coordinate as `depths.x`. `sampling_depth[]` and `depth_thickness_scale[]` describe the
  **receiver** and must keep coming from the full depth buffer. Point either at the mask and
  `depth_thickness_scale` is zero on every non-caster pixel, which divides by zero in `depth_scale`
  and makes `early_out_pixel()` reject every non-caster: grass self-shadows and the ground it stands
  on receives nothing.
- The restriction itself is one select at the shared-memory store, because `depth_data` already
  encodes "cannot shadow" as a value -- `1e10`, the same sentinel the `i != 0` overshoot case
  writes:

      depth_data[(i * WAVE_SIZE) + int(gl_LocalInvocationID.x)] = may_cast[i] ? stored_depth : 1e10;

  Nothing new crosses the barrier and the wavefront layout is unchanged.
- `FLAG_RESTRICT_CASTERS = 1 << 7` and `FLAG_DEBUG_CASTER_MASK = 1 << 8` must match
  `ScreenSpaceShadows::Flags` in `screen_space_shadows.h` bit for bit; the two lists are matched by
  nothing but their order.
- **Add `FLAG_DEBUG_CASTER_MASK` to the early-out exclusion**, beside `FLAG_DEBUG_WAVE_INDEX |
  FLAG_DEBUG_THREAD_INDEX | FLAG_DEBUG_EDGE_MASK`. Miss it and the debug view is blank exactly where
  a wave votes to leave, which is most of the sky and most of the shadowed ground -- the view then
  looks broken while the feature works.

**Two deliberate refusals.** `_using_restricted_sss_casters()` gates the whole thing, testing in
this order: the project setting, `_using_screen_space_shadows()` (so the pass's own refusals --
reflection probe, multiview, orthographic -- carry through), the sun, then MSAA. In both refusals
**the screen space pass still runs, unrestricted, exactly as before** -- neither is a fallback to a
degraded path.

- **It requires the SUN to be raytraced -- `is_raytraced_directional_available()` -- not merely that
  a structure exists.** The premise of the restriction is that anything it stops casting already
  casts a correct traced shadow *from this light*. With `raytraced_shadows/directional/enabled` off,
  the structure holds only geometry gathered near raytraced lamps and the sun is on a demoted
  cascade, so restricting would take the contact shadow away from geometry receiving none from
  anywhere else. Gate on `is_raytracing_scene_available()` instead and a scene with one raytraced
  lamp and a shadow-mapped sun loses its grass shadows.
- **It declines under MSAA, with `WARN_PRINT_ONCE`.** The caster flag would have to be resolved with
  the depth's own `best_index` sample; averaging it or OR-ing it casts from a depth belonging to a
  surface that was never a caster, and that shows up only as shadows at silhouettes with nothing
  above them -- the one artifact nobody looks for on foliage. The framebuffer sample-count mismatch
  above makes it a hard refusal rather than a judgment call. The MSAA resolve branch in
  `_render_scene` lists the new pass mode alongside the other two, which is unreachable today; leave
  it, but do not read it as MSAA support.

**The predicate is called twice per frame**, once to pick the pass mode and once in
`_render_screen_space_shadows` to decide whether to bind the mask. The two agree on the sun because
`raytraced_shadows/directional/enabled` is snapshotted once per frame in
`RaytracingScene::update_frame_settings()` (`renderer_rd/environment/rt_scene.cpp`) rather than read
live. Make that a live read and within one frame you can write a mask nothing binds, or bind a mask
nothing wrote. They do **not** agree on VoxelGI; see the pass mode chain above.

**Both calls also happen before it is known whether any light needs the pass.** The pass mode is
chosen during `_render_scene`, while whether a directional light is actually casting is only settled
in `_render_screen_space_shadows` from `LightStorage::get_sss_light().valid`. So a scene with the
setting on and no shadow-casting sun still pays the `R8` attachment, the extra pre-pass target and
the advanced-group compile for nothing. This is the same tradeoff as the forced depth pre-pass in
stage 19, and worth stating because the CPU-side flag really is free while the GPU-side attachment
is not.

**The one real cost to authors.** **Alpha-scissor materials pass `casts_shadows()`**, so
`can_cast_shadows` is true, so they are in the acceleration structure, so they stop casting a screen
space shadow when this is on. Today a leaf card casts a correctly cut-out contact shadow while its
traced shadow is the whole quad (the cutout is ignored by the trace -- stage 9); afterwards it keeps
only the quad. This is a regression for the exact content the feature was built for, and nothing
surfaces it: the shadow does not vanish, it coarsens. It is called out in the class reference for
`restrict_casters` and in the fork guide, and the answer for authors is to set `cast_shadow = Off`
on the foliage as well, which puts it back in the screen space set.

**Debug view.** `DEBUG_VIEW_CASTER_MASK` is appended **after** `DEBUG_VIEW_WAVE_INDEX` in the
`DebugView` enum, and `Caster Mask` appended last to the `debug_view` project setting's
`PROPERTY_HINT_ENUM` string. The setting is read as an int, `CLAMP`ed to `DEBUG_VIEW_MAX - 1` and
cast, so the hint string is positional: append to one list and not the other and every value from
that point on names a different view than the inspector says. The view draws white where a pixel's
surface may cast; with the restriction off it is white everywhere, which is the correct answer
rather than a broken one.

---

## Shared interfaces this fork widens

Every entry here is a member added to an interface the engine implements more than once, so a port
that adds it in one place and not the others fails to link -- and for a pure virtual the error names
an abstract class being instantiated, far from anything this fork touched. The stages introduce
these in passing; this is the checklist.

| Added to | Member | Kind | Who must implement it |
| --- | --- | --- | --- |
| `storage/light_storage.h` | `light_set_shadow_map_enabled`, `light_get_shadow_map_enabled` | pure virtual | RD, dummy, GL |
| `storage/light_storage.h` | `light_instance_is_raytraced_shadow_candidate`, `light_instance_can_use_raytraced_shadows`, `light_instance_set_raytraced_shadow`, `light_instance_has_raytraced_shadow` | virtual, defaulted | RD only; the defaults answer for the rest |
| `storage/material_storage.h` | `material_shadow_casting_disabled` | pure virtual | RD, dummy, GL |
| `storage/mesh_storage.h` | `multimesh_uses_3d_transforms` | virtual, defaulted `false` | RD only |
| `rendering_server.h` | `light_set_shadow_map_enabled`, `environment_set_ssao_method` | pure virtual | `RenderingServerDefault` (`FUNC2`) |
| `rendering_method.h` | `environment_set_ssao_method` | pure virtual | `RendererSceneCull` (`PASS2`) |
| `renderer_scene_render.h` | `environment_set_ssao_method` / `_get_`, and the `RaytracingInstance` record | non-virtual | forwards to `RendererEnvironmentStorage` |
| `storage/environment_storage.h` | `environment_set_ssao_method` / `_get_` | non-virtual | the storage itself |
| `rendering_device.h` | `acceleration_structure_is_valid` | non-virtual | the device |
| `renderer_geometry_instance.h` | `set_screen_space_shadow_caster` | pure virtual | every `RenderGeometryInstance`: the forward-clustered one, the mobile one and the dummy. The base implementation must call `_mark_dirty()`, or the flag never reaches instance data and the caster mask comes back empty with nothing to indicate why. |

Default a virtual where a renderer with no raytraced shadows would only be repeating itself; make
it pure where it changes behavior a backend cannot sensibly guess at.

`RenderSceneDataRD` also gains an `alpha_pass` bool that reaches the shader as a scene data flag;
see stage 15. It is not on this table because nothing else implements that class.

## Reference values

Everything in this section belongs to the fork rather than to upstream, so unlike the rest of this
document it can be copied literally and will not drift when Godot changes underneath it. A rebuild
that guesses at these is wrong in ways that read as the system working.

### Project settings -- `rendering/lights_and_shadows/raytraced_shadows/`

| Setting | Type | Default | Range / values |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | restart-required; every other setting here is live |
| `samples_per_light` | int | `1` | 1–16 |
| `max_ray_distance` | float | `0.0` | 0–4096, or greater; `0` = no extra clamp |
| `softness_scale` | float | `1.0` | 0–1 |
| `accurate_occluder_distance` | bool | `true` | |
| `denoiser/enabled` | bool | `true` | |
| `denoiser/spatial_passes` | int | `3` | 1–5 |
| `denoiser/temporal_frames` | int | `32` | 1–64 |
| `denoiser/min_filter_pixels` | float | `1.0` | 0–8 |
| `denoiser/history_clamp_sigma` | float | `2.0` | 0–8; `0` disables |
| `denoiser/lag_response` | float | `1.0` | 0–1; `0` restores pre-lag behavior |
| `directional/enabled` | bool | `false` | live, snapshotted once per frame |
| `directional/caster_distance_scale` | float | `2.0` | 0.5–8, or greater |
| `directional/scatter_casters` | int | `1` | Disabled, **Near Camera**, Full Distance |
| `directional/scatter_distance` | float | `25.0` | 0–500, or greater |
| `directional/demoted_shadow_mode` | int | `2` | Keep Authored, Orthogonal, **2 Splits** |
| `directional/demoted_shadow_size` | int | `1024` | 0–4096; `0` leaves the request alone |

### Project settings -- `rendering/lights_and_shadows/screen_space_shadows/`

All live. Four defaults are Bend Studio's own values, kept as they were; two are measured results
belonging to this fork and would be wrong if taken from Bend's sample.

| Setting | Type | Default | Notes |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | forces the depth pre-pass on and forces its MSAA resolve |
| `quality` | int | `1` | Low, **Medium**, High -- 32, 60 and 96 samples, which is the march length in PIXELS |
| `surface_thickness` | float | `0.005` | hint `0.0001–0.1`. Bend's recommended starting value, and **measured** to be right at two blade sizes -- do not scale it with the occluder, see FINDINGS |
| `bilinear_threshold` | float | `0.02` | hint `0.001–0.2`. Bend's; scale it with `surface_thickness` |
| `contrast` | -- | `4.0` | **constant, not a setting.** Bend's value. It saturates: 4 to 16 moves mass 11% and darkness 5% |
| `hardness` | float | `1.0` | hint `0–1`. **Not Bend's at all**: their shader always averages the four accumulators, which is `0.0` here. `1.0` is a measured result and taking `0.0` from the upstream sample gives about half the trace's shadow |
| `restrict_casters` | bool | `false` | **ships off deliberately; do not flip it during a port.** The reason and the experiment that would justify it are in FORK_GUIDE section 10.6 |
| `ignore_edge_pixels` | bool | `false` | Bend suggest trying it; off here because it thins genuine shadows at silhouettes |
| `debug_view` | int | `0` | Disabled, Edge Mask, Thread Index, Wave Index, Caster Mask |

### Project settings -- `rendering/environment/ssao/`

| Setting | Type | Default | Notes |
| --- | --- | --- | --- |
| `method` | int | `0` | **Screen Space (Legacy)**, Ground Truth. Ships off. Two values against a three-value enum -- resolve by branch, never by cast. |
| `ground_truth/scale_radius_with_distance` | bool | `true` | also selects which `filter_radius_for` branch runs |
| `ground_truth/screen_radius` | float | `0.1` | hint `0.005–0.5`; re-clamped to `0.001–0.5` in the push. Fraction of screen **height** |
| `ground_truth/thickness` | float | `0.3` | hint `0.01–2`; floored at 0. Fraction of the effect radius, not a distance. The one real look tradeoff |
| `ground_truth/visibility_bitmask` | bool | `true` | off falls back to a single horizon per side |
| `ground_truth/slices` | int | `4` | `1–8`, re-clamped identically |
| `ground_truth/steps_per_slice` | int | `8` | `1–16`, re-clamped identically |
| `ground_truth/intensity_scale` | float | `0.5` | hint `0.05–2`; divides the legacy `ssao_intensity` default of 2.0 |
| `ground_truth/shading_rate` | int | `1` | Quarter Resolution, **Checkerboard**; read only when `half_size` is on |

`Environment.ssao_radius`, `ssao_intensity` and `ssao_power`, and the shared `fadeout_from` /
`fadeout_to`, are read straight off the same properties and project settings the legacy estimator
reads, so their defaults are upstream's rather than this fork's -- but `intensity_scale` is
calibrated against two of them, which at the time of writing default to `1.0` radius, `2.0`
intensity, `1.5` power and `50` / `300`. `ssao_detail`, `ssao_horizon` and `ssao_sharpness` have no
counterpart here and are hidden in the inspector when this estimator will run.

### Node defaults this fork changes

These are constructor defaults, not settings, and they apply in **every** renderer. A `.tscn` only
stores what differs from a fresh node, so changing them changes existing scenes.

| Property | Vanilla | Here |
| --- | --- | --- |
| `OmniLight3D.shadow_enabled` | `false` | `true` |
| `SpotLight3D.shadow_enabled` | `false` | `true` |
| `OmniLight3D` / `SpotLight3D` `light_size` | `0.0` | `0.05` |
| `DirectionalLight3D.light_angular_distance` | `0.0` | `0.25` |

A non-zero angular distance reaches further than shadows: it puts the cascade path on PCSS, draws a
sun disk in the sky materials, and slows `LightmapGI` bakes. That is intended, and it is why
`softness_scale` scales the trace's copy rather than the authored value.

### Fixed constants

Compile-time, and each is load-bearing for the reason given.

| Constant | Value | Why it is that |
| --- | --- | --- |
| `LIGHTS_PER_PIXEL` | 4 | one RGBA8 mask texel per pixel |
| `MAX_RT_LIGHTS` | 255 | the slot index rides in a float with 255 reserved as "not raytraced" |
| `SLOT_NONE` | 255 | that sentinel, in the trace and denoise shaders; spelled `RT_SLOT_NONE` in the forward shaders |
| `TILE_SIZE` | 8 | the trace's workgroup, 64 threads |
| `MAX_TILE_LIGHTS` | 128 | shared-memory candidate list per tile |
| `MAX_PENUMBRA_PIXELS` | 32.0 | widest penumbra the 8-bit hit-distance channel describes |
| `HISTORY_FILL_SCALE` | 4.0 | how much wider than its penumbra a disoccluded pixel may filter |
| a-trous `KERNEL` | 0.375, 0.25, 0.0625 | the standard 5-tap B3 spline row |
| a-trous `depth_sigma` | 0.02 | the depth term's falloff; relative, so unitless -- see stage 6 |
| a-trous `normal_sigma` | 64.0 | the normal term's exponent -- see stage 6 |
| `MAX_BLAS_BUILDS_PER_FRAME` | 64 | build budget; the rest defer |
| `MAX_BLAS_BUILD_TRIANGLES_PER_FRAME` | 1 << 20 | the other half of that budget |
| `MAX_RT_CASTERS` | 65536 | gather ceiling, warns and drops past it |
| TLAS instance ceiling | 65536 | a second, separate ceiling on caster SURFACES rather than casters, tested as a bare literal in the structure update and silent when it is hit -- a scene of multi-surface meshes reaches it first |
| `SHADER_VERSION_COLOR_PASS` | 10 | **an invariant, not a value.** It must equal the number of depth versions declared above it in `scene_shader_forward_clustered.h`, because the color pipeline index is `SHADER_VERSION_COLOR_PASS * 2 + shader_flags` and the depth loop pushes each depth version twice, once per ubershader. The caster mask variant was inserted as version 9 and pushed this from 9 to 10. A newer Godot adding its own depth version -- an ordinary thing for it to do -- silently mis-indexes every color pipeline, and the symptom is wrong or missing geometry rather than an error. |
| `SECTOR_COUNT` | 32 | bits in the GTAO visibility mask, one uint |
| `ANGLE_BIAS` | 0.03 | GTAO self-occlusion guard |
| `DEPTH_MIP_COUNT` | 5 | levels in the GTAO depth pyramid |

### The light record

64 bytes, `std430`, one row per slot in a storage buffer indexed by `rt_slot` and sized to the
highest live slot. Slots are sticky, so the buffer is sparse: gaps are zeroed and the trace skips any
row with `radius <= 0`, which is why a live light keeps a positive radius whatever its type. A
directional light takes a row in the same buffer and reinterprets four fields -- `light_type` is the
discriminator and the trace branches on it once, never on a sentinel in another field.

This is the whole CPU-to-shader contract for the trace, the mask and the directional path. Keep the
C++ mirror and the GLSL struct in one commit, with a `static_assert` on the size.

| Off | Field | Type | Omni / spot | Directional |
| --- | --- | --- | --- | --- |
| 0 | `position` | float[3] | light world position | the **camera's** world position |
| 12 | `radius` | float | world range, m | view depth at which the shadow has fully faded |
| 16 | `direction` | float[3] | axis the light points **away** along | unit vector **toward** the light -- the ray's own |
| 28 | `cos_spot_angle` | float | `cos(spot_angle)` | unused |
| 32 | `size` | float | emitter radius in m, times `softness_scale` | **tan** of the angular radius, times `softness_scale` |
| 36 | `light_type` | uint | 0 omni, 1 spot | 2 |
| 40 | `mask` | uint | 8-bit fold of `shadow_caster_mask`, zero promoted to `0xFF` | same |
| 44 | `energy` | float | per-pixel ranking term only | same |
| 48 | `bias` | float | `shadow_bias * 0.05`, m -- the ray's `tmin` | same |
| 52 | `normal_bias` | float | `shadow_normal_bias * 0.015` | `* 0.0075` |
| 56 | `fade_from` | float | unused | view depth where the fade begins |
| 60 | `max_ray_length` | float | unused | ray `tmax`: `radius * (1 + caster_distance_scale)` |

The two directional depths are the negation of the `fade_from`/`fade_to` the cascade path already
computes, which is what keeps the traced fade and the cascade fade from drifting apart. The
directional normal bias is half the lamp scale because the node defaults that property to 2.0 for a
`DirectionalLight3D` and 1.0 for a lamp, so the same slider has to mean the same offset.

### The caster record

What the culler hands the renderer, one per instance, built into a list the renderer consumes whole.
Casters are deliberately **not** frustum culled, so this list is not the visible set.

| Field | What it is |
| --- | --- |
| `mesh` | mesh RID. For a multimesh, the shared mesh -- emitted once per element |
| `mesh_instance` | set only where the geometry deforms; the per-instance skinned buffer the structure reads |
| `transform` | world. For a multimesh element, instance transform times element transform |
| `layer_mask` | the full **32-bit** layers. The fold to eight happens where the TLAS instance is written, not here |
| `surface_mask` | one bit per surface, from the eligibility predicate; surfaces past the thirty-second always cast |

There is no multimesh in the record: the culler expands elements itself, so per-element culling is
the culler's job rather than an interface the renderer sees.

### Texture formats

Get these wrong and the failure is silent. All are single-layer -- this path is not multiview. The
raytraced set and the GTAO depth pyramid are created at the render buffer's **internal** size; the
two GTAO AO buffers are the reduced ones, created at `gather_size`, which is the internal size cut
down by `half_size` and the shading rate.

| Texture | Format | Cleared to | Notes |
| --- | --- | --- | --- |
| RT shadow mask | `R8G8B8A8_UNORM` | white when the trace does not run | sqrt-encoded visibility, one channel per light |
| RT shadow index | `R8G8B8A8_UINT` | 0 | which light each channel carries; the trace writes 255 (`SLOT_NONE`) into unused channels |
| RT raw hit distance | `R8G8B8A8_UNORM` | 0 | penumbra pixels / `MAX_PENUMBRA_PIXELS` |
| RT denoise A/B | `R8G8B8A8_UNORM` | 0 | ping-pong; the last a-trous pass writes the mask |
| RT history visibility | `R8G8B8A8_UNORM` | 0 | |
| RT history index | `R8G8B8A8_UINT` | 0 | |
| RT history meta | `R16G16_SFLOAT` | 0 | linear view depth, history length normalized to the window |
| RT history length | `R8_UNORM` | 0 | normalized to the window |
| GTAO depth pyramid | `R32_SFLOAT` | -- | 5 mips, mip 0 at **full** internal size, farthest-biased |
| GTAO AO A/B | `R16G16_SFLOAT` | -- | occlusion and the depth the denoise re-plane-fits against |
| shared occlusion output | `R8_UNORM` | white when the pass does not run | `RB_SCOPE_SSAO` / `RB_FINAL`, full size, shared with the legacy estimator |

### Push constant sizes

Both sides must match exactly; see the note above the assertions in `effects/rt_shadows.h` for why a
trailing pad on one side alone is fatal, and how to read the reflected size.

| Struct | Bytes |
| --- | --- |
| `TracePushConstant` | 120 |
| `TemporalPushConstant` | 112 |
| `AtrousPushConstant` | 48 |
| `GTAO::PrefilterPushConstant` | 32 |
| `GTAO::GatherPushConstant` | 96 |
| `GTAO::FilterPushConstant` | 80 |
| `RaytracingScene::DequantizePushConstant` | 32 |
| `ScreenSpaceShadows::PushConstant` | 76 |
| `DLSSEffect::ReactivePushConstant` | 16 |

*The three GTAO structs carry their field order here as well, because that order is the other half
of the contract; the assertions catch a size mismatch but not a reordering.*

`ScreenSpaceShadows::PushConstant` is `light_coordinate[4]`, `wave_offset[2]`, `screen_size[2]`,
`inv_depth_texture_size[2]`, `depth_bounds[2]`, `surface_thickness`, `bilinear_threshold`,
`shadow_contrast`, `far_depth_value`, `near_depth_value`, `flags`, `hardness`. The C++ struct is
plain, with no `alignas`: the agreement comes from that grouping putting every `vec2`/`ivec2` on an
8 byte boundary, so reordering the trailing scalars for readability keeps `sizeof == 76` and breaks
the alignment silently.

| Struct | Bytes | Fields, in order |
| --- | --- | --- |
| `GTAO::PrefilterPushConstant` | 32 | `screen_size[2]`, `linearize_mul`, `linearize_add`, `falloff_mul`, `falloff_add`, `orthogonal`, `pad` |
| `GTAO::GatherPushConstant` | 96 | `gather_size[2]`, `full_size[2]`, `uv_to_view_mul[2]`, `uv_to_view_add[2]`, `radius`, `thickness`, `power`, `intensity`, `fade_from`, `fade_inv_span`, `slice_count`, `steps_per_slice`, `scale_radius_with_distance`, `screen_radius`, `orthogonal`, `use_bitmask`, `gather_stride[2]`, `checkerboard`, `pad0` |
| `GTAO::FilterPushConstant` | 80 | `source_size[2]`, `dest_size[2]`, `full_size[2]`, `gather_stride[2]`, `uv_to_view_mul[2]`, `uv_to_view_add[2]`, `plane_tolerance`, `filter_radius`, `direction[2]`, `checkerboard`, `pad0`, `pad1`, `pad2` |

Two of the three grew a field for the checkerboard rate, which is the same edit that once took a
push constant out of sync and blacked out the scene. `FilterPushConstant` has no `orthogonal` field,
which is the orthographic gap noted above rather than an oversight in this table.

---

## Do not retry these

Each was tried, measured, and refused. `FINDINGS.md` has the numbers; what a rebuild needs is the
decision, because every one of these looks like an obvious improvement from the code alone.

Four more were proposed by an audit, examined, and **declined on judgment rather than on a
measurement**. They are here because each reads as an obvious cleanup from the code alone and will
be proposed again otherwise:

- **Deleting `FLAG_USE_PRECISION_OFFSET` and `FLAG_BILINEAR_SAMPLING_OFFSET_MODE`** from
  `screen_space_shadows.h` because nothing sets them. They are Bend's own options in a file that is
  a port of their HLSL under Apache-2.0, next to a header vendored unmodified. Deleting them makes
  the port diverge from its upstream for no gain. Leave them.
- **Removing `ssao/ground_truth/intensity_scale`** because its only correct value is its default.
  It is a derived constant, not a knob: `0.5` puts the shipped `Environment.ssao_intensity` default
  of `2.0` at exactly `1.0`, the identity of the strength curve. Removing it doubles occlusion in
  every existing scene, and `ao_validation/main.gd` reads it back and solves for the value that
  cancels it, so the harness would keep scoring at the old strength while the game got darker.
- **Scaling the ray-origin normal offset by camera distance instead of light distance.** The
  reasoning is sound -- the offset covers depth-reconstruction error, which scales with the camera
  -- but the arithmetic does not reach a pixel at any reachable bias. Comment fix at most.
- **Treating the 128-lights-per-tile overflow as a denoiser-history problem.** The claim that the
  surviving set is re-rolled every frame was asserted rather than measured, and it sits awkwardly
  beside this harness being byte-for-byte deterministic. Measure it before acting on it.

- **Widening the occlusion denoise unconditionally.** It is already sized from the radius and the
  slice count. A wider fixed filter scores worse, because the problem at half resolution is missing
  samples rather than too few candidates.
- **Replacing the occlusion dither.** Measured against a traced reference and it did not move.
- **Rebalancing `slices` against `steps_per_slice`** -- specifically, spending the budget on slices
  instead of steps. Steps buy accuracy and slices buy smoothness, and they are not interchangeable:
  at a large radius 8 slices x 4 steps is 18% smoother and **35% less accurate** than the shipped
  4 x 8. Keep the ratio; raise both if you want more.
- **Averaging shadow visibility in sqrt space.** The mask stores a square root for precision, but
  filtering the roots and squaring darkens every penumbra by Jensen's inequality. Encode and decode
  bracket the storage only.
- **Early-outing the shadow trace on a pair of agreeing probe rays.** Two points on a disk both read
  lit across the outer half of a penumbra, so the shadow hardens as the sample count rises -- the
  opposite of what the setting is for.
- **Feeding the a-trous result back into the temporal history.** It compounds without bound; a two
  pixel kernel becomes a twenty pixel smear and contact hardening is the first thing lost. The
  history stores the accumulation, never the filtered output.
- **Deriving pass cost by subtracting whole-frame framerates.** It produced a fixed-overhead figure
  that three direct measurements later refuted outright.

---

## Quick reference: the seams that break

These integration points were rated fragile -- they depend on a data layout, an ordering, or a
format Godot revises between versions. Check these first.

| Seam | What to verify on the new engine |
| --- | --- |
| `RD::AccelerationStructureGeometry` / `blas_build` | Still carries `vertex_buffer`/`offset`/`stride`/`count`/`format` plus index fields, and `blas_build` is still a full in-place rebuild with no refit. |
| Mesh vertex layout | Positions still a contiguous `float32x3` block at offset 0 ahead of the attribute block; compressed decode still `pos * aabb.size + aabb.position`. |
| `MeshInstance::Surface` (`vertex_buffer[2]`, `current_buffer`, `last_change`) | `last_change` still set on **every** surface `update_mesh_instances()` dispatches, not only on a buffer flip. |
| `LightData` / `DirectionalLightData` trailing `pad[2]` | Still unclaimed padding. If upstream took it, find new space and keep `sizeof` identical. This fork appended a whole `vec4` for `sss_strength` rather than a bare float, because the `vec4` array after it needs its 16 byte alignment and one loose float shifts every shadow matrix by four bytes on one side only. Of the other three slots, `rt_caster_mask` and `rt_softshadow_angle` are now taken and one `pad_sss` float remains. |
| `RENDER_PASS_UNIFORM_SET` bindings 37/38/39 | Find the new highest binding; renumber C++ and GLSL in lockstep. 37 and 38 are the raytraced mask and its light index, 39 the screen space shadow mask. |
| `_setup_render_pass_uniform_set` | Bindings added on every path, including probe and no-render-buffer renders. |
| `update_light_buffers` | Every early-out preserves both invariants: `rt_slot < RT_SLOT_NONE` iff the light has a channel this frame, `shadow_map_opacity > 0.001` iff an atlas rect or cascade was actually written. |
| `_pre_opaque_render` dispatch site | Depth is resolved before it; the trace is fed `scene_data->get_cam_projection()`, not the raw member. |
| Directional loop in `scene_forward_clustered.glsl` | Re-derive the three-way split by hand: upstream's single `shadow_opacity` block becomes a mask block, a cascade block gated on `shadow_map_opacity`, and a shared tail gated on `rt_shadowed \|\| shadow_opacity`. The lightmap shadowmask branches and the vertex-lighting apply run on both paths; the plain fade smoothstep runs only on the non-raytraced one, because the trace already baked it. **The mask block must hand over RAW visibility**: the second loop applies `shadow_opacity` to the unpacked byte for both paths, and fading in the first loop as well squares it. |
| Fog `Params` UBO / `ParamsUBO` | `cam_position` at the identical offset on both sides. |
| Fog `ShaderGroup` enum | The four device-capability groups still contiguous and first; `+ SHADER_GROUP_BASE_RAYTRACED` silently maps wrong if a fifth is inserted. |
| `_get_fog_process_variant` | Still `device_group * VOLUMETRIC_FOG_PROCESS_SHADER_MAX + idx`, and the push order matches the enum position-for-position. |
| `RB_SCOPE_SSAO` / `RB_FINAL` format and usage | Still `R8_UNORM` with sampling and storage, and still what the forward shader samples for occlusion. Both estimators write it; if upstream changes it, change both. |
| `Environment::_validate_property` forward_plus branch | The `else` this fork added is still reachable, i.e. upstream has not put its own `return` in front of it. |
| `re-spirv` `SpvIsSupported()` | Still excludes ray-query opcodes so those modules bail out rather than being miscompiled. Watch stderr for the "not supported yet" line. |
| C++ push constant struct vs its GLSL block | Sizes match **exactly**, trailing padding included. The reflected size is the block's exact end, not rounded up to sixteen, so a pad on one side alone breaks it. RenderingDevice then rejects the whole push and refuses the dispatch -- but only under `DEBUG_ENABLED`, so this is fatal in the editor and invisible in a shipped game. The pass silently stops running and the frame shows whatever its target already held; in this fork that was an entirely black scene. **Nine** pairings, spread across `effects/rt_shadows.h`, `effects/gtao.h`, `effects/screen_space_shadows.h`, `effects/dlss.h` and `environment/rt_scene.h`. The registry listing all eight, and the way to read a block's reflected size, is the comment above the assertions in `effects/rt_shadows.h` -- keep it in step, since it is the only place they are gathered. |
| Screen space shadow light selection | `update_light_buffers` still runs before `_pre_opaque_render` reads `get_sss_light()`, and still fills `DirectionalLightData::direction` for a directional light from the light basis's **+Z** (pointing toward the light), not the `-Z` omni and spot use. If upstream unifies those two, the march runs backwards and shadows radiate away from the sun. |
| Screen space shadow depth availability | `force_depth_pre_pass` and `finish_depth` both still take a term for this feature. It marches the pre-pass depth buffer and, unlike raytraced shadows, can be enabled with raytracing off -- where nothing else would force either. |
| Bend's Y convention | `Projection::set_depth_correction` still negates Y (`m[5] = -1` under `flip_y`) against a positive-height Vulkan viewport. The vendored dispatch builder applies D3D's `* -0.5 + 0.5`, so the effect negates clip Y on the way in. If upstream changes the viewport or the correction, this double negation flips and the sun lands at its vertical mirror. |
| The shadow mask is written every frame | An untouched target reads as its clear, and a cleared mask is every raytraced light fully occluded at every pixel -- the worst answer rather than a degraded one. The trace must report whether it wrote, and the caller must clear the mask to white when it did not. The same asymmetry applies to the occlusion buffer, where the safe value is also white. The denoiser's own history buffers are deliberately exempt: losing those degrades to the raw trace, which is noise rather than nothing. |

---

## How to verify a port

Nothing here needs a real GPU. The original work was validated on **lavapipe** (Mesa's software
Vulkan) under Xvfb, rendering to PNG and comparing with a small Python script.

Know what that distorts: lavapipe traverses the BVH on the CPU, so it **overstates** rasterization
cost and **understates** the benefit of ray early-out. Treat its frame times as directional only.
Image comparisons are trustworthy and reproducible to the byte -- two consecutive runs of the same
binary and scene differ by zero pixels, so a difference of a few hundred pixels is a real change and
not noise.

lavapipe **does** run the raytraced path: it advertises ray query support and this fork takes it. It
prints `OpTypeRayQueryKHR is not supported yet.` once at startup, which comes from the Mesa stack
rather than the engine and does not stop the trace. `GODOT_RT_DEBUG=1` settles it either way -- a
line reading `pre_opaque: ... rt_lights=1 new_slots=1 tlas=1` is the mask being written.

**Score in linear light. This is the rule the whole fork's measurements rest on, and getting it
wrong invalidated every published screen space shadow ratio once already.** A PNG is sRGB encoded,
so differencing two of them measures gamma space rather than light, and a darkness ratio read off
that difference is not the ratio of light the two images remove. Decode first:

    a <= 0.04045 ? a / 12.92 : ((a + 0.055) / 1.055) ** 2.4

The error is not obvious from the numbers it produces -- they look plausible and merely pessimistic.
What caught it was a control that could not miss and did: a shadow-map path applying an opacity fade
exactly once must read 0.500 at an opacity of 0.5, and it read 0.336. **Build a control with a known
exact answer into any new measurement**, and disbelieve the measurement before the code when the
control misses.

Two harnesses do all of this already and are the place to start rather than a new script:

| | What it scores | How |
| --- | --- | --- |
| `docs/rt_shadows/shadow_validation/` | the screen space contact shadow against a raytraced reference, and `shadow_opacity` linearity | `./run.sh field`, `./run.sh probe`, `./run.sh opacity` |
| `docs/rt_shadows/ao_validation/` | the occlusion estimators against two CPU-traced references | `./run.sh room gtao`, then `ao_truth.py` and `ao_compare.py` |

Each README carries the numbers a change must not move, and each pins its own quality tier, capture
resolution and scene geometry rather than inheriting them -- which is how a run silently stops
reproducing.

The technique that settled most **denoiser** questions was **RMSE against a high-sample,
denoiser-off render of the same scene** -- one sample plus denoiser versus sixteen-sample ground
truth. Edge-width metrics were tried first and proved unreliable there, because they were confounded
by the two images having different noise levels. Note that this does not replace stage 6's
acceptance gate: a rendered reference carries the same geometric defects as the render, so the three
that stage names have to be measured against a closed form instead.

For "this change costs nothing when unused", the standard is **byte-identical output**: build with
the change and render; stash the change, rebuild, render the same scene; compare checksums. That is
how the fog work was shown to be free.
