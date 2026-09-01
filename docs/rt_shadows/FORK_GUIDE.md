# The godot-rt fork: what it changes and how to use it

This engine is Godot 4.8-dev with two additions to the Forward+ renderer: hardware ray-traced
shadows, and a second ambient occlusion estimator. Everything else about Godot is unchanged, so
ordinary Godot knowledge applies — except in the places listed here, where it will actively
mislead you.

Sections 1 to 8 are the shadows. Section 9 is the occlusion; the two are independent and either
can be used without the other.

This document is self-contained. If you are working in a **game project** that uses this engine
rather than in the engine repository, copy this file (or the parts you need) into that project so
your assistant has it.

Upstream base: `b56a91878e7c94977e4af978968e41d0670c0a8b`. Everything after it is fork work.

---

## 1. Differences from vanilla Godot

### 1.1 Node defaults

A `.tscn` records only the properties that differ from a freshly constructed node. These defaults
are therefore what a new node *is*, not something you can look up in project settings — and a scene
authored here carries them implicitly.

| Property | Vanilla Godot | This fork |
| --- | --- | --- |
| `OmniLight3D.shadow_enabled` | `false` | **`true`** |
| `SpotLight3D.shadow_enabled` | `false` | **`true`** |
| `OmniLight3D.light_size`, `SpotLight3D.light_size` | `0.0` | **`0.05`** |
| `DirectionalLight3D.light_angular_distance` | `0.0` | **`0.25`** |
| `light_angular_distance` inspector range | `0–90`, step `0.01` | `0–5` or greater, step `0.001` |

Set in `Light3D::_apply_local_light_shadow_defaults()` and the `DirectionalLight3D` constructor.

Why they are unconditional rather than keyed to the raytracing setting: because a scene stores only
non-default values, a default that depended on a project setting would never be recorded, and a
scene authored with raytracing on would silently lose every light's shadow the moment it was off.

**These defaults change how a scene looks and what it costs even with raytracing disabled, in every
renderer.** Four consequences, none of them obvious:

- A non-zero `light_angular_distance` puts the ordinary cascade path onto its PCSS branch and widens
  each cascade's extents.
- `ProceduralSkyMaterial` and `PhysicalSkyMaterial` read the same property as the sun's angular
  diameter, so **a default `DirectionalLight3D` now draws a visible sun disk** where vanilla draws
  none.
- `LightmapGI` bakes read it too, so **bakes are now soft-shadowed and slower** by default.
- Every mesh lit by a default `OmniLight3D` or `SpotLight3D` now compiles and runs the
  `use_light_soft_shadows` shader specialization, on Forward+ and Mobile alike.

Set the size back to `0.0` for the hard, uniform, cheaper behavior stock Godot gives you.

### 1.2 New API

| Symbol | What it does |
| --- | --- |
| `Light3D.shadow_map_enabled` (bool, default `false`) | Render a shadow map for this light *even though* it takes its shadow from the raytraced mask. Buys back volumetric fog shafts and subsurface transmittance for that light, at the cost of an atlas quadrant and a shadow map render. |
| `RenderingServer.light_set_shadow_map_enabled(light, enabled)` | The server-level equivalent. |
| `Environment.ssao_method` (enum, default `SSAO_METHOD_DEFAULT`) | Which estimator fills the occlusion buffer for this environment. See section 9. |
| `RenderingServer.environment_set_ssao_method(env, method)` | The server-level equivalent. |

Nothing was removed or renamed.

### 1.3 Project settings

All under `rendering/lights_and_shadows/raytraced_shadows/`.

