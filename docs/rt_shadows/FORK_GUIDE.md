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

**These defaults change how a scene looks even with raytracing disabled.** A non-zero
`light_angular_distance` puts the ordinary cascade path onto its PCSS branch and widens each
cascade's extents. Set the size back to `0.0` for the hard, uniform shadows stock Godot gives you.

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

### The two traps

**Alpha-scissor materials cast the shadow of their whole quad.** Rays are traced with
`gl_RayFlagsOpaqueEXT`, so the cutout is never evaluated. A leaf card casts a rectangle. Give
foliage real geometry, or turn its shadow off, or give that light a shadow map.

**Casters are deliberately not frustum-culled.** Something behind the camera still casts into view —
that is a feature, and it is why shadows do not pop as you turn. It also means the acceleration
structure holds more than what is on screen. Casters are gathered from each light's own volume; the
sun, having no range, uses the visible frustum cut off at the shadow distance and swept toward the
light by `caster_distance_scale`. Above 65,536 gathered casters the rest are dropped with a warning.

---

## 3. What raytraced shadows do not cover

| Area | Behaviour |
| --- | --- |
| `AreaLight3D` | Always shadow maps. |
| XR / multiview | Shadow maps. A stereo pair would need a trace and full denoiser history per eye. |
| Reflection probes | Shadow maps. The acceleration structure is not built during probe passes, and probes render before viewports, so a probe cannot trace. |
| Mobile and Compatibility renderers | Shadow maps. Forward+ only. |
| Subsurface transmittance | **Known gap.** Falls back to the material's own transmittance depth for any raytraced light. `shadow_map_enabled` restores it. |
| Volumetric fog, raytraced `OmniLight3D`/`SpotLight3D` | Lit, but casts no light shafts. `shadow_map_enabled` restores it. |
| Volumetric fog, raytraced `DirectionalLight3D` | **Works.** The fog traces its own ray per froxel. |
| Alpha-blended surfaces | Read the shadow map, not the mask — the mask holds one answer per pixel and it belongs to the opaque surface behind the glass. |
| Light projectors | Unaffected. |

### Side effects of enabling directional raytracing

Turning on `directional/enabled` changes two things for **every** `DirectionalLight3D` in the
project, raytraced or not, because the directional shadow atlas is shared:

- `directional_shadow_mode` set on the node is overridden to 2 splits.
- The atlas is capped at 1024 regardless of `rendering/lights_and_shadows/directional_shadow/size`.

Both are deliberate — what still reads that map does not need cascade density — and both are
configurable via `directional/demoted_shadow_*`. Set the mode to `Keep Authored` and the size to
`0` to disable the demotion.

---

## 4. How it works, in enough detail to reason about cost

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

## 5. Tuning

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

## 6. Diagnostics

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

## 7. Known gaps

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
- **CI runs Windows only.** The Linux jobs that were dropped carried the `--doctool` class reference
  check, the GDExtension API compatibility check, the unit tests, and the export/converter tests.
  If you change a bound property, run `godot --headless --doctool .` yourself and commit the result.
