# Re-applying raytraced shadows to a newer Godot

This document exists so the system in this fork can be rebuilt on a later version of Godot, by
someone — or something — that was not here when it was written the first time.

It is deliberately **not** a diff. On a newer engine the line numbers will be wrong, some functions
will have been renamed, and some structures will have gained fields. What survives that is the
*shape* of the integration: which upstream thing each piece hooks into, what it assumes about the
engine around it, and what the failure looks like when that assumption stops holding.

Most of the value here is in the **pitfalls**. Nearly every one is a bug that actually shipped and
had to be found again later, usually by measurement rather than by reading. They are recorded with
their symptoms because the symptom is rarely a crash — it is a picture that looks slightly wrong.

Read `FORK_GUIDE.md` first for what the system does. This is about how it attaches.

Upstream base for the original work: `b56a91878e7c94977e4af978968e41d0670c0a8b` (Godot 4.8-dev).
To see any piece as it was written: `git diff b56a91878..HEAD -- <path>`.

---

## Stage 0 — Preflight: is the raytracing layer still there?

Godot 4.7/4.8 shipped a **complete hardware-raytracing layer inside `RenderingDevice`** — BLAS/TLAS
create and build, `UNIFORM_TYPE_ACCELERATION_STRUCTURE`, `SUPPORTS_RAY_QUERY` and
`SUPPORTS_BUFFER_DEVICE_ADDRESS` feature queries, AS-aware buffer creation bits, render-graph
barrier tracking — with **no consumer anywhere in the renderer**. This fork is a re-integration, not
a reimplementation. If that layer has changed shape, that is the single largest risk in the port and
you must know it before writing anything else.

The one thing the fork *added* to `RenderingDevice`: **`acceleration_structure_is_valid(RID)`**,
mirroring the existing `*_is_valid` queries. It exists because an acceleration structure is freed
implicitly when a buffer it was built from is freed, and the owning mesh can be destroyed first — a
cache that outlives its source meshes must be able to ask whether a handle is still live. A dead
handle takes the whole `tlas_build` down.

**Done when:** a throwaway `#version 460` compute shader with `#extension GL_EXT_ray_query : enable`,
an `accelerationStructureEXT` at set 0 binding 0 and a `rayQueryInitializeEXT`/`ProceedEXT` loop
compiles and links through Godot's own shader build, and a one-triangle BLAS plus one-instance TLAS
report true from the new validity query.

**Pitfalls:**

- **glslang gates the `rayQueryEXT` keyword and every `rayQuery*EXT` builtin on `#version 460`.**
  Every other shader in `renderer_rd` is 450. `accelerationStructureEXT` itself has *no* version
  gate, so a 450 shader compiles the uniform fine and only fails at the first `rayQueryEXT` — the
  error reads like a shader-specific bug rather than a version problem. Ray query also cannot be
  hidden behind a preprocessor branch in a 450 shader; the whole file must go to 460.
- **Godot's `re-spirv` optimizer does not understand `OpTypeRayQueryKHR`.** It prints
  `OpTypeRayQueryKHR is not supported yet.` and falls back to unoptimized SPIR-V. Harmless and
  expected — do not chase it. It is also the cheapest instrument available: counting those lines
  counts exactly how many ray-query modules a run compiled.
- **`tlas_build` rejects a zero `hit_sbt_range`** even for ray-query-only use with no shader binding
  table anywhere. Pass a synthetic `HitShaderBindingTableRange(int64_t(1) << 32)`.
- A TLAS's `max_instance_count` is frozen at create time; scratch buffers are per-structure and
  never pooled; build-input buffers need `DEVICE_ADDRESS` as well as the AS-input bit.
- **There is no refit or compaction entry point.** Every "update" of a BLAS is a full `blas_build`
  on the same RID.
- The Vulkan container targets SPIR-V 1.4 with a Vulkan 1.1 client — exactly the minimum
  `GL_EXT_ray_query` needs. Check `RenderingShaderContainerFormatVulkan::get_shader_spirv_version`.

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
  `mesh_add_surface` decides buffer creation bits at upload time, **before the RenderingDevice and
  the renderer exist** — which is also exactly why the master setting is restart-required.