| Setting | Default | What it does |
| --- | --- | --- |
| `enabled` | `false` | Master switch. `OmniLight3D` and `SpotLight3D` take their shadows from the raytraced mask. |
| `samples_per_light` | `1` | Shadow rays per pixel per light per frame. Rays past the second are only traced where the first two disagree, so 1 → 2 is the step that costs. |
| `max_ray_distance` | `0.0` | Extra clamp on ray length. `0.0` = no additional limit. |
| `accurate_occluder_distance` | `true` | Find the *closest* occluder rather than the first one hit. Changes no shadow's shape, only how wide the denoiser is allowed to filter. |
| `denoiser/enabled` | `true` | The denoiser keeps its own temporal history and does not need TAA — it works with SMAA, FXAA or nothing. |
| `denoiser/spatial_passes` | `3` | Edge-stopping wavelet passes. Each doubles the filter's reach at roughly constant cost. |
| `denoiser/temporal_frames` | `32` | Frames blended over. History is discarded on disocclusion, so this does not cause trailing. |
| `denoiser/min_filter_pixels` | `1.0` | Narrowest the spatial filter may work where a penumbra was measured. At ≤1 px it switches off at a hard edge, which is what keeps contact shadows crisp. |
| `denoiser/history_clamp_sigma` | `2.0` | How far reprojected history may sit outside this frame's local spread before being pulled back. This is what stops a *moving* shadow trailing across a *stationary* surface. `0.0` disables. |
| `directional/enabled` | `false` | `DirectionalLight3D` also takes its shadow from the mask. Requires `enabled`. |
| `directional/caster_distance_scale` | `2.0` | How far past the shadow distance geometry is still gathered as a sun caster. Raising it lets distant landmarks cast onto ground you walk on; it costs proportionally more geometry, which slows *every* ray in the frame. |
| `directional/scatter_casters` | `Near Camera` | Whether MultiMesh/GridMap geometry casts sun shadows: `Disabled` / `Near Camera` / `Full Distance`. |
| `directional/scatter_distance` | `25.0` | The radius for `Near Camera`. |
| `directional/demoted_shadow_mode` | `2 Splits` | What a raytraced sun's `directional_shadow_mode` is replaced with. |
| `directional/demoted_shadow_size` | `1024` | Upper bound on the directional shadow atlas once raytraced directional shadows are available. |

**All of these are live except the master `enabled` flag.** Change one in the inspector, or from a
script with `ProjectSettings.set_setting()`, and the renderer picks it up on the next frame — no
restart. Most are read through `GLOBAL_GET_CACHED`, which keeps a typed copy and re-reads only when
`ProjectSettings` bumps its version, so the steady state costs an integer compare rather than a
string lookup.

Each is clamped on read, because a live value arrives straight from the inspector and several
property hints allow `or_greater`.

Three of them are instead snapshotted once per frame, in `RaytracingScene::update_frame_settings()`,
called from `RendererSceneRenderRD::update()` before any viewport draws — the same place Godot
snapshots its own per-frame rendering settings:

- `directional/enabled`
- `directional/demoted_shadow_mode`
- `directional/demoted_shadow_size`

All three decide how many cascades a sun gets and how big the atlas holding them is, and that has to
be the same answer for the culler, the atlas layout and the light buffer, which run at three
different points in a frame. Read on demand they could disagree within one frame and put cascades in
the wrong atlas rects. Snapshotting costs them up to one frame of latency and nothing else.

**`enabled` is the one that cannot ever be live.** `MeshStorage::mesh_add_surface` decides a vertex
buffer's creation bits at upload time, before the rendering device or the renderer exist, so a mesh
uploaded while the setting was off has no buffer an acceleration structure could be built from.
Re-reading the value would only produce build failures against buffers that can never satisfy it.

Requires Forward+, the Vulkan driver, and a GPU with ray query support. Without ray query it prints
a warning and every light falls back to shadow maps, so a project stays playable.

---

## 2. Authoring: what casts a raytraced shadow

An object must pass all of these:

