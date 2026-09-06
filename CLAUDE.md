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
`ProceduralSkyMaterial`/`PhysicalSkyMaterial` draw a visible **sun disk**, and makes `LightmapGI`
bakes soft-shadowed and slower; and a non-zero lamp `light_size` makes every mesh lit by a default
`OmniLight3D` or `SpotLight3D` compile the `use_light_soft_shadows` specialization.

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
- **Alpha-blended surfaces also RECEIVE no shadow.** They cannot read the mask, which holds one
  answer per pixel belonging to the opaque surface behind the glass. `shadow_map_enabled` restores
  it, because the alpha pass then falls through to the map. Alpha-to-coverage and
  `depth_prepass_alpha` materials write pre-pass depth and are shadowed from the mask normally.
- **Subsurface transmittance** — falls back to the material's own transmittance depth. Known gap.
- **Volumetric fog under a raytraced `OmniLight3D`/`SpotLight3D`** — lit, but casts no light shafts.
  A raytraced `DirectionalLight3D` traces its own ray per froxel, so sun shafts do work.
- **XR / multiview, reflection probes, the Mobile and Compatibility renderers** — shadow maps.

`Light3D.shadow_map_enabled` buys a light back its shadow map, at the cost of an atlas quadrant and
a shadow map render. That helps the three entries above that read a map and find none -- subsurface
transmittance, volumetric fog under a lamp, and alpha-blended surfaces receiving. The rest of the
list never reads a shadow map in the first place -- an opaque surface under a light that holds a mask
slot takes its answer from the mask whether or not a map was also rendered -- so the flag does
nothing for them.

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
  **fully unshadowed there**, with no shadow-map fallback. A second ceiling sits above it: at most
  128 raytraced lights per 8x8 tile, and lights past that are dropped *before* the importance
  ranking, so which ones lose is arbitrary. Directional lights claim their slots first, so it is
  always a lamp that loses, never the sun.
- **A mesh updated in place keeps its old shadow.** Only skinned surfaces carry a version check, so
  `surface_update_vertex_region()` and `ImmediateMesh` rewrites cast the geometry the structure was
  first built from. Replacing the surface outright is handled correctly.
- **A light switching on or off resets the denoiser history for every light at that pixel**, because
  the history is keyed on the whole set of light indices and compared for exact equality. This is
  the one to know before building muzzle flashes: a light that blinks never lets the region it lights
  accumulate, and its own shadow cannot converge past the number of frames it exists. Give a flash
  `light_size = 0` and the problem goes away — a hard shadow is one deterministic ray and the filter
  switches itself off. Turn a flash off with `visible = false` rather than fading `light_energy` to
  zero: a zero-energy light keeps its slot and all of its rays.

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
- Tuning lives under `rendering/environment/ssao/ground_truth/`. `shading_rate` (Checkerboard) is
  the first one to reach for on weak hardware — it is read only when `half_size` is on, and
  `Quarter Resolution` is the cheaper rung. `thickness` (0.3) is the one real
  tradeoff: higher suits thick solid shapes, lower suits foliage and slats. `screen_radius` (0.1)
  is a fraction of screen **height** and is the knob to reach for first — a real interior wants more
  than a test scene does. `intensity_scale` (0.5) divides down the `ssao_intensity` default of 2.0,
  which is a legacy-estimator calibration constant.
- **The denoise sizes itself from the radius and the slice count** (on the distance-scaled branch,
  which is the default; fixed otherwise) and weights neighbors by distance from the shaded point's
  plane, not by depth difference. Three things here have already
  been tried and measured to fail: widening the filter unconditionally, replacing the dither, and
  rebalancing `slices` against `steps_per_slice`. See `docs/rt_shadows/FINDINGS.md` before
  re-attempting any of them.
- **The strength curve is a ratio, not a subtraction**, so occlusion approaches black without ever
  reaching it. If occlusion ever looks crushed and speckled, suspect the transfer before the
  estimator: put a traced reference through the same curve and see whether the artifact survives.
- **Forward+, single view only.** Stereo/XR falls back to legacy without saying so.
- Half resolution changes how many pixels get their own answer and nothing else — the march reach
  is derived from the full resolution footprint either way. It scores the same against a ray trace;
  what it costs is sharpness at silhouettes.
- Do not tune it by screenshot. `docs/rt_shadows/ao_validation/` traces the scene on the CPU two
  ways and scores a render against both; section 9 of the fork guide has the numbers to beat.

