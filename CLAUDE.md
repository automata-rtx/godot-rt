# godot-rt — Godot with hardware-raytraced shadows

**This is not vanilla Godot.** It is Godot 4.8-dev with hardware ray-traced shadows added to the
Forward+ renderer. Almost all of the engine is untouched, but a handful of node defaults and
renderer behaviors differ from stock Godot. Answering from memory of vanilla Godot will produce
wrong code and wrong advice in exactly the areas people ask about most: lights, shadows, and what
a scene costs.

Before answering anything about lights, shadows, fog, or the renderer, read
**`docs/rt_shadows/FORK_GUIDE.md`**. It is the authoritative description of this fork.

## What this engine is for

A single-player first-person shooter. Not a general-purpose engine release, so a tradeoff that suits
this game is the right tradeoff even where a general one would differ. The profile is the missing
premise under a lot of what follows:

- **Two target machines**, and every measurement in the documentation was taken on one of them
  rather than on arbitrary test hardware: an **RTX 5090 desktop at 3440x1440**, and a
  **Ryzen 7 7840HS / Radeon 780M laptop**. When the docs single out `shading_rate` as the first knob
  for weak hardware, the 780M is the hardware they mean.
- **Never TAA. SMAA only when DLSS is off.** There are two shipping antialiasing configurations and
  they are exclusive: with DLSS super resolution on, DLSS does the antialiasing and SMAA and FXAA
  are both OFF; with DLSS off, SMAA does it. Do not reason about a post-process AA running alongside
  DLSS -- that combination is not used and would be wrong.
  This matters beyond antialiasing, because Godot fills the velocity buffer only for a viewport
  running a temporal upscaler or TAA. With SMAA there is no velocity buffer; with DLSS there is, and
  DLSS is what supplies it. That is why DLSS frame generation, which refuses without motion vectors,
  is reachable only while super resolution is running -- and since super resolution does run, it is
  a live path rather than a blocked one.
  It also means **anything that ghosts is a DLSS-on problem**, not a general one: with SMAA there is
  no temporal reprojection of the frame at all. The raytraced shadow denoiser is the exception --
  it accumulates over time in both configurations.
- **MSAA deliberately off.** So "measure with MSAA off as the control" is the shipping configuration
  rather than a methodology note, and `restrict_casters` declining under MSAA is a non-issue here.
- **Not VR.** Every multiview and stereo fallback in this fork is dead code for this project.
- Builds come from **GitHub Actions**, not a local toolchain.

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

## Screen space shadows for the sun

Off by default. `rendering/lights_and_shadows/screen_space_shadows/enabled` gives the first
shadow-casting `DirectionalLight3D` a screen-space contact shadow, marched over the depth pre-pass
buffer. Read section 10 of **`docs/rt_shadows/FORK_GUIDE.md`** before answering anything about it.

- **It is not an alternative to that light's own shadow.** It is laid over it and the two are
  combined with `min()`, not a multiply, because an occluder that is both in the acceleration
  structure and on screen is described by both terms and multiplying darkens it twice.
- **It exists for geometry deliberately kept out of the acceleration structure.** Grass is the case:
  the caster gather walks every element of a `MultiMesh` every frame on the render thread, so a
  field of blades is removed with `GeometryInstance3D.cast_shadow = Off` and gets its contact shadow
  from here instead. The grass still *receives* raytraced shadows -- `cast_shadow` governs casting
  only.