1. **Visible.** `instance->visible`, and `cast_shadows != SHADOW_CASTING_SETTING_OFF`.
2. **Mesh- or multimesh-backed.** `INSTANCE_MESH` or `INSTANCE_MULTIMESH` only. That includes
   `MeshInstance3D`, `MultiMeshInstance3D`, `CSGShape3D`, `CPUParticles3D` and `GridMap`.
   **`GPUParticles3D` casts nothing.** (`Sprite3D` and `Label3D` are mesh-backed and so pass this
   test, but their default transparent material fails the next one.)
3. **A material Godot already considers a caster.** The same test the shadow map path makes, so
   glass and shaders that discard depth do not start casting solid shadows just because the light
   became raytraced. Per-surface, via `shadow_caster_surface_mask`.
4. **Triangle surfaces with 3D positions.** Non-triangle primitives, 2D vertex arrays and empty
   vertex arrays are skipped, with a one-time warning naming how many surfaces were dropped.

Compressed (16-bit) vertex positions are *not* a blocker — they are expanded by a dequantize pass
into a raytracing-legal buffer.

### Five traps

**Alpha-scissor materials cast the shadow of their whole quad.** Rays are traced with
`gl_RayFlagsOpaqueEXT`, so the cutout is never evaluated. A leaf card casts a rectangle. Give
foliage real geometry, or turn its shadow off, or give that light a shadow map.

**Anything a vertex shader does is invisible to the shadow.** The acceleration structure is built
from the mesh's *stored* vertices at the node's *authored* transform. So a `BaseMaterial3D` with
`billboard_mode` set, a `Sprite3D` / `AnimatedSprite3D` / `Label3D`, a `fixed_size` or `grow`
material, and any custom shader whose `vertex()` moves geometry all cast a shadow of geometry that
is not where you see it. Skinning and blend shapes are the exception — those run in a compute
pre-pass whose output the structure reads, so they are correct.

**Mesh LODs and `ArrayMesh.shadow_mesh` are ignored.** The full-detail LOD 0 index buffer is always
traced, so `mesh_lod_threshold` and a cheap shadow proxy do not reduce raytraced shadow cost the way
they reduce shadow-map cost.

**A mesh updated in place keeps its old shadow.** The structure for a static surface is cached on
`(mesh RID, surface index)` and only *skinned* surfaces carry a version check
(`mesh_instance_get_last_change`). So `ArrayMesh.surface_update_vertex_region()`, an `ImmediateMesh`
rewritten into the same buffers, or any equivalent in-place vertex edit leaves the shadow frozen at
the geometry the structure was first built from. Replacing the surface outright — `clear_surfaces()`
and re-add, which is what `PrimitiveMesh` does on any property change — allocates a new buffer and
is handled correctly.

**Casters are deliberately not frustum-culled.** Something behind the camera still casts into view —
that is a feature, and it is why shadows do not pop as you turn. It also means the acceleration
structure holds more than what is on screen. Casters are gathered from each light's own volume; the
sun, having no range, uses the visible frustum cut off at the shadow distance and swept toward the
light by `caster_distance_scale`. Above 65,536 gathered casters the rest are dropped with a warning.

### Masks behave differently

`shadow_caster_mask` and `VisualInstance3D.layers` are 32-bit, but a ray query's instance mask is
8-bit. The fork folds 32 down to 8 by OR-ing the four bytes, which is conservative — it never
excludes something it should include — but it means **layers 9–32 alias onto layers 1–8**. A mask
that would separate layer 1 from layer 9 under shadow maps will not separate them here.

A fold that comes out zero is promoted to `0xFF`. So a `shadow_caster_mask` of 0, which under shadow
maps means "nothing casts", means **everything casts** here.

`Light3D.shadow_reverse_cull_face` has no effect on a raytraced shadow: the mask is per-scenario
while that setting is per-light, so triangle facing is never culled. For the same reason
`GeometryInstance3D.cast_shadow = ON` and `DOUBLE_SIDED` behave identically.

---

## 3. Vanilla knobs that stop doing anything

This is the fastest way to waste an afternoon. On a light that is actually raytraced, everything
that tunes a shadow *map* is inert, because no map is rendered:

| You reach for | It does | Reach for instead |
| --- | --- | --- |
| `Light3D.shadow_blur` | nothing | `light_size` / `light_angular_distance` |
| `positional_shadow/atlas_size` and its quadrant subdivisions | nothing | — (no atlas quadrant is claimed) |
| `positional_shadow/soft_shadow_filter_quality` | nothing | `denoiser/spatial_passes`, `denoiser/min_filter_pixels` |
| `directional_shadow/size` | capped to 1024 | `directional/demoted_shadow_size` |
| `directional_shadow/soft_shadow_filter_quality` | nothing | `samples_per_light` |
| `DirectionalLight3D.directional_shadow_mode` | overridden to 2 splits | `directional/demoted_shadow_mode` |
| `Light3D.shadow_bias` / `shadow_normal_bias` | rescaled into ray `tmin` and a world-space normal offset in meters — same properties, very different magnitudes | tune by eye, not by shadow-map intuition |

Setting the positional atlas size to 0 no longer removes positional shadows either.

Softness comes from the light's physical size; noise comes from `samples_per_light` and the
denoiser. If a shadow looks wrong, that is the axis to move along.

---

## 4. What raytraced shadows do not cover

| Area | Behavior |
| --- | --- |
| `AreaLight3D` | Always shadow maps. |
| XR / multiview | Shadow maps — but the acceleration structure is still built and the depth pre-pass still forced, so an XR project pays the cost and gets nothing. |
| Reflection probes | Shadow maps. The acceleration structure is not built during probe passes, and probes render before viewports, so a probe cannot trace. |
| Mobile and Compatibility renderers | Shadow maps. Forward+ only. |
| Subsurface transmittance | **Known gap.** Falls back to the material's own transmittance depth for any raytraced light. `shadow_map_enabled` restores it. |
| Volumetric fog, raytraced `OmniLight3D`/`SpotLight3D` | Lit, but casts no light shafts. `shadow_map_enabled` restores it. |
| Volumetric fog, raytraced `DirectionalLight3D` | **Works.** The fog traces its own ray per froxel. Note that ray is culled by the light's `cull_mask`, not its `shadow_caster_mask` — an inconsistency with the surface path. |
| Alpha-blended surfaces | **Receive no shadow at all** from a raytraced light. They cannot read the mask (it holds one answer per pixel, belonging to the opaque surface behind the glass) and there is no map to fall back to. |
| Materials with `depth_draw_never` or `depth_test_disabled` | Cast a raytraced shadow where vanilla casts none, and never receive one. |
| Light projectors | Unaffected. |
| SDFGI, VoxelGI, LightmapGI, decals | Unaffected by the raytraced path itself — but see the note on lightmap bake times below. |

### The four-light ceiling

The mask is one RGBA8 texel per pixel, so **at most four raytraced lights are shadowed at any one
pixel**. Where more overlap, the four contributing most light there win. The losers are not
degraded — they are rendered **fully unshadowed at that pixel, with no shadow-map fallback**. In
practice this is only visible where five or more shadow-casting lights genuinely overlap on the same
surface. Up to 255 raytraced lights may exist in a frame overall.

A light faded out by `distance_fade` still holds its mask slot and still costs trace work.

### Side effects of enabling directional raytracing

Turning on `directional/enabled` changes two things for **every** `DirectionalLight3D` in the
project, raytraced or not, because the directional shadow atlas is shared:

- `directional_shadow_mode` set on the node is overridden to 2 splits.
- The atlas is capped at 1024 regardless of `rendering/lights_and_shadows/directional_shadow/size`.

Both are deliberate — what still reads that map does not need cascade density — and both are
configurable via `directional/demoted_shadow_*`. Set the mode to `Keep Authored` and the size to
`0` to disable the demotion.

---

## 5. How it works, in enough detail to reason about cost

**Per frame, in order:**

