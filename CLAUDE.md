# godot-rt — Godot with hardware-raytraced shadows

**This is not vanilla Godot.** It is Godot 4.8-dev with hardware ray-traced shadows added to the
Forward+ renderer. Almost all of the engine is untouched, but a handful of node defaults and
renderer behaviors differ from stock Godot. Answering from memory of vanilla Godot will produce
wrong code and wrong advice in exactly the areas people ask about most: lights, shadows, and what
a scene costs.

Before answering anything about lights, shadows, fog, or the renderer, read
**`docs/rt_shadows/FORK_GUIDE.md`**. It is the authoritative description of this fork.

## Defaults that differ from vanilla Godot

A `.tscn` only stores properties that differ from a freshly constructed node, so these are the
values a new node actually gets — not a project setting you can look up.

| Property | Vanilla | Here |
| --- | --- | --- |
| `OmniLight3D.shadow_enabled` | `false` | **`true`** |
| `SpotLight3D.shadow_enabled` | `false` | **`true`** |
| `OmniLight3D` / `SpotLight3D` `light_size` | `0.0` | **`0.05`** |
| `DirectionalLight3D.light_angular_distance` | `0.0` | **`0.25`** |

New lights therefore cast soft, contact-hardening shadows with no configuration. Set the size back
to `0.0` for hard shadows.

These apply in **every** renderer, whether or not raytraced shadows are enabled, and they reach
further than shadows: a non-zero angular distance puts the cascade path on its PCSS branch, makes
`ProceduralSkyMaterial`/`PhysicalSkyMaterial` draw a visible **sun disk**, makes `LightmapGI` bakes
soft-shadowed and slower, and makes every mesh lit by a default lamp compile the
`use_light_soft_shadows` specialization.

`Light3D` gains one property, `shadow_map_enabled` (and `RenderingServer.light_set_shadow_map_enabled`).

## What raytraced shadows do and do not cover

Off by default. Turn on `rendering/lights_and_shadows/raytraced_shadows/enabled` for
`OmniLight3D` and `SpotLight3D`, and additionally `.../raytraced_shadows/directional/enabled`
for `DirectionalLight3D`. Requires Forward+, Vulkan, and a GPU with ray query support; it warns
and falls back to shadow maps otherwise.

Not covered, and silently falling back or losing shadowing:

- **`AreaLight3D`** — always shadow maps.
- **`GPUParticles3D`** — casts no raytraced shadow at all. A caster must be mesh-backed
  (`INSTANCE_MESH`) or multimesh-backed (`INSTANCE_MULTIMESH`), which does include `CSGShape3D`,
  `CPUParticles3D` and `GridMap`, and its surfaces must be triangles with 3D positions.
- **Alpha-scissor materials** — cast, but the cutout is *ignored*: a leaf card casts the shadow of
  the whole quad. This is the one that bites when authoring foliage. (Alpha-*blended* and
  screen-reading materials cast nothing, exactly as with shadow maps.)
- **Subsurface transmittance** — falls back to the material's own transmittance depth. Known gap.
- **Volumetric fog under a raytraced `OmniLight3D`/`SpotLight3D`** — lit, but casts no light shafts.
  A raytraced `DirectionalLight3D` traces its own ray per froxel, so sun shafts do work.
- **XR / multiview, reflection probes, the Mobile and Compatibility renderers** — shadow maps.

`Light3D.shadow_map_enabled` buys a light back its shadow map for the effects above, at the cost of
an atlas quadrant and a shadow map render.

## Traps when authoring for raytraced shadows

- **Vertex shaders are invisible to the shadow.** The structure holds the mesh's stored vertices at
  the node's authored transform, so billboards, `Sprite3D`, `Label3D`, `fixed_size`/`grow`
  materials and any custom `vertex()` cast a shadow of geometry that is not where you see it.
  Skinning and blend shapes are fine — they run in a compute pre-pass the structure reads.
