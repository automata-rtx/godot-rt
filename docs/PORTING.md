# Porting: re-applying this fork to a newer Godot

The ordered recipe: a preflight check, twenty-one stages in dependency order, the interfaces this
fork widens, the constants it owns, the seams most likely to break under upstream drift. Not here:
how a feature works (`docs/internals/`), what to set and what it costs (`docs/features/`), what was
measured or refused (`docs/HISTORY.md`), how to score a change (`docs/VALIDATION.md`), diagnosing a
symptom (`docs/TROUBLESHOOTING.md`).

**Not a diff.** On a newer engine the line numbers below are wrong, some functions are renamed, some
structs have grown fields. What survives is the *shape*: which upstream thing each piece hooks into,
what it assumes, and what the failure looks like when the assumption stops holding.

Upstream base: `b56a91878e7c94977e4af978968e41d0670c0a8b` (Godot 4.8-dev). Any piece as written:
`git diff b56a91878..HEAD -- <path>`.

Each stage: what to change, in which files, what it must satisfy, how to tell it worked. Mechanism
is in the linked `docs/internals/` file; read it beside this. Nearly every pitfall is a bug that
shipped and was found again by measurement, so each carries its **symptom** — rarely a crash,
usually a picture that looks slightly wrong. Every "Done when" figure is a render or instrumented
run on the software-Vulkan rig in `docs/VALIDATION.md`; figures naming a `run.sh` target reproduce
to the byte.

---

## Stage 0 — Preflight: is the raytracing layer still there?

Godot 4.7/4.8 shipped a **complete hardware-raytracing layer inside `RenderingDevice`** — BLAS/TLAS
create and build, `UNIFORM_TYPE_ACCELERATION_STRUCTURE`, `SUPPORTS_RAY_QUERY` and
`SUPPORTS_BUFFER_DEVICE_ADDRESS` queries, AS-aware buffer creation bits, render-graph barrier
tracking — with **no consumer anywhere in the renderer**. This fork is a re-integration, not a
reimplementation. If that layer changed shape, that is the port's largest risk; settle it first.

The fork's one addition: **`acceleration_structure_is_valid(RID)`**
(`servers/rendering/rendering_device.cpp:5155`), mirroring the existing `*_is_valid` queries. A
structure is freed implicitly with any buffer it was built from and the owning mesh can die first,
so a cache outliving its source meshes must be able to ask whether a handle is live; one dead handle
takes the whole `tlas_build` down.

**Done when:** a throwaway `#version 460` compute shader with `#extension GL_EXT_ray_query :
enable`, an `accelerationStructureEXT` at set 0 binding 0 and a `rayQueryInitializeEXT`/`ProceedEXT`
loop compiles and links through Godot's own shader build, and a one-triangle BLAS plus one-instance
TLAS report true from the new validity query.

**Pitfalls:**

| What | Why it bites |
| --- | --- |
| **glslang gates the `rayQueryEXT` keyword and every `rayQuery*EXT` builtin on `#version 460`**; every other `renderer_rd` shader is 450 | `accelerationStructureEXT` has *no* version gate, so a 450 shader compiles the uniform and fails only at the first `rayQueryEXT`, reading like a shader-specific bug. No preprocessor branch can hide it either — the whole file goes to 460 |
| **Godot's `re-spirv` optimizer does not understand `OpTypeRayQueryKHR`** | it prints `OpTypeRayQueryKHR is not supported yet.` and falls back to unoptimized SPIR-V. Harmless. (Same text also appears once at startup under lavapipe, from Mesa — `docs/VALIDATION.md`) |
| **`blas_create` resolves a geometry's vertex buffer through `vertex_buffer_owner` ALONE** (`rendering_device.cpp:323`) | so every buffer handed to it must come from `vertex_buffer_create` (`:3865`). A `storage_buffer_create` RID lands in a different owner (`:1509`), fails the lookup, and prints `Parameter "vertex_buffer" is null.` once per surface per frame forever while building nothing. This fork shipped that: the dequantized-position buffer for compressed meshes was a storage buffer, so **no compressed mesh cast a raytraced shadow at all**. Stage 1 has the rule |
| **`tlas_build` rejects a zero `hit_sbt_range`**, even for ray-query-only use with no shader binding table anywhere | pass a synthetic `HitShaderBindingTableRange(int64_t(1) << 32)` |
| A TLAS's `max_instance_count` is frozen at create time; scratch buffers are per-structure, never pooled; build-input buffers need `DEVICE_ADDRESS` as well as the AS-input bit | and there is **no refit or compaction entry point**, so every "update" of a BLAS is a full `blas_build` on the same RID |
| The Vulkan container targets SPIR-V 1.4 with a Vulkan 1.1 client, exactly `GL_EXT_ray_query`'s minimum | check `RenderingShaderContainerFormatVulkan::get_shader_spirv_version` (`drivers/vulkan/rendering_shader_container_vulkan.cpp:103`) |
| **Creating a structure is not thread-safe; building one is guarded** | `blas_build` takes `ERR_RENDER_THREAD_GUARD` (`rendering_device.cpp:445`); `blas_create` (`:302`) and `tlas_create` (`:423`) take neither that nor `_THREAD_SAFE_METHOD_`, where `compute_pipeline_create` (`:5092`) does — and they touch the frame's disposal lists and the render graph's resource tracker unguarded. So **every creation happens on the render thread**: cull records, the render step builds |
| **`AccelerationStructure::invalidated` never re-arms** | it starts true, is cleared by a successful build (`:460`, `:566`), and nothing sets it back when the vertex data changes — a skinned mesh whose deformed buffer was just rewritten leaves a valid-looking stale BLAS with no diagnostic. The cache tracks staleness itself rather than trusting the flag |
| **`SUPPORTS_RAY_QUERY` can return true where every implementation body is compiled out** | raytracing is `#define VULKAN_RAYTRACING_ENABLED 0` on macOS and iOS (`drivers/vulkan/rendering_device_driver_vulkan.cpp:56`) but the query (`:7479`) sits outside that guard, so on MoltenVK it says yes and `blas_create()` returns a null RID. `has_feature()` alone is not the capability test |
| **`misc/extension_api_validation/` treats a changed arity as non-additive**, default argument or not | `blas_build(RID)` → `blas_build(RID, bool)` fails that gate. Add a separate method — which is why the fork's addition is a new `acceleration_structure_is_valid(RID)` |

---

## The rebuild order

The commits are in the order the work was *discovered*, false starts included. Follow this order
instead; each stage ends somewhere you can check.

Three blocks are independent of the raytracing chain and of each other, and can be ported alone or
left out: **stage 18** (ambient occlusion) touches no raytracing; **stages 19–20** (screen space
contact shadow) need a depth pre-pass and no ray query; **stage 21** (Streamline/DLSS) is
Windows-only and touches the Vulkan loader. Stages 1–17 are one chain in order, with their mechanism
in **`docs/internals/rt-shadows.md`**, section by section; each stage names the section it needs.

### 1. Settings and availability

Register the setting family, stand up `RaytracingScene` as a settings-plus-capability object with an
empty `update()`, thread the renderer-agnostic virtuals from `RendererSceneRender` down to
`RenderForwardClustered`, widen mesh buffer creation bits. **Nothing traces yet; no pixel changes.**
Mechanism: "Settings plumbing", "Buffer creation bits, upstream side".

**Done when:** the engine boots with the setting on and off; a startup line reports whether
raytracing is *active* (setting on and device able to trace are different questions, and only the
second matters); every frame is byte-identical to the unmodified engine; and with the setting on a
mesh's vertex buffer is created with `DEVICE_ADDRESS` and AS-build-input usage.

- Register the raytracing family in `ProjectSettings`' own constructor
  (`core/config/project_settings.cpp`), not near its consumer: `mesh_add_surface` decides buffer
  creation bits at upload time, **before the `RaytracingScene` that would otherwise own them
  exists** — which is also why the master setting is restart-required. The RenderingDevice is up by
  then, which is what lets the predicate ask it for feature support. (Stage 18's GTAO family
  registers in `servers/rendering/rendering_server.cpp` instead.)
- **Latch only what genuinely cannot change; read the rest through `GLOBAL_GET_CACHED`.** The first
  version resolved the whole family once behind a `settings_registered` flag, quietly making every
  knob restart-required while the editor advertised two as such — turning the denoiser off in the
  inspector did nothing, with no feedback. Only `enabled` is latched, for the buffer-bits reason.
- **`GLOBAL_GET_CACHED`** (`core/config/project_settings.h:281`) keeps a function-local typed copy
  plus the `ProjectSettings` version counter it was filled at, and re-reads only when that counter
  moves. A steady-state read is an integer compare against a static — what makes a per-frame live
  read affordable — and an inspector or `ProjectSettings.set_setting()` edit reaches the
  renderer on the next frame. The type must be trivially destructible (`static_assert`). Clamp **on
  read**, not at registration: a live value arrives with no validation beyond the property hint, and
  several hints allow `or_greater`.
- **Widening the buffer bits is one predicate, one flag word, two call sites.**
  `MeshStorage::_raytracing_buffers_required()`
  (`servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp:1105`) = latched master setting AND
  `SUPPORTS_RAY_QUERY` AND `SUPPORTS_BUFFER_DEVICE_ADDRESS`. Ray query must be tested even though
  nothing traces yet: testing only the setting and device address gave every mesh buffer AS usage
  nothing could consume on D3D12, whose `has_feature()` has no `SUPPORTS_RAY_QUERY` case and returns
  false. The word is `DEVICE_ADDRESS | ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY | AS_STORAGE`,
  OR-ed in whole rather than decided per buffer — nothing checks a buffer's usage against what a
  build needs, and `blas_create` reports only that it failed, naming no missing bit.

  | Allocation | Bits | Why |
  | --- | --- | --- |
  | A surface's vertex, attribute, skin and index buffers, in `mesh_add_surface` | all three, OR-ed into what that code already computed | vertex and index buffers are build input; the other two ride the same word |
  | That surface's LOD index buffers | none | only LOD 0 is traced, so a LOD buffer is never build input |
  | The per-mesh-instance vertex buffer the skeleton/blend-shape pass writes (`_mesh_instance_add_surface_buffer`) | device address and AS build input only | upstream already gives it storage usage |

- **`AS_STORAGE` on the vertex buffer is the bit upstream would not have set, and is not optional.**
  Upstream grants storage usage only to a surface with skin data, blend shapes or
  `ARRAY_FLAG_USE_STORAGE_BUFFER`; a plain static mesh has none, and stage 2's dequantize pass binds
  the mesh's *own* vertex buffer as a storage buffer for static unskinned casters too.
- **The second call site is the one that gets missed, and its failure is a decoy.** A skinned
  caster's structure is built from the per-instance buffer the deform pass wrote, so that buffer
  needs the same usage. Widen only the surface upload and every static caster works while every
  skinned one fails at `blas_create` — printing the message about meshes uploaded before the setting
  was on, so it reads as a stale setting and restarting does not fix it. The helper is called again
  when a second buffer index is allocated for motion vectors, so **both** buffers of the pair must
  come from it.

> **The expanded position buffer, both halves of which cost a debugging session.** Stage 2's
> dequantize pass writes compressed positions out as `float32x3`, and it is that buffer — not the
> compressed source — the BLAS is built from. Create it with **`vertex_buffer_create`** and **all
> three** bits: device address, AS build input, **`BUFFER_CREATION_AS_STORAGE_BIT`**. The function,
> because `blas_create` resolves through `vertex_buffer_owner` alone (`rendering_device.cpp:323`)
> and a `storage_buffer_create` RID (`:1509`) fails the lookup, so no compressed mesh casts a
> shadow — this fork shipped that bug and an older revision of this recipe reintroduced it exactly.
> The bit, because `uniform_set_create` refuses a vertex buffer lacking storage usage (`:4756`),
> which `storage_buffer_create` sets unconditionally (`:1465`) and `vertex_buffer_create` only when
> asked (`:3872`), so without it the dequantize pass cannot bind its output.

- `_uses_raytraced_shadows()` must be a **separate virtual**, because the RT objects live on the
  shared RD base class. Without it the Mobile renderer looks capable and its lights lose their
  shadow maps without gaining a mask.
- New include directions upstream lacks: `storage_rd` → `environment` (`mesh_storage.cpp` includes
  `rt_scene.h`), and `environment` → a generated shader header in `effects/`.
- clang `-Werror` rejects unused private fields; GCC and MSVC do not. A leftover flag cost a CI
  round.

### 2. Acceleration structure

One BLAS per mesh surface, one TLAS per frame, from a caster list gathered in the culler by querying
the geometry index with each candidate light's bounds. Includes the dequantize pass. **Build the
light-volume gather directly** — the fork started with a whole-scenario walk, which ties cost to
level size and had to be replaced. Mechanism: "Caster gather", "Acceleration structure".

**Done when:** `GODOT_RT_DEBUG=1` prints a non-zero TLAS entry count and the count follows the
lights' reach rather than the level size. On a 400 m level of 2000 props lit by four ten-meter
lamps: seven casters, nineteen geometry-index nodes visited (instrumented run).

- **The vertex format is the most fragile thing in the port.** Godot's compressed positions
  (`ARRAY_FLAG_COMPRESS_ATTRIBUTES`, `R16G16B16A16_UNORM` normalized into the surface AABB) are not
  a legal AS vertex format; `rt_dequantize.glsl` exists only to expand them to `R32G32B32_SFLOAT`.
  Decode: `position.xyz * aabb.size + aabb.position`. **Re-find it** by grepping
  `_mesh_surface_generate_version_for_input_mask` for `offset = i == RSE::ARRAY_NORMAL ?
  position_stride * s->vertex_count : 0`. If positions are no longer a contiguous `float32x3` block
  at offset 0 ahead of the attribute block, the zero-copy path is gone and that shader plus the
  format tests must be rewritten. The output buffer follows the stage 1 callout.
- Uncompressed surfaces are zero-copy: the surface buffer at offset 0, stride 12. Classify
  ineligible surfaces **once** (non-`PRIMITIVE_TRIANGLES`, `ARRAY_FLAG_USE_2D_VERTICES`,
  `ARRAY_FLAG_USES_EMPTY_VERTEX_ARRAY`, zero vertices), not per frame.
- Use the **LOD-0** index buffer; a LOD silhouette does not match the shadow the raster path casts.
- Set `ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT` on every instance:
  `shadow_reverse_cull_face` is per-light while the TLAS is per-scenario, so flip-facing cannot be
  honored at all.
- TLAS instance sourcing must live in `RendererSceneCull` — `render_forward_clustered` cannot reach
  `Scenario` or `Instance`. Gather before the shadow loops; skip entirely for probe renders.
  Deduplicate with a per-`Instance` pass stamp, since every light touching an instance returns it.
- Report each failure kind separately. `blas_create` failure almost always means the mesh was
  uploaded before the setting was on, which is what makes the setting restart-required.

### 3. Light slot pipeline