1. **Gather casters.** For each raytraced light, query the scenario's geometry index with that
   light's bounds. Not frustum-culled. MultiMesh elements are culled individually so one large
   GridMap octant cannot flood the structure.
2. **Build the acceleration structure.** Per-surface BLAS entries are cached and reused; the TLAS is
   rebuilt only when it stops describing the scene. Skinned meshes are skinned first, including
   off-screen ones, so a character behind the camera does not cast a stale pose.
3. **Depth pre-pass with normal/roughness.** Forced on whenever raytracing is available — the trace
   needs both. This is the main unconditional cost of turning the feature on.
4. **Trace.** One compute dispatch. Per 8×8 tile, cull the lights that reach it; per pixel, keep the
   four contributing the most light; trace `samples_per_light` rays each — all of them, with the
   emitter sampled as a Vogel disk whose radius is jittered per frame. Writes an RGBA8 visibility
   mask, an RGBA8 hit-distance (penumbra width in pixels), and an RGBA8UI index saying which light
   each channel belongs to.
5. **Denoise.** Temporal reprojection with variance clamping — floored by the standard error the
   ray counts carry, so it cannot pin a penumbra's shallow ends to a binary answer, and shortening
   the accumulation window in proportion to how far it had to correct the history — then N
   edge-stopping à-trous passes whose reach is driven by the measured penumbra width. The
   accumulator's 8-bit store is dithered, because it re-reads its own rounded output every frame.
6. **Volumetric fog**, which traces its own ray per froxel for a raytraced sun.
7. **Forward pass** samples the mask instead of the shadow atlas.

**Cost model.** It scales with how many raytraced lights *overlap a pixel*, not how many the scene
contains — where more than four overlap, the four brightest at that pixel are shadowed and the rest
are unshadowed there. Up to 255 raytraced lights may exist in a frame. Shadow maps are not rendered
for raytraced lights at all, so a scene can hold far more shadow-casting lights than the atlas has
room for.

Visibility is stored as its square root and squared on read, spending more of the 8-bit range on the
dark end where a shadow's detail is.

### Where the code lives

| Concern | Files |
| --- | --- |
| Acceleration structure, settings accessors | `servers/rendering/renderer_rd/environment/rt_scene.{h,cpp}` |
| Trace and denoiser passes | `servers/rendering/renderer_rd/effects/rt_shadows.{h,cpp}` |
| Shaders | `servers/rendering/renderer_rd/shaders/effects/rt_shadow_{trace,temporal,atrous}.glsl`, `rt_dequantize.glsl` |
| Which lights are raytraced, mask slots, demotion | `servers/rendering/renderer_rd/storage_rd/light_storage.{h,cpp}` |
| Caster gathering, skipping shadow map renders | `servers/rendering/renderer_scene_cull.cpp` |
| Frame integration | `servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp` |
| Forward shading | `servers/rendering/renderer_rd/shaders/scene_forward_lights_inc.glsl`, `forward_clustered/scene_forward_clustered.glsl` |
| Fog | `servers/rendering/renderer_rd/environment/fog.{h,cpp}`, `shaders/environment/volumetric_fog_process.glsl` |

---

## 6. Tuning

Start with the defaults. In order of what actually moves the picture:

At the defaults the shadow's width is the width the geometry calls for. Measured against a
closed-form ground truth — a lamp of known radius over a post of known size, in a scene where the
50% crossing of the shadow edge lands within a pixel of the analytic answer at every distance — the
10-90 penumbra comes out at 17/28/38/47/55/51/52 pixels where the geometry asks for
16.3/26.2/36.0/45.9/51.5/51.5/51.5, and at sixteen samples per light it reproduces it exactly. So
softness is a property of the light, not of the denoiser, and these are the knobs in order of what
actually moves the picture:

- **Shadow softness** is `light_size` (lamps, in meters, a radius) and `light_angular_distance` (the
  sun, in degrees). Godot treats the latter as the disk's angular radius, so the default `0.25°`
  gives about 94% of the real sun's penumbra despite the class reference quoting `0.5` for the sun.
