# Raytraced Shadows

Settings, what casts, what is not covered, the ceilings, tuning. Not here: passes and code structure
(`docs/internals/rt-shadows.md`); symptom-first diagnosis (`docs/TROUBLESHOOTING.md`); the
measurements behind the tuning (`docs/HISTORY.md`).

## Turning it on

| Step | Setting |
| --- | --- |
| Lamps (`OmniLight3D`, `SpotLight3D`) | `rendering/lights_and_shadows/raytraced_shadows/enabled` |
| Sun (`DirectionalLight3D`) | additionally `.../raytraced_shadows/directional/enabled` |

| Requirement / effect | Detail |
| --- | --- |
| **Forward+**, **Vulkan**, **ray query** support | Without it a startup `WARN_PRINT` ("...does not support hardware ray queries. Falling back to shadow maps.") and every light uses shadow maps, so a project stays playable (`rt_scene.cpp:192-205`). |
| `enabled` is **restart-required** (`GLOBAL_DEF_RST_BASIC`) | Could not be live anyway: `MeshStorage::mesh_add_surface` fixes a vertex buffer's creation bits at upload, so a mesh loaded while it was off has nothing to build a structure from. |
| Every other `raytraced_shadows/*` setting is **live** | Next frame, inspector or `set_setting()`. |
| `directional/enabled`, `directional/demoted_shadow_mode`, `directional/demoted_shadow_size` are live but **snapshotted once per frame** | A sun's cascade count must be one answer for the culler, the atlas layout and the light buffer, which run at three points in a frame. One frame stale at worst. |
| **Forces the depth pre-pass on** (`render_forward_clustered.cpp:2706`) | The trace reads depth and normal/roughness. The main unconditional cost. |
| `directional/enabled` demotes **every** `DirectionalLight3D`, raytraced or not | The directional shadow atlas is shared: `directional_shadow_mode` overridden to **2 splits**, atlas capped at **1024** whatever `rendering/lights_and_shadows/directional_shadow/size` says. What still draws into it once the mask drives opaque shading needs no cascade density (see "What is not covered"). Undo: `demoted_shadow_mode = Keep Authored`, `demoted_shadow_size = 0`. |

## Node defaults and new API

New lights cast soft, contact-hardening shadows unconfigured; the defaults table and its four
non-shadow consequences are in `CLAUDE.md`. Back to `0.0` for hard shadows. Written by
`Light3D::_apply_local_light_shadow_defaults()` (`light_3d.cpp:698`) and the `DirectionalLight3D`
constructor (`light_3d.cpp:644`). Unconditional rather than keyed to the raytracing setting
**because a scene records only non-default values**: a default depending on a project setting would
never be recorded, and a scene authored with raytracing on would silently lose every light's shadow
the moment it was off.

Nothing removed or renamed. One property added: `Light3D.shadow_map_enabled` (bool, default
`false`), server-side `RenderingServer.light_set_shadow_map_enabled(light, enabled)`. Renders a
shadow map for a light taking its shadow from the mask — an atlas quadrant plus a shadow map render
— helping only the three cases under "What is not covered" that read a map and find none.

## Project settings

Under `rendering/lights_and_shadows/raytraced_shadows/`, verified against
`core/config/project_settings.cpp:1840-1908`. Each clamped on read: a live value arrives straight
from the inspector and several hints allow `or_greater`.

