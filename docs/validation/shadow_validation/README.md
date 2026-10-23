# Measuring the screen space shadow against the trace

Everything here exists to answer one question with numbers instead of opinion: **how close does the
screen space contact shadow get to a ray trace of the same geometry, and which half of it is wrong?**

The reference is this fork's own raytraced shadow, deliberately, and not a shadow map. A map brings
its own resolution and depth-bias error to a comparison about millimeter-scale occluders, and would
be measuring two techniques' errors at once. The trace intersects the blade's actual triangles.

Every rig renders **one scene several ways, changing only the shadow term**. So the luminance a
capture loses relative to the unshadowed baseline *is* the shadow, everywhere, with no segmentation
mask and no assumption about which pixels are ground.

| capture | what it is |
| --- | --- |
| `a_off.png` | occluders cast nothing, screen space off — the unshadowed baseline, the divisor |
| `h<H>_t<T>.png` | screen space on, at that `hardness` and `surface_thickness` — under test |
| `b_rt.png` | occluders put **into** the acceleration structure and traced — **ground truth** |

## The one rule

**A PNG is sRGB encoded. Decode to linear before differencing anything.**

Every published number in the screen space section of `../../HISTORY.md` was first taken by
differencing sRGB values directly, which measures gamma space rather than light, and all of them had
to be re-derived: gamma compresses the dark end, so every ratio came out *lower* than the truth and
the technique looked further from the reference than it is. `score.py` decodes first, always, and
its `--srgb` flag exists only so that a number found in an old note can be *identified* as
gamma-space rather than mistaken for a regression.

The error was caught by a control that could not miss and did: `opacity.gd` renders the same sun on
shadow maps, a path this fork does not touch, which applies `shadow_opacity` exactly once and must
therefore read `0.500` at an opacity of `0.5`. It read `0.336`. **If that control ever moves off
`0.500` again, fix the measurement before believing anything else it says.**

## The three numbers, and why it is not one

- **mass** — total light removed, relative to the trace's. Threshold free, no selection bias, and
  the only one of the three that is safe to tune `surface_thickness` against.
- **area** — how many pixels it shadows at all, relative to the trace's.
- **darkness** — mass ÷ area. *When it does find a shadow, is that shadow as dark as the trace's?*

They have to be read together. The screen space pass systematically **overshoots darkness while
undershooting area**, which is the signature of a `min()` composition that can only darken: where
the march finds the occluder it commits fully, and where it does not there is nothing at all. A
single figure of merit hides which half is wrong, and that is exactly the mistake that made
`surface_thickness` look like it wanted retuning when it did not.

`--bands` exists for the same reason at a smaller scale. A frame average hides that every variant
undershoots near the camera — where a tall blade throws a shadow longer than the quality tier's
march, which is bounded in **pixels** — and overshoots far away, where the fixed one pixel of
rasterization overshoot is proportionally huge on a blade under two pixels deep.

## The rigs

Each pins its own quality tier, capture resolution and geometry, because **each published table was
measured at different ones and they are not cosmetic**. The tier bounds the march in pixels and so
sets area directly; the resolution sets how many pixels wide a blade is, which is the entire
variable `hardness` exists for. Letting a rig inherit either from the shared `project.godot` is how
a run silently stops reproducing — it happened while this directory was being written.

| rig | geometry | tier | capture | what it is for |
| --- | --- | --- | --- | --- |
| `probe` | 20 separated prisms, 2.2 cm × 4 mm, 90 cm tall | Medium | 1280×720 | the `hardness` sweep. Few enough occluders that one shadow can be looked at |
| `field` | 4,504 blades, 1.0 × 1.5 cm × 25 cm, clustered | High | 1600×900 | what a game actually scatters. The `surface_thickness` question |
| `field_thin` | 15,000 blades, 2.2 cm × 4 mm | Medium | 1280×720 | nearly razor thin — the far end of the size range |
| `opacity` | boxes on open ground | — | 800×450 | is `shadow_opacity` linear on a raytraced sun, with the shadow-map control |
| `geometry` | shared ArrayMeshes, compressed and non-indexed variants, 16/32-bit indices, buffer replacement, blend shapes, eviction | — | 641×359 | exact image regression against a baseline engine for changes to geometry storage |
| `material` | indexed/non-indexed and compressed ArrayMeshes with known shader inputs | — | 16×16 capture tiles, 641×359 window | explicit triangle-material capture checks; no GI lighting or performance measurement |
| `gi` | colored room, two white boxes, one hard-shadow omni light | — | 641×359 | uncached diffuse transport validation; enabled/disabled stills and material/energy controls |