- **Too soft at contact?** Lower `denoiser/min_filter_pixels`. At or below `1.0` the filter switches
  off entirely at a hard edge, so `1.0` and `0.0` render identically.
- **Shadow trails behind a moving object?** Lower `denoiser/history_clamp_sigma`. `2.0` cuts
  ghosting to nothing; what is left after a blocker moves is its new shadow still filling in, not
  its old one lingering.
- **Grainy in wide penumbrae?** Raise `samples_per_light`, or `denoiser/spatial_passes`. Samples now
  cost what they say: every one is traced. They converge on the same shadow, only with less noise.
- **Slow in an open outdoor scene?** Lower `directional/caster_distance_scale`, or set
  `directional/scatter_casters` to `Disabled`.

All of these take effect on the next frame.

---

## 7. Diagnostics

Set `GODOT_RT_DEBUG=1` in the environment. Each frame prints, when it changes:

```
RT_DEBUG cull:       how many instances were visited and how many became casters
RT_DEBUG update:     TLAS instance count, BLAS cache size, skipped and deferred surfaces
RT_DEBUG shadows:    how many lights are raytraced, and how many shadow maps still rendered
RT_DEBUG pre_opaque: whether the mask ran, how many lights took slots, whether a TLAS exists
RT_DEBUG cpu:        what this path costs the CPU, averaged over 120 frames
```

`shadow_maps_rendered=0` with `raytraced=N` is what a fully raytraced scene looks like.
`skipped_surfaces>0` means geometry was rejected as un-raytraceable.

The `cpu` line is the one to read when the frame is CPU-bound rather than GPU-bound, which is what
this path is most likely to cost you in a large scene. It separates two halves that scale with
different things:

- **gather** — finding which of the scene's instances are within reach of a raytraced light. Grows
  with how much world is inside those volumes, so it is the half that grows with level size and with
  the sun's shadow distance.
- **build** — turning those casters into acceleration structures. Grows with the caster count, and
  spikes on the frame that first builds them (the peak figure, not the average, is what you feel).

### Making it cheaper

Measured in a deliberately hostile scene — three thousand props over a 200 m field, sixteen lamps of
25 m range, a raytraced sun and a spotlight on the camera — on a slow CPU:

| Change | RT CPU per frame |
| --- | --- |
| As described above | 1.28 ms |
| `DirectionalLight3D.directional_shadow_max_distance` 100 → 50 | 0.99 ms |
| ...→ 25 | 0.54 ms |
| Raytraced sun off entirely | 0.45 ms |
| `directional/caster_distance_scale` 2.0 → 0.5 | 1.12 ms |

Lamps whose bounds already sit inside the sun's caster volume are not queried separately, so in a
scene where the sun reaches everything the lamps are close to free to gather. That is automatic;
there is nothing to set.

**The raytraced sun is two thirds of the cost, and the sun's shadow distance is the lever, not
`caster_distance_scale`.** A lamp bounds its own casters with its range; a sun has no range, so the
volume swept for it is the camera frustum out to the shadow distance, pushed back toward the light.
Shortening the shadow distance shrinks that volume in every direction at once, which is why halving
it does far more than quartering the sweep. If a raytraced sun is costing more than you want, set
`directional_shadow_max_distance` to the distance you actually need shadows at, before reaching for
anything else.

---

## 8. Known gaps

- **Subsurface transmittance** still reads the cascade map (task deferred). The fix is the same
  shape as the fog one: trace toward the light instead of range-finding in the cascade, with the
  acceleration structure declared inside `#ifdef LIGHT_TRANSMITTANCE_USED` so non-SSS shader
  variants never carry the ray-query capability.