| Setting | Default | Hint / range | What it does |
| --- | --- | --- | --- |
| `enabled` | `false` | bool, **restart** | Master switch for `OmniLight3D` / `SpotLight3D`. |
| `samples_per_light` | `1` | `1,16,1` | Shadow rays per pixel per light per frame. Every one is traced; cost is linear in it. |
| `max_ray_distance` | `0.0` | `0,4096,0.1,or_greater`, m | Extra clamp on ray length. **`0.0` means unlimited**, not "no rays". |
| `softness_scale` | `1.0` | `0,1,0.05` | Multiplies every raytraced light's size, and a raytraced sun's angular distance, on the way into the trace. Reaches the trace only. |
| `accurate_occluder_distance` | `true` | bool | Find the *closest* occluder, not the first hit. Changes no shadow's shape, only how wide the denoiser may filter. Ignored where effective size is `0`. |
| `denoiser/enabled` | `true` | bool | Keeps its own temporal history — needs no TAA, works with SMAA, FXAA or nothing. |
| `denoiser/spatial_passes` | `3` | `1,5,1` | Edge-stopping wavelet passes. Each doubles the filter's reach at roughly constant cost, and each is one more full-resolution dispatch. |
| `denoiser/temporal_frames` | `32` | `1,64,1` | Frames blended over. History is discarded on disocclusion, so this alone does not cause trailing. |
| `denoiser/min_filter_pixels` | `1.0` | `1,8,0.1`, px | Narrowest the spatial filter may work where a penumbra was measured. Only goes up, and is not free — see the ladder in Tuning. |
| `denoiser/history_clamp_sigma` | `2.0` | `0,8,0.1` | How far reprojected history may sit outside this frame's local spread before being pulled back. `0.0` disables. |
| `denoiser/lag_response` | `1.0` | `0,1,0.05` | How much of the clamp's own correction sets the blend weight, once it has decided history was wrong. Inert on frames the clamp did not fire; `0.0` restores pre-clamp behavior. |
| `directional/enabled` | `false` | bool, snapshotted per frame | `DirectionalLight3D` also takes its shadow from the mask. Requires `enabled`. |
| `directional/caster_distance_scale` | `2.0` | `0.5,8,0.1,or_greater` | How far past the shadow distance geometry is still gathered as a sun caster. Also sets sun ray length: `shadow distance * (1 + scale)`. Clamped to non-negative on read. |
| `directional/scatter_casters` | `Near Camera` (`1`) | `Disabled,Near Camera,Full Distance` | Whether MultiMesh/GridMap geometry casts sun shadows. |
| `directional/scatter_distance` | `25.0` | `0,500,1,or_greater`, m | The radius for `Near Camera`. |
| `directional/demoted_shadow_mode` | `2 Splits` (`2`) | `Keep Authored,Orthogonal,2 Splits` | What a raytraced sun's `directional_shadow_mode` is replaced with. |
| `directional/demoted_shadow_size` | `1024` | `0,4096,1`, px | Upper bound on the shared directional shadow atlas once raytraced directional shadows are available. |

`caster_distance_scale` is a setting rather than a constant because it is a look decision and a cost
decision at once: raising it lets distant landmarks cast onto ground you actually walk on, and costs
proportionally more geometry — which slows every ray in the frame, not only the sun's.

## What casts a raytraced shadow

Must pass all four:

1. **Visible** — `instance->visible`, `cast_shadows != SHADOW_CASTING_SETTING_OFF`.
2. **Mesh- or multimesh-backed** — `INSTANCE_MESH` / `INSTANCE_MULTIMESH` only: `MeshInstance3D`,
   `MultiMeshInstance3D`, `CSGShape3D`, `CPUParticles3D`, `GridMap`. **`GPUParticles3D` casts
   nothing.**
3. **A material Godot already considers a caster** — the same per-surface test the shadow map path
   makes (`shadow_caster_surface_mask`), so glass and depth-discarding shaders do not start casting
   solid shadows because a light became raytraced. (`Sprite3D`/`Label3D` pass test 2; their default
   transparent material fails this one.)
4. **Triangle surfaces with 3D positions** — non-triangle primitives, 2D and empty vertex arrays are
   skipped, one-time warning naming how many surfaces were dropped (`rt_scene.cpp:689`).

- Compressed (16-bit) vertex positions are **not** a blocker; a dequantize pass expands them.
- `CPUParticles3D` republishes its whole transform buffer every frame, paying the MultiMesh
  per-element cost on the render thread. Sparks and casings spawn exactly where a muzzle flash is,
  always inside a raytraced light's range: `cast_shadow = OFF` where nobody looks.
- Two 65,536 caster ceilings exist, and the one that hits first is silent —
  `docs/internals/rt-shadows.md`.

## Authoring traps