- **Latch only the settings that genuinely cannot change; read the rest through
  `GLOBAL_GET_CACHED`.** The fork's first version resolved all fifteen once behind a
  `settings_registered` flag, which quietly made every tuning knob restart-required while the editor
  advertised only two of them as such — so turning the denoiser off in the inspector did nothing at
  all, with no feedback. `GLOBAL_GET_CACHED` keeps a typed copy keyed on `ProjectSettings`' version
  counter, so a live read costs an integer compare and the value reaches the renderer on the next
  frame. Only `enabled` truly has to be latched, for the buffer-bits reason above. Clamp on read
  rather than on registration: a live value arrives with no validation beyond the property hint, and
  several hints allow `or_greater`.
- Gate the buffer bits on `SUPPORTS_RAY_QUERY` as well as `SUPPORTS_BUFFER_DEVICE_ADDRESS`. Testing
  only the setting and device address gave every mesh buffer AS usage nothing could consume on
  D3D12, whose `has_feature()` has no `SUPPORTS_RAY_QUERY` case and returns false.
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
light-volume gather directly** — the fork started with a whole-scenario walk, which ties cost to
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
  `offset = i == ARRAY_NORMAL ? position_stride * s->vertex_count : 0` — if positions are no longer
  a contiguous `float32x3` block at offset 0 ahead of the attribute block, the zero-copy path is gone.
- Uncompressed surfaces are zero-copy: point at the surface buffer with offset 0, stride 12.
  Classify ineligible surfaces once (non-`PRIMITIVE_TRIANGLES`, `ARRAY_FLAG_USE_2D_VERTICES`,
  `ARRAY_FLAG_USES_EMPTY_VERTEX_ARRAY`, zero vertices) rather than retesting per frame.
- Use the surface's **LOD-0** index buffer; a LOD silhouette does not match the shadow the raster
  path would have cast.
- Set `ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT` on every instance.
  `shadow_reverse_cull_face` is per-light while the TLAS is per-scenario, so flip-facing cannot be
  honored at all.
- TLAS instance sourcing must live in `RendererSceneCull` — `render_forward_clustered` cannot reach
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
  *consumed the existing trailing pad* rather than growing them — `float pad[2]` became
  `float rt_slot; float shadow_map_opacity;` on both sides. Do not grow either struct, or every
  offset after the change moves silently and lighting goes subtly wrong rather than crashing.
  **If the newer Godot has repurposed that padding, find two other slots and update both sides
  together, keeping `sizeof` identical.**
- `DirectionalLightData`'s pad changes type from `uvec2` to two floats deliberately — the shader
  compares `rt_slot` as a float against `255.0`.
- **Slots must be sticky** (a light keeps its index while it keeps casting, plus a four-frame grace
  period). The denoiser's temporal history records which light each mask channel carried, so a light
  that changes index invalidates the whole screen's history. Assigning in light-buffer order — which
  is sorted by distance to camera — re-rolls every index as the camera moves.
- The buffer is therefore **sparse**: a slot may belong to a light outside this pass. Zero the gaps
  and let the trace skip them by `radius <= 0`. That is also why a live light's radius must stay
  positive whatever its type.
- **Grant a slot only when a built TLAS exists this frame.** A slot with nothing behind it makes the
  forward shader skip the shadow atlas *and* read "fully lit" from the mask: the light casts no
  shadow from any source, which is strictly worse than not enabling the feature.
- The per-instance ray cull mask folds from the light's **`shadow_caster_mask`**, not its cull mask
  (which decides what the light *lights*). Fold 32 bits to 8 by OR-ing the four bytes —
  conservative, never under-inclusive — and promote a zero fold to `0xFF`.

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
  appearing to hang on the splash screen** with the CPU at 90–120 ms and the GPU idle. That file is
  also shared with the mobile renderer, so every added block needs `#ifndef USING_MOBILE_RENDERER`.
- `texelFetch` on a bare `texture2D` requires `GL_EXT_samplerless_texture_functions`, which these
  shaders do not enable. Build a combined sampler — `sampler2D(rt_shadow_mask, SAMPLER_NEAREST_CLAMP)` —
  the way `ssil_buffer` and `ssr_buffer` do.