Give each raytraced light a stable index into a GPU light buffer and carry that index plus a second
opacity down to the shaders, **with nothing reading either yet**. Its own stage because it isolates
the port's highest-risk quiet breakage. Mechanism: "Light slots", "Sticky allocation".

**Done when:** `GODOT_RT_DEBUG` prints `new_slots=N` on the first frame and `new_slots=0` on every
frame after, including while walking through a ring of eight lamps that fully reorders the light
buffer. The render is still byte-identical.

- **`LightData` / `DirectionalLightData` are hand-maintained mirrors of the GLSL structs** in
  `servers/rendering/renderer_rd/shaders/light_data_inc.glsl`, and the fork **consumed the existing
  trailing pad** rather than growing them: `float pad[2]` became `float rt_slot; float
  shadow_map_opacity;` on both sides. Do not grow either struct, or every offset after the change
  moves silently and lighting goes subtly wrong rather than crashing. **If the newer Godot has
  repurposed that padding, find two other slots and update both sides together, `sizeof`
  identical.** `DirectionalLightData`'s pad changes type from `uvec2` to two floats deliberately —
  the shader compares `rt_slot` as a float against `255.0`.
- **Slots must be sticky**: a light keeps its index while it keeps casting, plus a four-frame grace
  period. The denoiser's history records which light each mask channel carried, so a light that
  changes index invalidates the whole screen's history (`docs/features/rt-shadows.md`). Assigning in
  light-buffer order — sorted by distance to camera — re-rolls every index as the camera moves.
- The buffer is therefore **sparse**: a slot may belong to a light outside this pass. Zero the gaps
  and let the trace skip them by `radius <= 0` — which is why a live light's radius must stay
  positive whatever its type.
- **Grant a slot only when a built TLAS exists this frame.** A slot with nothing behind it makes the
  forward shader skip the shadow atlas *and* read "fully lit" from the mask: no shadow from any
  source, strictly worse than not enabling the feature.
- The ray cull mask folds from the light's own **`shadow_caster_mask`**, not its cull mask —
  distinct from the per-instance `layer_mask` folded where the TLAS instance is written. Fold 32
  bits to 8 by OR-ing the four bytes (conservative, never under-inclusive); promote a zero to
  `0xFF`.

### 4. Trace and mask

First raytraced shadow on screen: the trace compute shader, the mask and its companion index
texture, the forward-pass read, the depth prerequisites. **Build the per-pixel top-four selection
from the start**; the fork's first design was a global channel-per-light mask, which caps a scene at
four lights and was thrown away. Mechanism, including the two-stage selection and the scoring
function: "The trace", "Tile stage", "Per-pixel stage".

**Done when:** an omni light over a box casts a correct traced shadow with the setting on and the
stock shadow map with it off; a room of many overlapping lamps each shadow correctly; a project with
the setting off renders byte-identically.

| Requirement | Why, and what a miss looks like |
| --- | --- |
| **`rt_shadow_lookup()` must live in `scene_forward_lights_inc.glsl`** (fragment-only), *not* in `scene_forward_clustered_inc.glsl` | that file is also included by the `#[vertex]` stage, where `gl_FragCoord` does not exist: every Forward+ vertex variant fails to compile and **the symptom is the editor appearing to hang on the splash screen**, CPU at 90–120 ms, GPU idle. `scene_forward_lights_inc.glsl` is shared with the mobile renderer, so every block added to *that* file needs `#ifndef USING_MOBILE_RENDERER` |
| Build a combined sampler — `sampler2D(rt_shadow_mask, SAMPLER_NEAREST_CLAMP)` — the way `ssil_buffer` and `ssr_buffer` do | `texelFetch` on a bare `texture2D` needs `GL_EXT_samplerless_texture_functions`, which these shaders do not enable |
| Reconstruct world position with `scene_data->get_cam_projection()` / `get_cam_transform()` | those carry the reverse-Z + Y-flip correction and the jitter the depth buffer was written with; the raw members collapse every pixel to ~0.1 units from the camera and the mask comes out black wherever geometry was drawn |
| Read the real view-space normal from the normal/roughness pre-pass and rotate it to world space with a **quaternion** in the push constant | a normal crossed from two neighboring depth taps fringes every silhouette, and the camera basis will not fit in 128 bytes beside the inverse view-projection. `normal_roughness` is not produced by default — that is why `depth_pass_mode` is forced; `has_normal_roughness()` is a sticky global and must not be used as a gate, and probe renders have no `rb_data` at all |
| **Bindings 37 and 38** appended to `RENDER_PASS_UNIFORM_SET` (set 1); upstream's highest was 36 | add them on **every** path through `_setup_render_pass_uniform_set`, probe and no-render-buffer renders included, with fallbacks: `DEFAULT_RD_TEXTURE_WHITE` for the mask and a new 1x1 all-`0xFF` `R8G8B8A8_UINT` texture for the index — none of the shared defaults are integer-formatted. **On a newer engine find that set's highest binding and renumber the C++ pushes and the GLSL declarations in lockstep** |
| **Sort the four surviving channels by ascending light index** before writing | both denoiser stages compare the entire four-index vector for equality to decide whether a tap may be blended, and the ranking order turns on distance and normal, so it is not canonical: an equality test over a non-canonical order rejects nearly every tap and the result collapses to the center pixel with its single ray of noise intact |
| **Every invocation must reach every `barrier()`** | the early return for threads off the right or bottom edge goes *after* the last tile barrier, not at the top of the shader |
| **Every on-screen pixel writes all three images unconditionally** — surface or not, light or not — with fully lit visibility, zero hit distance, four `SLOT_NONE` channels | nothing clears them on a frame the trace runs, and a lit surface no raytraced light reached is exactly the pixel where a stale index texel reads as a real light assignment carrying last frame's visibility |

### 5. Denoiser

Temporal accumulation plus an edge-stopping a-trous filter, both keeping their own history so the
feature does not depend on the image's TAA. Mechanism, including the four history textures and the
exact surface test: "The denoiser", "Temporal pass", "A-trous".

**Done when:** after ninety frames of camera movement the denoised result is byte-identical to a
converged render from the same pose, and a camera orbiting at 3.4 degrees/frame lands within 2/255
of a static converged render.

| Requirement | Why, and what a miss looks like |
| --- | --- |
| **Reproject with the camera, not motion vectors** | the velocity buffer is written by the opaque color pass, which runs *after* the mask is needed, so it is a frame stale; under MSAA it resolves only when TAA or an upscaler asks. Camera reprojection is exact for static geometry, and geometry that moved on its own is then rejected by the surface test rather than smeared |
| Store the history's depth as a raw view distance | the `w` of a reprojected position is the previous clip position scaled by the reciprocal of view depth — **a ratio, not a distance**. Compare it against a tolerance in meters and every tap is rejected every frame, silently: the accumulation never builds and the only sign is a spatial filter that never narrows |
| The history count is stored **normalized to the accumulation window** (`temporal_frames`) in both the meta and the length texture, and **the temporal pass is the only place that multiplies back up** | the length texture is eight bits. Write normalized and read raw anywhere in the loop and the blend factor pins at 1, throwing the history away every frame — which reads as a denoiser that does not work rather than as a bug with a location |
| **Feed the temporal stage back its own output as history, never the a-trous result** | filtering inside the loop compounds without bound: a two-pixel kernel arrives on screen as a twenty-pixel smear |
| Channel assignments are per pixel and **cannot be interpolated** | filter the temporal history by hand, accepting or rejecting each bilinear tap on its own, and reject a-trous taps whose index assignment differs from the center's |
| **Both passes return early on the same two tests, neither looking at visibility values:** depth of zero (sky, under reverse-Z), or `SLOT_NONE` in all four index channels | do **not** write this as "the mask is fully lit in all four channels" — a pixel a light does reach that happens to read fully lit is one noisy sample inside a region that still needs filtering, and skipping it leaves speckle |
| **Every early return in the history-writing iteration must still write all three forward-carried history textures** | or next frame reprojects against the frame before last. The two exits write deliberately different meta: the sky/unreached exit writes zeroed meta (a stored zero fails the relative depth test against any real distance, so nothing reprojects onto it); stage 6's reach early-out writes the pixel's real view distance and history length |
| Multiview is not a fallback inside the denoiser; the whole raytraced path is off above one view | a stereo pair would need its own trace and a full set of history per eye, and none of these passes are layered |

### 6. Denoiser quality

Make one ray per light per frame match a sixteen-sample reference: penumbra-driven filter width,
blue-noise rotation with a jittered radius, sqrt-encoded mask, temporal variance clamp with a
binomial floor, dithered accumulator stores, closest-occluder distance. The sampling, the R2
advance, the a-trous tap weights and the clamp arithmetic are in "Sampling and the ray loop", "The
clamp", "The store dither", "A-trous"; reproduce them exactly rather than from the papers.

**Done when:** the 10–90 penumbra width matches a **closed-form** ground truth across a contact
hardening curve — not merely when an RMSE stops improving. Build the reference from the geometry,
not from another render: a lamp of known radius over a post of known size, perspective camera;
confirm the model first by checking that the 50% crossing of the shadow edge lands within a pixel of
the analytic edge at every distance. RMSE against a rendered reference catches none of the three
defects below, because all three are in the reference too. Recover the shadow term **in linear
light** first — linearize both frames, then divide the render by an occluder-free render of the same
scene, canceling the falloff and the lambert term and leaving visibility. Dividing the *encoded*
frames reads the 10–90 off the wrong curve: under a 2.2 power law that quotient's 10% and 90%
crossings land at roughly **0.006** and **0.79** of the real visibility, so the width is measured
between the wrong two points (`docs/VALIDATION.md`).

Three defects each squeeze or stretch the penumbra, each invisible without that ground truth:

- **No pair of rays can early out for a disk.** Two opposite rim points both read lit over the whole
  outer half of a penumbra, and the binary answer pulls that pixel fully lit. Cost 28% of the
  penumbra's width at sixteen samples per light and less at lower counts, so the shadow got
  *sharper* as the sample count rose. Trace every sample.
- **A variance clamp needs a floor, and its sampling noise subtracted.** The raw neighborhood spread
  collapses to exactly zero wherever a handful of binary taps agree (removing a third of every
  penumbra) and charges the whole per-tap binomial scatter to the signal (so the clamp never fires).
  Floor it with the standard error the ray counts carry, two pseudo-counts so the floor cannot
  collapse with it; subtract the predictable per-tap term; make the radius the remaining spatial
  variance plus the uncertainty in the mean.
- **An 8-bit accumulator that re-reads its own output must round stochastically.** Under half a
  quantization level the step stops moving, and asymmetrically — rare large steps land, frequent
  small ones do not, so the value ratchets. It made the stock penumbra 15% too wide. Dither the
  store by a per-pixel, per-frame fraction of a step.

Other pitfalls:

| Requirement | Why, and what a miss looks like |
| --- | --- |
| **Decode out of sqrt space everywhere it is read** | averaging roots and squaring darkens every penumbra by Jensen's inequality; one missed decode lightens every umbra almost invisibly unless you measure it. (NVIDIA's SIGMA filters *in* sqrt space on purpose; this system does not) |
| Take the widest penumbra any immediate neighbor reports, not the center pixel's | at one sample a ray that misses reports **no** penumbra, so sizing from the center alone smooths the shadowed half of a penumbra and leaves the lit half speckled. At a real contact edge every neighbor reports zero and it costs nothing |
| **Do not set `gl_RayFlagsTerminateOnFirstHitEXT` by default** | visibility is identical either way, but the reported distance becomes whichever occluder traversal reached first rather than the nearest, mis-sizing the penumbra and over-blurring crisp shadows. Keep the flags in the push constant, not a define, so the trade costs no second pipeline, and decide **per light**: a light of zero size sets the flag whatever the setting says, because both penumbra formulas multiply by the emitter size and throw the distance away |
| **Both floors (`min_filter_pixels` and the history-fill widening) apply only where a penumbra was actually measured** | a pixel a light reaches but no ray hit has no blocker to measure to; apply a floor there and it is dragged into the tap loop at up to eight pixels and takes thirty-one frames to recover — which is what every camera turn does to the newly revealed screen edge. Restricted correctly its reach is zero and the same early-out skips it: in a sunlit frame, most of the screen |
| `min_filter_pixels` at its default of 1.0 equals the first a-trous pass's step of one pixel | and every pass early-outs where no channel's reach survives a single step, so a pixel whose penumbra is narrower than a pixel is filtered in no pass at all — which is what keeps a contact edge exact. The trade for raising it, with fringe widths: `docs/features/rt-shadows.md`, "Tuning" |
| Ray offsets come from the light's own bias properties **scaled down** | a shadow map's bias clears a depth texel, a ray only clears the error in a position reconstructed from depth. A directional light defaults normal bias to 2.0 where a lamp defaults to 1.0, so it needs half the scale or the sun's contact shadows lift off their casters |

### 7. Deforming casters

Skinned and blend-shaped meshes cast their current pose, on screen or not. Mechanism: "Entry states,
eligibility, dequantize, skinning".

**Done when:** a two-bone skeleton bending a bar casts a straight shadow at rest and a bent one at
0.7 rad, differing over 8.7% of the frame — and still does with the caster above the top of the
frustum.

- `update_mesh_instances()` only runs the skeleton pass for instances that survived frustum culling,
  and raytraced casters are deliberately **not** frustum culled. Without an explicit second
  mark-and-flush *before* the structures are built, a character behind the camera freezes at
  whatever pose it last held on screen.
- **Key the cache on the skinned vertex buffer, not the mesh.** That buffer is already unique per
  (instance, surface), and the skeleton pass double-buffers it when motion vectors are on, so keying
  on the buffer gives each side of the pair its own BLAS rebuilt in place rather than recreated as
  the pair alternates. A surface with a mesh instance but no deformation falls back to the mesh's
  shared BLAS. `mesh_instance_get_last_change()` is the staleness version.
- Godot's importers already disable vertex compression for skinned and morph-target meshes, so
  skinned geometry is already in the format the AS wants. Re-check on the newer engine.
- No refit, so each pose is a full `blas_build` (reusing the existing scratch allocation).
  Per-instance structures need eviction — the fork evicts after 60 unused frames — or every
  character that ever existed keeps one alive.

### 8. MultiMesh casters

Expanded CPU-side into one TLAS entry per element sharing one BLAS. The expansion belongs to the
culler: the caster record has no multimesh field, and the renderer sees one record per element whose
transform is the instance transform times the element transform. Mechanism: "Caster gather".

**Done when:** a GridMap interior stops leaking light into the next room; twelve pillars in one
MultiMesh become twelve TLAS entries backed by one built BLAS.

- **Iterate the visible element count, not the allocated one**, whenever the multimesh reports one —
  it reports `-1` for "all", so the test is on the sign, and the visible count is then clamped to
  the allocation in case it was set larger. Elements past the visible count still hold whatever
  transform was last written there; tracing them while drawing nothing from them puts a shadow in
  the scene with no object under it.
- Reject a multimesh whose mesh is null, and reject 2D transforms before asking for any element
  transform: `multimesh_uses_3d_transforms` is the query the fork adds to mesh storage for this.