- **A setting changed mid-frame is seen mid-frame.** The live settings are re-read the moment
  `ProjectSettings` changes, so a change that lands between the culler's decision and the light
  buffer's can leave them disagreeing for one frame. Only `demoted_shadow_mode` has a visible
  failure mode (cascades briefly in the wrong atlas rects); the rest degrade to a one-frame stale
  value. Snapshotting the whole set once per frame would remove even that.
- **A light that loses the four-channel per-pixel competition is unshadowed at that pixel**, with no
  shadow map fallback.
- **The per-instance directional caster cull runs before the raytraced decision**, so reordering it
  risks double-spending the mask slot budget.
- **Orthogonal cameras are not handled well, in two places.** The penumbra width is converted to
  pixels with a perspective formula (`penumbra_world * focal_pixels / view_distance`), which under
  an orthogonal projection collapses towards zero — the spatial denoiser then sees no penumbra and
  switches itself off, leaving only temporal accumulation, so shadows look noisy. Separately, the
  directional caster gather ignores `directional_shadow_max_distance` for an orthogonal camera and
  sizes the caster volume from `Camera3D.far` instead, which defaults to 4000. An isometric or 2.5D
  project will feel both of these. Neither is hard to fix; neither has been.
- **The fog's shadow ray is culled by the light's `cull_mask`**, where the surface trace uses
  `shadow_caster_mask`. The two should agree.
- **The first frame that has both volumetric fog and a raytraced sun stalls** while two shader
  variants compile. That is the price of not compiling them for projects that never need them.
- **A `MultiMesh` populated through `multimesh_set_buffer` is read back from the GPU** the first time
  it is a raytraced caster, and pays a CPU cache sync on every upload thereafter. Its per-element
  cost is also paid every frame on the render thread; `visible_instance_count` is the only property
  that shrinks it.
- **CI runs Windows only.** The Linux jobs that were dropped carried the `--doctool` class reference
  check, the GDExtension API compatibility check, and the export/converter tests. Unit tests are
  not among them — the Windows job runs `--test` itself.
  If you change a bound property, run `godot --headless --doctool .` yourself and commit the result.

---

## 9. Ambient occlusion

The fork adds a second estimator behind Godot's existing occlusion buffer. It writes the same
texture the stock one does, so everything downstream — the occlusion the forward shader multiplies
ambient light by, light affect, specular occlusion — keeps working without knowing which one ran.

It is **off by default**: `rendering/environment/ssao/method` ships as `Screen Space (Legacy)`, and
an `Environment` with `ssao_method` left at `Project Default` follows it. A project that has never
heard of any of this behaves exactly as it did.

### 9.1 What it is

Slice-based horizon marching (Jimenez et al., GTAO, 2016) with a **visibility bitmask** (Therrien,
Levesque and Gilet, 2023). The difference from a horizon march is what a slice remembers. A horizon
march keeps one angle per side and treats everything past the first occluder as solid; this keeps a
32 sector occupancy mask over the slice's half turn, and each sample marks the range of sectors
between its front face and a back face pushed a fixed distance behind it. Two occluders with sky
between them stay two occluders, and a thin surface stops occluding once the march passes behind it.

That distinction is the whole point, and it is worth knowing when it pays. Measured against a CPU
ray trace of the real geometry (mean absolute error / correlation, lower and higher being better):

| scene | bitmask | bitmask off | legacy |
| --- | --- | --- | --- |
| thin geometry — a louvre, a standing fin, a table on thin legs | **0.0134 / 0.947** | 0.0346 / 0.875 | 0.0433 / 0.845 |
| solid boxes | 0.0307 / 0.796 | **0.0235 / 0.859** | 0.0515 / 0.693 |

The mask wins decisively wherever geometry is thin and loses slightly where it is thick, because on
solid convex shapes "everything behind the first occluder is also occluded" happens to be true. Both
beat the legacy estimator everywhere. The harness that produced those numbers is in
`docs/rt_shadows/ao_validation/`, and re-running it is the way to check a change rather than
arguing about a screenshot.

### 9.2 Turning it on

