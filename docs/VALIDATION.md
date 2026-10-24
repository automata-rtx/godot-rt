# Validating a Change to This Fork

AMD GI GPU cost investigation on the RTX 5090: see the
[2026-10-24 profile](validation/amd_gi_profile_2026_10_24/README.md), external
fps-proto harness, per-frame evidence and temporary instrumentation patch.
Synchronized timestamps correct the earlier hit-shading attribution: light-grid
construction and emitter regeneration dominate. Diagnostic ablations are not
shipping quality presets; the report records the separate exit-time fault.

Compute storage/indirect synchronization: run the graphical Windows editor with
`--path docs/validation/shadow_validation --script res://compute_indirect_storage.gd`.
The local RenderingDevice fixture alternates 256 GPU-produced dispatch counts
with consumers that also bind the arguments as storage. It checks 16,384 words
and exits nonzero on mismatch. No CPU readback occurs between dispatches. On the
RTX 5090, the original graph dropped the indirect-read access and produced 7,567
incorrect words; merging both accesses produced zero. Run
`amd_gi_consequential` with hit, bounce and cache diagnostics as the separate
production-pipeline integration test. These are hardware correctness checks,
not image parity or general performance claims.

How to measure a change to godot-rt, what each rig's measurement is worth, and the four things no
rig here can tell you. The shared layer above `docs/validation/`. Not here: what the measurements
found or refuted (`docs/HISTORY.md`); diagnosing a symptom (`docs/TROUBLESHOOTING.md`); porting to a
newer engine (`docs/PORTING.md`); how to run one rig (that rig's own README, the maintained copy).

## Consequential correction integration

See [the current handoff](AMD_GI_IMPLEMENTATION.md) for status and unresolved game issues;
[archived correction evidence](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-consequential-corrections) records earlier test results. `./run.sh amd_gi_consequential` exercises quarter-budget
compaction, hit/cache membership, multibounce, camera motion, an empty screen,
odd-size resize and disable. `./run.sh amd_gi_exposure` exercises manual and automatic
exposure changes with accumulated glossy history. These do not establish whole-pipeline
AMD image equivalence or hardware performance.

The emitter rig's history assertion now follows the reference zero/nonzero light-class
settings transition: its sole emitter produces nine settings-only resets through four
off/on cycles and final removal. Ordinary light-index changes do not justify a global
reset. Existing emitter image thresholds are unchanged. Reflection scoring requires
641×359 because its mirror/emitter regions are defined at that fixture resolution.

## AMD reference-correction controls

The [full AMD source comparison](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-full-comparison) is complete.
Its [coverage appendix](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-comparison-coverage) distinguishes matching
helpers from different inputs, storage, branch behavior and missing stages.
Existing equation/regression passes are not whole-pipeline AMD equivalence.
The comparison added only read-only source/data/algebra checks, not new renders.
The archive records both failed attempts and later results; current hardware/gameplay qualification remains open. Future preview comparisons
use quarter primary samples per pixel, denoising enabled and native-resolution FSR2.

`./run.sh amd_gi_winding` traces 48 rays through a native BoxMesh with normal and
mirrored instance transforms. It establishes Vulkan's facing flag independently
of lighting, so front-facing emission cannot silently disappear. Both inside and
outside hits are checked, including a negative control without the facing flip.

`amd_gi_reference` also compares the reference ray-origin offset and rough
secondary BRDF, in addition to cache, denoiser and bounded-VNDF equations.
The diffuse control now measures light-change decay separately from the exact
zero-indirect-energy image. The latter starts with fresh history: an immediate
clear after every light edit would contradict AMD's retained-cache behavior.
The exact GI-disabled restoration check remains unchanged.

## The one rule: score in linear light

**A PNG is sRGB encoded. Decode to linear before differencing anything.**

    a <= 0.04045 ? a / 12.92 : ((a + 0.055) / 1.055) ** 2.4

- Differencing sRGB values measures gamma space, not light. A darkness ratio read off that
  difference is not the ratio of light the two images remove.
- Every published screen space shadow ratio was first taken that way and **all had to be
  re-derived** — gamma compresses the dark end, so every ratio came out low and the technique looked
  further from its reference than it is (`docs/HISTORY.md`).
- The error is invisible in its own output: the numbers look plausible, merely pessimistic.
- Both harnesses decode first, always. `docs/validation/shadow_validation/score.py --srgb` exists
  only so a number found in an old note can be *identified* as gamma-space, never to produce one.

## Build a control with a known exact answer into every new measurement

- What caught the gamma error was a control that could not miss and did. `./run.sh opacity`
  (`docs/validation/shadow_validation/opacity.gd`) renders that sun on **shadow maps** — a path this
  fork does not touch, which applies `shadow_opacity` exactly once — so at an opacity of 0.5 it must
  read **`0.500`**. It read `0.336`.
- **If that control ever moves off `0.500` again, fix the measurement before believing anything else
  it says.** Same for that rig's raytraced rows: `shadow_opacity` is a linear fade, so fitting the
  exponent counts how many times the fade was applied. Every raytraced exponent must be `1.00`; a
  `2.00` is a double-apply, which is how one was found and fixed.
- Every rig renders **one scene several ways, changing only the term under test**, so the difference
  *is* that term — no segmentation mask, no assumption about which pixels are ground. Preserve that
  property in anything new.

## Getting a binary

The owner builds through **GitHub Actions**; a local build exists only to test before pushing.

```
scons platform=linuxbsd target=editor dev_build=no debug_symbols=no -j$(nproc)
```

- Lands at `bin/godot.linuxbsd.editor.x86_64`, gitignored, so a fresh clone has none. At `-j4` an
  incremental build is about 90 seconds. Both `run.sh` scripts look there, or at `GODOT_BIN`.
- A Linux binary can also be had from CI on demand: `.github/workflows/linux_builds.yml` was not
  deleted and still carries `workflow_dispatch`.

## The two harnesses

Do not write a new script. Each `run.sh` already does the whole dance — parse check, Xvfb, lavapipe
ICD, capture, move, score.

| harness | what it scores | entry point |
| --- | --- | --- |
| `docs/validation/shadow_validation/` | the screen space contact shadow against a **raytraced** reference, and `shadow_opacity` linearity | `./run.sh probe` / `field` / `field_thin` / `opacity` |
| `docs/validation/shadow_validation/geometry.gd` | geometry-cache rendering regressions against a baseline engine, including compressed meshes and deformation | `./run.sh geometry --reference /path/to/baseline-captures` |
| `docs/validation/shadow_validation/material.gd` | explicit native triangle-material capture against analytical outputs, including original attributes, material updates, and legacy UV2 baking | `./run.sh material` |
| `docs/validation/shadow_validation/gi.gd` | uncached diffuse transport stills: extra-bounce energy, non-caster material transfer, zero-indirect-energy control, and exact disabled restoration | `RTGI_SAMPLES=1 ./run.sh gi` |
| `docs/validation/shadow_validation/amd_gi.gd` | sparse cached diffuse, multibounce and denoising; startup, material/light/camera controls and disabled restoration | `./run.sh amd_gi` |
| `docs/validation/shadow_validation/amd_gi_sampling.gd` | fixed-budget guiding/adaptive/cache switches, dark-history recovery, emissive removal, GPU cache ownership, allocation and disabled controls | `./run.sh amd_gi_sampling` |
| `docs/validation/shadow_validation/amd_gi_cache.gd` | GPU probe ownership/LRU permutation, small-camera-motion history preservation, displacement/reuse and disabled restoration | `./run.sh amd_gi_cache` |
| `docs/validation/shadow_validation/amd_gi_materials.gd` | retained capture preparation, in-place vertex-color edits versus surface rebuild, non-caster indirect color transfer and disabled restoration | `./run.sh amd_gi_materials` |
| `docs/validation/shadow_validation/amd_gi_lights.gd` | light-reservoir normalization/reuse, exhaustive-light comparison at the same primary-ray budget, allocation and direct-only controls | `./run.sh amd_gi_lights` |
| `docs/validation/shadow_validation/amd_gi_bounces.gd` | secondary receiver population/ownership, multibounce energy and allocation toggle at a fixed primary-ray budget | `./run.sh amd_gi_bounces` |
| `docs/validation/shadow_validation/amd_gi_emitters.gd` | emission-only receiver energy, hit-sampling comparison, repeated flicker and removal without full resets, at quarter rate | `./run.sh amd_gi_emitters` |
| `docs/validation/shadow_validation/amd_gi_gameplay_audit.gd` | moving-metal history, analytic-light membership pulses and retained flickering-mesh captures; continuity counters, not visual acceptance | `./run.sh amd_gi_gameplay_audit` |
| `docs/validation/shadow_validation/amd_gi_atlas.gd` | persistent placements, cross-layer copies, live growth/shrink and bounded new material preparation | `./run.sh amd_gi_atlas` |
| `docs/validation/shadow_validation/amd_gi_reflections.gd` | off-screen reflected emitter, motion/ghosting, half/full resolution, compacted/direct dispatch and allocation release | `./run.sh amd_gi_reflections` |
| `docs/validation/shadow_validation/gi_compare.gd` | same-room diffuse stills against baked VoxelGI and settled SDFGI, with disabled controls and settling diagnostics | `./run.sh gi_compare` |
| `docs/validation/ao_validation/` | both occlusion estimators against **two** CPU-traced references (real geometry, and a depth buffer from the camera's own view) | `./run.sh room gtao`, then `ao_truth.py` and `ao_compare.py` |

- Each README carries its own invocation, environment variables and scene list; read it rather than
  reconstructing a command line.
- **Each rig pins its own quality tier, capture resolution and geometry** rather than inheriting
  them from the shared `project.godot`. The tier bounds the contact shadow's march in pixels and so
  sets area directly; the resolution sets how many pixels wide a blade is, which is the entire
  variable `hardness` exists for. `SHADOW_RES` and `SHADOW_QUALITY` are for deliberately
  re-deriving, never for reproducing.
- Two traps are encoded in the scripts rather than left to be rediscovered: both parse-check
  headlessly before opening a window, because a GDScript parse error otherwise leaves Godot sitting
  on a window until the timeout; and both kill Xvfb **by PID from a trap**, because `pkill -f`
  matches the running script's own command line. Symptoms in `docs/TROUBLESHOOTING.md`.
- **Byte-for-byte deterministic**: two consecutive runs of the same binary and scene differ by zero
  pixels, so even a few hundred pixels of difference is a real change worth explaining.

## What lavapipe does and does not run

- **lavapipe runs the raytraced path.** It advertises ray query support and the fork takes it, so
  the raytraced reference is real under software rendering.
- It prints `OpTypeRayQueryKHR is not supported yet.` once at startup. **That line comes from the
  Mesa stack, not the engine, and does not stop the trace** — it reads exactly like the reference
  silently degrading, which would make every "vs trace" ratio look untrustworthy.
- `GODOT_RT_DEBUG=1` settles it. `render_forward_clustered.cpp:2148` prints
  `RT_DEBUG pre_opaque: rb=1 available=1 rt_lights=1 new_slots=1 tlas=1` — a mask slot granted and
  the structure built. Printed only when that string *changes*, so expect it once, not per frame;
  the variable is read once at startup and cached (`environment/rt_scene.cpp:49`), so set it in the
  launching shell.
- Behavioral proof, stronger than either line: the `opacity` rig tells the raytraced branch from the
  shadow-map branch, impossible if the mask were absent.
- lavapipe traverses the BVH on the CPU, so it **overstates** rasterization cost and **understates**
  the benefit of ray early-out. Image comparisons are trustworthy; frame times are not.

## Standing blind spots — limitations of the approach, not gaps awaiting a better run

**1. Cost.** Every timing under lavapipe is meaningless. Profile on hardware — next section.

**2. Anything temporal.** Both harnesses capture settled still frames from a static camera,
deliberately: a filtered accumulating shadow is not deterministic frame to frame and cannot be
differenced against a fixed baseline. The shadow rigs' `project.godot` turns the denoiser off and
sets `samples_per_light = 1`; the AO rigs capture one frame at frame 30, and neither estimator
accumulates anyway (the gather's dither is fixed per pixel with no frame counter, because with no
temporal antialiasing downstream nothing would resolve a changing one). Ghosting, steady-state
noise, disocclusion and every history clamp setting are outside what either rig can mean.
- Covered on the shadow side by **simulation, not render**:
  `docs/validation/shadow_validation/denoiser_sim.py` reimplements `rt_shadow_temporal.glsl` in
  numpy, driven by synthetic visibility whose true value is known exactly, which a render never
  gives you. **Label anything published from it simulated.** Its docstring states what it models
  faithfully (binary taps, 8-bit storage of the square root of visibility, the dithered store, the
  variance decomposition and clamp) and what it omits (reprojection — the camera is static, the
  worst case for ghosting; the a-trous pass; the surface and light-set rejection tests).
- Nothing covers the motion side of the AO dither: how that fixed pattern reads while the camera
  moves is unmeasured.

**3. How a mesh was authored.** The original AO and shadow-accuracy rigs build geometry
procedurally in GDScript from `BoxMesh` and `PlaneMesh`, and `PrimitiveMesh` uploads its surface with a compress format of zero
(`scene/resources/3d/primitive_meshes.cpp:129`) — so every mesh in both directories is uncompressed,
unskinned, single surface and never imported.
- Compressed vertex attributes, which is what an **imported** mesh gets by default, take a separate
  path into the acceleration structure and nothing here walks it.
- That is how a real bug went through unseen: `blas_create` resolves a geometry's vertex buffer
  through `vertex_buffer_owner` alone, and the dequantized position buffer for a compressed mesh was
  created with `storage_buffer_create`, so no compressed surface built a BLAS and **no imported mesh
  cast a raytraced shadow at all**.
- The `geometry` regression rig now supplies compressed `ArrayMesh` geometry, non-indexed and
  16/32-bit indexed meshes, shared instances, source-buffer replacement, blend-shape deformation,
  eviction and destruction. It compares each stage against the same stage from a baseline engine.
  It does not validate skeletal animation, actual imported assets, or establish ground-truth
  correctness of a baseline that already has a defect.

**4. Streamline / DLSS.** Nothing here can exercise it: the driver files compile to empty objects
off Windows, so CI type-checks them and nothing runs them. The reactive mask shader is validated
only in that `glslangValidator` compiles it and reflects a 16-byte push block — nothing about
whether DLSS likes the tag. Hardware is the only validator; the ladder is in
`docs/TROUBLESHOOTING.md`. **No Streamline tagging change is low risk**: the first attempt was
reasoned as additive and low risk, both claims about the code, and the failure was in the runtime
(`docs/internals/dlss.md`).

**Not a blind spot but a missing rig:** `restrict_casters` has none. All four shadow rigs are grass
on an empty ground plane, so the toggle moves a single pixel and settles nothing; why it ships off,
and what a real rig needs, are in `docs/features/screen-space-shadows.md`.

## Measuring cost — hardware only

- **CPU**: the `RT_DEBUG cpu over N frames: gather avg ... peak ... | build avg ... peak ...` line
  (`servers/rendering/renderer_scene_cull.cpp:74`), under `GODOT_RT_DEBUG=1`.
- **GPU**: the Visual Profiler rows `Raytraced Shadows` (`render_forward_clustered.cpp:2166`) and
  `Process GTAO` (`:1555`). Reach them from the **Debugger** panel → **Visual Profiler** tab; click
  the graph to freeze a frame, then read that frame's rows. No `GODOT_RT_DEBUG` figure is GPU time,
  and profiler rows are named for the work that *follows* their timestamp — see
  `docs/TROUBLESHOOTING.md` before reading one.
- **Never infer a pass's cost from whole-frame framerates.** The GTAO fixed-versus-gather split was
  first derived by subtracting three frame totals and came out at 40–65% fixed against an actual 9%:
  a small error in a large subtrahend becomes a large error in a small difference. The wrong
  derivation and the three-rung solve that refuted it: `docs/HISTORY.md`.
- **Two captures split a GTAO reading with no code change and no restart**: read `Process GTAO` with
  `half_size` on, then off. Which pair applies depends on `ground_truth/shading_rate`, because
  `half_size` on shades a checkerboard — half the pixels — by default (arithmetic). A **negative**
  fixed cost means the wrong pair, not a bad reading. Discard the first frame after the toggle:
  `gather_size` changes with `half_size`, and the buffers are reallocated in the mark.

| shading rate | fixed cost | full-resolution gather |
| --- | --- | --- |
| Checkerboard (default) | `F = 2*t_half - t_full` | `G_full = 2*(t_full - t_half)` |
| Quarter Resolution | `F = (4*t_half - t_full)/3` | `G_full = (4/3)*(t_full - t_half)` |

## Standards for particular claims

| claim | what settles it |
| --- | --- |
| "this costs nothing when unused" | **Byte-identical output.** Build with the change and render; stash the change, rebuild, render the same scene; compare checksums. That is how the fog work was shown to be free. |
| a **spatial** denoiser question | **RMSE against a high-sample, denoiser-off render of the same scene** — one sample plus denoiser versus sixteen-sample ground truth. Edge-width metrics were tried first and proved unreliable, confounded by the two images having different noise levels. |
| a **geometric** defect | A closed form, not a rendered reference: a rendered reference carries the same geometric defect as the render. (Why `docs/PORTING.md` stage 6's acceptance gate is not the RMSE technique above.) |
| a **temporal** question | Nothing rendered. `docs/validation/shadow_validation/denoiser_sim.py`, labeled simulated. |
| a push constant size change | The reflect-the-block recipe and the registry of all **nine** C++/GLSL pairings, in `docs/internals/rt-shadows.md`. |

- **Score the estimator AND what ships.** `docs/validation/ao_validation/main.gd` defaults to the
  identity transfer so `ao_compare.py` can recover raw visibility by division, which measures the
  estimator; run it again with `AO_INTENSITY` and `AO_POWER` at the values a project actually uses,
  to measure what a player sees. `ao_compare.py` prints the fraction of the frame below one 8-bit
  code alongside the error columns, because **a clipping transfer looks fine on every average and
  terrible on screen**.
- **A CPU model beside the shader localizes a fault.** `docs/validation/ao_validation/gtao_sim.py`
  reproduces the engine to within 0.001 mean absolute error every time it has been checked. If the
  model and the shader disagree, the shader has a plumbing bug; if they agree but both miss the
  reference, the estimator itself is wrong. Every defect fixed so far was found that way. No command
  line — import it.

**Provenance is mandatory.** Every number carries which harness produced it, or that it is simulated
or arithmetic. A number with none of those is an opinion.

## Where the numbers live

| | |
| --- | --- |
| screen space shadow reproduce tables (`probe`, `field`, `field_thin`, `opacity`) | `docs/validation/shadow_validation/README.md`, "The numbers to reproduce" |
| AO accuracy targets against a CPU trace | `docs/features/ambient-occlusion.md`, "Accuracy" |
| AO smoke test — a run happened, not a score | `docs/validation/ao_validation/README.md` |
| denoiser simulation tables | `docs/HISTORY.md` (printed by `denoiser_sim.py`) |
| everything measured, refuted or superseded | `docs/HISTORY.md` |

The AO harness has **no fixed table of numbers to reproduce**; the shadow harness does.


## CI, and what it no longer checks

`.github/workflows/runner.yml` runs static checks, then **Windows builds only**. The Android, iOS,
Linux, macOS and Web workflow files are untouched but not invoked.

- Dropped along with the Linux jobs: the `--doctool` class reference check, the GDExtension API
  compatibility check, and the project export/converter tests (`runner.yml:13`).
- **Unit tests are not lost** — the Windows job runs `--test`.
- `linux_builds.yml` still carries `workflow_dispatch`, so those checks can be run on demand from
  the Actions tab without restoring them to every push.
- **If you add or change a bound property, run `godot --headless --doctool .` yourself and commit
  the result.** Nothing else will catch it.
- Matrix: editor x2 (MSVC, clang-cl) and `template_release` x2 (MSVC, MinGW). Artifacts upload for
  MSVC only: **`windows-editor`** and **`windows-template`**.
- Before pushing, run the repo's own hooks over the **range**, not just what is staged; they rewrite
  in place, and codespell rejects British spellings (`CLAUDE.md`):
  `prek run --from-ref origin/master --to-ref HEAD`

## Exporting a build to test

- **An export needs this fork's own template.** Stock Godot templates produce a running game with
  none of the fork in it — the renderer changes are in the binary, not in the project.
- The `windows-template` artifact holds `godot.windows.template_release.x86_64.exe` and its
  `.console.exe`. Point the preset at it with **Export → preset → Custom Template → Release**, which
  sidesteps version matching entirely: a fork's version string will not line up with any installed
  template.
- **No `template_debug` build exists in the matrix**, so debug exports, one-click deploy and remote
  debugging into an exported build do not work, and nothing shippable has `DEBUG_ENABLED` on —
  exercise a push constant change in an **editor** build (`CLAUDE.md`).


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

Reference-conformance checks: `run.sh amd_gi_reference` compiles the production
diffuse-denoiser/GGX/cache-update helpers alongside an independent oracle extracted from
Capsaicin `914b915`. It checks 4,096 cases and fails on nonfinite results or relative
error above 1e-5. This verifies those equations, not complete renderer parity.
`amd_gi_lights` additionally reads the independent reservoir hash and verifies every
prefix, compacted hit, entry/slot ownership and packed confidence, including entries
containing multiple hits. These structural checks do not alone establish estimator fidelity.
See [current status](AMD_GI_IMPLEMENTATION.md) and consult the archived audit only for historical evidence.

Legacy capture-era scene checks (not proof of current source-material behavior): `run.sh amd_gi_atlas` exercises packed small
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

The `amd_gi_feedback` rig exercises native opaque HDR feedback before fog/upscaling.
It verifies GPU hit acceptance, exposure removal, fog isolation, feedback texture
release and exact zero-indirect/disabled controls at the ordinary quarter primary
ray budget. Native feedback variants compile on demand; rerun the native material
and shadow geometry rigs when changing that shader-group behavior.

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

### AMD environment input conformance

Run `docs/validation/shadow_validation/run.sh amd_gi_environment` under Vulkan.
It executes the production octahedral-to-cube/mip compute shader and independently
checks 4,096 directional cube samples against an analytic direction-colored input,
plus every face's terminal mip against its full-resolution mean. Tolerances are
0.003 per channel for 64x64 source interpolation/half storage. The rendered
`amd_gi_sky` fixture separately exercises native sky updates, orientation, ambient
replacement and disabled restoration. `amd_gi_reference` includes AMD's cone LOD
at both the fresh-candidate and final-shading cone widths.

AMD GI source normals: `docs/validation/shadow_validation/run.sh amd_gi_normals` runs 36 GPU cases against authored CPU expectations for packed/compressed normals, index layouts and nonuniform/mirrored transforms. This local-RD fixture explicitly completes its buffer uploads via diagnostic readback; production geometry reads use RD synchronization without CPU readback. Use `amd_gi_deformation` for posed normals, blend shapes and alternating FSR2 buffers, and `amd_gi_consequential` for cache/hit ownership and disabled lifetime. See the current AMD GI handoff for validation limits and remaining material compatibility gaps.

Current AMD source-material and capacity checks: `run.sh amd_gi_source_material`
reads an opt-in GPU oracle for native UV/UV2/color/custom attributes, vertex
varyings, local/global/instance uniforms, compression, point/volume/cone texture
LOD, actual alpha/discard ray candidates and dark-phase emissive classification.
It compares against authored numeric expectations, not a high-sample render.
`amd_gi_collection` tests 1025 lights, emitter-prefix changes and isolation of an
unsupported shader, with zero capture-atlas allocation. `amd_gi_distance` imports
the production distance packing/accumulation functions and verifies exact integer
carry words beyond the old overflow point. Both diagnostics are correctness tests,
not hardware performance measurements.

Source-domain bug proofs are preserved in
[`amd_gi_source_proofs`](validation/amd_gi_source_proofs/README.md), with an
overridable pinned-reference checkout path. These are CPU algebra/index tests,
not AMD GPU captures. `amd_gi_consequential` now additionally exercises abrupt
camera replacement and an independent viewport creation, resize and destruction.
The material oracle includes a vertex-stage implicit texture read that must stay
at mip zero while fragment reads use volume/cone filtering.


Approved affine emitter mapping: `run.sh amd_gi_emitter_coordinates` checks 704 GPU
samples against textures whose mip levels and texel positions have known colors.
It covers ordinary/alternate UVs, scaling/rotation/translation/mirroring, aliases,
compound assignments, interpolated/flat varyings, explicit LOD/bias, compression
and live uniforms. Unrelated partial writes must not invalidate known coordinates.
`run.sh amd_gi_emitter_coordinate_limits` requires explicit diagnostics for five
unqualified mappings; a successful shader compile alone is not a filtering proof.
The ordinary source-material oracle and emitter-room regression remain separate.