## DLSS through NVIDIA Streamline

The fork also carries a Vulkan Streamline integration: **DLSS super resolution** as
`VIEWPORT_SCALING_3D_MODE_DLSS`, and **DLSS frame generation** as the application-wide
`rendering/streamline/frame_generation`. Read **`docs/streamline/INTEGRATION.md`** before
answering anything about upscaling, frame generation or the Vulkan loader.

- **Needs the Vulkan rendering driver, which new projects do not get.** `EditorNode::get_initial_settings()`
  writes `rendering/rendering_device/driver.windows = "d3d12"` into every project the editor
  creates, and Streamline is loaded from the Vulkan context driver — so on a default new project
  none of it runs, whatever the settings say. This is the first thing to check when DLSS reports
  itself unavailable.
- **Off by default, and Windows only.** `rendering/streamline/enabled` is restart-required
  because it replaces the process's Vulkan entry-point loader with the interposer's: volk is
  initialized with `vkGetInstanceProcAddr` from `sl.interposer.dll`, so `vkCreateInstance`,
  `vkCreateDevice`, `vkCreateSwapchainKHR`, `vkAcquireNextImageKHR` and `vkQueuePresentKHR` all
  become Streamline proxies without a single call site changing.
- **No SDK binaries are vendored** — only the headers, under `thirdparty/streamline/`. The
  runtime is loaded from `rendering/streamline/binary_path` and refused unless the OS trusts its
  signature and the signer is NVIDIA, so a self-built Streamline will not load.
- **Frame generation's plugin is not even loaded in the editor.** `sl.dlss_g` hooks
  `vkCreateSwapchainKHR` and the interposer returns a declined hook's error without calling the
  driver, so with it loaded every editor popup -- each one an OS window with its own swapchain --
  fails to create one and renders blank. It is left out of `featuresToLoad` there. DLSS super
  resolution registers no hooks and is unaffected. A game that presents more than one window is
  still unhandled.
- **Frame generation refuses rather than half-applies**: never in the editor, never in stereo,
  never on a viewport no window presents, and never without motion vectors (which means a
  temporal upscaler or TAA must be running). It provides hudless colour but **not UI alpha**,
  which Godot cannot currently produce, so a moving interface element smears across generated
  frames. Fixed 2x only — dynamic multi-frame generation is D3D12-only in this SDK.
- **V-Sync with frame generation is D3D12-only too**, so on Vulkan it has to be forced from the
  driver control panel.
- **Streamline 2.12.0 does not ship XeSS.** Adding it means integrating Intel's SDK directly, not
  adding a Streamline feature id.
- **Nothing has rendered a DLSS frame yet.** The load path is confirmed on an RTX 5090 — the
  interposer loads, the signature check passes, `slInit` succeeds and Reflex reports available —
  but no image has come out of super resolution or frame generation. Section 8 of the integration
  document lists what to check first and in what order.

## Working in this repo

- `docs/rt_shadows/FORK_GUIDE.md` — what changed, why, and how to use it. Self-contained; copy it
  into a game project that uses this engine.
- `docs/rt_shadows/PORTING.md` — every seam where this fork hooks into the engine, and the ordered
  recipe for re-applying it to a newer Godot.
- `docs/rt_shadows/FINDINGS.md` — what was measured and what the numbers refused. Read it before
  re-trying an idea that looks obvious; several already were, and failed. Keep it out of the guide.
- `docs/rt_shadows/PLAN.md` — the pre-implementation design document. **Historical. Superseded by
  the guide and the porting document; several of its decisions were not taken.** Not current.
- `docs/streamline/INTEGRATION.md` — the DLSS integration: how it attaches, every seam it touches,
  the motion vector and depth conventions it assumes, and what to check first on hardware.
- `docs/streamline/EVALUATION.md` — the design note that preceded it. **Historical.** Some of its
  decisions were taken differently.

Set `GODOT_RT_DEBUG=1` to print per-frame acceleration structure and shadow mask diagnostics.

CI was narrowed to Windows only, which dropped the checks that ran on Linux — the `--doctool` class
reference check and the GDExtension API compatibility check. (Unit tests still run: the Windows
job runs `--test`.) **If you add or
change a bound property, run `godot --headless --doctool .` yourself and commit the result**;
nothing else will catch it.