Either globally, with `rendering/environment/ssao/method = Ground Truth`, or per environment, with
`Environment.ssao_method`. The per-environment setting exists so two environments in one project can
be compared directly; `Project Default` on an environment means "follow the project setting", which
is why old scenes are unaffected.

`Environment.ssao_enabled`, `ssao_radius`, `ssao_intensity` and `ssao_power` mean the same thing to
both estimators. `ssao_detail`, `ssao_horizon` and `ssao_sharpness` describe the legacy one only and
the inspector hides them once the other is selected. `rendering/environment/ssao/half_size` and the
fade distances apply to both; `quality` and `adaptive_target` do not.

### 9.3 The settings that are actually worth touching

Under `rendering/environment/ssao/ground_truth/`.

| Setting | Default | What it is for |
| --- | --- | --- |
| `scale_radius_with_distance` | `true` | Hold the march to a fixed share of the screen rather than a fixed distance in the world. Without it the on-screen span shrinks as a surface recedes until the steps land on the same texel and the occlusion disappears. This is what buys coverage at distance, and it is why it is on. |
| `screen_radius` | `0.05` | The share of screen width that span covers. `Environment.ssao_radius` multiplies it. |
| `thickness` | `0.3` | How far behind a sample its back face sits, as a fraction of the effect radius. The one genuine tradeoff: raise it toward `1.0` for scenes of thick solid shapes, lower it for foliage, railings and slats. `0.3` is the joint optimum measured across both test scenes. |
| `visibility_bitmask` | `true` | Off falls back to horizon behavior. Worth a look on a scene that is all solid geometry; not worth it otherwise. |
| `slices` / `steps_per_slice` | `4` / `8` | The whole sample budget, and cost is linear in both. Raising `steps_per_slice` mostly buys the far half of the march. |

### 9.4 Things to know before you are surprised

- **Forward+ and single view only.** A stereo or XR viewport silently falls back to the legacy
  estimator, because the occlusion buffer is a layer per eye and the gather has no notion of a
  second one.
- **The half resolution setting is genuinely free of consequence here.** Every world space quantity
  the gather uses is derived from the full resolution pixel footprint, so halving the resolution
  changes how many pixels get their own answer and nothing else. Measured, half and full differ by
  0.06 of 255 on average, with under a tenth of a percent of pixels differing by more than 10.
- **The step spacing is even, not quadratic.** A horizon march can crowd its steps near the shaded
  point because one early hit stands in for everything behind it; a mask cannot, so an occluder
  falling between two steps is absent rather than approximated. This is why `steps_per_slice`
  matters more here than the same number would in a stock GTAO.
- **Contact on thick solid geometry reads about 0.03 too bright**, and roughly a third of that is
  inherent to screen space rather than to this implementation — a reference that only sees what the
  camera sees misses the same occlusion. `thickness` is the knob.
- **Switching an environment back to the legacy estimator releases the depth pyramid**, which is a
  full resolution float target with mips. Switching between them per frame would thrash it.

### 9.5 Where the code lives

| File | What it does |
| --- | --- |
| `servers/rendering/renderer_rd/effects/gtao.{h,cpp}` | The pass driver: buffer sizing, push constants, the four dispatches. |
| `shaders/effects/gtao_prefilter.glsl` | Linear view depth pyramid, five mips, biased toward the *farthest* of each quad. Deliberately not the pyramid the other screen space effects build, which is deinterleaved, half resolution based, and biased the other way. |
| `shaders/effects/gtao_gather.glsl` | The march and the bitmask resolve. |
| `shaders/effects/gtao_filter.glsl` | A 3x3 edge-aware denoise at gather resolution, then a depth-guided upsample into the shared occlusion buffer. |
| `render_forward_clustered.cpp` | `_use_gtao`, `_ensure_gtao_buffers`, `_process_gtao`, and the branch that skips the legacy depth downsample when this is the only screen space effect running. |