- **Mesh LODs and `ArrayMesh.shadow_mesh` are ignored**; LOD 0 is always traced.
- **Everything that tunes a shadow *map* is inert** on a raytraced light: `shadow_blur`, atlas size
  and quadrants, soft-shadow filter quality. Softness comes from `light_size` /
  `light_angular_distance`; noise from `samples_per_light` and the denoiser settings.
- **`shadow_caster_mask` and `layers` fold from 32 bits to 8**, so layers 9–32 alias onto 1–8; and a
  mask of `0` is promoted to "everything casts" rather than "nothing casts".
  `shadow_reverse_cull_face` does nothing.
- **At most four raytraced lights are shadowed per pixel.** Where more overlap, the losers render
  **fully unshadowed there**, with no shadow-map fallback.

## Two behaviors that surprise people

- **`raytraced_shadows/*` settings are live** — change one in the inspector or via
  `ProjectSettings.set_setting()` and it takes effect next frame. The one exception is the master
  `enabled` flag, which is restart-required and marked so, and could not work live in any case:
  `MeshStorage::mesh_add_surface` fixes a vertex buffer's creation bits at upload time, so a mesh
  loaded while it was off has nothing to build a structure from. The three `directional/enabled` and
  `directional/demoted_shadow_*` settings are live but snapshotted once per frame, because a sun's
  cascade count has to be one answer for the whole frame.
- With raytraced directional shadows available, a `DirectionalLight3D`'s
  `directional_shadow_mode` is overridden to 2 splits and the shared directional shadow atlas is
  capped at 1024 — for every directional light, not only raytraced ones. Both are configurable
  under `raytraced_shadows/directional/demoted_shadow_*`.

## Ambient occlusion is two estimators now

`Environment.ssao_method` and `rendering/environment/ssao/method` choose between the Intel point
obscurance estimator Godot has always shipped and a slice-based horizon march with a **visibility
bitmask** (GTAO + Therrien 2023). Both write the same occlusion buffer, so nothing downstream knows
which ran. Ships **off**: the project setting defaults to legacy and an `Environment` defaults to
`SSAO_METHOD_DEFAULT`, which follows it.

- `ssao_enabled`, `ssao_radius`, `ssao_intensity`, `ssao_power`, `half_size` and the fade distances
  apply to both. `ssao_detail`, `ssao_horizon`, `ssao_sharpness`, `quality` and `adaptive_target`
  are legacy-only and inert on the new one.
- Tuning lives under `rendering/environment/ssao/ground_truth/`. `thickness` (0.3) is the one real
  tradeoff: higher suits thick solid shapes, lower suits foliage and slats.
- **Forward+, single view only.** Stereo/XR falls back to legacy without saying so.
- Half resolution is close to free of consequence here — the march reach is derived from the full
  resolution footprint, so half and full differ by 0.06/255 on average.
- Do not tune it by screenshot. `docs/rt_shadows/ao_validation/` traces the scene on the CPU two
  ways and scores a render against both; section 9 of the fork guide has the numbers to beat.

## Working in this repo

- `docs/rt_shadows/FORK_GUIDE.md` — what changed, why, and how to use it. Self-contained; copy it
  into a game project that uses this engine.
- `docs/rt_shadows/PORTING.md` — every seam where this fork hooks into the engine, and the ordered
  recipe for re-applying it to a newer Godot.
- `docs/rt_shadows/PLAN.md` — the pre-implementation design document. **Historical. Superseded by
  the two documents above; several of its decisions were not taken.** Do not treat it as current.

Set `GODOT_RT_DEBUG=1` to print per-frame acceleration structure and shadow mask diagnostics.

CI was narrowed to Windows only, which dropped the checks that ran on Linux — the `--doctool` class
reference check and the GDExtension API compatibility check. (Unit tests still run: the Windows
job runs `--test`.) **If you add or
change a bound property, run `godot --headless --doctool .` yourself and commit the result**;
nothing else will catch it.