| Trap | What happens, and what to do |
| --- | --- |
| **Alpha-scissor materials cast the shadow of the whole quad** | Rays use `gl_RayFlagsOpaqueEXT`, so the cutout is never evaluated — a leaf card casts a rectangle. Real geometry, shadow off, or a shadow map for that light. (Alpha-*blended* and screen-reading materials cast nothing, as with shadow maps.) |
| **Vertex shaders are invisible to the shadow** | The structure holds *stored* vertices at the *authored* transform. So `billboard_mode`, `Sprite3D`/`AnimatedSprite3D`/`Label3D`, `fixed_size`/`grow` and any custom `vertex()` cast geometry that is not where you see it. **Skinning and blend shapes are fine**: a compute pre-pass writes what the structure reads. |
| **Mesh LODs and `ArrayMesh.shadow_mesh` are ignored** | LOD 0's index buffer is always traced, so `mesh_lod_threshold` and a cheap shadow proxy do not reduce raytraced shadow cost. |
| **A mesh updated in place keeps its old shadow** | A static surface's structure is cached on `(mesh RID, surface index)`; only *skinned* surfaces carry a version check (`mesh_instance_get_last_change`). So `surface_update_vertex_region()` and `ImmediateMesh` rewrites cast what the structure was first built from. Replacing the surface outright — `clear_surfaces()` and re-add, what `PrimitiveMesh` does on any property change — allocates a new buffer and is correct. |
| **Casters are deliberately not frustum-culled** | Geometry behind the camera still casts into view, shadows do not pop as you turn, and the structure holds more than is on screen. Casters come from each light's own volume; the sun, having no range, uses the visible frustum cut off at the shadow distance, swept toward the light by `caster_distance_scale`. |
| **32-bit masks fold to 8** | `RTShadows::fold_layer_mask` (`rt_shadows.h:77`); mechanism in `docs/internals/rt-shadows.md`. **Layers 9-32 alias onto 1-8**, and a fold of zero is promoted to `0xFF`, so `shadow_caster_mask = 0` — "nothing casts" under shadow maps — means **everything casts** here. |
| **First-person view model** | The standard recipe, high layer with that bit cleared in `shadow_caster_mask`, **silently does nothing** — the high layer folds back onto a low one the light still asks for. Use `cast_shadow = OFF`, also the only way out of the gather: masking is GPU-side only, so a masked-out caster is still gathered, still built, still in the TLAS. |
| **`Light3D.shadow_reverse_cull_face` does nothing** | The mask is per-scenario, that setting per-light, so triangle facing is never culled; for the same reason `cast_shadow = ON` and `DOUBLE_SIDED` are identical. |

## Vanilla knobs that stop doing anything

Everything tuning a shadow *map* is inert on a raytraced light, no map being rendered. Positional
atlas size `0` no longer removes positional shadows either.

| You reach for | It does | Reach for instead |
| --- | --- | --- |
| `Light3D.shadow_blur` | nothing | `light_size` / `light_angular_distance` |
| `positional_shadow/atlas_size` and its quadrant subdivisions | nothing, unless `shadow_map_enabled` puts the light back in the atlas | — (no quadrant is claimed) |
| `positional_shadow/soft_shadow_filter_quality` | nothing | `denoiser/spatial_passes`, `denoiser/min_filter_pixels` |
| `directional_shadow/size` | capped to 1024 | `directional/demoted_shadow_size` |
| `directional_shadow/soft_shadow_filter_quality` | nothing | `samples_per_light` |
| `DirectionalLight3D.directional_shadow_mode` | overridden to 2 splits | `directional/demoted_shadow_mode` |
| `Light3D.shadow_bias` / `shadow_normal_bias` | still used — rescaled into ray `tmin` (`* 0.05`) and a world-space normal offset in meters (`* 0.015` lamp, `* 0.0075` sun) | tune by eye, not by shadow-map intuition |

The sun's normal bias is halved because `DirectionalLight3D` defaults it to `2.0` where a lamp
defaults to `1.0`, so the same inspector number buys the same offset in meters; a ray need only
clear the error in a depth-buffer-reconstructed world position, not a cascade's depth texel. Uses:
`docs/internals/rt-shadows.md`.

## What is not covered