- **Test every element against the light bounds.** A multimesh instance's own AABB covers the whole
  field, so without a per-element test one large GridMap octant fills the structure with elements no
  light can reach. Bound each element by putting the shared mesh's AABB through the composed
  transform. A directional light's swept volume is a second chance only, and only when
  `scatter_casters` allows it (stage 12).
- The per-element test consults the **whole** lamp bounds list, including lamps the gather skipped
  because a directional volume already enclosed them — which is why stage 12 partitions those to the
  back of the list rather than dropping them. Drop them and the bug shows up as scattered props
  missing their shadows only near a lamp, only with a sun in the scene.
- A raytraced light has no shadow-map fallback, so an unsupported caster type is an **absent**
  shadow, not a degraded one, and turning the feature off brings the shadows back — which reads as
  the feature being broken. Bound the total at `MAX_RT_CASTERS` (65536,
  `servers/rendering/renderer_scene_cull.cpp:3573`) and warn once rather than truncating silently,
  re-checking inside the element loop as well as around the instance loop, or one multimesh can
  overrun it alone. It is not the only ceiling ("TLAS build and the contents hash").

### 9. Caster eligibility

Only surfaces that can actually write a shadow enter the structure, decided per surface. Mechanism:
"Per-surface caster eligibility".

**Done when:** a pane of glass in front of a lamp costs one fewer structure entry and stops casting
a solid shadow.

- Compute the mask where upstream already computes its instance-level shadow-casting answer: the
  dirty-instance update that walks an instance's per-surface materials. Store it on the geometry
  data beside `can_cast_shadows` (`geom->shadow_caster_surface_mask`). Invalidation is then free —
  the material dependency that already re-dirties the instance recomputes the mask in the same pass
  — and no new bookkeeping exists to get wrong.
- The mask starts all ones and a bit is only ever cleared, for a material *definitely* unable to
  write a shadow. A surface with no material casts; a `material_override` that cannot cast zeroes
  the whole mask; surfaces at index 32 and beyond have no bit and always cast; a multimesh's
  surfaces come from the shared mesh's own materials.
- It arrives as a new **pure virtual** on material storage, `material_shadow_casting_disabled` —
  true when the material's shader blends rather than writing depth, or reads the screen, depth or
  normal texture. RD, dummy and GL each need an implementation before the engine links; the last two
  return `false`.
- **This is not the negation of upstream's `material_casts_shadows`.** That predicate errs toward
  yes: a material whose shader cannot cast and which has no `next_pass` still answers true, because
  the instance stays in the shadow render list and each draw decides for itself. A raytraced caster
  is decided once and needs the exact answer, and that terminal case is the common one — a pane of
  glass. Write `!material_casts_shadows` and the mask is all ones forever, which looks like the
  stage working. Both walk `next_pass` the same way, so a later pass that does cast rescues one that
  does not.
- The mask sits **on top of** upstream's instance-level answer, which the gather still tests first.
  Two tests, two questions: may this instance cast, and which of its surfaces. Alpha-scissor and
  alpha-hash materials **do** cast, cutout ignored — a documented limitation, not something this
  predicate fixes.

### 10. Structure lifetime and budgets

The BLAS cache, its key, its staleness guard, its budgets, the TLAS contents hash. Mechanism: "Cache
keying and the freed-buffer guard", "Entry states, eligibility, dequantize, skinning", "Budgets and
eviction", "TLAS build and the contents hash".

**Done when:** dragging a `BoxMesh`'s size in the inspector no longer prints `Parameter blas is
null` at frame rate, and shadows survive the session.

- **The key is `SurfaceKey { RID source; uint32_t surface; }`** (`environment/rt_scene.h:88`), and
  only `source` varies: the per-instance skinned vertex buffer where the caster record carries a
  mesh instance and mesh storage returns one (stage 7), the **mesh RID** otherwise. Otherwise is the
  common case, so every static mesh and every multimesh element keys on the mesh and one built
  structure per surface serves all of them — which is what makes stage 8's expansion cheap.
- **Do not key a static entry on the surface's own vertex buffer**, even though that is what it
  builds from. The mesh RID is valid for every caster the gather can hand over and survives a
  surface being cleared and re-added, so a surface that can never build is *remembered* as
  ineligible under its own key instead of being re-attempted every call.
- Every `PrimitiveMesh` clears its mesh and re-adds surface zero on any property change, and
  `ArrayMesh.clear_surfaces()` does the same. That frees the vertex buffer, and the structure was
  registered as a dependent of it, so the structure goes too: **a cache keyed on the mesh RID hands
  out a freed handle forever after**, and one dead handle fails the whole TLAS build rather than one
  shadow. The guard is to compare, on every cache hit, the buffer the surface would build from *now*
  against the one the entry was built from, and **erase** the entry when they differ rather than
  skip it for the frame — a skipped entry is handed out again next frame. Asking the rendering
  device whether the structure is still valid was rejected: that query takes the device lock, and
  this path would take it once per surface per frame. It still guards the free and teardown paths,
  once per entry actually released.
- **The key is not the quantity the guard compares, and that gap is what makes the guard work.** For
  a mesh-keyed entry the key survives `clear_surfaces()` and the buffer does not, so the dead entry
  is still found and can be erased. Key on the buffer and it is never looked up again — no crash, it
  just sits there until eviction while a second entry is built beside it.
- **Three states (`BLAS_UNBUILT`, `BLAS_READY`, `BLAS_INELIGIBLE`), and only `BLAS_READY` is ever
  re-examined.** `BLAS_UNBUILT` is never stored — a surface that loses to the build budget has no
  entry inserted. `BLAS_INELIGIBLE` is permanent for the life of the key, so a failure of the device
  calls that allocate and build is cached exactly as permanently as a non-triangle primitive.
- The build budget gates **first-time builds only**. Check it after the cache lookup returns, so a
  skinned surface whose pose moved is refreshed regardless of how many new surfaces the frame is
  also building — a deferred pose is a visibly wrong shadow, a deferred first build only a late one.
  A surface that loses contributes **no TLAS entry at all**, not an unbuilt handle. Spend a build
  slot before attempting the build, including for a surface that turns out ineligible, and charge
  triangles only on success with a saturating subtract: a mesh larger than the entire triangle
  budget then builds in one frame and zeroes the remainder, where a predictive "would this fit" test
  would defer it forever.

  | Constant | Value | Why |
  | --- | --- | --- |
  | `MAX_BLAS_BUILDS_PER_FRAME` | 64 | a level streaming in can bring hundreds of surfaces into range at once; without a ceiling that is a visible stall |
  | `MAX_BLAS_BUILD_TRIANGLES_PER_FRAME` | 1 << 20 | sixty-four small surfaces and sixty-four large ones are not the same frame |
  | frames until eviction | 60 | skinned structures are per instance; without eviction every character that ever existed keeps one alive |
  | frames between eviction sweeps | 8 | the sweep walks the whole cache; an entry is ineligible for sixty frames anyway, so sweeping every eighth costs at most seven more |
  | minimum TLAS capacity | 64, doubling | capacity is fixed at creation, so exceeding it means recreating |

- Hash the TLAS contents by **summing** per-instance hashes, not chaining them: a ray query reads
  nothing that depends on where an instance sits in the array, so the spatial index's iteration
  order must not read as a change. Seed with the instance count and put each per-instance hash
  through `hash_fmix32` before adding, or the sum degenerates into an additive collision. Hash
  exactly three fields per instance, in this order: **BLAS handle**, **8-bit instance mask**, **full
  transform** (nine basis components then three origin) — the mask because it is the only thing that
  catches a `layers` change with nothing moving; not the array index (it would defeat the order
  independence) and not the geometry flags or hit-SBT range (constant).
- Two things force a rebuild whatever the hash says: any BLAS built or refreshed this frame (a
  per-frame flag, set in both places), and a freshly created or resized TLAS. Keep the "has been
  built" flag distinct from the per-frame "may trace against it" flag — one outlives a frame, the
  other does not.
- **The expanded position buffer belongs to the entry, not to the build**, and only a compressed
  source has one. The entry holds the source buffer, its stride and the surface AABB so a skinned
  refresh can re-expand the new pose into the *same* allocation: the geometry description was fixed
  at creation and cannot be re-pointed. Free it on every path that drops an entry, ineligible ones
  included — it is allocated before the build is attempted.
- **Every "frame" here is an `update()` call, not a rendered frame.** The counter and both budgets
  reset at the top of that call, and the culler makes it once per non-probe camera render. Two
  viewports therefore build up to 64 structures each per rendered frame, sweep twice as often, cut
  the grace period to thirty rendered frames, and pay a TLAS rebuild each. Each camera still traces
  against a structure built for it moments earlier, so this costs rebuilds, not correctness.
- **A second entry ceiling lives here**, on the TLAS instance list rather than the gather:
  **65536**, a bare literal (`environment/rt_scene.cpp:662`), silent when hit, counting caster
  *surfaces* where the gather counts casters.

### 11. Drop the shadow maps

A raytraced light stops claiming an atlas quadrant and stops having a map rendered. Add
`Light3D.shadow_map_enabled` here. Mechanism: "Who is marked raytraced", "Three consumers that read
shadow-map state a raytraced light no longer has".

**Done when:** `GODOT_RT_DEBUG` prints `shadow_maps_rendered=0` alongside `raytraced=N`, and a
spotlight with a projector cookie still projects with no atlas quadrant.

**Decide in one place, before anything acts on it**, and make the culler ask exactly the question
the renderer will later ask itself. The fork's split decision — culler skipping on light
eligibility, renderer granting channels only when it would produce a mask — meant that under
multiview every omni and spot was skipped by the culler and then denied a channel, rendering with
**no shadow at all**; the same happened to any light past the 255 the mask can address. Split it in
two and keep the third part out of both:

- *candidate* (`light_instance_is_raytraced_shadow_candidate`) asks only about the light — shadows
  enabled, and omni or spot (area lights keep their maps), or directional plus the directional
  setting on plus a renderer that can trace at all;
- *can use* (`light_instance_can_use_raytraced_shadows`) adds that this renderer samples the mask
  and that the structure holds a build this frame may trace against;
- whether *this pass* has a mask belongs to the caller: the culler ANDs in that this is not a probe
  render and that the mask is available for these render buffers.

None depends on anything that changes during a pass, which is what lets the culler, the atlas layout
and the light buffer visit lights in three different orders and still agree.

| Requirement | Why, and what a miss looks like |
| --- | --- |
| The culler decides the pass's raytraced lights itself, **directional first**, counting as it goes | directional lights are not in the culled positional list, having no bounds. The culler therefore enforces the 255-light ceiling, which is load bearing twice: it stops a light being skipped by the culler and then denied a channel, and it lets the slot allocator evict the least recently seen slot knowing the victim cannot be a light in this pass |
| **Skipping the shadow-map render must not skip `light_instance_set_shadow_transform`** — set the transforms for every cascade, skip only the render list merge | that per-cascade call hands the light instance a cascade's projection, transform, far plane and split distance, and those split distances are what `fade_from`/`fade_to` derive from, which the raytraced path reads |
| Keep `shadow_opacity` (multiplies the traced visibility read from the mask) and `shadow_map_opacity` (what the effects sampling cascades multiply by) strictly distinct | the second doubles as the flag those effects test to know whether a map exists at all, so swapping them produces a scene that looks right until you add fog |
| `Light3D.shadow_map_enabled`, with a `RenderingServer` setter and a light-instance query beside it, buys a light its map back | both shadow loops test it in the same shape: skip the render when the light is raytraced **and** was not asked for a map anyway |
| Three consumers read shadow-map state a raytraced light no longer has | **subsurface transmittance** falls back to the material's own transmittance depth, gated on `shadow_map_opacity`; **volumetric fog** lights unshadowed until stage 16; **light projectors** get a fix rather than a fallback, below |

| Projector light | Matrix to rebuild on the raytraced branch |
| --- | --- |
| Omni | the light's transform relative to the camera, inverted, stored as a transform. The shader normalizes the result, so nothing but the rigid transform matters |
| Spot | that same modelview with a rebuilt cascade-zero projection in front of it: `bias * (depth_correction * projection) * modelview`, using upstream's own light-bias matrix (clip space into `[0,1]`) and its depth correction with z reversal only — no y flip, no z remap |

Build the spot's projection with a **vertical FOV of twice the spot angle in degrees**, **aspect
1**, **near `MIN(0.025, radius)`**, **far `radius`** (the light's range as the surrounding code
already floored it at 0.001) — the same four numbers the culler uses for that spot's cascade-zero
shadow transform. The FOV, the aspect and the bias matrix place the cookie; near and far live in the
z row, which nothing on this path reads, so getting them wrong is invisible until some later change
reads depth from this matrix. Take them from the map path anyway.

### 12. Directional casters

Bound the sun's caster set behind its own setting, and fix the cascade-slot fill. Mechanism: "Caster
volume".

**Done when:** with props every ten meters out to 400 m and a 100 m shadow distance, sweeps of
0.5x/1x/2x/4x gather 17/22/32/42 casters, each landing exactly where the geometry says (instrumented
run).

**The volume is the frustum box merged with a copy of itself swept toward the light.** Take the
projection's viewport half extents (the extents at the *near* plane). Far half extents are the same
for an orthogonal camera and `near_extents * (far_distance / MAX(z_near, 0.001))` for a perspective
one. That gives eight view-space corners, `(+-ex, +-ey, -z_near)` and `(+-ex, +-ey, -far_distance)`;
transform each by the camera transform, take the world AABB. Then copy the box, translate the copy
by `far_distance * caster_distance_scale` along the light basis's normalized **+Z** column — toward
the light, the opposite sense to the direction the light travels — and merge it back in. One volume
per directional light, one geometry-index query per volume.

Both halves are load bearing: the swept copy alone holds occluders and no receivers, the
untranslated box alone holds nothing not already on screen. **Sweeping the wrong way is the quiet
failure**, because it still gathers plenty — the volume fills with geometry down-sun of the visible
frustum, which cannot occlude anything, so the scene keeps its self-shadowing and loses every shadow
thrown in from off screen, reading as a lighting bug rather than a culling one.

| Requirement | Why, and what a miss looks like |
| --- | --- |
| **Iterate the scenario's own list of directional lights**, not the culled light list, skipping a sun that is invisible, outside the pass's visible layer mask or has shadows off — and all of them when the directional feature gate is off | directional lights are never in the culled list, because the engine reports an empty AABB for a light with no range. That gate is the same one that decides whether a sun may take its shadow from the mask, so a sun never gives up its map with nothing to trace |
| **Re-derive `far_distance` exactly as the engine's directional cascade setup does**: the main projection's `z_far`, clamped by the light's shadow max distance parameter only when that is `> 0` **and** the camera is not orthogonal, then `MAX(..., z_near + 0.001)` | a max distance of zero means "as far as the camera sees"; treating it as a literal zero collapses the volume to a millimeter and gathers nothing, silently. Getting the orthogonal test backwards fails the same way |
| **The ray's `tmax` comes from the same pair, and the light buffer must not re-derive it**: a directional row's `max_ray_length` is `radius * (1 + caster_distance_scale)`, where `radius` is the negation of the `fade_to` the cascade path just computed | recomputing `far_distance` in the light buffer would work today and drift the first time one input changes on one side only |
| **Multimesh and GridMap elements are gated for the sun separately, and the order matters**: each element's bounds are tested against every lamp volume first and unconditionally; only if that finds nothing is the directional volume consulted, and only when `scatter_casters` is not `Disabled` (`Near Camera` also requires the element bounds' **center** within `scatter_distance` of the camera; `Full Distance` admits it outright) | so `Disabled` means a raytraced sun casts no shadow from any multimesh or GridMap at all, easy to misread as a broken structure |
| **Lights whose bounds a directional volume already encloses are partitioned to the back of the query list, not dropped** — partition with a swap and query only the prefix | the per-instance pass counter throws every duplicate away at the leaf, so skipping the query changes which casters are gathered not at all, and it is the common case (a sun's volume swallows every lamp in an interior or a street). Stage 8's per-element test asks a **different** question of the same array and iterates it whole, so erasing the enclosed entries loses exactly the elements those lamps were the only reason to include |

**Filling unused cascade slots from the last real one is a prerequisite for stage 14, not a
tidy-up.** The cascade ladders end in a branch that reads slot 3; with fewer cascades that slot
holds a default-constructed `ShadowTransform` — identity projection, zero far plane, zero split.
Surface shading and fog hide it because the distance fade bleaches the result at that depth, but
**subsurface transmittance has no fade**: it scales both its sampled depth and its own by slot 3's
far plane, so zero far plane means zero thickness means full light through a solid object. The zero
in `shadow_split_offsets.w` is also the denominator of the last PCF blur factor,
`shadow_split_offsets.x / shadow_split_offsets.w` — a division by zero for every fragment past the
last real split, blend splits on or off. GLES3 already clamps the source index for the split offsets
alone; extend it to the matrix, ranges, biases, uv scales and atlas rect.

### 13. Directional trace

The sun takes a slot in the same mask and competes for a pixel's four channels on the same terms as
every lamp, reusing the 64-byte light record with four fields reinterpreted. Mechanism: "Record
reinterpretation and the two fades", "Forward pass: three blocks where upstream has one".

**Done when:** pillars of increasing height give a 10–90% shadow edge width of 0/3/6 px against the
cascade map's uniform 0/1/1 — the traced sun's penumbra grows with the gap it crosses.

**The forward directional loop becomes three blocks where upstream has one.** Upstream wraps the
cascade chain, the lightmap shadowmask handling, the distance fade and the vertex-lighting apply in
a single `if (shadow_opacity > 0.001)`. Split it in three, keeping that `0.001` everywhere:

| Block | Condition | Body |
| --- | --- | --- |
| mask | `rt_slot < RT_SLOT_NONE && RT_MASK_ANSWERS_HERE` | set `rt_shadowed = true`; then, only if `shadow_opacity > 0.001`, sample the mask. Hand over RAW visibility — do NOT fade it here |
| cascades | `!rt_shadowed && shadow_map_opacity > 0.001` | upstream's chain unchanged, with the `#undef` of the loop's own per-cascade bias macro (`BIAS_FUNC`) moved inside it |
| tail | `rt_shadowed \|\| shadow_opacity > 0.001` | the lightmap shadowmask branches, the fade, the vertex-lighting apply |