- Reconstruct world position with `scene_data->get_cam_projection()` / `get_cam_transform()`, which
  carry the reverse-Z + Y-flip correction and the TAA jitter the depth buffer was written with.
  Using the raw members collapses every pixel to ~0.1 units from the camera and the mask comes out
  black wherever geometry was drawn.
- Read the real view-space normal from the normal/roughness pre-pass and rotate it to world space
  with a **quaternion** in the push constant. A normal crossed from two neighboring depth taps
  fringes every silhouette; the camera basis will not fit in 128 bytes beside the inverse
  view-projection.
- `normal_roughness` is not produced by default — that is why `depth_pass_mode` is forced.
  `has_normal_roughness()` is a sticky global and must not be used as a gate. Reflection-probe
  renders have no `rb_data` at all.
- **Bindings 37 and 38** are appended to `RENDER_PASS_UNIFORM_SET` (set 1); upstream's highest was
  36. They must be added on **every** path through `_setup_render_pass_uniform_set`, including
  reflection-probe and no-render-buffer renders, with fallbacks: `DEFAULT_RD_TEXTURE_WHITE` for the
  mask and a new 1×1 all-`0xFF` `R8G8B8A8_UINT` texture for the index — none of the shared default
  textures are integer-formatted. **On a newer engine, find the highest binding in that set and
  renumber both the C++ pushes and the GLSL declarations in lockstep.**

### 5. Denoiser

Temporal accumulation plus an edge-stopping à-trous filter, both keeping their own history so the
feature does not depend on the image's TAA.

**Done when:** after ninety frames of camera movement the denoised result is byte-identical to a
converged render from the same pose, and a camera orbiting at 3.4°/frame lands within 2/255 of a
static converged render.

- **Reproject with the camera, not motion vectors.** The velocity buffer is written by the opaque
  colour pass, which runs *after* the mask is needed, so it is a frame stale; under MSAA it is only
  resolved when TAA or an upscaler asks. Camera reprojection is exact for static geometry, and
  geometry that moved on its own is then rejected by the surface test rather than smeared.
- The `w` of a reprojected position is the previous clip position scaled by the reciprocal of view
  depth — **a ratio, not a distance**. Comparing it against a tolerance in meters fails every pixel
  every frame, and the failure is silent: it shows only as a spatial filter that never narrows.
  Store the history's depth as a raw view distance and compare that.
- **Feed the temporal stage back its own output as history, never the à-trous result.** Filtering
  inside the loop compounds without bound — a two-pixel kernel arrives on screen as a twenty-pixel
  smear.
- Write and read history length in the same units. Writing it normalized and reading it raw pins the
  blend factor at 1 and throws the history away every frame.
- Channel assignments are per pixel and **cannot be interpolated**: filter the temporal history by
  hand, accepting or rejecting each bilinear tap on its own, and reject à-trous taps whose index
  assignment differs from the centre's.
- Return early where the mask is fully lit in all four channels — in an outdoor scene that is most
  of the screen, and the 25-tap loop cannot change the answer there. Output is byte-identical.
- Multiview falls back to the raw signal: these passes are plain 2D and would filter one eye with
  the other's history.

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

Recover the shadow term before measuring. Divide the render by an occluder-free render of the same
scene: that cancels the falloff, the lambert term and the sRGB transfer and leaves visibility, which
is the quantity the geometry predicts. A 10-90 measured on pixel values instead is a 10-90 of a
tonemapped product and does not correspond to anything.

Three defects each squeeze or stretch the penumbra, and each is invisible without that ground truth:

- **No pair of rays can early out for a disk.** Probing the emitter with two rays and stopping when
  they agree is a large saving, but two points on the rim, opposite each other, still both read lit
  over the whole outer half of a penumbra — where a fifth of the emitter is covered they agree a
  third of the time — and the binary answer pulls that pixel to fully lit. The umbra side goes the
  same way. It cost 28% of the penumbra's width at sixteen samples per light and less at lower
  counts, so the shadow got *sharper* as the sample count rose. Trace every sample. Skipping settled
  work is still worth having, but it has to learn the penumbra is absent from somewhere other than
  the rays it is trying to avoid.
- **A variance clamp needs a floor.** With a handful of rays per pixel the 3x3 neighborhood used for
  the clamp agrees outright in the shallow ends of a penumbra — at one ray per light and a true
  visibility of 0.95, about two frames in three — so the measured spread is exactly zero and the
  history is pinned to that binary answer. It removed a third of every penumbra. Floor the spread
  with the standard error the ray counts carry, with two pseudo-counts so the floor cannot collapse
  with the spread.