`probe` also carries the controls that ruled out explanations before the cause was found:
`SSS_SUN_AZ`, `SSS_SUN_EL`, `SSS_BLADE_W`, `SSS_BLADE_D`, `SSS_RANDOM_YAW`, `SSS_BIAS`,
`SSS_NBIAS`. Set `SSS_BLADE_W=0.12` for fat blades whose shadow is tens of pixels across, which is
what a *width* measurement needs; it does not give the same numbers as the default and is not a
substitute for it.

## Getting a binary

### Geometry cache regression

`material` calls `RenderingServer.bake_render_triangle_material()` and compares the
returned channels with analytically known values. It checks original UV0/UV2, colors,
custom attributes, original indexed vertex IDs, tangent-space normals, transforms,
cutouts, HDR emission, parameter and texture updates, surface material selection,
page clipping, and existing UV2 baking after a triangle capture. Normals must be
normalized after decoding the native best-fit representation. The rig exits nonzero
on an assertion or engine error. It requires Forward+ but does not itself trace rays;
RT shadow support advertised by the project is not evidence of GI. See
[the capture contract](../../internals/rt-materials.md) for unsupported cases.

`gi` is a separate transport validation checkpoint for the GI port, not AMD's
screen-probe/radiance-cache implementation. `RTGI_SAMPLES` sets its paths per pixel
(default 1). It captures disabled, one-encounter, three-encounter, zero-indirect-energy,
changed-wall-material, and disabled-again images. `score_gi.py` verifies extra light,
color transfer from a non-shadow-casting wall onto a white box, and exact restoration
of the direct-only control. The printed RGB gains are display-space diagnostics,
not linear-light energy measurements. See [the mode's documentation](../../features/rtgi-validation.md).

`gi_compare` reuses the same room to compare the cached AMD diffuse path with
native VoxelGI and SDFGI. Run `./run.sh gi_compare`. AMD captures use approximately
1/4 and 1 primary ray per pixel per frame, with multibounce and denoising on.
Native geometry is marked static, VoxelGI is baked at 128 and 256 subdivisions
(including a normal-bias variant), and SDFGI is captured at default and finer
occlusion-enabled settings. Native setups get 120 settling frames, an early
capture, 60 additional frames, and a final capture. `score_gi_compare.py` checks
exact disabled restoration and reports remaining native settling differences.
See [comparison settings](../../features/amd-gi.md#native-comparisons).
These are neither accuracy scores against a perfect reference nor GPU benchmarks.

`geometry` requires ray queries and rejects shadow-map fallback. It also requires the
`RT_DEBUG pre_opaque` log to establish a traceable TLAS. The runner enables that diagnostic
automatically and fails on engine errors or missing captures. A control checks that shadows
actually change the image, and two others check that replacement and deformation change it.

Run once with a baseline engine and preserve `out/geometry` outside `out/` before running
the modified engine. Then use:

```
GODOT_BIN=/path/to/modified/godot ./run.sh geometry --reference /path/to/baseline-captures
```

Each of the 11 captures must match the corresponding baseline pixel for pixel. This compares
engines, not compressed geometry against uncompressed geometry. Both engines must use the same
driver and resolution. A run without `--reference` checks controls and capture completeness only.
The rig exercises blend-shape deformation, not skeletal skinning; neither this rig nor software
Vulkan can establish the game's hardware performance or future GI fidelity.

### Engine build

`run.sh` looks for `bin/godot.linuxbsd.editor.x86_64` at the repository root, or wherever
`GODOT_BIN` points. The binary is gitignored, so a fresh clone has none. Build one with:

```
scons platform=linuxbsd target=editor dev_build=no debug_symbols=no -j$(nproc)
```

The project's own builds come from GitHub Actions rather than from a local toolchain.
`.github/workflows/linux_builds.yml` still exists and carries `workflow_dispatch`, so a Linux binary
and the class-reference check can both be had from the Actions tab on demand, even though the
default push only runs the Windows jobs.

## Running it

```
./run.sh field                                       the default two hardness rows
./run.sh probe                                       the full hardness sweep, one render
./run.sh opacity                                     the shadow_opacity linearity check
SHADOW_THICKNESS=0.0025,0.005,0.010 ./run.sh field --bands
./run.sh field --srgb --overlay /tmp/agree.png
```

Anything after the rig name goes to `score.py`, except on `opacity`, whose scorer takes the output
directory and ignores the rest. `GODOT_BIN` points at the engine binary, `SHADOW_RES` and
`SHADOW_QUALITY` override a rig's pinned values — for deliberately re-deriving, never for
reproducing. `SHADOW_HARDNESS` and `SHADOW_THICKNESS` are comma-separated lists rendered
as a cross product; the whole sweep runs in **one** render, because every `screen_space_shadows`
setting is live from one frame to the next.

A field run is about a minute under lavapipe.

## What this harness cannot tell you

Two of these are standing blind spots rather than oversights, and `../ao_validation/` has both of
them as well: **no rig measures temporal behavior, and no rig can produce a compressed mesh.**

**Cost.** Every timing under lavapipe is meaningless; profile on hardware.

**Anything temporal.** `project.godot` turns the denoiser off and sets `samples_per_light = 1`, and
every capture is a settled still frame from a static camera, deliberately: a filtered accumulating
shadow is not deterministic frame to frame and cannot be differenced against a fixed baseline. So
no rig here measures the denoiser, and none can while that holds -- ghosting, steady state noise,
disocclusion and every history clamp setting are outside what a number from here can mean.

`denoiser_sim.py`, in this directory, covers that gap by simulation rather than by render: it
reimplements `rt_shadow_temporal.glsl` in numpy and drives it with synthetic visibility whose true
value is known exactly, which a render never gives you. **It is a model of the shader rather than a
measurement of it**, so label anything published from it simulated; its docstring states what the
model leaves out, and `../../HISTORY.md` carries the tables it prints. Four modes, and `--quick`
shortens any of them:

- no flag -- the temporal pass's 3x3 gather against a 5x5 one, noise against bias: what the
  shader's choice between the two widths was decided from.
- `--kernels` -- weighted 5x5 gathers against the box.
- `--radius` -- the history clamp window each variance estimator asks for, the old one against the
  shipped one, at one to eight samples per light.
- `--window` -- what a tight clamp does to a penumbra: three penumbra widths against three
  `history_clamp_sigma` values and two window lengths.

**Anything that depends on how a mesh was authored.** Every rig here builds its geometry
procedurally in GDScript from `BoxMesh` and `PlaneMesh`, and `PrimitiveMesh` uploads its surface
with a compress format of zero (`scene/resources/3d/primitive_meshes.cpp:129`), so every mesh is
uncompressed, unskinned, single surface and never imported. Compressed vertex attributes -- what an
IMPORTED mesh gets by default -- take a separate path into the acceleration structure, and nothing
here walks it. That is how a bug that made every compressed surface fail to build a BLAS, so that no
imported mesh cast a raytraced shadow at all, went through this harness unseen. Closing it is one
rig building its blade as an `ArrayMesh` and passing `Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES` as the
`flags` argument of `add_surface_from_arrays`; until that exists, test any change to
`_build_blas_geometry` against such a mesh by hand.

The raytraced reference itself is real under lavapipe -- it advertises ray query support, the fork
takes it, and `GODOT_RT_DEBUG=1` shows the TLAS built and a mask slot granted and written. Startup
prints `OpTypeRayQueryKHR is not supported yet.` once; **that line comes from the Mesa stack, not
from the engine, and does not stop the trace.** The proof is behavioral rather than textual: the
opacity rig can tell the raytraced branch from the shadow-map branch, which it could not if the mask
were absent. Worth knowing, because the line reads exactly like the reference silently degrading and
believing it would make every "vs trace" ratio here look untrustworthy.

**`restrict_casters` has no rig here, and the four that exist cannot give it one.** All of them are
grass on an empty ground plane, so the only geometry in the acceleration structure is a flat plane,
and a flat plane cannot occlude itself from a 38 degree sun: toggling the setting changes the frame
by a single pixel, which is correct and tells you nothing. Do not read that as the toggle doing
nothing. A rig that could settle it needs real props at `cast_shadow = On` standing among the grass
-- rocks, posts, a wall -- so there is genuinely redundant casting to remove; `field.gd` is the
closest starting point. Why the default is off, and what flipping it would take, is in section 10.6
of `../../features/screen-space-shadows.md`.

## The numbers to reproduce

If a change is not meant to move the screen space shadow, these should come back unchanged. All
linear; the sRGB column of `--srgb` is in `../../HISTORY.md` beside them.

`./run.sh probe` — trace removes 0.2767 per px over 2217 px:

| `hardness` | darkness | mass | area |
| --- | --- | --- | --- |
| 0.00 (Bend) | 0.445 | 0.664 | 1.49 |
| 0.25 | 0.563 | 0.867 | 1.54 |
| 0.50 | 0.685 | 1.069 | 1.56 |
| 0.75 | 0.812 | 1.273 | 1.57 |
| 1.00 (default) | 0.939 | 1.477 | 1.57 |

`./run.sh field` — trace removes 0.1595 per px over 253,632 px:

| | darkness | mass | area |
| --- | --- | --- | --- |
| `hardness` 0 | 0.802 | 0.594 | 0.740 |
| `hardness` 1 (default) | 1.052 | 0.832 | 0.792 |

`./run.sh field_thin` — trace removes 0.1044 per px over 132,257 px:

| | darkness | mass | area |
| --- | --- | --- | --- |
| `hardness` 0 | 0.864 | 0.468 | 0.541 |
| `hardness` 1 (default) | 1.149 | 0.830 | 0.722 |

`./run.sh opacity` — every exponent `1.00`, and the shadow-map control at ratio `0.500`.

The harness is byte-for-byte deterministic under lavapipe: two consecutive runs of the same binary
and scene differ by zero pixels. So a difference of even a few hundred pixels is a real change, not
noise, and is worth explaining rather than dismissing.

### Sparse AMD GI progress

`./run.sh amd_gi_sampling` compares uniform and radiance-guided sampling at a fixed
camera and approximately 1/4 primary ray per pixel per frame. Multibounce and
denoising stay enabled. It verifies black-history recovery when an emissive
ceiling turns on, decay after emission is removed, unchanged allocation on
sampling switches, and exact disabled restoration. Each stage settles for 64
frames plus capture synchronization. Adaptive placement and cache toggles retain
the primary-ray budget. A short camera sweep and return separately exercises
displaced-probe reuse. The diagnostic GPU readback checks queue ownership and
LRU permutations; it is not a hardware performance benchmark.

`./run.sh amd_gi_cache` focuses on small camera motion, displacement/reuse, and
history lifetime. It requires exactly one initialization reset across a camera
sweep and return plus 64 stationary frames. GPU ownership checks run every frame;
the disabled image must restore exactly.

`./run.sh amd_gi_materials` checks retained preparation with a vertex-colored
non-caster wall. An attribute-buffer edit must change indirect light on a separate
box and match a freshly rebuilt surface within the stated stochastic tolerance.
The diagnostic preparation log requires only the seven initial pages and the two
changed wall pages to prepare. Unchanged frames reuse geometry and targets while
rendering current material pixels. The geometry rig separately requires an
in-place vertex/index-buffer edit to match a freshly rebuilt BLAS exactly.

`./run.sh amd_gi_lights` compares exhaustive light evaluation with world-cache
reservoir resampling at the same 1/4 primary-ray budget, with multibounce and
denoising on. Four identical lights check normalization; varied positions, colors,
and energy exercise nonuniform targets and visibility. GPU readback validates
stored light indices, finite RIS weights, and confidence bounds, and requires
temporal reuse. Exact direct-only controls and reservoir allocation release are
checked separately. This does not compare GPU performance or a high-sample reference.

`./run.sh amd_gi_bounces` toggles multibounce off/on/off while keeping the 1/4
primary-ray budget and denoiser fixed. It requires extra indirect energy, restores
the single-bounce result within stochastic tolerance, and checks exact buffer
release. Diagnostic GPU readback verifies secondary hits originate from unique
primary cache owners and create additional cache receivers. Continuation probability
stays at 0.3. Disabled direct-only restoration must be exact.

`./run.sh amd_gi` renders the cached diffuse pipeline at approximately 1/4 and 1
primary GI ray per internal pixel per frame, with multibounce and denoising on.
It includes startup/settled captures, material and light controls, camera cuts,
and disabled restoration. See [settings and limitations](../../features/amd-gi.md).
The historical high-sample `gi` / `gi_compare` images are debugging references,
not representative progress or equal-budget comparisons.


AMD GI sky/reflection integration checks: `run.sh amd_gi_sky` and
`run.sh amd_gi_reflections`. Both keep diffuse at 1/4 primary ray/pixel with
multibounce and denoising enabled. Sky checks removal, color, orientation, ambient
occlusion and disabled restoration. Glossy checks half/full sampling, an emitter
behind the camera, motion, and buffer release; synchronous GPU sample validation
is diagnostic-only. See the AMD GI feature document for remaining limitations.

`run.sh amd_gi_dirty_materials` verifies static page reuse, image updates in place,
material emission and TIME/global-uniform refresh. `run.sh amd_gi_fsr2` checks a
jittered FSR2 Performance viewport at odd internal dimensions with both GI lobes,
multibounce and denoising enabled. Neither harness measures target-hardware speed.

AMD GI scene compatibility checks: `run.sh amd_gi_atlas` exercises packed small
surfaces and relocation across layers; `run.sh amd_gi_dynamic_lighting` checks
continuous sky/light changes; `GODOT_AMD_GI_VALIDATE_CACHE=1 run.sh amd_gi_deformation`
compares native skeleton/blend-shape output with independently baked geometry and
checks local motion invalidation, including FSR2. These are lavapipe correctness
checks, not target-hardware performance measurements.

`run.sh amd_gi_material_sharing` exercises 300 repeated mesh instances and compares
local-normal captures against independent world captures. `run.sh amd_gi_multimesh`
compares per-element colors/custom data/IDs against separate MeshInstances and
checks movement and live updates. `amd_gi_atlas` also grows beyond the old capacity
and shrinks its live budget. Keep denoising and the quarter-ray diffuse budget on;
these are native rendering checks, not hardware performance estimates.

`./run.sh amd_gi_feedback` validates the optional native screen-lighting feedback.
It keeps quarter primary diffuse sampling and denoisers on, checks actual GPU
acceptance, changes fog and exposure independently, and checks target release and
per-light indirect-energy/disabled controls. Synchronous diagnostic readback means
its timings must not be used as hardware performance measurements.

`./run.sh amd_gi_hit_updates` exercises all-hit and one-hit world-cache modes,
including multibounce on/off, restored-mode lighting, exact disabled controls and
release of the list/sample buffers. `GODOT_AMD_GI_VALIDATE_HITS` verifies actual
GPU lists: every registered hit exactly once, matching cells, acyclic links,
finite complete samples. Its readbacks are diagnostic and must be off for timing.
The matched `amd_gi_budget_compare` captures explicitly enable all-hit accumulation
and native screen feedback at both budgets, with denoisers on and 64 fresh GI draws.

`./run.sh amd_gi_opacity` places an emissive card and an alpha blocker behind the
camera. It compares zero coverage against hiding the blocker, full coverage against
an opaque material, and fractional coverage between those endpoints. It keeps the
quarter primary budget and denoiser enabled; multibounce/screen feedback are off
to isolate transport. Disabled images must remain exact. This is a correctness
rig, not a representative all-features-on progress capture or hardware benchmark.

AMD GI scene-churn regression: `run.sh amd_gi_scene_churn` crosses collection
boundaries, rotates the camera and adds/removes geometry, requiring only one global
initialization and bounded local invalidation. `run.sh amd_gi_flashlight` checks
moving spotlight GI with a quarter primary budget and denoising; its image scorer
decodes sRGB and compares resampled with exhaustive light shading. Switch-off must
restore the dark reference exactly. These tests use the lightweight
`GODOT_AMD_GI_TRACE_HISTORY` diagnostic, not synchronous GPU cache readback.

`run.sh amd_gi_material_density` switches 8→4→8-pixel hit-material tiles live,
checks a fourfold atlas byte reduction, tinted-instance sharing and restoration.
Triangle geometry, primary ray density and denoising stay unchanged.