`RT_SLOT_NONE` is `255.0` and the slot is a float in the light record, so that is a float compare.
`RT_MASK_ANSWERS_HERE` is the stage 15 macro, constant-`true` wherever the material writes pre-pass
depth.

| Requirement | Why, and what a miss looks like |
| --- | --- |
| **The mask arm hands over raw visibility; applying `shadow_opacity` there is a bug** | the second directional loop already applies it, unconditionally, to whatever byte the first loop packed. This fork shipped the extra `mix()` for months: invisible at the default opacity of 1.0 because `mix(1, s, 1)` is `s`, and wrong at every value below — the light a shadowed pixel loses goes as opacity **squared**. Two consumers between the lookup and the pack want the raw value for the same reason: the screen space contact shadow is combined with `min()`, and the lightmap shadowmask crossfade blends against a raw `shadowmask`. Regression test and exponents: `docs/VALIDATION.md`. Omni and spot keep their own `mix()` and must not be changed to match — they compute and consume the value inside one function, with no pack and unpack |
| **The mask arm is chosen on the slot alone, never on `shadow_opacity`** | `rt_shadowed` means "the mask is this light's answer here", not "the mask shadowed this fragment". A sun holding a slot with `shadow_opacity` at zero sets the flag, leaves `shadow` at 1.0 and skips the cascade block — which is what zero opacity means; fold the opacity test into the flag and that light goes down the cascade path to sample an atlas rect it does not own. The tail's gate is `shadow_opacity` and not `shadow_map_opacity` for the mirror-image reason: a raytraced sun has `shadow_map_opacity` of zero unless asked to keep a map, and the tail still has to run for it |
| **The fade is hoisted out of the cascade block, but only two of its three arms are shared.** The plain arm's `mix(shadow, 1.0, smoothstep(...))` **must be wrapped in `if (!rt_shadowed)`** | the trace already applied it, and what has to stay continuous is the mask, which the denoiser filters and reprojects. The two lightmap arms (REPLACE and OVERLAY) keep their `smoothstep(fade_from, fade_to, vertex.z)` unguarded and run for both paths, because both end at the baked `shadowmask` and the trace knows nothing about a shadowmask — a **known defect, reproduced deliberately** so a port matches the shipped engine: under a raytraced sun they fade the dynamic term a second time and a lightmapped surface mid-window reads lighter than the cascade path does. Confined to the fade window, reachable only with `USE_LIGHTMAP` plus a shadowmask plus a raytraced sun. If you fix it, guard both arms' dynamic term the way the plain arm is guarded, and fix it in the engine rather than only in the port |
| **Everything the culler did not gather has to be faded out inside the trace, keyed on view depth**: the light-selection pass drops a directional light whose `radius` is less than the fragment's view depth, and inside the window the trace multiplies its answer toward fully lit by `smoothstep(fade_from, max(radius, fade_from + 0.0001), view_depth)`, skipping the rays once that reaches 1.0 | the trace treats every non-sky pixel as a receiver, but casters were gathered only as far as the shadow distance, so a surface past it traces an empty region and comes back confidently **lit** — a hard seam across the landscape at exactly the shadow distance. Both tests read the same last-cascade split offset the cascade fade reads, so they cannot drift. The `+ 0.0001` guards equal smoothstep edges; the CPU side's guard is clamping the fade-start fraction to 0.999 |
| **Softness follows the `softshadow_angle` convention so both paths agree at the default `softness_scale`** — the trace carries the same tangent of the angular radius, scaled only by that setting | a nonzero angular distance also puts the **cascade** path onto its PCSS branch and widens every cascade's extents, visible in projects that never enable raytracing |

### 14. Directional demotion

Cut the sun's remaining shadow map down to what still reads it, as two settings rather than
constants. Only safe on top of stage 12's cascade-slot fill. Mechanism: "Demotion".

**Done when:** instrumented, a raytraced sun allocates the directional atlas **zero** times where a
non-raytraced scene allocates it once — 2 MiB at the demoted size, 32 MiB at Godot's default.

- **Both readings of the shadow mode must move together.** `update_light_buffers` read
  `light->directional_shadow_mode` *directly* rather than through the accessor, so overriding the
  accessor alone leaves the culler emitting two cascades while the buffer still computes `limit ==
  3` — split offsets of `(s0, s1, 0, 0)`, a `fade_to` of negative zero, a smoothstep with equal
  edges.
- Leave the authored shadow mode untouched on the `Light` so it still round-trips through the
  editor; only what the renderer asks for changes. Keep `requested_size` separately so the full size
  comes back if raytracing goes away.

### 15. Alpha-pass correctness

Stop an alpha-blended fragment reading the mask at its own pixel and wearing the visibility of the
opaque surface behind it. Mechanism: "The alpha pass".

**Done when:** a horizontal sheet of glass above a floor in full shade goes from mean luminance 31.6
to 180.3, and every opaque test scene renders identically.

- "Am I in the alpha pass" is not quite the question. Alpha-to-coverage and `depth_prepass_alpha`
  materials are drawn in the transparent list but **do** write pre-pass depth, so the mask describes
  them correctly — known at compile time (`USE_OPAQUE_PREPASS` / `ALPHA_ANTIALIASING_EDGE_USED`) and
  must skip the runtime test entirely. Alpha scissor and alpha hash go through the pre-pass like
  anything opaque and were never affected.
- The runtime half is a scene-data flag, not a shader variant: a bool on `RenderSceneDataRD` set
  true only across the transparent pass's own scene-data setup call — the one that builds that
  pass's uniform buffer, before the list is drawn — and cleared immediately, so only that buffer
  carries the bit. Packed as `SCENE_DATA_FLAGS_IN_ALPHA_PASS`, mirrored in `scene_data_inc.glsl`.
  The shader wraps both halves in one macro (`RT_MASK_ANSWERS_HERE`) so each mask read is a single
  condition and the compile-time exemptions collapse it to a constant `true`. The fallback guards
  move from `shadow_opacity` to `shadow_map_opacity` at the same time.
- **Demonstrating this needs a horizontal pane.** A vertical one edge-on to the sun receives almost
  no direct light, the shadow term is multiplied by nearly nothing, and the bug is invisible — three
  test scenes each looked like evidence the fix did nothing.

### 16. Fog: the zero-cost variant pattern

Volumetric fog traces its own directional shadow ray per froxel. **Also the reusable pattern for
adding a ray-query variant to an existing shader at no cost to projects that never use it** — the
deferred subsurface-transmittance work should use it, with the structure declared inside `#ifdef
LIGHT_TRANSMITTANCE_USED`. Mechanism: "Fog".

**Done when:** on a row of slats lit from behind, the fog's luminance at the darkest point of the
shadow reads 74.9 against the shadow-mapped render's 75.4 (183.8 with the shafts missing).

All five parts of the pattern are required:

1. Give the raytracing variants a `ShaderRD` **group of their own**.
2. **Do not create their pipelines at init** — skip those indices in the loop, because
   `version_get_shader` on a disabled group returns a placeholder.
3. `enable_group()` **lazily**, the first frame something needs them.
4. Put the acceleration structure in a **uniform set of its own** that only those variants declare,
   so every other variant's uniform set is byte-for-byte unchanged.
5. Guard the `#extension` and the `accelerationStructureEXT` declaration behind the variant's own
   define, so non-tracing variants emit SPIR-V requesting no raytracing capability.

Other pitfalls:

| Requirement | Why, and what a miss looks like |
| --- | --- |
| The froxel's view-space position needs the camera translation, not just `cam_rotation` — hence `cam_position` in the params UBO and the mirrored `vec4` in the std140 block **at the identical position** | `cam_rotation` only rotates and the structure is world space. Half-applying this garbles `cam_rotation`, `to_prev_view` and `radiance_inverse_xform` |
| Spread the sun's angular size across **frames**: offset the ray within the cone by the same `halton_map[temporal_frame]` value that already jitters the froxel position, under the same reprojection guard | one ray per froxel is the whole budget, and this keeps it a global jitter rather than per-froxel noise |
| Leave the TLAS null unless a directional light actually took a slot | a froxel has no pixel in the mask, so positional lights get no ray and a raytraced lamp lights the fog unshadowed |

### 17. Docs, defaults and CI

Small, but three separate CI rounds were burned on it the first time.

**Done when:** `godot --headless --doctool .` produces no diff and the style hooks pass.

| Requirement | Why, and what a miss looks like |
| --- | --- |
| **`--doctool` emits `ProjectSettings` members sorted by name** — apply its output verbatim | hand-placing new entries beside related ones fails the class-reference check. Changed node defaults propagate into the XML whether or not you edit it, because doctool computes the attribute from the real registered default |
| A new top-level directory needs a `CODEOWNERS` rule | one that nothing matches fails `validate-codeowners --unowned`, and that gates every platform build |
| Run the hooks over the whole **range** before pushing (`CLAUDE.md`) | `codespell` rewrites British spellings in prose *and* in shader comments, and its write-changes mode makes the hook exit non-zero |
| CI here is Windows-only | what that dropped, and what the surviving job still runs, is in `docs/VALIDATION.md`. Check before claiming a check is gone |
| Running a hook script by hand, **filter the file list the way the hook config does** | they are fixers, not linters: handing `copyright_headers.py` an unfiltered list prepends C-style banners to XML files, and the mess looks exactly like a second and third CI failure. `file` reporting a `.xml` as "C source" is the giveaway |

### 18. Ground truth ambient occlusion

Independent of everything above — no raytracing, portable on its own or omissible. Five new files
plus about a dozen small hooks: a depth prefilter, a gather, two denoise passes and an upsample,
writing the same occlusion buffer the legacy estimator writes.

**The estimator's arithmetic is exact and belongs to the fork**, and a rebuild that reproduces its
shape but guesses at its constants is wrong in ways that read as the effect working. It is set out
dispatch by dispatch in **`docs/internals/ambient-occlusion.md`** — shared reconstruction terms, the
pyramid's farthest-biased reduction, the slice basis, the uniform march spacing, the sector weight
with its `|sin t|` Jacobian, the open/total ratio resolve, the strength curve. Port from that, not
from Jimenez et al (2016) or Therrien et al (2023), which `gtao_gather.glsl` cites for the slice
geometry and the visibility bitmask respectively.

**Done when:** `docs/validation/ao_validation/run.sh room gtao` scores against both CPU-traced
references within the bounds `docs/validation/ao_validation/README.md` states. There is no cheaper
gate, because every defect below reads as the effect working.

**Six load-bearing details, every one wrong before it was measured.** Each is a steady bias:

| # | Detail | Why |
| --- | --- | --- |
| 1 | **Reconstruct each march sample at the center of the texel its depth came from**, not at the position the step asked for | the pyramid is sampled **nearest** |
| 2 | **The `\|sin t\|` Jacobian in the per-sector weight** | a sector's worth is the integral of `cos(t - n) * \|sin t\|` across it, not its share of the arc. Weighting by angular width counted the two sectors either side of the normal about ten times too heavily — wrong everywhere anything is occluded, does not average out, does not shrink with more samples |
| 3 | **The strength curve scales occlusion as a ratio**, not a subtraction | subtracting a multiple of the distance from white has a hard floor and clips a third of the tonal range to black inside the gather, where no filter can recover it |
| 4 | **The checkerboard is the shipped shading rate whenever `half_size` is on**; the quarter-resolution grid is the fallback rung | a port reproducing only the grid ships a renderer whose default occlusion path does not exist. It packs pixel `(2u + (y & 1), y)` into gather texel `(u, y)`, so the gather is half width and **full height**. Load bearing: at an odd width the last texel of an odd row is clamped and no full-resolution pixel maps back to it, so the upsample never reads it — but the horizontal denoise walks the gather's own grid and does, so it must still be written |
| 5 | **The half-resolution stride is passed in a push constant** | `gather_size_for` rounds up and integer division rounds down, so recovering it in the shader gives 2 at every even width and 1 at every odd one, and at an odd width the gather then answers only for the top-left quadrant. Do not "fix" it by rounding the gather size down; that drops the last column at widths like 1281 |
| 6 | **The upsample inverts the gather's sampling position as `pos / stride`** (quarter-resolution grid only; the checkerboard branches and never reads the stride) | the obvious `(pos + 0.5) * scale - 0.5` assumes the gather texel represents the center of its block and is wrong by half a full-resolution pixel on each axis |