| Area | Behavior |
| --- | --- |
| `AreaLight3D`, `GPUParticles3D` | Shadow maps; `GPUParticles3D` casts no raytraced shadow at all. |
| XR / multiview | Shadow maps — but the structure is still built and the depth pre-pass still forced, so an XR project pays the cost and gets nothing. |
| Reflection probes | Shadow maps. The structure is not built during probe passes, and probes render before viewports. |
| Mobile and Compatibility renderers | Shadow maps. Forward+ only. |
| Subsurface transmittance | **Known gap.** Falls back to the material's own `transmittance_depth`, so a surface still transmits but stops responding to what is in front of the light. |
| Volumetric fog under a raytraced `OmniLight3D`/`SpotLight3D` | Lit, but casts **no light shafts**. |
| Volumetric fog under a raytraced `DirectionalLight3D` | **Works** — the fog traces its own ray per froxel. That ray is culled by the light's `cull_mask`, not its `shadow_caster_mask`: an inconsistency with the surface path. |
| Alpha-blended surfaces | **Receive no shadow** — they cannot read the mask, which holds one answer per pixel belonging to the opaque surface behind the glass. Alpha-to-coverage and `depth_prepass_alpha` materials write pre-pass depth and are shadowed from the mask normally. |
| `depth_draw_never` / `depth_test_disabled` materials | Cast a raytraced shadow where vanilla casts none, and never receive one. |
| Light projectors, SDFGI, VoxelGI, LightmapGI, decals | Unaffected by the raytraced path itself. |

**`shadow_map_enabled` buys back exactly three of those**: subsurface transmittance, volumetric fog
under a lamp, alpha-blended surfaces receiving (the alpha pass then falls through to the map).
Everything else answers from the mask whether or not a map was rendered. It does **not** buy back
the screen space contact shadow for an alpha-blended surface — no map exists to fall through to
(`docs/features/screen-space-shadows.md`).

## Ceilings on how many lights are shadowed

| Ceiling / slot rule | Detail |
| --- | --- |
| **Four raytraced lights per pixel** | The mask is one RGBA8 texel per pixel (`RTShadows::LIGHTS_PER_PIXEL = 4`). The four contributing most light there win; **the losers render fully unshadowed at that pixel, no shadow-map fallback.** Visible only where five or more shadow-casting lights genuinely overlap on one surface. |
| **128 raytraced lights per 8x8 tile** | `MAX_TILE_LIGHTS`, `rt_shadow_trace.glsl:23`. Lights past that are dropped *before* the importance ranking, so which lose is arbitrary rather than the weakest. Directional lights claim their slots first (`rt_shadow_trace.glsl:352-376`) — always a lamp that loses, never the sun. |
| **255 raytraced lights per frame** | `RTShadows::MAX_RT_LIGHTS`, `rt_shadows.h:64`; index 255 is reserved to mean "not raytraced". |
| `distance_fade` does **not** release a slot | A faded light still costs trace work. |
| `light_energy` animated to zero does **not** release one either | The ranking floors energy at `0.0001` (`rt_shadow_trace.glsl:292`) so a zero-energy light does not silently lose its shadow — which also lets it outrank a lamp to the last percent of its falloff and take that lamp's channel. |
| `shadow_opacity <= 0.001` **does** release it | Slot acquisition tests it for lamps and suns (`light_storage.cpp:1161`, `:1454`). **Turn a light off with `visible = false`, or free it.** |

- **A light switching on or off resets the denoiser history at that pixel.** History is keyed on the
  whole set of light indices the pixel carries, compared for exact equality, so a changed set is
  rejected outright: the pixel falls back to one frame of raw trace and re-accumulates, **taking the
  sun's and every nearby lamp's already-converged shadow with it**. Same path a disocclusion takes,
  so the spatial filter widens to cover it and the cost reads as near-field noise, not a new
  artifact.
- **Muzzle flashes** blink several times a second, so the region never accumulates and the flash's
  shadow cannot converge past the frames it exists. Give it **`light_size = 0`**: a hard shadow is
  one deterministic ray, the traced answer already exact, the spatial filter switches itself off,
  the reset costs nothing visible. If it must be soft, raise `samples_per_light` so the few frames
  it lives are worth more. Off with `visible = false`, never by fading `light_energy` to zero.

## Tuning

At the defaults the penumbra is the width the geometry calls for: against a closed-form reference
the 10-90 width lands within a pixel of the analytic answer at every distance, exactly at 16 samples
per light. **Softness belongs to the light, not the denoiser** — `light_size` (lamps, meters, a
radius), `light_angular_distance` (sun, degrees). Godot treats the latter as the disk's angular
*radius*, so the default `0.25` gives ~94% of the real sun's penumbra despite the class reference
quoting `0.5`. Derivations: `docs/HISTORY.md`. Harnesses and blind spots: `docs/VALIDATION.md`.

