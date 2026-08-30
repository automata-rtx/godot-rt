# The godot-rt fork: what it changes and how to use it

This engine is Godot 4.8-dev with hardware ray-traced shadows added to the Forward+ renderer.
Everything else about Godot is unchanged, so ordinary Godot knowledge applies — except in the
places listed here, where it will actively mislead you.

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

Set the size back to `0.0` for the hard, uniform, cheaper behaviour stock Godot gives you.

### 1.2 New API

| Symbol | What it does |
| --- | --- |
| `Light3D.shadow_map_enabled` (bool, default `false`) | Render a shadow map for this light *even though* it takes its shadow from the raytraced mask. Buys back volumetric fog shafts and subsurface transmittance for that light, at the cost of an atlas quadrant and a shadow map render. |
| `RenderingServer.light_set_shadow_map_enabled(light, enabled)` | The server-level equivalent. |

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

**Every one of these is read once at startup and cached for the process lifetime**
(`RaytracingScene::register_settings`, guarded by a `settings_registered` flag). Changing one at
runtime does nothing until restart, including the thirteen the editor does not label
restart-required.

For `enabled` there is a deeper reason than the cache: `MeshStorage::mesh_add_surface` decides a
vertex buffer's creation bits at upload time, before the rendering device or the renderer exist. A
mesh uploaded while the setting was off has no buffer an acceleration structure can be built from,
so turning the setting on mid-session could not work even if the value were re-read.

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
| `Light3D.shadow_bias` / `shadow_normal_bias` | rescaled into ray `tmin` and a world-space normal offset in metres — same properties, very different magnitudes | tune by eye, not by shadow-map intuition |

Setting the positional atlas size to 0 no longer removes positional shadows either.

Softness comes from the light's physical size; noise comes from `samples_per_light` and the
denoiser. If a shadow looks wrong, that is the axis to move along.

---

## 4. What raytraced shadows do not cover

| Area | Behaviour |
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
   four contributing the most light; trace `samples_per_light` rays each. Writes an RGBA8 visibility
   mask, an RGBA8 hit-distance (penumbra width in pixels), and an RGBA8UI index saying which light
   each channel belongs to.
5. **Denoise.** Temporal reprojection with variance clamping, then N edge-stopping à-trous passes
   whose reach is driven by the measured penumbra width.
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

- **Shadow softness** is `light_size` (lamps, in meters) and `light_angular_distance` (the sun, in
  degrees). A real sun is about `0.5°`; the default `0.25°` is half that. Both are live-editable.
- **Too soft at contact?** Lower `denoiser/min_filter_pixels`. At or below `1.0` the filter switches
  off entirely at a hard edge.
- **Shadow trails behind a moving object?** Lower `denoiser/history_clamp_sigma`. `2.0` cuts
  ghosting by roughly 85% against no clamp; lower reacts faster and accumulates less.
- **Grainy in wide penumbrae?** Raise `samples_per_light` to `2`, or `denoiser/spatial_passes`.
  Raising samples above 2 is close to free but rarely changes much.
- **Slow in an open outdoor scene?** Lower `directional/caster_distance_scale`, or set
  `directional/scatter_casters` to `Disabled`.

Remember these all need an engine restart to take effect.

---

## 7. Diagnostics

Set `GODOT_RT_DEBUG=1` in the environment. Each frame prints, when it changes:

```
RT_DEBUG cull:       how many instances were visited and how many became casters
RT_DEBUG update:     TLAS instance count, BLAS cache size, skipped and deferred surfaces
RT_DEBUG shadows:    how many lights are raytraced, and how many shadow maps still rendered
RT_DEBUG pre_opaque: whether the mask ran, how many lights took slots, whether a TLAS exists
```

`shadow_maps_rendered=0` with `raytraced=N` is what a fully raytraced scene looks like.
`skipped_surfaces>0` means geometry was rejected as un-raytraceable.

---

## 8. Known gaps

- **Subsurface transmittance** still reads the cascade map (task deferred). The fix is the same
  shape as the fog one: trace toward the light instead of range-finding in the cascade, with the
  acceleration structure declared inside `#ifdef LIGHT_TRANSMITTANCE_USED` so non-SSS shader
  variants never carry the ray-query capability.
- **Raytraced settings are all restart-required**, but only `enabled` and `directional/enabled` are
  registered `GLOBAL_DEF_RST`, so the editor does not say so for the other thirteen.
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