Three more rules:

| Rule | Why |
| --- | --- |
| **Anchor the distance-scaled radius to screen HEIGHT** | `uv_to_view_mul.x` is `2 * tan(fovy/2) * aspect` and a camera holds the *vertical* field fixed, so anchoring a screen-space fraction to width makes the effect reach 1.8x further on a 16:9 viewport than on a square one. The fixed-world-radius branch is already aspect invariant; leave it alone |
| **The gather and both filter passes must reconstruct view positions identically** | the filter judges a gather texel by plane-fitting the point that texel claims to describe, so a half-pixel disagreement makes it reject the gather's own samples along every slope |
| Watch the prefilter's mip bounds | levels 3 and 4 are where an off-by-one hides until the render size stops dividing evenly (`docs/internals/ambient-occlusion.md`, "The mip-bound trap"; `CLAUDE.md` for the size that exposed it) |

**Two silent gaps a port inherits unless it closes them.** `_use_gtao` answers false above one view,
so a stereo or XR pair keeps the legacy estimator with no warning. And **orthographic projection is
wrong in three separate places** — two in `gtao_gather.glsl`, one in `gtao_filter.glsl`, whose push
constant carries no orthographic flag at all. Fix all three or gate on it; the prefilter's
linearization and the gather's UV-to-view already handle it. Which three and what each gets wrong:
`docs/features/ambient-occlusion.md`, "Limits and surprises".

### 19. Screen space contact shadow for the sun

A contact shadow for one `DirectionalLight3D`, marched over the depth pre-pass buffer, for geometry
deliberately absent from the acceleration structure. Independent of stages 2–14: no ray query, no
TLAS, no light slot, and it works with raytraced shadows off. It does need a depth pre-pass, which
is why it forces one. **Mechanism, and every rule below in full:
`docs/internals/screen-space-shadows.md`** — this stage is the order, the files and the traps that
bite during a port.

**Files:** the complete list, with line numbers, is `docs/internals/screen-space-shadows.md`, "Code
map". Four things about it belong to the port rather than to the code:
`thirdparty/bend_sss/bend_sss_cpu.h` and `LICENSE.txt` are vendored with no changes but the line
endings and trailing whitespace this repository normalizes, and being header-only they take no
`SCsub` entry but do need an entry in `thirdparty/README.md` and one in `COPYRIGHT.txt` covering the
ported shader as well (both paths under one `Files:` stanza);
`shaders/effects/screen_space_shadow.glsl` is picked up by the `Glob("*.glsl")` in
`shaders/effects/SCsub`, so nothing registers it; `~RendererSceneRenderRD` must `memdelete` the
effect; and `doc/classes/ProjectSettings.xml` is regenerated, not hand-edited (stage 17).

**Done when:** `docs/validation/shadow_validation/run.sh field_thin` reproduces the published
`hardness` 1 and `hardness` 0 ratios for 15,000 grass blades at `cast_shadow = Off` under a 26
degree sun, scored in linear light against the same field put back into the structure
(`docs/HISTORY.md`; `run.sh field` and `run.sh probe` have their own targets in that directory's
README). Run with `--verbose`: **no pixel of any variant may be lighter than the frame with the pass
off** — the check that the composition can only darken.

**Where it plugs in:**