| Symptom | First lever | Then | Price of the first lever |
| --- | --- | --- | --- |
| Ghosting, trailing smear | `denoiser/history_clamp_sigma` down | `samples_per_light` `2` before `4` | noise; penumbra accuracy |
| Grainy wide penumbrae | `samples_per_light` — linear, every sample traced | `denoiser/spatial_passes` | converges on the same shadow |
| Noisy contact edge | `denoiser/min_filter_pixels` up | — | a fringe on every contact edge |
| Shadow arrives late | `denoiser/lag_response` | `denoiser/temporal_frames` | nothing on frames the clamp did not fire |
| Weak hardware | `softness_scale` down | `denoiser/spatial_passes` | look only; free at `1.0` |
| Slow, large level | `OccluderInstance3D` geometry | — | none |
| Slow outdoors | `directional_shadow_max_distance` | `caster_distance_scale`, then `scatter_casters = Disabled` | shadow range |
| Slow everywhere | `rendering/scaling_3d/scale` (quadratic) | `denoiser/spatial_passes` | resolution |

- **The clamp alone stands between a moving shadow and a smear across a receiver that did not move**
  — that receiver reprojects exactly, the depth test passes, nothing else rejects the stale tap.
  Works at the shipped `samples_per_light = 1`: each tap's own sampling noise is subtracted from the
  spread it measures.
- From a game, not a harness, at 1 sample and the default 32-frame window: dropping
  `history_clamp_sigma` to **`0.3`** almost entirely removed a first-person weapon's smear, for
  slightly more noise. `docs/validation/shadow_validation/denoiser_sim.py --radius` prints the clamp
  window per sample count (simulated, not rendered).
- Tightening it widens the clamp's own moment gather: 5x5 instead of 3x3 where
  `sample_count < 4.0 && clamp_sigma <= 1.0`, less noise for ~2x the peak error at a narrow
  penumbra's shoulder. **At the shipped defaults — 1 sample, sigma 2.0 — that gate is false and the
  5x5 path never runs.**
- Independent of `temporal_frames`: a tight clamp no longer needs a short window to stay honest,
  where `temporal_frames` shortens the window everywhere and pays in steady-state noise.
- Anything rigidly attached to the camera is the worst case, and **strafing is worse than turning**:
  turning pivots a weapon about the camera so its world position barely moves; strafing translates
  it bodily and its shadow sweeps static ground, where history is longest and a stale tap weighted
  most heavily. No temporal filter removes it; if a residual survives tuning, `cast_shadow = Off` on
  the view model or `light_size = 0` on the light.

**`denoiser/min_filter_pixels` only goes up, and it is a trade both ways.** Every a-trous pass
early-outs where a pixel's reach is no wider than that pass's own step, and the first pass already
steps one pixel. At the default `1.0` — the bottom of the hint range; nothing lower renders
differently — a penumbra narrower than a pixel is filtered in **no pass at all** and the temporal
output reaches the screen. That is what makes a contact edge exact, and why a contact shadow reading
noisy stays noisy. Raising it buys those pixels spatial filtering and fringes every contact edge in
the same move. On a perfect step edge over a flat floor, nothing rejected by depth or normal weight:

| `min_filter_pixels` | Step edge reads | Fringe |
| --- | --- | --- |
| `1.0` | `0.000 \| 1.000` | none — exact |
| `1.5` | `0.137 \| 0.863` | — |
| `2.0` | `0.208 \| 0.792` | 2 px |
| `3.0` | `0.036 0.122 0.322 \| 0.678 0.878 0.964` | 6 px |

**Arithmetic** on the shipped kernel (`0.375/0.25/0.0625`), its per-tap reach taper and the
early-out, over the three default passes at steps 1, 2 and 4 — not a render and not a simulation.