- **`hardness` is the knob for a shadow that reads too faint, not `surface_thickness`.** Bend average
  the march into four buckets, so a pixel needs four samples' worth of agreement before it is fully
  shadowed -- and samples are one pixel apart, so a grass blade narrower than that casts well short
  of the shadow a trace of the same blade gives. Measured in linear light: 0.445 of the raytraced
  path's darkening per pixel on separated prisms, over 1.5x the area, rising to about 0.80 on a
  dense field where blades shadow each other. `hardness` blends that average against
  the minimum of the same four buckets; `0.0` is Bend's behavior exactly and the default `1.0`
  matches the trace. It moves darkness 2.1x while moving area 5%, so it and `surface_thickness` are
  independent: hardness sets how dark, thickness sets how wide. There is no third darkness knob --
  `contrast` and `strength` were settings until they were measured, and are now constants at 4.0 and
  1.0. Score these captures in linear light (the rule and the decode are under "Building and
  validating" below); the sweeps are in `docs/rt_shadows/FINDINGS.md`, screen space section.
- **Do not tune it by screenshot.** `docs/rt_shadows/shadow_validation/` renders the same scene with
  and without the pass and scores it against a raytraced reference; its README lists the numbers a
  change must not move. The pass overshoots darkness while undershooting area, so an eye judging
  "too dark" is reading one of those and not the other.
- **One light, Forward+, single view.** The mask has one channel. A second `DirectionalLight3D` gets
  nothing, and this is not a per-light property: `LightStorage` picks the light and marks it with
  `DirectionalLightData::sss_strength`. Multiview, reflection probe and **orthographic** renders
  decline the pass, the first and last with a one-time warning -- an orthographic projection gives a
  direction vector a clip `w` of exactly zero, and the march takes its direction from that sign. A light is marked ONLY when a mask is genuinely written for it that
  pass -- marking one whose mask never arrives puts the sun out rather than leaving it alone, because
  the fallback bound in the mask's place is a 4x4 texture the lookup reads past.
- **It only shadows from occluders on screen and in front, and shadow length is bounded in PIXELS**
  by the quality tier, not in world units. So grass above the top of the viewport casts nothing, and
  a low sun wants shadows longer than any tier reaches. Neither is tunable. The complement for those
  cases is a few hundred low-poly clump proxies set to `SHADOWS_ONLY`, which still cast raytraced
  shadows while drawing nothing.
- **Enabling it forces the depth pre-pass on and forces its MSAA resolve**, the same way raytraced
  shadows do, because that buffer is what it marches.
- `debug_view` is how to bring it up, not guesswork: **Wave Index** draws the compute wavefront
  layout, which must fan out from the sun's screen position, and does not if the light's projected
  coordinate is wrong. **Edge Mask** is for tuning `bilinear_threshold`.
- Leave `ignore_edge_pixels` off for foliage. It thins genuine shadows at silhouettes, which is
  exactly the geometry the feature serves.
- The technique is Bend Studio's (Apache-2.0). `thirdparty/bend_sss/bend_sss_cpu.h` is vendored
  with no code changes; `shaders/effects/screen_space_shadow.glsl` is a port of their HLSL.

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
- **`rendering/anti_aliasing/quality/dlss_preset` forces a DL model** (Default, J, K, L, M — the
  other eleven SDK slots are removed, deprecated, or revert to default). Live, and applied to every
  quality mode at once. **Which model is actually running cannot be read back**: `DLSSState` carries
  only a VRAM estimate, the NGX preset parameters are write-only hints, and `sl.dlss`'s own debug
  HUD prints the quality mode and not the preset -- the plugin does not know it either. So on
  Default the editor overlay reports the preset the SDK header documents for the mode and labels it
  as such. The authoritative answer is NVIDIA's on-screen indicator, a machine-wide registry switch
  (`HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore\ShowDlssIndicator`, flipped by the SDK's
  own `scripts/ngx_driver_onscreenindicator.reg`); the overlay reads that value and defers to the
  letter on screen when it is on.
- **View → View Information shows the DLSS resolutions, scale and preset** when DLSS is the
  upscaler that actually ran. It reads `viewport_get_internal_size` and
  `viewport_get_effective_scaling_3d_mode`, which report what the renderer did rather than what the
  viewport asked for — a DLSS request silently becomes FSR 2 wherever DLSS cannot run.
- **DLSS needs the velocity buffer pre-filled with camera motion**, which is why
  `MotionVectorsStore` is no longer MetalFX-only. Godot clears that buffer to `(-1, -1)` meaning
  "nothing wrote here" and FSR2 decodes the sentinel inside its own patched shader; DLSS reads it
  literally and, scaled by the render size, sees a full screen of motion everywhere the motion pass
  did not draw. The symptom is edges that crawl and never resolve even with the camera still.
- **Frame generation refuses rather than half-applies**: never in the editor, never in stereo,
  never on a viewport no window presents, and never without motion vectors (which means a
  temporal upscaler or TAA must be running). It provides hudless colour but **not UI alpha**,
  which Godot cannot currently produce, so a moving interface element smears across generated
  frames. Fixed 2x only — dynamic multi-frame generation is D3D12-only in this SDK.
- **V-Sync with frame generation is D3D12-only too**, so on Vulkan it has to be forced from the
  driver control panel.
- **Streamline 2.12.0 does not ship XeSS.** Adding it means integrating Intel's SDK directly, not
  adding a Streamline feature id.
- **DLSS super resolution works. Frame generation is still unverified.** Super resolution is
  confirmed on the RTX 5090 at 3440x1440 fullscreen with a 3D scale of 0.67, the equivalent of DLSS
  Quality, and the image is clean — no ghosting, no smearing under motion, no shimmer at rest. That
  also confirms the conventions it rides on, because each fails visibly and differently: motion
  vector sign and `mvecScale` smear under motion, the `clipToPrevClip` transpose ghosts with the
  camera still, the jitter sign reads as softness, bad resource tags give black. Do not describe
  those as unverified. Section 9 of the integration document is the ladder for frame generation and
  for any configuration not yet tried.
- **DLSS is what makes the render size arbitrary, and the fork's passes are budgeted in pixels.**
  Every pass this fork adds dispatches from `get_internal_size()`. The contact shadow's march
  length, `denoiser/min_filter_pixels` and `MAX_PENUMBRA_PIXELS` are all in *internal* pixels, so at
  0.67 the contact shadow reaches about two thirds as far across the output image. That is the
  upscaler's tradeoff, not a fault. The sharper trap is size alignment: 3440x1440 divides cleanly by
  16 and the 2304x964 that DLSS Quality gives does not, which is how a mip-bound off-by-one in the
  occlusion prefilter stayed invisible until DLSS ran. Godot TRUNCATES the internal size
  (`renderer_viewport.cpp:315`, a float expression assigned to an `int`), so 0.67 of 3440x1440 is
  2304x964 and not 2305x965 -- work the real number, because whether a dimension divides by 2^level
  is the whole question. **Check a new pass against an awkward size, not against the native one.**

## Working in this repo

- `docs/rt_shadows/FORK_GUIDE.md` — what changed, why, and how to use it. Self-contained; copy it
  into a game project that uses this engine.
- `docs/rt_shadows/PORTING.md` — every seam where this fork hooks into the engine, and the ordered
  recipe for re-applying it to a newer Godot.
- `docs/rt_shadows/FINDINGS.md` — what was measured and what the numbers refused. Read it before
  re-trying an idea that looks obvious; several already were, and failed. Keep it out of the guide.
- `docs/streamline/INTEGRATION.md` — the DLSS integration: how it attaches, every seam it touches,
  the motion vector and depth conventions it assumes, and what to check first on hardware.
- `docs/rt_shadows/ao_validation/` and `docs/rt_shadows/shadow_validation/` — the two measurement
  harnesses. Each has its own README. Every published number came from one of them, and a claim
  about occlusion or shadow quality that did not is an opinion.

## Building and validating

The owner builds through GitHub Actions, not locally, so a local build here exists only to test a
change before pushing.

```
scons platform=linuxbsd target=editor dev_build=no debug_symbols=no -j4   # ~90 s incremental
```

The binary lands at `bin/godot.linuxbsd.editor.x86_64` and is gitignored.

**Rendering is validated under Xvfb plus lavapipe**, which is byte-for-byte deterministic: two runs
of the same binary and scene differ by zero pixels, so a difference of a few hundred pixels is a real
change and not noise. Do not write a new script for it — `shadow_validation/run.sh` and
`ao_validation/run.sh` already do the whole dance, and the traps that cost a run each
(`pkill -f` matching the running script's own command line; a GDScript parse error leaving Godot
sitting on a window until the timeout) are recorded as comments beside the code that trips on them.
Details live in those two READMEs, which are the copies that get maintained.

Three things about it are worth knowing before reading any output:

- **Score in linear light, never off the sRGB PNG values.** A PNG is sRGB encoded, so differencing
  two of them measures gamma space rather than light. Every screen space shadow ratio was first
  published from gamma-space differences and had to be re-derived. Decode with
  `a <= 0.04045 ? a/12.92 : ((a+0.055)/1.055)**2.4` first — or use the harnesses, which do.
  `docs/rt_shadows/PORTING.md`, "How to verify a port", is the authoritative statement of this.
- **lavapipe DOES run the raytraced path.** It advertises ray query support and the fork takes it.
  It prints `OpTypeRayQueryKHR is not supported yet.` once at startup; that line comes from the Mesa
  stack, not the engine, and does not stop the trace. `GODOT_RT_DEBUG=1` settles it — a line reading
  `pre_opaque: ... rt_lights=1 new_slots=1 tlas=1` is the mask being written.
- **It cannot tell you cost.** Every timing under software rendering is meaningless.

CI was narrowed to Windows only, which dropped the checks that ran on Linux — the `--doctool` class
reference check and the GDExtension API compatibility check. (Unit tests still run: the Windows
job runs `--test`.) `.github/workflows/linux_builds.yml` was **not deleted** and still carries
`workflow_dispatch`, so those checks can be run on demand from the Actions tab without restoring
them to every push. **If you add or
change a bound property, run `godot --headless --doctool .` yourself and commit the result**;
nothing else will catch it. Static checks run `codespell`, which rejects
British spellings. The -our, -re and -ise endings have each failed a build here; write US English in
prose and comments. Note that codespell rewrites in place, so it will also "correct" a sentence
that quotes a British spelling as an example.

**Run the repository's own hooks before pushing rather than discovering them in CI.** `pip install
prek`, then:

```
prek run --from-ref origin/master --to-ref HEAD   # the whole branch
prek run                                          # just what is staged
```

Use the **range**, not the staged form alone. CI compares against the branch point, so a formatting
problem introduced two commits earlier fails the run for whichever commit happens to be on top --
that has cost a cycle here twice. `clang-format`, `ruff-format` and `codespell` all rewrite in
place, so a hook that "fails" with no message has usually just edited your files: check `git diff`
and commit what it did.

**Exporting a game from this fork needs this fork's own export template.** Stock Godot templates
produce a running game with none of the fork in it -- the renderer changes are in the binary, not in
the project. The Windows CI run uploads two artifacts, MSVC only: `windows-editor` and
`windows-template` (`godot.windows.template_release.x86_64.exe` and its `.console.exe`). Point the
export preset at it with **Export -> preset -> Custom Template -> Release**, which sidesteps version
matching entirely -- a fork's version string will not line up with any installed template.

**There is no `template_debug` build anywhere in the matrix**, which is editor x2 and
`template_release` x2. So release exports work and debug exports do not: no "Export With Debug", no
one-click deploy, no remote debugging into an exported build. It also means no shippable
configuration has `DEBUG_ENABLED` on, and that is the flag that turns a C++/GLSL push constant
mismatch into a hard error instead of a silently skipped pass. Adding the target is a matrix entry
plus a CI job.