| Seam | Requirement, and what a miss does |
| --- | --- |
| **One predicate answers for the whole feature and is asked twice per frame.** `_using_screen_space_shadows` is consulted in `_render_scene` to build `force_depth_pre_pass`, and in `_pre_opaque_render` to decide what `update_light_buffers` is told and whether `_render_screen_space_shadows` runs | the first site is reached before the light buffers exist, so **it must not consult the light**: project setting, reflection probe, render buffers, view count, projection, whether the effect could be built, nothing else. Give it a term only the second site can evaluate — "is there a shadow casting sun" — and the two disagree, the pre-pass is not forced, and the march reads a depth buffer never written this frame. The honest version costs a forced pre-pass for a scene that turns out to have no sun |
| **Enabling it forces the depth pre-pass on and forces its MSAA resolve.** Exactly two variables in `_render_scene`, both already carrying a raytraced term: `force_depth_pre_pass` (`scene_state.used_opaque_stencil \|\| is_raytracing_scene_available() \|\| using_screen_space_shadows`) and, inside the `if (depth_pre_pass)` block, `finish_depth`, whose `else if (finish_depth)` branch calls `resolve_effects->resolve_depth` into `rb->get_depth_texture()` | miss the first and the setting does nothing in a project that has not turned the pre-pass on by hand; miss the second and the feature works with MSAA off and produces nothing, or last frame's shadows, with MSAA on — reading as an MSAA bug. This is the one feature that forces both with raytracing off, so neither term folds into `is_raytracing_scene_available()` |
| **The pass runs from `_pre_opaque_render`, after `update_light_buffers`, beside the raytraced block rather than inside it.** The site is `if (rb_data.is_valid() && using_screen_space_shadows)`, deliberately not gated on `is_raytracing_scene_available()` | `_render_screen_space_shadows` reads `LightStorage::get_sss_light()`, which `update_light_buffers` fills a few lines above; call it earlier and `light.valid` is always false and the mask is never written |
| **`update_light_buffers` gains two parameters, and the mobile renderer calls it too**: `..., bool p_using_shadows, bool p_use_raytraced_shadows, bool p_use_screen_space_shadows, ...`; `RenderForwardMobile::_render_scene` passes `false, false` for the last two | forget that call site and the build fails; insert in the wrong position and `using_shadows` lands in the raytraced slot |
| **`DirectionalLightData` gains a whole `vec4`, not a spare float**: `sss_strength` plus three more slots, after `volumetric_fog_energy` and before `shadow_bias` | the fields ahead of it sum to exactly 80 bytes, so `sss_strength` opens a fresh 16-byte slot and the rest close it: the `vec4` array that follows needs its alignment, and one bare float shifts every shadow matrix in the struct by four bytes on one side only. Two of the three are claimed (`uint rt_caster_mask`, `float rt_softshadow_angle`, both for the fog's sun ray), leaving `pad_sss0`. **Anything added here must be written UNCONDITIONALLY**, beside the field it derives from rather than inside a branch: the array is persistent and indexed by light count, so a field written only on some frames holds whichever light last occupied that index on the others. `light_data_inc.glsl` is included by `forward_clustered/scene_forward_clustered_inc.glsl`, `forward_mobile/scene_forward_mobile_inc.glsl`, `environment/volumetric_fog.glsl` and `environment/volumetric_fog_process.glsl` |
| **`sss_strength` is also the name of Godot's own subsurface scattering local** in `scene_forward_clustered.glsl` and `scene_forward_mobile.glsl`, and appears in `material.cpp`, `shader_types.cpp` and the GLES3 shaders for that reason | grepping it returns mostly false hits; the ones that matter are qualified, `directional_lights.data[i].sss_strength` |

**The invariant that keeps the sun lit.** A light is marked with `sss_strength` **only when a mask
is genuinely written for it that pass** (`LightStorage::update_light_buffers`, `sss_available =
p_using_shadows && p_use_screen_space_shadows`; the first directional light with `light->shadow` and
non-zero `shadow_opacity` takes it). Marking a light whose mask never arrives is not a missing
shadow but a **black** one: binding 39 falls back to the 4x4 `DEFAULT_RD_TEXTURE_WHITE` and
`sss_shadow_lookup` `texelFetch`es at `gl_FragCoord`, which past the fourth pixel is an out-of-range
fetch returning zero — fully shadowed. Keep the lookup's `textureSize` guard returning 1.0, and keep
the invariant that makes it unreachable. A pass with no light selected does not run at all rather
than running and multiplying by zero; the mask then keeps whatever it last held, harmless precisely
because no light is marked to read it, and the pre-pass is still forced because the predicate cannot
see the light.

**Four conventions, each failing silently and differently.** All four are set out in
`docs/internals/screen-space-shadows.md`, "Coordinate conventions the port inverts"; a port that
gets one wrong still renders shadows, so check them with `debug_view` rather than by eye:

| Convention | Get it wrong and |
| --- | --- |
| The direction is **view space** and comes from the light basis's **+Z** (toward the light, where omni and spot store `-Z`), passed through with **no negation** | shadows radiate away from the sun, reading as a lighting setup rather than a bug |
| The projection is `scene_data->get_cam_projection()` — corrected and **jittered**, not the raw `cam_projection` member | the light's screen position moves up to half a pixel per frame and the whole shadow field crawls |
| Clip Y is negated on the way in (`-light_clip.y` in `ScreenSpaceShadows::render`), because `Projection::set_depth_correction` already sets `m[5] = -1` where Bend's builder applies D3D's `* -0.5 + 0.5` | the sun lands at its own vertical mirror; a high sun reads as a low one |
| `ivec2(gl_WorkGroupID.yz) * WAVE_SIZE + params.wave_offset` — the cast to signed **before** the add, since `WaveOffset_Shader` is routinely negative | the two quadrants left of and above the light wrap to garbage; the two below and right staying correct is the tell |

**Targets, build and dispatch:**

| Requirement | Why, and what a miss looks like |
| --- | --- |
| `_ensure_screen_space_shadow_mask` creates `RB_SCOPE_SCREEN_SPACE_SHADOWS` / `RB_TEX_SCREEN_SPACE_SHADOW_MASK`, `R8_UNORM` at the render buffer's **internal** size, one layer, usage `SAMPLING \| STORAGE \| CAN_COPY_TO \| CAN_COPY_FROM`; `is_target_format_supported()` queries the first three | `CAN_COPY_TO` is what the two `texture_clear` calls need — a storage-only texture fails the clear, not the dispatch. Cleared **white** on creation, because white is fully lit and an uncleared mask is a screen of arbitrary darkness on the frame the buffers are reconfigured. Keep this clear **and** the one inside `render()`: they cover different frames |
| **The output is cleared to white ahead of every *remaining* early return in `render()`** | two returns precede the clear (invalid effect or a null depth/output texture, and a non-positive size); everything after it clears first — the degenerate direction, and an empty dispatch list. A frame that bails out after the clear must not leave the previous frame's shadows standing while the light is already marked with a strength |
| **The effect is built on first use and its failure is sticky**: `get_screen_space_shadows` sets `screen_space_shadows_unavailable = true` before constructing and clears it only on success | so a device that cannot run the pass is not retried every frame. Four constructor failures, each with its own message: `R8_UNORM` not usable as a storage image (not in Vulkan's guaranteed set without `shaderStorageImageExtendedFormats`), a shader variant that will not compile (the subgroup vote is the likely cause), pipeline creation, the border sampler. Lazily rather than in the constructor because the feature is off by default and compiles three variants. `~ScreenSpaceShadows` frees `depth_sampler` and `shader_version` |
| **One compiled variant per quality tier; the sample count cannot be a uniform** — the tiers are version defines (32/60/96 samples, 5/8/12 faded out, `HARD_SHADOW_SAMPLES` at Bend's 4 in every tier) | the loops are unrolled and the shared array is sized from it (`READ_COUNT = SAMPLE_COUNT / WAVE_SIZE + 2`). `WAVE_SIZE` is 64 and is the shader's `local_size_x`, a **workgroup** size and not a hardware wave size — which is what the `lds_early_out` path's two `memoryBarrierShared(); barrier();` pairs exist for. Reduce it to `gl_SubgroupSize` and the wavefront geometry no longer matches what the CPU builder laid out |
| **Push constant: 76 bytes**, `static_assert`ed; field order under Reference values. `wave_offset` is the only field that changes between dispatches | a C++/GLSL mismatch is rejected and the dispatch refused only under `DEBUG_ENABLED`, so the mask keeps its white clear and **the feature reads as "the setting does nothing"** — and no shipped configuration has that flag on (`CLAUDE.md`) |
| **The dispatch loop.** `BuildDispatchList` takes the negated-Y clip vector, the viewport size and full-screen **inclusive** bounds (`{0, 0}` to `{p_size.x - 1, p_size.y - 1}`), at most 8 dispatches. One `compute_list_begin()` / `compute_list_end()` around the whole loop with one pipeline and one uniform set bind outside it; each iteration sets `wave_offset` and dispatches `dispatch.WaveCount[0..2]` — **`compute_list_dispatch`, not `compute_list_dispatch_threads`** | a directional light has no on-screen volume to bound, and bounding it would cost dispatches without saving any, because the shader reads and writes up to `2 * WAVE_SIZE` pixels outside whatever it is given. `WaveCount[0]` is `inWaveSize` workgroups, which is how the wavefronts step along their rays; dividing it by the local size runs a sixty-fourth of the work and produces a thin wedge of shadow near the light and nothing else. The dispatches write disjoint pixels and read only the depth buffer, so they need no barrier between them — one compute list per dispatch puts those back |
| **The depth sampler is point-filtered on all three filters and clamped to a transparent black border, not to the edge** | the march reads off screen on purpose and those reads must come back as "nothing here"; under reverse-Z, red reading back as 0.0 is the far plane, which is exactly that. `SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE` smears the border texel outward and **produces shadows that stream in from the sides of the screen** |
| **Reverse-Z is expressed entirely in two push constant fields**, `far_depth_value = 0.0` and `near_depth_value = 1.0`, from which the shader derives its `z_sign`; `depth_bounds` is `(0, 1)` | nothing else in the port assumes a direction, and those bounds are what make the early-out cull the sky. Bend's suggestion to also skip pixels an existing shadow pass already found occluded is deliberately not taken: this pass has to work with raytraced shadows off |
| **`surface_thickness` is floored at `1e-6` in the driver**, not only ranged in the setting (the range starts at 0.0001) | it is the divisor in the shader's `depth_scale`, so a zero is a divide-by-zero across the whole frame. The floor guards `ProjectSettings.set_setting()`, which the range does not constrain |
| **Which renders decline, and which warn**, in order: the project setting off (silent); a reflection probe render or absent render buffers (silent); `rb->get_view_count() > 1` (**warns once**); an orthographic camera (**warns once**); an effect that could not be built | **orthographic must decline, not be patched** — `Projection::set_orthogonal` leaves `columns[2][3]` at 0, so a direction vector comes out with `w` exactly zero and forcing the sign fixes only half of it. This is why the editor's Top/Front/Side views show no contact shadow. Why each one declines: `docs/internals/screen-space-shadows.md` |

**Composition and tuning:**

| Requirement | Why, and what a miss looks like |
| --- | --- |
| **`hardness` is the fork's own control and is not part of Bend's technique**, so it will not be in any upstream sample you diff against. The combination is `mix(dot(shadow_value, vec4(0.25)), min(min(x, y), min(z, w)), hardness)` followed by `min(hard_shadow, result)` — `0.0` is Bend's behavior exactly, the default `1.0` takes the darkest of the four, three `min()` for the whole march | Bend average their four accumulators, which needs four samples' worth of agreement before a pixel is fully shadowed; a grass blade narrower than the march's one-pixel spacing **is** a one-sample occluder. Measured ratios: `docs/HISTORY.md` |
| **The composition is `min()` and not a multiply.** It goes in `scene_forward_clustered.glsl` immediately after the `} // shadows` brace closing both the mask path and the cascade path and **before** the `if (rt_shadowed \|\| shadow_opacity > 0.001)` tail | an occluder both in the acceleration structure and on screen is described by both terms and multiplying darkens it twice (stage 20 argues that case in full). After the tail, a baked shadowmask's replace/overlay branch overwrites it and the `USE_VERTEX_LIGHTING` apply never sees it. The exact block, including the `sun_fade` term the raytraced path needs, is in `docs/internals/screen-space-shadows.md`, "Composition in the forward shader" — copy it from there rather than reconstructing it |
| **`sss_shadow_lookup()` goes in `scene_forward_lights_inc.glsl`, inside the `#ifndef USING_MOBILE_RENDERER` block**, for the same reason as `rt_shadow_lookup()` in stage 4. The mask is stored **linearly**, unlike the raytraced mask's square root | this is a contact term whose interesting range is the whole of zero to one rather than a visibility that is mostly one, so the sqrt trick would spend its eight bits in the wrong place. Squaring it here silently lightens every contact shadow |
| **Binding 39 in `RENDER_PASS_UNIFORM_SET`**, after stage 4's 37 and 38: `texture2D sss_shadow_mask`, declared **inside the `#else` half of `scene_forward_clustered_inc.glsl`'s `#ifdef MODE_RENDER_SDF`**, not at file scope. Plain 2D in every variant, multiview included, because the pass is single view | at file scope the SDF variant declares a binding it has no uniform for. Added on **every** path through `_setup_render_pass_uniform_set` defaulting to `DEFAULT_RD_TEXTURE_WHITE` — a path that skips it fails uniform set validation for the whole pass |
| **`#include <thirdparty/bend_sss/bend_sss_cpu.h>` — angle brackets, after the engine includes** | `validate-includes` and `clang-format` want different things here and are satisfied only by meeting both conventions at once |
| **`debug_view` is how to bring the pass up during the port**, and every mode must suppress the early-out or the view is blank exactly where a wave votes to leave | **Wave Index** (`fract(float(gl_WorkGroupID.x) / float(WAVE_SIZE))`) first: the pattern must fan out from the sun's screen position and track it as the camera turns, and if it converges on the wrong point one of the four conventions above is wrong and nothing else is worth tuning. **Thread Index** separates a light-coordinate error from a wave-offset error; **Edge Mask** is for `bilinear_threshold` (`docs/features/screen-space-shadows.md`) |
| **The settings are all live**, `enabled` included: `GLOBAL_DEF_BASIC`, **not** restart-required and it must not be marked so | it is read through `GLOBAL_GET_CACHED` every frame with the effect built lazily. `enabled` is read in `_using_screen_space_shadows`, the rest in `_render_screen_space_shadows`. Bend's `contrast` and this fork's own `strength` were settings and are now constants (4.0 and 1.0) — both measured to have exactly one correct value, and `strength`'s zero doubled as an undocumented off switch. Run `godot --headless --doctool .` and commit the result per stage 17: nine new `ProjectSettings` members, sorted by name by the tool |

**Two invariants that make this stage independently portable.** A port may stop here:

- Stage 20 adds **no push constant field and changes no offset** — it spends two spare bits of the
  existing `flags` word (`FLAG_RESTRICT_CASTERS`, `FLAG_DEBUG_CASTER_MASK`) and one new descriptor
  binding. The 76 bytes above are final either way.
- Before stage 20 the shader's `may_cast[i]` is uniformly true and **every opaque surface casts** —
  the configuration `surface_thickness` and `hardness` were calibrated in.

### 20. Restricting what casts a screen space shadow

Make only geometry the acceleration structure will **not** hold cast a screen space contact shadow,
by writing one byte per pixel during the depth pre-pass and consulting it at the march's caster
reads. **Mechanism, and each seam below with its failure in full:
`docs/internals/screen-space-shadows.md`, "Restricting what casts"** and its five subsections.

**Files:** `docs/internals/screen-space-shadows.md`, "Code map", names them all. The symbols this
stage adds, each of which the sections below place: `_casts_into_acceleration_structure()` and
`_is_screen_space_shadow_caster()`; `set_screen_space_shadow_caster()` on
`renderer_geometry_instance.{h,cpp}` and `dummy/rasterizer_scene_dummy.h`; `RB_TEX_SSS_CASTER`,
`ensure_sss_caster_texture()`, `DEPTH_FB_ROUGHNESS_SSS_CASTER`,
`PASS_MODE_DEPTH_NORMAL_ROUGHNESS_SSS_CASTER`, `INSTANCE_DATA_FLAG_SSS_CASTER` and
`_using_restricted_sss_casters()`;
`SHADER_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_AND_SSS_CASTER`, its `PipelineVersion` twin and
the renumbered `SHADER_VERSION_COLOR_PASS`; `MODE_RENDER_SSS_CASTER` and
`INSTANCE_FLAGS_SSS_CASTER`; the `p_caster_mask` parameter, `FLAG_RESTRICT_CASTERS`,
`FLAG_DEBUG_CASTER_MASK` and `DEBUG_VIEW_CASTER_MASK` on `effects/screen_space_shadows.{h,cpp}` —
which also needs a new include of `storage_rd/texture_storage.h` for the white default texture,
without which the file does not compile; and `caster_mask_texture` / `may_cast` in
`shaders/effects/screen_space_shadow.glsl`.

**Done when:** with a grass `MultiMesh` at `cast_shadow = Off` on a ground plane under a raytraced
sun, `restrict_casters` on and `debug_view = Caster Mask`, the grass reads white and the ground
black, and the run prints no null-pipeline errors from `ShaderData::_create_pipeline`. The rendered
frame difference is **not** the test — on the committed rigs the toggle moves one pixel
(`docs/features/screen-space-shadows.md`, "`restrict_casters`").

**Ships off** — `GLOBAL_DEF(".../restrict_casters", false)` — and a port must not flip it; the
calibration argument is in `docs/features/screen-space-shadows.md`.

**The predicate is a complement by construction, and must stay one.**
`_is_screen_space_shadow_caster()` (`renderer_scene_cull.cpp:158`) is
`!_casts_into_acceleration_structure()` (`:143`), and `CullRTCasters::operator()` calls that same
helper (`:3689`), so the two cannot disagree. They were once two hand-maintained copies; a port that
rebuilds them as copies reintroduces a drift whose damage is silent and one-directional — an
instance the structure rejects but the predicate misses casts *no* shadow at all once the
restriction is on, with no warning and nothing in `GODOT_RT_DEBUG`. The three instance-level tests
are `cast_shadows == SHADOW_CASTING_SETTING_OFF`, `base_type` neither `INSTANCE_MESH` nor
`INSTANCE_MULTIMESH`, and `InstanceGeometryData` null or `!geom->can_cast_shadows`. It is **instance
level on purpose**: not seeing `shadow_caster_surface_mask`, per-element multimesh culling, light
range or the BLAS budget can only **over-include**, which `min()` absorbs by construction, where
under-including loses a shadow outright.

**Three call sites, all required.** The flag is pushed at the instance, never polled:

| Call site | Why it is required |
| --- | --- |
| `instance_set_base()` (`:814`) | creation — miss it and a new instance carries the default until something else dirties it |
| `instance_geometry_set_cast_shadows_setting()` (`:1419`) | the runtime one — `GeometryInstance3D.cast_shadow = Off` on a grass field is how this is authored and must take effect in the same frame |
| `_update_dirty_instance()` (`:4837`) | must sit **outside** the `if (can_cast_shadows != geom->can_cast_shadows)` guard, because a material swap leaving `can_cast_shadows` alone can still be the first time this instance's flag is computed |

**Getting the flag to the GPU** — four seams, each silent:

| Seam | Requirement, and what a miss does |
| --- | --- |
| `set_screen_space_shadow_caster(bool)` | **Pure virtual** on `RenderGeometryInstance`. `RenderGeometryInstanceBase` implements it (Forward+, Mobile, GLES3 inherit); `GeometryInstanceDummy` derives `RenderGeometryInstance` directly and needs its own empty override or the dummy rasterizer fails to build as an abstract class, naming a class this stage otherwise never touches. |
| The base implementation must call `_mark_dirty()` | It writes `data->screen_space_shadow_caster`, which nothing reads until `_geometry_instance_update` rebuilds `base_flags`. Without the mark the value sits in `data` forever, `INSTANCE_DATA_FLAG_SSS_CASTER` is never set, the mask is zero everywhere, and with the setting on **the screen space shadow disappears from the whole frame** — it compiles, it runs, and it reads as the setting breaking the feature. |
| `INSTANCE_DATA_FLAG_SSS_CASTER = 1 << 0` | Bits 0 and 1 were free; the rest starts at `1 << 2`. Set in `_geometry_instance_update` **after** `ginstance->base_flags = 0`, in `base_flags` rather than the per-frame flags, so caster status costs no per-frame CPU work — the point, since this geometry left the structure precisely to stop paying one. |
| `INSTANCE_FLAGS_SSS_CASTER (1 << 0)` in `scene_forward_clustered_inc.glsl` | The two enums are matched only by a comment. |

**The pre-pass attachment and its variant** — every one silent:

| Seam | Requirement |
| --- | --- |
| `ensure_sss_caster_texture()` | `RB_TEX_SSS_CASTER` (`SNAME("sss_caster")`), `RD::DATA_FORMAT_R8_UNORM`, usage `SAMPLING \| COLOR_ATTACHMENT \| CAN_COPY_FROM`, internal size, **deliberately no MSAA twin**. `get_sss_caster()` beside it is an unused accessor a port can leave out. |
| `DEPTH_FB_ROUGHNESS_SSS_CASTER` in `get_depth_fb()` | Depth + normal/roughness + caster, selecting the MSAA normal/roughness twin as the other cases do. With no MSAA caster texture to pair with it, dropping the MSAA refusal below hands RD a framebuffer mixing sample counts, rejected outright: *"if an attachment is marked as multisample, all of them should be multisample and use the same number of samples."* |
| `PASS_MODE_DEPTH_NORMAL_ROUGHNESS_SSS_CASTER` — three additions | A `case` in `_render_list()` instantiating `_render_list_template<>` (its `default:` is a comment, so a missing case is a pre-pass that draws nothing, with no message); a `case` in `_render_list_template()` setting `pipeline_key.version`, with `ERR_FAIL_COND_MSG` on `view_count > 1`; and two `depth_pass_clear` entries in the `switch` on `depth_pass_mode`, one per color attachment — zero means "not a caster", so the sky and any pixel the pre-pass does not draw cannot cast. |
| `depth_pass_mode` chain order | `using_voxelgi` first and winning, the restricted branch next, **before** `is_raytracing_scene_available()`. Put it after and it is unreachable, the mask is never written, and the setting reads as doing nothing. The VoxelGI precedence is structural: `sss_caster_output_buffer` and `voxel_gi_buffer` are both `layout(location = 1)` under `MODE_RENDER_NORMAL_ROUGHNESS` and no variant defines both. |
| `PIPELINE_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_AND_SSS_CASTER`, before `PIPELINE_VERSION_COLOR_PASS` | That enum is hashed rather than packed, so its order is free, but it needs a `case` in `_get_shader_version()` **and** in `_create_pipeline()`'s blend state switch, sharing `blend_state_depth_normal_roughness_giprobe` — `create_disabled(2)`, two color attachments, which is what this pass has. Falling through to the one-attachment state fails pipeline creation against the render pass, silently, through the same null-pipeline path. |
| The fourth site, `_fill_render_list()`'s dynamic-instance condition | **Dead code kept for symmetry**; a port can skip it. Checkable: `_fill_render_list` has six call sites in `render_forward_clustered.cpp` and none passes a `PASS_MODE_DEPTH_NORMAL_ROUGHNESS*` mode — `PASS_MODE_COLOR` (`:2482`, the one filling `render_list[RENDER_LIST_OPAQUE]`, which the depth pre-pass reuses), `PASS_MODE_SHADOW` / `PASS_MODE_SHADOW_DP` (`:3537`, `:3631`), `PASS_MODE_DEPTH_MATERIAL` (`:3682`, `:3738`), `PASS_MODE_SDF` (`:3808`). Re-run that grep on the newer engine rather than trusting the line numbers. |

**The shader group, and the bug that reads as "the setting does nothing".** The variant is pushed
with group `SHADER_GROUP_ADVANCED` and `default_enabled` false, **last in the depth block** of
`SceneShaderForwardClustered::init()`, after the `base_define` the loop prepends:

    "\n#define MODE_RENDER_DEPTH\n#define MODE_RENDER_NORMAL_ROUGHNESS\n#define
    MODE_RENDER_SSS_CASTER\n"

A disabled group is **not** an error condition: `ShaderRD::_allocate_placeholders` fills every
variant of one with `RD::shader_create_placeholder()`, a valid RID with no stages, so every null
check downstream passes, `render_pipeline_create` fails, and the only message is the bare
`ERR_FAIL_COND(pipeline.is_null())`, which says nothing about shader groups. `pipeline_valid` stays
false, every surface is skipped: **the entire depth pre-pass draws nothing** and the march reads a
cleared depth buffer. The fix is one line in `_render_scene`, inside the same branch that selects
the pass mode — `scene_shader.enable_advanced_shader_group(p_render_data->scene_data->view_count >
1);` — there and not at init, which would compile the whole advanced set for every project.

**The variant numbering invariant.** `ShaderVersion`'s constants are not an enum, they are the
**indices at which `init()` pushes each `VariantDefine`**, and the depth block is pushed twice, once
per value of `ubershader`:

> `SHADER_VERSION_COLOR_PASS` must equal the number of depth variants pushed per iteration of the
> ubershader loop.

This variant made that ten, so `SHADER_VERSION_COLOR_PASS` went 9 → 10
(`scene_shader_forward_clustered.h:69`). Two things in `_get_shader_version()` depend on it:
`ubershader_base = SHADER_VERSION_COLOR_PASS`, and the color pass index `SHADER_VERSION_COLOR_PASS *
2 + shader_flags`. **A violation produces no error of any kind** — every index stays inside the
array (`VERTEX_INPUT_MASKS_SIZE` derives from the same constant and shrinks in step), the lookup
succeeds, and the wrong shader is bound: ubershader depth requests shift down one slot and color
pass indices down two, so the first two color passes get a `MODE_RENDER_DEPTH` shader bound for a
color draw. Push the new variant **last** in the depth block and bump the constant in the same edit.

**These pipelines are not precompiled**, and a port reproduces that knowingly or fixes it:
`GlobalPipelineData` has no bit for this pass mode, `_mesh_compile_pipelines_for_surface` no block
for the new pipeline version, and `_get_depth_framebuffer_format_for_pipeline` no parameter that
would produce this format (the VoxelGI one cannot stand in — an `R8_UNORM` second attachment is not
`R32UI`). Every material therefore compiles its pre-pass pipeline the first time it is drawn, the
ubershader retry with `p_wait_for_compilation` true, stalling the render thread: a hitch on first
sight of new geometry, and a large part of why the setting ships off.

**The march:**

| Requirement | Why, and what a miss looks like |
| --- | --- |
| `layout(set = 0, binding = 2) uniform sampler2D caster_mask_texture`, bound with the **same `depth_sampler`** the depth texture uses (nearest, `CLAMP_TO_BORDER`, transparent-black border) | deliberate: an off-screen mask read returns 0, "not a caster", agreeing with the off-screen depth read returning the far plane, "no occluder" |
| With no mask bound the uniform takes `DEFAULT_RD_TEXTURE_WHITE` and `FLAG_RESTRICT_CASTERS` is left clear, so `!has_flag(FLAG_RESTRICT_CASTERS) \|\|` short-circuits and no fetch happens | unlike the shadow mask the 4x4 default is safe at any size, the read being a normalized `textureLod` rather than a `texelFetch` |
| **Only the caster side is restricted.** `may_cast[i]` is fetched at the same coordinate as `depths.x`; `sampling_depth[]` and `depth_thickness_scale[]` describe the **receiver** and must keep coming from the full depth buffer | point either at the mask and `depth_thickness_scale` is zero on every non-caster pixel, dividing by zero in `depth_scale` and making `early_out_pixel()` reject every non-caster: grass self-shadows and the ground receives nothing |
| The restriction is one select at the shared-memory store, `depth_data` already encoding "cannot shadow" as `1e10`, the same sentinel the `i != 0` overshoot case writes: `depth_data[(i * WAVE_SIZE) + int(gl_LocalInvocationID.x)] = may_cast[i] ? stored_depth : 1e10;` | so nothing new crosses the barrier and the wavefront layout is unchanged |
| `FLAG_RESTRICT_CASTERS = 1 << 7` and `FLAG_DEBUG_CASTER_MASK = 1 << 8` must match `ScreenSpaceShadows::Flags` bit for bit; add `FLAG_DEBUG_CASTER_MASK` to the early-out exclusion beside `FLAG_DEBUG_WAVE_INDEX \| FLAG_DEBUG_THREAD_INDEX \| FLAG_DEBUG_EDGE_MASK` | the two flag lists are matched by nothing but their order. Without the exclusion that view is blank wherever a wave votes to leave — most of the sky and most of the shadowed ground — and looks broken while the feature works |
| `DEBUG_VIEW_CASTER_MASK` is appended **after** `DEBUG_VIEW_WAVE_INDEX` in `DebugView`, and `Caster Mask` last in the `debug_view` setting's `PROPERTY_HINT_ENUM` string | the setting is read as an int, `CLAMP`ed to `DEBUG_VIEW_MAX - 1` and cast, so the hint string is positional: append to one list and not the other and every value from that point on names a different view than the inspector says |

**Three refusals of its own.** `_using_restricted_sss_casters()` tests, in order: the project
setting; `_using_screen_space_shadows()` (so the pass's own refusals carry through);
`is_raytraced_directional_available()`; a visible VoxelGI (`WARN_PRINT_ONCE`); MSAA
(`WARN_PRINT_ONCE`). In every refusal **the screen space pass still runs, unrestricted, exactly as
before** — none is a fallback to a degraded path.

| Refusal | Why |
| --- | --- |
| **The SUN must be raytraced**, not merely that a structure exists | the premise is that anything the restriction stops casting already casts a correct traced shadow *from this light*. With `raytraced_shadows/directional/enabled` off the structure holds only geometry gathered near raytraced lamps and the sun is on a demoted cascade, so restricting would take the contact shadow away from geometry receiving none from anywhere else. Gate on `is_raytracing_scene_available()` instead and a scene with one raytraced lamp and a shadow-mapped sun loses its grass shadows |
| **A visible VoxelGI** takes the pre-pass away outright through the pass mode chain above, so nothing writes the mask | the check belongs in this predicate rather than at the bind, because the mask is a named render buffer living until the buffers are reconfigured and cleared by nothing: without it, turning the camera toward a VoxelGI left the march reading whichever frame last wrote a caster mask against this frame's depth |
| **MSAA** | the caster flag would have to be resolved with the depth's own `best_index` sample, and averaging or OR-ing it casts from a surface that was never a caster — visible only as shadows at silhouettes with nothing above them, the one artifact nobody looks for on foliage. The framebuffer sample-count mismatch above makes it a hard refusal. The MSAA resolve branch in `_render_scene` lists the new pass mode alongside the other two, unreachable today; leave it, but do not read it as MSAA support |

**The predicate is called twice per frame** — to pick the pass mode, and in
`_render_screen_space_shadows` to decide whether to bind the mask — so every reason the pre-pass can
lose its slot must live inside it. The two agree on the sun because
`raytraced_shadows/directional/enabled` is snapshotted once per frame in
`RaytracingScene::update_frame_settings()` (`renderer_rd/environment/rt_scene.cpp`) rather than read
live; make that a live read and within one frame you can write a mask nothing binds, or bind a mask
nothing wrote. Both calls also happen before it is known whether any light needs the pass, so a
scene with the setting on and no shadow-casting sun still pays the `R8` attachment, the extra
pre-pass target and the advanced-group compile for nothing.

**The one real cost to authors, which a port must carry into its own class reference.**
Alpha-scissor materials pass `casts_shadows()`, so `can_cast_shadows` is true, so they are in the
acceleration structure, so they stop casting a screen space shadow when this is on — and their
traced shadow is the whole uncut quad (stage 9). A regression for the exact content the feature was
built for, and nothing surfaces it: the shadow does not vanish, it coarsens. The answer for authors
is `cast_shadow = Off` on the foliage as well (`docs/features/screen-space-shadows.md`).

### 21. NVIDIA Streamline (DLSS)

Independent of everything above and **Windows-only**: off Windows the driver files compile to empty
objects, so nothing here can be exercised from a Linux checkout or in CI. Mechanism, including the
tagging rule and the constants conventions: `docs/internals/dlss.md`.

**Done when:** startup prints the resolved binary directory, then the Streamline version once
`slInit` succeeds, then the adapter's available features once the graphics device exists; and **View
→ View Information** in the 3D viewport reports DLSS resolutions and preset when DLSS is the
upscaler that actually ran. Frame generation has never been verified on hardware
(`docs/features/dlss.md`, `docs/HISTORY.md`).

**Seams:** every file and what was added to it, with line numbers, is `docs/internals/dlss.md`,
"Code map". Two that are easy to miss because they are not Streamline code:
`storage_rd/render_scene_data_rd.cpp` stores the *previous* frame's `main_cam_inv_view_matrix` so
billboards produce a motion vector (seams table below), and `platform/windows/detect.py` puts
`wintrust` on the link line for the signature check.

| Requirement | Why, and what a miss looks like |
| --- | --- |
| **Attachment is loader interposition, which is why the master setting is restart-required**: Streamline is loaded before volk, and volk is initialized with the `vkGetInstanceProcAddr` the interposer exports rather than the Vulkan loader's | `vkCreateInstance`, `vkCreateDevice`, `vkCreateSwapchainKHR`, `vkAcquireNextImageKHR` and `vkQueuePresentKHR` become Streamline proxies with no call site changing. Taking the create-instance and create-device proxies also hands Streamline the job of adding the instance extensions, device extensions, feature bits and extra queues its features need, which is why none of that is duplicated in the engine and `slSetVulkanInfo` is never called |
| **Nothing in `streamline_vk.h` may name a Vulkan or Streamline type** — native handles cross as `uint64_t`, the way `RenderingDevice::get_driver_resource()` already hands them out | that is what keeps the renderer side free of both include paths |
| **The interposer is refused unless the OS trusts its Authenticode signature and the signer is NVIDIA** | without that check, dropping a hostile `sl.interposer.dll` beside the executable would take over the Vulkan loader for the whole process. A self-built Streamline will not load. No SDK binaries are vendored — headers only, under `thirdparty/streamline/` |
| **`sl.dlss_g` must be left out of `featuresToLoad` in the editor** | or every editor popup renders blank; the mechanism and the exact `VkResult` are in `docs/internals/dlss.md`, section 2 |
| **Anything tagged for Streamline has to be a texture of its own** | parent, swizzled view and slice all resolve to one native `VkImage` handle, so two tags built from any of them collide. `docs/internals/dlss.md`, section 4, has the rule and the incident that established it |
| **The conventions the integration asserts**, each failing visibly and differently: motion vectors are `prev_position_uv - position_uv` with jitter subtracted from both endpoints, so `mvecScale` is `{1, 1}` and `motionVectorsJittered` is false; depth is reverse-Z so `depthInverted` is true; `cameraMotionIncluded` is true | matrices cross as a straight copy because Godot's column-major `M * v` and Streamline's row-major `v * M` are transposes in both convention and storage and the two cancel; jitter is handed over in pixels, the same expression FSR2 gets |
| **DLSS needs the velocity buffer pre-filled with camera motion** | which is why `MotionVectorsStore` is no longer MetalFX-only (`docs/internals/dlss.md`, section 6) |
| Every pass this fork adds dispatches from `get_internal_size()`, and DLSS is the only feature that makes that size arbitrary | so it is the thing most likely to expose a latent size-alignment assumption (`docs/internals/dlss.md`, section 9; `CLAUDE.md` for the truncation rule and the size to test against) |

---

## Shared interfaces this fork widens

Every entry is a member added to an interface the engine implements more than once, so a port that
adds it in one place and not the others fails to link — and for a pure virtual the error names an
abstract class being instantiated, far from anything this fork touched. Default a virtual where a
renderer with no raytraced shadows would only repeat itself; make it pure where it changes behavior
a backend cannot sensibly guess at.

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
| `renderer_geometry_instance.h` | `set_screen_space_shadow_caster` | pure virtual | every `RenderGeometryInstance`: forward-clustered, mobile, dummy. The base implementation must call `_mark_dirty()`, or the flag never reaches instance data and the caster mask comes back empty with nothing to indicate why |

`RenderSceneDataRD` also gains an `alpha_pass` bool reaching the shader as a scene data flag (stage
15), and its previous-frame UBO carries one changed field (seams table). Neither is on the table
because nothing else implements that class.

## Reference values

These belong to the fork rather than to upstream, so unlike the rest of this document they can be
copied literally. Every value was re-read from the code at the paths given.

### Project settings

Defaults, hints and ranges are stated in full in the feature docs; this is the registration
contract, which those do not carry.

| Family | Registered in | Macros and liveness |
| --- | --- | --- |
| `rendering/lights_and_shadows/raytraced_shadows/` (17 settings) | `core/config/project_settings.cpp:1840-1908` | `enabled` is `GLOBAL_DEF_RST_BASIC`, **restart-required**, for the buffer-bits reason in stage 1. `directional/enabled` is `GLOBAL_DEF_BASIC`, live but snapshotted once per frame. Every other setting is live and clamped **on read**. Table: `docs/features/rt-shadows.md`, "Project settings". |
| `rendering/lights_and_shadows/screen_space_shadows/` (8 settings) | `core/config/project_settings.cpp:1917-1955` | All `GLOBAL_DEF_BASIC` and all live, `enabled` included — it must **not** be marked restart-required. `contrast` (4.0) and `strength` (1.0) are constants rather than settings. Table: `docs/features/screen-space-shadows.md`. |
| `rendering/environment/ssao/` (`method` plus 8 under `ground_truth/`) | **`servers/rendering/rendering_server.cpp`**, beside upstream's other `ssao/` settings — not in `project_settings.cpp` with the two above | `method` has two enum values against the three of `Environment::SSAOMethod` (`SSAO_METHOD_DEFAULT`, `_SCREEN_SPACE`, `_GROUND_TRUTH`, `scene/resources/environment.h:78`) — **resolve by branch, never by cast**. Several `ground_truth/` values are re-clamped in the push constant to a tighter range than the hint. Table: `docs/features/ambient-occlusion.md`. |

`Environment.ssao_radius`, `ssao_intensity`, `ssao_power` and the shared `fadeout_from` /
`fadeout_to` are read off the same properties the legacy estimator reads, so their defaults are
upstream's; `ssao_detail`, `ssao_horizon` and `ssao_sharpness` have no counterpart here and are
hidden in the inspector when this estimator runs.

### Node defaults this fork changes

Constructor defaults, not settings, so a `.tscn` storing only what differs from a fresh node means
changing them changes existing scenes. The table and its four non-shadow consequences are in
`CLAUDE.md`; the code is `scene/3d/light_3d.cpp` — `_apply_local_light_shadow_defaults()` for omni
and spot (`shadow_enabled` true, `set_param(PARAM_SIZE, 0.05)`) and `DirectionalLight3D()` for the
sun (`set_param(PARAM_SIZE, 0.25)`). `softness_scale` scales the trace's copy rather than the
authored value, which is why the angular default can reach PCSS, sky and lightmap code untouched.

### Fixed constants

Compile-time, each load-bearing for the reason given.

| Constant | Value | Where | Why it is that |
| --- | --- | --- | --- |
| `LIGHTS_PER_PIXEL` | 4 | `effects/rt_shadows.h:83` | one RGBA8 mask texel per pixel |
| `MAX_RT_LIGHTS` | 255 | `effects/rt_shadows.h:64` | the slot index rides in a float with 255 reserved as "not raytraced" |
| `SLOT_NONE` | 255 | `rt_shadow_trace.glsl:32` | that sentinel; spelled `RT_SLOT_NONE` in the forward shaders |
| `TILE_SIZE` | 8 | `rt_shadow_trace.glsl:12` | the trace's workgroup, 64 threads |
| `MAX_TILE_LIGHTS` | 128 | `rt_shadow_trace.glsl:23` | shared-memory candidate list per tile |
| `MAX_PENUMBRA_PIXELS` | 32.0 | `rt_shadow_trace.glsl:28` | widest penumbra the 8-bit hit-distance channel describes |
| `HISTORY_FILL_SCALE` | 4.0 | `rt_shadow_atrous.glsl:43` | how much wider than its penumbra a disoccluded pixel may filter |
| a-trous `KERNEL` | 0.375, 0.25, 0.0625 | `rt_shadow_atrous.glsl` | the standard 5-tap B3 spline row |
| a-trous `depth_sigma` | 0.02 | `effects/rt_shadows.cpp:346` | the depth term's falloff; relative, so unitless |
| a-trous `normal_sigma` | 64.0 | `effects/rt_shadows.cpp:347` | the normal term's exponent |
| `MAX_BLAS_BUILDS_PER_FRAME` | 64 | `environment/rt_scene.h:159` | build budget; the rest defer |
| `MAX_BLAS_BUILD_TRIANGLES_PER_FRAME` | 1 << 20 | `environment/rt_scene.h:160` | the other half of that budget |
| `MAX_RT_CASTERS` | 65536 | `renderer_scene_cull.cpp:3573` | gather ceiling, warns and drops past it |
| TLAS instance ceiling | 65536 | `environment/rt_scene.cpp:662` | a second, separate ceiling on caster SURFACES, a bare literal, silent when hit |
| `SHADER_VERSION_COLOR_PASS` | 10 | `scene_shader_forward_clustered.h:69` | **an invariant, not a value** — stage 20. A newer Godot adding its own depth version silently mis-indexes every color pipeline, and the symptom is wrong or missing geometry rather than an error |
| `SECTOR_COUNT` | 32 | `gtao_gather.glsl:23` | bits in the GTAO visibility mask, one uint |
| `ANGLE_BIAS` | 0.03 | `gtao_gather.glsl:28` | GTAO self-occlusion guard |
| `DEPTH_MIP_COUNT` | 5 | `effects/gtao.h:68` | levels in the GTAO depth pyramid |

### The light record

64 bytes (`RTShadows::LightParams`, `effects/rt_shadows.h:100`, `static_assert` at `:137`),
`std430`, one row per slot in a storage buffer indexed by `rt_slot` and sized to the highest live
slot. Sparse, because slots are sticky: gaps are zeroed and the trace skips any row with `radius <=
0`. A directional light takes a row in the same buffer and reinterprets four fields — `light_type`
is the discriminator and the trace branches on it once, never on a sentinel in another field. This
is the whole CPU-to-shader contract for the trace, the mask and the directional path; keep the C++
mirror and the GLSL struct in one commit, with a `static_assert` on the size.

| Off | Field | Type | Omni / spot | Directional |
| --- | --- | --- | --- | --- |
| 0 | `position` | float[3] | light world position | the **camera's** world position |
| 12 | `radius` | float | world range, m | view depth at which the shadow has fully faded |
| 16 | `direction` | float[3] | axis the light points **away** along | unit vector **toward** the light — the ray's own |
| 28 | `cos_spot_angle` | float | `cos(spot_angle)` | unused |
| 32 | `size` | float | emitter radius in m, times `softness_scale` | **tan** of the angular radius, times `softness_scale` |
| 36 | `light_type` | uint | 0 omni, 1 spot | 2 |
| 40 | `mask` | uint | 8-bit fold of `shadow_caster_mask`, zero promoted to `0xFF` | same |
| 44 | `energy` | float | per-pixel ranking term only | same |
| 48 | `bias` | float | `shadow_bias * 0.05`, m — the ray's `tmin` | same |
| 52 | `normal_bias` | float | `shadow_normal_bias * 0.015` | `* 0.0075` |
| 56 | `fade_from` | float | unused | view depth where the fade begins |
| 60 | `max_ray_length` | float | unused | ray `tmax`: `radius * (1 + caster_distance_scale)` |

The two directional depths are the negation of the `fade_from`/`fade_to` the cascade path already
computes, which keeps the traced fade and the cascade fade from drifting apart. The directional
normal bias is half the lamp scale because the node defaults that property to 2.0 for a
`DirectionalLight3D` and 1.0 for a lamp, so the same slider means the same offset.

### The caster record

What the culler hands the renderer, one per instance, consumed whole. Casters are deliberately
**not** frustum culled, so this list is not the visible set. There is no multimesh field: the culler
expands elements itself, so per-element culling is the culler's job rather than an interface.

| Field | What it is |
| --- | --- |
| `mesh` | mesh RID. For a multimesh, the shared mesh — emitted once per element |
| `mesh_instance` | set only where the geometry deforms; the per-instance skinned buffer the structure reads |
| `transform` | world. For a multimesh element, instance transform times element transform |
| `layer_mask` | the full **32-bit** layers. The fold to eight happens where the TLAS instance is written, not here |
| `surface_mask` | one bit per surface, from the eligibility predicate; surfaces past the thirty-second always cast |

### Texture formats

Get these wrong and the failure is silent. All single-layer — this path is not multiview. The
raytraced set and the GTAO depth pyramid are created at the render buffer's **internal** size; the
two GTAO AO buffers at `gather_size`, the internal size cut down by `half_size` and the shading
rate.

| Texture | Format | Cleared to | Notes |
| --- | --- | --- | --- |
| RT shadow mask | `R8G8B8A8_UNORM` | white when the trace does not run | sqrt-encoded visibility, one channel per light |
| RT shadow index | `R8G8B8A8_UINT` | 0 | which light each channel carries; unused channels get 255 (`SLOT_NONE`) |
| RT raw hit distance | `R8G8B8A8_UNORM` | 0 | penumbra pixels / `MAX_PENUMBRA_PIXELS` |
| RT denoise A/B | `R8G8B8A8_UNORM` | 0 | ping-pong; the last a-trous pass writes the mask |
| RT history visibility | `R8G8B8A8_UNORM` | 0 | |
| RT history index | `R8G8B8A8_UINT` | 0 | |
| RT history meta | `R16G16_SFLOAT` | 0 | linear view depth, history length normalized to the window |
| RT history length | `R8_UNORM` | 0 | normalized to the window |
| GTAO depth pyramid | `R32_SFLOAT` | — | 5 mips, mip 0 at **full** internal size, farthest-biased |
| GTAO AO A/B | `R16G16_SFLOAT` | — | occlusion and the depth the denoise re-plane-fits against |
| screen space shadow mask | `R8_UNORM` | white | `RB_SCOPE_SCREEN_SPACE_SHADOWS`, internal size, `SAMPLING \| STORAGE \| CAN_COPY_TO \| CAN_COPY_FROM` |
| screen space caster mask | `R8_UNORM` | 0 by pre-pass clear | `RB_TEX_SSS_CASTER`, internal size, `SAMPLING \| COLOR_ATTACHMENT \| CAN_COPY_FROM`, no MSAA twin |
| shared occlusion output | `R8_UNORM` | white when the pass does not run | `RB_SCOPE_SSAO` / `RB_FINAL`, full size, shared with the legacy estimator |

### Push constant sizes

Both sides must match exactly, trailing padding included — see the note above the assertions in
`effects/rt_shadows.h` for why a trailing pad on one side alone is fatal, and how to read a block's
reflected size. **Nine** pairings, and that comment is the only place they are gathered.

| Struct | Bytes | Declared in |
| --- | --- | --- |
| `RTShadows::TracePushConstant` | 120 | `effects/rt_shadows.h:277` |
| `RTShadows::TemporalPushConstant` | 112 | `effects/rt_shadows.h:278` |
| `RTShadows::AtrousPushConstant` | 48 | `effects/rt_shadows.h:279` |
| `GTAO::PrefilterPushConstant` | 32 | `effects/gtao.h:193` |
| `GTAO::GatherPushConstant` | 96 | `effects/gtao.h:194` |
| `GTAO::FilterPushConstant` | 80 | `effects/gtao.h:195` |
| `ScreenSpaceShadows::PushConstant` | 76 | `effects/screen_space_shadows.h:180` |
| `DLSSEffect::ReactivePushConstant` | 16 | `effects/dlss.h:77` |
| `RaytracingScene::DequantizePushConstant` | 32 | `environment/rt_scene.h:137` |

Four carry their **field order** too, because that order is the other half of the contract: the
assertions catch a size mismatch but not a reordering.

| Struct | Fields, in order |
| --- | --- |
| `ScreenSpaceShadows::PushConstant` | `light_coordinate[4]`, `wave_offset[2]`, `screen_size[2]`, `inv_depth_texture_size[2]`, `depth_bounds[2]`, `surface_thickness`, `bilinear_threshold`, `shadow_contrast`, `far_depth_value`, `near_depth_value`, `flags`, `hardness` |
| `GTAO::PrefilterPushConstant` | `screen_size[2]`, `linearize_mul`, `linearize_add`, `falloff_mul`, `falloff_add`, `orthogonal`, `pad` |
| `GTAO::GatherPushConstant` | `gather_size[2]`, `full_size[2]`, `uv_to_view_mul[2]`, `uv_to_view_add[2]`, `radius`, `thickness`, `power`, `intensity`, `fade_from`, `fade_inv_span`, `slice_count`, `steps_per_slice`, `scale_radius_with_distance`, `screen_radius`, `orthogonal`, `use_bitmask`, `gather_stride[2]`, `checkerboard`, `pad0` |
| `GTAO::FilterPushConstant` | `source_size[2]`, `dest_size[2]`, `full_size[2]`, `gather_stride[2]`, `uv_to_view_mul[2]`, `uv_to_view_add[2]`, `plane_tolerance`, `filter_radius`, `direction[2]`, `checkerboard`, `pad0`, `pad1`, `pad2` |

The `ScreenSpaceShadows` struct is plain, with no `alignas`: the agreement comes from that grouping
putting every `vec2`/`ivec2` on an 8-byte boundary, so reordering the trailing scalars for
readability keeps `sizeof == 76` and breaks the alignment silently. Two of the three GTAO structs
grew a field for the checkerboard rate — the same edit that once took a push constant out of sync
and blacked out the scene. `FilterPushConstant` has no `orthogonal` field: that is the orthographic
gap named in stage 18, not an oversight in this table.

---

## Quick reference: the seams that break

Rated fragile — each depends on a data layout, an ordering or a format Godot revises between
versions. Check these first; the named stage has the failure in full.

| Seam | What to verify | Stage |
| --- | --- | --- |
| `blas_create`'s vertex buffer lookup | still `vertex_buffer_owner` and nothing else (`rendering_device.cpp:323`); every buffer built from must come from `vertex_buffer_create`, dequantized positions included | 0, 1 |
| `RenderSceneDataRD` previous-frame UBO | the fork stores `prev_cam_transform` into `main_cam_inv_view_matrix` where upstream stores the current camera's (`storage_rd/render_scene_data_rd.cpp:295`), so a billboard's previous-frame vertex evaluation uses the basis it actually had. If upstream rewrites that copy, billboards report almost no motion of their own and ghost under DLSS with nothing pointing at the cause | 21 |
| `RD::AccelerationStructureGeometry` / `blas_build` | still `vertex_buffer`/`offset`/`stride`/`count`/`format` plus index fields; still a full in-place rebuild with no refit | 0 |
| Mesh vertex layout | positions still a contiguous `float32x3` block at offset 0 ahead of the attribute block; decode still `pos * aabb.size + aabb.position` | 2 |
| `MeshInstance::Surface` (`vertex_buffer[2]`, `current_buffer`, `last_change`) | `last_change` still set on **every** surface `update_mesh_instances()` dispatches, not only on a buffer flip | 7 |
| `LightData` / `DirectionalLightData` trailing `pad[2]` | still unclaimed. If upstream took it, find new space and keep `sizeof` identical. The fork appended a whole `vec4` for `sss_strength`, not a bare float; `rt_caster_mask` and `rt_softshadow_angle` are taken, `pad_sss0` remains | 3, 19 |
| `RENDER_PASS_UNIFORM_SET` bindings 37/38/39 | find the new highest binding (upstream's was 36) and renumber C++ and GLSL in lockstep. 37/38 raytraced mask and light index, 39 screen space shadow mask | 4, 19 |
| `_setup_render_pass_uniform_set` | bindings added on every path, probe and no-render-buffer renders included | 4, 19 |
| `update_light_buffers` | every early-out preserves both invariants: `rt_slot < RT_SLOT_NONE` iff the light has a channel this frame, `shadow_map_opacity > 0.001` iff an atlas rect or cascade was written | 3, 11 |
| `_pre_opaque_render` dispatch site | depth resolved before it; the trace fed `scene_data->get_cam_projection()`, not the raw member | 4 |
| Directional loop in `scene_forward_clustered.glsl` | re-derive the three-way split by hand; the mask block must hand over RAW visibility, or `shadow_opacity` is squared | 13 |
| Fog `Params` UBO / `ParamsUBO` | `cam_position` at the identical offset on both sides | 16 |
| Fog `ShaderGroup` enum | the four device-capability groups still contiguous and first; `+ SHADER_GROUP_BASE_RAYTRACED` silently maps wrong if a fifth is inserted | 16 |
| `_get_fog_process_variant` | still `device_group * VOLUMETRIC_FOG_PROCESS_SHADER_MAX + idx`, push order matching the enum position-for-position | 16 |
| `RB_SCOPE_SSAO` / `RB_FINAL` format and usage | still `R8_UNORM` with sampling and storage, and still what the forward shader samples for occlusion. Both estimators write it; if upstream changes it, change both | 18 |
| `Environment::_validate_property` forward_plus branch | the `else` this fork added still reachable, i.e. upstream has not put its own `return` in front of it | 18 |
| `re-spirv` `SpvIsSupported()` | still excludes ray-query opcodes, so those modules bail out rather than being miscompiled | 0 |
| C++ push constant struct vs its GLSL block | sizes match **exactly**, trailing padding included; the reflected size is the block's exact end, not rounded up to sixteen. Nine pairings, under Reference values | 19, 20 |
| Screen space shadow light selection | `update_light_buffers` still runs before `_pre_opaque_render` reads `get_sss_light()`, and still fills a directional light's `direction` from the light basis's **+Z**, not the `-Z` omni and spot use. Unify those two and the march runs backwards | 19 |
| Screen space shadow depth availability | `force_depth_pre_pass` and `finish_depth` both still take a term for this feature — it can be enabled with raytracing off, where nothing else forces either | 19 |
| Bend's Y convention | `Projection::set_depth_correction` still negates Y (`m[5] = -1` under `flip_y`) against a positive-height Vulkan viewport, so the effect negates clip Y on the way in. Change either and the sun lands at its vertical mirror | 19 |
| `SHADER_VERSION_COLOR_PASS` vs the depth variant count | a newer Godot adding a depth variant of its own breaks the index arithmetic with no error | 20 |
| The shadow mask is written every frame | an untouched target reads as its clear, and a cleared mask is every raytraced light fully occluded everywhere — the worst answer, not a degraded one. The trace must report whether it wrote and the caller must clear to white when it did not. Same asymmetry for the occlusion buffer. The denoiser's history buffers are exempt: losing those degrades to the raw trace, noise rather than nothing | 4, 18 |
| Streamline hook set (`sl_hooks.h`) | volk still initialized with the interposer's `vkGetInstanceProcAddr`, and the interposer still returns a declined before-hook's error without calling the driver | 21 |

---

## Do not retry these

Moved. Every refused idea with the measurement that refused it is in **`docs/HISTORY.md`** — read it
before re-attempting anything here that looks like an obvious improvement from the code alone.

## How to verify a port

Moved. The harnesses, the linear-light rule, the byte-identical standard and the two blind spots are
in **`docs/VALIDATION.md`**.