| Lever | Why, and what it costs |
| --- | --- |
| **`softness_scale` scales the whole path at once** | `0.0` is worth more than the sample count suggests. At one ray per light a hard shadow traces as many rays as a soft one; what it saves is that neighboring pixels stop aiming at different points on the emitter and stay coherent through the structure, the traced penumbra is zero so every pixel takes the spatial filter's early-out and the three wavelet passes collapse to a copy, and the trace stops hunting for the closest occluder. `0.0` also hardens volumetric fog's per-froxel sun rays, which take the same scaled angle. Continuous — a slider, not a switch. Reaching only the trace, it leaves cascade-path PCSS softness and any shadow map fallback untouched, so raising it restores exactly what was authored: a player who turns it down keeps the sun in the sky and every light as authored. |
| **`OccluderInstance3D` pays off indirectly, and more than in stock Godot** | A lamp that gets occlusion culled leaves the visible light list, so its bounds never reach the caster gather, so every occluder in the structure only for that lamp leaves with it. One occluded lamp can take a room's geometry out, paying again in the build, in every ray traced anywhere in the frame, and in per-pixel light selection. It does not reach a raytraced sun, whose caster volume comes from the camera frustum. It never costs correctness — a caster behind a wall is in the structure because some light reaches it, not because the camera sees it. |
| **Outdoors, `directional_shadow_max_distance` before anything else** | The raytraced sun is ~two thirds of the CPU cost in a hostile scene, and shadow distance dominates while `caster_distance_scale` does not (measured; `docs/HISTORY.md`). Shortening it shortens every sun ray on the GPU too: ray length is `shadow distance * (1 + caster_distance_scale)`, three times the shadow distance at the default scale, traced for the nearest hit. |
| **The whole stage — trace, temporal accumulation, every a-trous pass — runs at the render buffer's internal size** | `rendering/scaling_3d/scale` moves all of it quadratically along with the depth pre-pass, occlusion pass and opaque pass; no half-resolution setting exists for the mask alone. Two of its knobs are in *internal* pixels, so an upscaler changes what they mean on the output image — `docs/internals/dlss.md`. |
| **Judge a denoiser change with the camera moving, not parked** | A converged static frame has no disocclusions, so the wide spatial passes do the least work they ever will and every reduction in filter width looks free. No render rig covers this — `docs/VALIDATION.md` has the blind spot and what covers the temporal pass. `GODOT_RT_DEBUG=1` is the diagnostic; `docs/TROUBLESHOOTING.md` reads its lines. |

## Known gaps

Verified against the code, not yet fixed. Line references are for whoever picks one up. The first
three are cheap; the shape of each fix is given.

| Gap | Mechanism, and the fix |
| --- | --- |
| **A spot light's cone falloff is ignored when the per-pixel top four are chosen** | `light_importance` (`rt_shadow_trace.glsl:275-292`) scores energy, radial falloff and facing only; the cone is a binary reject at `:461`. A spot contributing nothing at its rim scores as high as one on its axis and can evict a light genuinely lighting the pixel, which then renders fully unshadowed. *Fix:* multiply the score by the same cone ramp the forward pass uses, reusing the dot product already computed at `rt_shadow_trace.glsl:461`. |
| **The sun can lose its channel at grazing incidence** | The tile cull gives directional lights a priority pass, but the per-pixel top four (`:473-482`) compares score alone, and a low sun has a small `facing` term: on a near-horizontal surface under a low sun, overhead lamps can take all four channels exactly when the sun's shadows are longest. *Fix:* make light type the primary key in that insertion, mirroring the tile cull. |
| **Penumbra width is converted to pixels with radial distance where `focal_pixels` is a per-view-depth scale** | `rt_shadow_trace.glsl:676`. Error is `1/cos(theta)` off axis, so penumbrae toward the edges of a wide frame read 15-30% narrower than they are and are filtered with too small a kernel. Worst on an ultrawide target, worse with a wide FOV. *Fix:* free — `view_depth` is already in a register two lines above. |
| **Orthogonal cameras are handled badly in two places** | The perspective penumbra formula collapses toward zero, so the spatial denoiser sees no penumbra and switches off, leaving noise; and the directional caster gather ignores `directional_shadow_max_distance`, sizing the caster volume from `Camera3D.far` (default `4000`). An isometric or 2.5D project feels both. |
| **`shadow_opacity` is ignored under `render_mode vertex_lighting`** | The second directional loop, the one place the fade is applied, is compiled out there. Upstream Godot does the same on the cascade path, so the fork matches rather than being the only path honoring it. |
| **The first frame with both volumetric fog and a raytraced sun stalls** | Two shader variants compile — the price of not compiling them for projects that never need them. |
| **A `MultiMesh` populated through `multimesh_set_buffer` is read back from the GPU** | On its first frame as a raytraced caster, then a CPU cache sync on every upload after. Its per-element cost is paid every frame on the render thread; `visible_instance_count` is the only property shrinking it. |
| **A setting changed mid-frame is seen mid-frame** | Live settings are re-read the moment `ProjectSettings` changes, so one landing between the culler's decision and the light buffer's can leave them disagreeing for a frame. The three snapshotted settings go one-frame stale instead. |