- **An 8-bit accumulator that re-reads its own output must round stochastically.** Once the step the
  accumulator wants is under half a quantization level it stops moving, and not symmetrically: rare
  large steps land and frequent small ones do not, so the value ratchets. It made the stock penumbra
  15% too wide. Dither the store by a per-pixel, per-frame fraction of a step.

- **Decode out of sqrt space everywhere it is read.** Averaging roots and squaring darkens every
  penumbra by Jensen's inequality; one missed decode lightens every umbra almost invisibly unless
  you measure it. (NVIDIA's SIGMA filters *in* sqrt space on purpose; this system does not.)
- `min_filter_pixels` below 1.0 is meaningless and above it grays everything: the kernel's nearest
  tap sits at exactly 1.0 px, so a floor of 1.5 leaves it at a third weight and turns a perfect step
  edge into 0.863/0.137 — a two-pixel fringe on every contact shadow.
- At one sample a ray that misses reports **no** penumbra, so sizing the filter from the center pixel
  alone smooths the shadowed half of a penumbra and leaves the lit half speckled. Take the widest
  penumbra any immediate neighbor reports; at a real contact edge every neighbor reports zero and
  it costs nothing.
- **Do not set `gl_RayFlagsTerminateOnFirstHitEXT` by default.** Visibility is identical either way,
  but the reported distance becomes whichever occluder traversal reached first rather than the
  nearest, which mis-sizes the penumbra and over-blurs crisp shadows. Keep the flags in the push
  constant, not a define, so the trade costs no second pipeline.
- Both floors (`min_filter_pixels` and the history-fill widening) must apply **only where a penumbra
  was actually measured**, or a freshly disoccluded pixel is filtered across twelve pixels and takes
  thirty-one frames to recover — every camera turn does that to the newly revealed screen edge.
- Advance the blue-noise pattern by a golden-ratio step per frame rather than shifting the sampling
  position; shifting re-rolls the pattern and lets a pixel revisit nearly the same angle.
- Ray offsets come from the light's own bias properties **scaled down** — a shadow map's bias clears
  a depth texel, a ray only clears the error in a position reconstructed from depth. A directional
  light defaults normal bias to 2.0 where a lamp defaults to 1.0, so it needs half the scale or the
  sun's contact shadows lift off their casters.

### 7. Deforming casters

Skinned and blend-shaped meshes cast their current pose, on screen or not.

**Done when:** a two-bone skeleton bending a bar casts a straight shadow at rest and a bent one at
0.7 rad, differing over 8.7% of the frame — and still does with the caster above the top of the
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
  skinned geometry is already in the format the AS wants — this is why characters were the easy
  case, and it is worth re-checking on the newer engine.
- No refit, so each pose is a full `blas_build` (which does reuse the existing scratch allocation).
  Per-instance structures need eviction — the fork evicts after 60 unused frames — or every
  character that ever existed keeps one alive.

### 8. MultiMesh casters

Expanded CPU-side into one TLAS entry per element sharing one BLAS.

**Done when:** a GridMap interior stops leaking light into the next room; twelve pillars in one
MultiMesh become twelve TLAS entries backed by one built BLAS.

- A multimesh instance's own AABB covers the whole field, so **without a per-element test** a single
  large GridMap octant fills the structure with elements no light can reach.
- Reject 2D multimeshes (`multimesh_uses_3d_transforms`) before calling
  `multimesh_instance_get_transform`.
- Because a raytraced light has no shadow-map fallback, an unsupported caster type is an **absent**
  shadow, not a degraded one — and turning the feature off brings the shadows back, which reads as
  the feature being broken. Bound the total and say so once rather than truncating silently.

### 9. Caster eligibility

Only surfaces that can actually write a shadow enter the structure, decided per surface.

**Done when:** a pane of glass in front of a lamp costs one fewer structure entry and stops casting
a solid shadow.

- **This is not the negation of `material_casts_shadows`.** Upstream's predicate deliberately errs
  toward yes so the instance stays in the shadow render list and each draw decides for itself; a
  raytraced caster is decided once as it enters the structure and needs the exact answer.
- A `material_override` replaces every surface, so it zeroes the whole mask; a `next_pass` that does
  cast rescues a pass that does not; surfaces at index ≥ 32 are always assumed to cast.
- Alpha-scissor and alpha-hash materials **do** cast, with the cutout ignored — a leaf card throws
  the shadow of its whole quad. That is a documented limitation, not something this predicate fixes.

### 10. Structure lifetime and budgets

**Done when:** dragging a `BoxMesh`'s size in the inspector no longer prints `Parameter blas is null`
at frame rate, and shadows survive the session.

- Every `PrimitiveMesh` clears its mesh and re-adds surface zero whenever a property changes, and
  `ArrayMesh.clear_surfaces()` does the same. That frees the vertex buffer and the structure built
  from it, so **a cache keyed on the mesh RID hands out a freed handle forever after.**
- Skipping one bad entry is not enough — validate before the TLAS build too, so one stale entry
  cannot take down every shadow in the scene.
- Hash the TLAS contents by **summing** per-instance hashes, not chaining them: a ray query reads
  nothing that depends on where an instance sits in the array, and the spatial index's iteration
  order must not read as a change.
- Any BLAS built or refreshed this frame invalidates the bounds the TLAS cached for it, and a
  resized TLAS describes nothing yet — both force a rebuild regardless of the hash.

### 11. Drop the shadow maps

A raytraced light stops claiming an atlas quadrant and stops having a map rendered. Add
`Light3D.shadow_map_enabled` here.

**Done when:** `GODOT_RT_DEBUG` prints `shadow_maps_rendered=0` alongside `raytraced=N`, and a
spotlight with a projector cookie still projects with no atlas quadrant.

- **Decide in one place, before anything acts on it**, and make the culler ask exactly the question
  the renderer will later ask itself. The fork's split decision — culler skipping on light
  eligibility, renderer granting channels only when it would produce a mask — meant that under
  multiview every omni and spot was skipped by the culler and then denied a channel, and rendered
  with **no shadow at all**. The same happened to any light past the 255 the mask can address. The
  culler must also enforce the light limit itself.
- **Skipping the shadow-map render must not skip `light_instance_set_shadow_transform`**: the
  cascade split distances carried on those transforms are what `fade_from`/`fade_to` are derived
  from, and the raytraced path reads them.
- Keep `shadow_opacity` (what reads the mask) and `shadow_map_opacity` (what samples cascades)
  strictly distinct. Getting them the wrong way round produces a scene that looks right until you
  add fog.
- Three consumers read shadow-map state a raytraced light no longer has: **light projectors** (fixed
  by computing `shadow_matrix` directly), **subsurface transmittance** (must fall back to the
  material's own transmittance depth — a screen-space mask cannot give a depth from the light's
  point of view), and **volumetric fog** (a froxel is not a visible surface, so it lights unshadowed
  until stage 16).

### 12. Directional casters

Bound the sun's caster set behind its own setting, and fix the cascade-slot fill.

**Done when:** with props every ten meters out to 400 m and a 100 m shadow distance, sweeps of
0.5×/1×/2×/4× gather 17/22/32/42 casters, each landing exactly where the geometry says.

- Re-derive `far_distance` exactly as the engine does: `z_far`, clamped by
  `LIGHT_PARAM_SHADOW_MAX_DISTANCE` only when that is `> 0` **and** the camera is not orthogonal,
  then `MAX(..., z_near + 0.001)`. A max distance of zero means "as far as the camera sees";
  treating it as a literal zero collapses the volume to a millimeter and gathers nothing, silently.
  Getting the orthogonal test backwards fails the same way.
- **Iterate `scenario->directional_lights` directly** — directional lights are never in
  `scene_cull_result.lights`, because `light_get_aabb` returns an empty AABB for them.
- **Filling unused cascade slots from the last real one is a prerequisite for stage 14, not a
  tidy-up.** Every cascade chain in the shaders is a four-way if/else whose final branch reads slot
  3; with fewer cascades that slot holds a default-constructed `ShadowTransform` — identity
  projection, zero far plane. Surface shading and fog hide it because the distance fade bleaches the
  result at exactly that depth, but **subsurface transmittance has no fade**: zero far plane means
  zero thickness means full light through a solid object, and the zero in `shadow_split_offsets.w`
  makes the PCF blur factor divide by zero (NaN once blend splits are on). GLES3 already does this
  for the split offsets alone — extend it to the matrix, ranges, biases and atlas rect.

### 13. Directional trace

The sun takes a slot in the same mask and competes for a pixel's four channels on the same terms as
every lamp, reusing the 64-byte light record with four fields reinterpreted.

**Done when:** pillars of increasing height give a 10–90% shadow edge width of 0/3/6 px against the
cascade map's uniform 0/1/1 — the traced sun's penumbra grows with the gap it crosses.

- The trace treats every non-sky pixel as a receiver, but the culler only gathers casters as far as
  the shadow distance — a surface past that traces against an empty region and comes back
  confidently **lit**, a hard seam across the landscape at exactly the shadow distance. Carry the
  negation of the cascade fade in the record and apply the fade **in the trace**, not the forward
  pass, so the mask the denoiser filters and reprojects stays continuous. Both ends read
  `shadow_split_offsets[limit]`, so they cannot drift.
- **Do not tile-cull directional lights with a sphere around the camera**: radial distance is always
  at least the view depth the fade is keyed on, so such a test rejects tiles the per-pixel check
  accepts and the corners of the frame lose the sun well before the fade starts. Admit every
  directional light, and claim them first so a crowded tile drops lamps rather than the sun.
- Softness follows the `softshadow_angle` convention so both paths agree — but note that a nonzero
  angular distance also puts the **cascade** path onto its PCSS branch and widens every cascade's
  extents, visible in projects that never enable raytracing. The node carries `0.25` itself rather
  than the trace hiding a default behind zero, so the inspector value is what is traced and zero
  means genuinely hard.

### 14. Directional demotion

Cut the sun's remaining shadow map down to what still reads it, as two settings rather than constants.

**Done when:** instrumented, a raytraced sun allocates the directional atlas **zero** times where a
non-raytraced scene allocates it once — 2 MiB at the demoted size, 32 MiB at Godot's default.

- **Both readings of the shadow mode must move together.** `update_light_buffers` read
  `light->directional_shadow_mode` *directly* rather than through the accessor, so overriding the
  accessor alone leaves the culler emitting two cascades while the buffer still computes
  `limit == 3` — split offsets of `(s0, s1, 0, 0)`, a `fade_to` of negative zero, and a smoothstep
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
  them correctly — those are known at compile time (`USE_OPAQUE_PREPASS` /
  `ALPHA_ANTIALIASING_EDGE_USED`) and must skip the runtime test entirely. Alpha scissor and alpha
  hash go through the pre-pass like anything opaque and were never affected.
- The fallback guards move from `shadow_opacity` to `shadow_map_opacity` at the same time.
- **Demonstrating this needs a horizontal pane.** A vertical one edge-on to the sun receives almost
  no direct light, the shadow term is multiplied by nearly nothing, and the bug is invisible. Three
  test scenes each looked like evidence the fix did nothing.

### 16. Fog: the zero-cost variant pattern

Volumetric fog traces its own directional shadow ray per froxel. **This stage is also the reusable
pattern for adding a ray-query variant to an existing shader at no cost to projects that never use
it** — the deferred subsurface-transmittance work should use it, with the structure declared inside
`#ifdef LIGHT_TRANSMITTANCE_USED`.

**Done when:** on a row of slats lit from behind, the fog's luminance at the darkest point of the
shadow reads 74.9 against the shadow-mapped render's 75.4 (it read 183.8 with the shafts missing).

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

- `cam_rotation` only rotates; the structure is world space, so the froxel's view-space position
  needs the camera translation too — hence `cam_position` in the params UBO and the mirrored `vec4`
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
  check, the GDExtension API compatibility check and the export tests with them — but check what
  the surviving platform still runs before claiming a check is gone; this fork's Windows job runs
  the unit tests, and the guide wrongly said otherwise for a while.
- **A green static-check run on a push says nothing about the same check on the pull request.** The
  workflow passes `--from-ref` to pre-commit, and that ref differs by event: a push run compares
  against the previous commit, so it sees only what that push touched, while a pull-request run
  compares against the base branch and therefore re-checks *every* file the branch has changed. A
  fixer hook — `codespell` here, with `write-changes = true` — will happily flag a file from a
  commit twenty pushes ago, and pre-commit fails whenever a hook modifies the tree. Run the hooks
  yourself over `git diff --name-only <base>..HEAD` before opening the PR.
- When you run those hook scripts by hand to reproduce a failure, **filter the file list the way the
  hook config does**. They are fixers, not linters: handing `copyright_headers.py` an unfiltered
  list prepends C-style banners to XML files, and the resulting mess looks exactly like a second and
  third CI failure. `file` reporting a `.xml` as "C source" is the giveaway.

### 18. Ground truth ambient occlusion

Independent of everything above — it touches no raytracing and can be ported on its own, or left
out. Four new files plus about a dozen small hooks.

**Done when:** `docs/rt_shadows/ao_validation/` scores a render inside the numbers in section 9 of
the fork guide, and flipping `Environment.ssao_method` between the two estimators changes what the
frame looks like without changing anything else.

- `effects/gtao.{h,cpp}` and three `shaders/effects/gtao_*.glsl` are new files. `SCsub` globs both
  `*.glsl` and `*.cpp`, so no build file changes; the generated class name follows the file name
  (`gtao_gather.glsl` -> `GtaoGatherShaderRD`).
- The **only** shared state is `RB_SCOPE_SSAO` / `RB_FINAL`, an `R8_UNORM` full resolution texture.
  Create it with exactly the format and usage the legacy path creates it with, and create it only
  if absent. Everything else lives under a private `RB_SCOPE_GTAO`.
- The pass runs from the same site the legacy one does in `_pre_opaque_render`, and must **skip**
  `ss_effects->downsample_depth` when it is the only screen space effect active — that pyramid is
  built for the other estimator and nothing reads it here.
- `environment_set_ssao_method` is a **separate** `RenderingServer` entry point rather than another
  parameter on `environment_set_ssao`, which keeps the existing binding hash intact. The chain is
  the usual five links: `RenderingServer` (pure virtual) -> `RenderingServerDefault` (`FUNC2`) ->
  `RenderingMethod` (pure virtual) -> `RendererSceneCull` (`PASS2`) -> `RendererSceneRender`
  (non-virtual, forwards to `RendererEnvironmentStorage`). Miss the `rendering_method.h` link and
  the error is a pure-virtual instantiation failure far from the change.
- The enum lives in `rendering_server_enums.h` and needs a `VARIANT_ENUM_CAST_EXT` line and a
  `BIND_ENUM_CONSTANT` alongside the existing SSAO quality ones.
- `Environment::_validate_property` hides `ssao_detail`, `ssao_horizon` and `ssao_sharpness` when
  the ground truth estimator will run; the existing `!= "forward_plus"` branch is the natural place
  and its `else` was previously empty.
- Five details are load-bearing, and every one was wrong before it was measured. Each is a steady
  bias that reads as the effect working rather than as a bug, so none will be caught by looking.
  `FINDINGS.md` has the measurements; what a port needs is the list.
  1. The depth pyramid is sampled with a **nearest** sampler, so a sample must be reconstructed at
     the center of the texel its depth came from, not at the position the step asked for.
  2. The per sector weight carries the `|sin t|` Jacobian of the slice parametrization, not the
     sector's share of the arc.
  3. The strength curve scales occlusion as a **ratio**. Subtracting a multiple of the distance
     from white has a hard floor and clips a third of the tonal range to black inside the gather,
     where no filter can recover it. The one-step test: put a flawless traced occlusion through the
     curve and see whether the artifact survives.
  4. The half resolution stride is **passed** in a push constant. `gather_size_for` rounds up and
     integer division rounds down, so recovering it in the shader gives 2 at every even width and 1
     at every odd one, and at an odd width the gather then answers only for the top left quadrant.
     Do not "fix" it by rounding the gather size down instead; that drops the last column at widths
     like 1281.
  5. The upsample inverts the gather's sampling position as `pos / stride`. The obvious
     `(pos + 0.5) * scale - 0.5` assumes the gather texel represents the center of its block and is
     wrong by half a full resolution pixel on each axis.
- One quantity is a function of viewport shape and must be anchored deliberately. Under
  `scale_radius_with_distance` the world reach comes from `uv_to_view_mul`, which on the x axis is
  `2 * tan(fovy/2) * aspect`; a camera holds the VERTICAL field fixed, so anchoring a screen space
  fraction to width makes the effect reach 1.8x further on a 16:9 viewport than on a square one.
  Anchor to height. The fixed-world-radius branch is already aspect invariant and must be left
  alone.
- The denoise is separable and its width is derived on the CPU from the effect radius and the slice
  count, and its weights are plane distances rather than depth differences, so the filter pass needs
  the view space normal and the projection terms bound to it as well as the AO buffer.

---

## Quick reference: the seams that break

Eighteen of the mapped integration points were rated fragile — they depend on a data layout, an
ordering, or a format Godot revises between versions. Check these first.

| Seam | What to verify on the new engine |
| --- | --- |
| `RD::AccelerationStructureGeometry` / `blas_build` | Still carries `vertex_buffer`/`offset`/`stride`/`count`/`format` plus index fields, and `blas_build` is still a full in-place rebuild with no refit. |
| Mesh vertex layout | Positions still a contiguous `float32x3` block at offset 0 ahead of the attribute block; compressed decode still `pos * aabb.size + aabb.position`. |
| `MeshInstance::Surface` (`vertex_buffer[2]`, `current_buffer`, `last_change`) | `last_change` still set on **every** surface `update_mesh_instances()` dispatches, not only on a buffer flip. |
| `LightData` / `DirectionalLightData` trailing `pad[2]` | Still unclaimed padding. If upstream took it, find new space and keep `sizeof` identical. |
| `RENDER_PASS_UNIFORM_SET` bindings 37/38 | Find the new highest binding; renumber C++ and GLSL in lockstep. |
| `_setup_render_pass_uniform_set` | Bindings added on every path, including probe and no-render-buffer renders. |
| `update_light_buffers` | Every early-out preserves both invariants: `rt_slot < RT_SLOT_NONE` iff the light has a channel this frame, `shadow_map_opacity > 0.001` iff an atlas rect or cascade was actually written. |
| `_pre_opaque_render` dispatch site | Depth is resolved before it; the trace is fed `scene_data->get_cam_projection()`, not the raw member. |
| Directional loop in `scene_forward_clustered.glsl` | Re-derive the three-way split by hand; the lightmap shadowmask handling and the fade smoothstep must be hoisted out so both paths run them. |
| Fog `Params` UBO / `ParamsUBO` | `cam_position` at the identical offset on both sides. |
| Fog `ShaderGroup` enum | The four device-capability groups still contiguous and first; `+ SHADER_GROUP_BASE_RAYTRACED` silently maps wrong if a fifth is inserted. |
| `_get_fog_process_variant` | Still `device_group * VOLUMETRIC_FOG_PROCESS_SHADER_MAX + idx`, and the push order matches the enum position-for-position. |
| `RB_SCOPE_SSAO` / `RB_FINAL` format and usage | Still `R8_UNORM` with sampling and storage, and still what the forward shader samples for occlusion. Both estimators write it; if upstream changes it, change both. |
| `Environment::_validate_property` forward_plus branch | The `else` this fork added is still reachable, i.e. upstream has not put its own `return` in front of it. |
| `re-spirv` `SpvIsSupported()` | Still excludes ray-query opcodes so those modules bail out rather than being miscompiled. Watch stderr for the "not supported yet" line. |

---

## How to verify a port

Nothing here needs a real GPU. The original work was validated on **lavapipe** (Mesa's software
Vulkan) under Xvfb, rendering to PNG and comparing with a small Python script.

Know what that distorts: lavapipe traverses the BVH on the CPU, so it **overstates** rasterization
cost and **understates** the benefit of ray early-out. Treat its frame times as directional only.
Image comparisons are trustworthy and reproducible to the byte.

The technique that settled most questions was **RMSE against a high-sample, denoiser-off render of
the same scene** — one sample plus denoiser versus sixteen-sample ground truth. Edge-width metrics
were tried first and proved unreliable, because they were confounded by the two images having
different noise levels.

For "this change costs nothing when unused", the standard is **byte-identical output**: build with
the change and render; stash the change, rebuild, render the same scene; compare checksums. That is
how the fog work was shown to be free.
