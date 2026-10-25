# AMD GI: current status and local handoff

Updated 2026-10-25. Pushed baseline: `9f4386ed09` on **`feature/amd-gi`**.
Emitter performance implementation: **`feature/amd-gi-emitter-performance`**,
branched directly from that baseline.
**Current execution permission:** on 2026-10-25 the owner chose source-only work.
Do not launch the game or renderer fixtures. Earlier reflection-run permission
does not authorize this work. Builds and CPU-only checks are separate from runtime
acceptance. Do not edit fps-proto source/assets.
**Standing diagnostic preference:** turn grass off for future GI/reflection
tests. External harnesses hide GrassField nodes at runtime, verify them hidden,
and restore their original visibility; do not save grass changes in fps-proto.
**Latest owner observations, after the saved full-resolution correction:**
reflections are overall more stable, but now look very blurry. Correctness of
the apparent blur has not been established; do not equate stability with visual
accuracy. Walking forward or backward reveals reflection artifacts on certain
faces, while strafing left or right makes them mostly invisible, with subtle
oddities still present. This directional movement dependence is a new reported
symptom, not yet reproduced or explained. Keep it separate from the proven
stationary cache bursts. Future investigation should compare those movement
directions and preserve reflection detail as well as stability. No new test was
authorized or run for this observation, and no setting was changed. Extra
filter passes remain reverted; the saved overrides are full-resolution
reflections and trace roughness cutoff 0.3.

**Earlier owner retest:** the 0.3 setting significantly improved reflections, but
thin faces still have noise and the magazine side facing the player flickers.
Magazine captures now identify exact black dropouts during half-resolution
reconstruction. The project also disables `reflections/half_resolution`; a fresh
launch confirms zero dropouts at all three measured problem pixels (previously
18, 35 and 38 of 64 frames). Broader magazine bursts are traced to the shared
coarse indirect-light cache and remain unresolved. Game testing stopped after
the owner's duration concern; do not resume this test sequence without checking
with the owner. Diagnostic layout v2 records actual normals/roughness
at every pixel and reflection samples before/after firefly cleanup. The previous
body ROI did not include the magazine; its 84% result is separate evidence.
Read this file first. Read [controls](features/amd-gi.md), [material internals](internals/rt-materials.md),
or [approval boundaries](AMD_GI_ADAPTER_DECISIONS.md) only as needed.
Older documentation is preserved in one [historical archive](history/AMD_GI_ARCHIVE.md).
Search a specific heading/finding there; do not load the entire archive into AI context.

Reflection follow-up: bounded GPU captures identified sparse-probe coverage
failures on the polished gold AK. The project's existing AMD trace roughness
threshold is now 0.3; the engine default remains AMD's 0.2. A fresh launch with
the persisted setting reproduces the visual improvement (about 84% lower
frame-to-frame variation in the affected strip). This is an AMD-native project
quality correction, not a new estimator or a repaired AMD history algorithm.
Windows build, offline layout/bounds/decoder checks and actual GPU captures pass.
Latest local executable SHA-256:
`530F349FEDBC554709DA47FC2E77160D98CF0A43E711DB31EADE26C3B1623544`.
External harness and record guide: `.artifacts/reflection-isolation/gpu-run.ps1`
and `DIAGNOSTICS.md`. Repeated diagnostic/fix-validation runs were authorized.
The first GPU capture completed in `gpu-capture-20261024-220426`: 64 frames,
unchanged GI settings, recorded matching camera/weapon poses. Its process closed
with the recurring access violation after the successful capture marker; this
is valid capture evidence, not a clean-exit test. Subsequent fps-proto edits are
limited to the two permitted GI project settings described above.
Read-only reconstruction of the affected AK faces finds matching flat geometric
and authored normals at roughly 79 degrees grazing; the earlier hypothetical
normal-tilt experiment does not explain those faces. No new estimator correction
was justified or implemented; the verified correction uses AMD's existing ray path.
Offline glslang compilation also passes all 112 production/diagnostic variants
using the native adapter's empty-material fallback. Binding 63 appears only in
the five intended observer passes. TRACE now records source/cell/mip provenance
in its existing sample storage without another descriptor; the other 50
production/diagnostic SPIR-V pairs are byte-identical. All 56 production variants
remain unchanged. Actual generated game materials compiled during v2 captures.
Evidence: `.artifacts/glslang-check/results.json`. The actual
Forward+/DLSS current/previous projection and jitter contracts were audited with
no source-supported defect found.

## Runtime options added, 2026-10-25

The owner subsequently authorized the full diagnostic tools, both optional sky
samplers, debug visualizers and alternate AMD reflection filter as live options.
This supersedes the older optional-feature table for these items only.

Implemented: uniform/cosine/luminance-importance sky sampling; independent AMD
split-ratio/a-trous/disabled reflection filtering and radius controls; 31 debug
views plus normal rendering; GPU cache/probe statistics; bounded object/surface
exclusion reports; and `RenderingServer.viewport_get_amd_gi_diagnostics()`.
Defaults: cosine sky, unchanged a-trous reflection filter, diagnostics off.
Windows MSVC editor build passed: `bin/godot.windows.editor.x86_64.exe`, SHA256
`33C9E7FE42984BF00501F59B02388AA6C0B927EEFFE0478B701EEC9EDBE96CF6`. Desktop editor remains unchanged.
Evidence: `.artifacts/amd-gi-runtime-options-20261025/`.
The [runtime guide](features/amd-gi.md#runtime-sampling-reflection-filters-and-diagnostics)
contains all enums, costs, legends, snapshot fields and overlay examples.

Work remains source-only. No game, editor runtime, renderer fixture or doctool
was launched; API XML was maintained directly. Offline shader and CPU checks do
not certify visual quality or performance. The existing reflection issue remains
open. No fps-proto files/settings or desktop editor changed. Publication targets
are `feature/amd-gi` and `master`; runtime acceptance remains pending.

## Current source-only hardening, 2026-10-25

Owner scope: fix same-frame acceleration-structure input reuse, muzzle-flash
integration overhead, and failed material-pipeline preparation. Negative lights
and orthographic cameras are explicitly unsupported for AMD GI. Ordinary MultiMesh
support is required for the game. Broader lifecycle work is deferred; shutdown is
investigation only. Shader prewarming/loading overlays are deferred game work.

The combined Windows MSVC editor speed build passed (13m31s). New local binary:
`bin/godot.windows.editor.x86_64.exe`, SHA-256
`F203DE4E0B56A582346382769D8BA9F8063FF944A1C4B6E36D9F6E3C94D321F8`.
The desktop installation was not replaced; all changes remain local/uncommitted.
Build log, exact changed-source archive/manifest and source-only evidence are in
`.artifacts/amd-gi-hardening-20261025/`. No game or renderer fixture was launched.

- New TLAS input buffers now reserve their initial payload, preventing another
  build in the same frame from overwriting it. A prepared local-RD regression
  performs three distinct builds/ray queries before each submission, over eight
  frames. It has not run on a GPU under this source-only authorization.
- The earlier retained analytic-light prefix still prevents flashes from moving
  every cached emitter record. A second, narrowly proven CPU inefficiency is now
  fixed: rejected additive/unshaded flare instances no longer shift the transform
  cache of supported objects following them. The light-storage fixture now blinks
  an early-allocated rejected flare and rejects any static transform repacking.
  Neither source fix proves the owner's firing stutter resolved; gameplay timing
  and the GPU byte-equivalence fixture remain pending permission.
- Material-pipeline preparation builds a complete candidate before publishing it.
  Partial candidates are freed; mismatched old material bindings never execute.
  Failures retry after 1/2/4/8/16/30 seconds with a 30-second cap, rather than
  permanently latching failure or compiling every frame. Only three warnings per
  unchanged failed signature are emitted. The actual shared CPU helper passes
  141 cleanup/readiness/backoff/recovery checks, including failures after the
  former reflection-output readiness sentinel. Runtime fault injection is prepared.
  Requested native SSR remains active until the current material pipeline set is
  ready, preventing preparation failure/backoff from sampling an old SSR output.
  Preparation is still synchronous and temporarily retains old and candidate
  pipeline resources; this is a recovery fix, not shader prewarming.
- Negative lights remain in native direct lighting but are omitted from AMD light
  sampling and outgoing-light feedback. Orthographic views clear their own GI
  textures, skip GI rendering, and retain native lighting/SSR. Shared scene resources
  remain available to perspective views; this is not full orthographic support.
- Three-agent review confirms the game's dressing uses ordinary CPU-managed 3D
  MultiMeshes, already handled by the adapter. Crossroads contains 2,693 authored
  MultiMesh nodes and at least 12,121 serialized dressing transforms. Bulk-upload
  transforms, color/custom data, mirrored parent transforms, zero/restored visible
  counts and resource replacement were added to the metadata regression. No new
  GPU-indirect path was substituted for the path the game actually uses.

Grass also uses ordinary CPU MultiMesh, but explicitly disables GI transport and
its shader deforms terrain height, camera-facing shape and wind. It can receive GI
without tracing every blade. Full transport would require matching deformed ray
geometry and extra acceleration-structure work; changing a GI flag alone is
incorrect. Keep receiver-only grass for now, especially on the 780M. Assess a
bounded desktop deformation implementation separately before enabling transport.

Shutdown investigation read four existing crash dumps without launching anything.
Three identify read access violations in `nvcuda64.dll`; the latest identifies
`nvoglv64.dll`. The dumps load the desktop Streamline interposer and Overwolf's
Vulkan hook. Raw fault-thread stack memory contains NVIDIA NGX model addresses,
but these are not unwound call frames and do not prove cause. No shutdown code,
driver, overlay or system setting was changed. Reproducible offline extraction:
`.artifacts/amd-gi-hardening-20261025/read_minidump.py` and `dump-exceptions.json`.

## State of the implementation

Windows freeze investigation (RTX 5090, 2026-10-24): the branch now splits AMD GI
entry points before SPIR-V generation instead of specializing one large native
material shader 54 times. It also retains both storage and indirect-command
access when a compute buffer has both roles. Dropping the indirect access let
dispatches consume stale counts; the unchanged engine failed cache ownership
validation on this GPU. The 256-dispatch regression produced 7,567 incorrect
words before the graph fix and zero afterward. The source-material oracle and
consequential cache/viewport regression pass on the corrected Windows build.

Actual fps-proto menu transitions through Systems Sandbox and Crossroads are
responsive with GI enabled. Cold shader creation can still pause loading; it is
not asynchronous. On the baseline branch, a deeper synchronized GPU profile at
1280x720 attributes about **121 ms to light-grid construction** and **17 ms to
emitter geometry regeneration** on the RTX 5090, out of roughly 140 ms total.
The earlier 122 ms hit-shading / 19 ms acceleration-structure attribution was
incorrect: ordinary timestamp boundaries allowed work to cross the labels.
Actual primary/secondary hit shading is about 0.17 ms combined; GI TLAS building
is about 0.2 ms. The light grid scans 5.29 million emissive triangles for each of
256 cells. Only 56 of 12,563 emitter batches changed in one snapshot, but all
were rebuilt. See the [profiling report and reproducible evidence](validation/amd_gi_profile_2026_10_24/README.md)
for controls, exact-zero candidate counts and the recommended fix work.
That investigation installed no production performance optimization.
The separate emitter-performance branch now rebuilds only changed native emitter
geometry and prepares current-frame emission once before traversing ordered
exact-zero masks. It preserves original light IDs, strata, weights and RNG order;
GPU oracles compare against the full original scan and full geometry regeneration.
A fresh Crossroads comparison at 1280x720 measured **135.604 ms whole GPU frame
before, 3.509/3.496 ms after** on this RTX 5090. Synchronized new stage timings:
0.484 ms emission preparation, 0.006 ms upper masks, 0.559 ms light grid,
0.092 ms emitter geometry. Extra scratch storage is approximately 82 MiB per
active GI viewport at this emitter count. This is not a gameplay FPS or Radeon
780M claim. See the [adversarial evaluation, implementation and evidence](validation/amd_gi_emitter_performance_2026_10_24/README.md).
The subsequent [Live World CPU profile](validation/amd_gi_cpu_profile_2026_10_24/README.md)
finds roughly 14.7–14.9 ms CPU RT preparation and 19.4–19.6 ms median frame
intervals at 1280x720 native. Its 62-NPC configuration uses primitive bodies;
sampled steady frames had zero skinned BLAS refreshes or new BLAS builds.
Repeated preparation of 16,528 GI surfaces and 98,534 buffer-address queries
per frame is the main CPU target. Detailed inner timers add substantial overhead;
read the report before interpreting their times. The installed desktop editor
still has no CPU optimization from this investigation.

Local, uncommitted CPU integration on top of `4ca77d59c7` now implements all three
audited priorities plus Vulkan address caching:

- Persistent scenario ordering, validated surface geometry records, packed transforms,
  dependency sets and reusable preparation storage; current live inputs remain checked.
- Shared native material/surface templates, stable-sized texture-index allocations
  and changed-span hit/context uploads. Uniforms, textures, TIME, instance values,
  dense indices and GPU dependencies remain current.
- Unchanged GI TLAS reuse and conservative transform-only refits, with native RD,
  graph and Vulkan support. Incompatible updates use a full build.
- Vulkan addresses queried once after binding and retained for the buffer lifetime.

Three agents researched, implemented and cross-reviewed the changes. The
[design, invalidation findings and boundaries](internals/rt-materials.md#persistent-scenematerial-research-2026-10-24)
explain why current resource polling is retained instead of trusting incomplete
notifications. AMD sampling, filtering, denoising and history are unchanged.
The owner subsequently tested this build and reported significantly improved
performance. There is no new controlled CPU/GPU timing comparison yet.

The combined Windows editor speed build passes. The production TLAS eligibility
test passed 15 native CPU checks; formatting, spelling, whitespace and runner shell
syntax checks pass. New scene/material reconstruction oracles and mutation/address
fixtures are prepared, but no Godot/game process or GPU test was run under the
owner's source-only restriction. Post-change performance is unmeasured. The built
editor is `bin/godot.windows.editor.x86_64.exe`; the desktop shortcut still launches
the previous build. Fresh owner permission is required for runtime validation.

### Follow-up: firing spikes and localized gold reflections

**Owner retest before the follow-up below:** the reflection flicker is unchanged after the face-normal
correction, including when standing still with the camera still. The muzzle-flash
spike correction has not yet been tested. The normal input correction is not a
confirmed fix for this symptom. The later GPU investigation and project correction
below are separate from that input repair.

The owner's test also reported large process-time spikes during muzzle flashes
and flickering reflections on small areas of the golden AK. Source inspection
found two separate adapter defects; runtime attribution remains unverified:

- The flash's child analytic light changes the active light count. That count
  previously determined the physical start of cached emitter triangles, forcing
  every batch to regenerate when the flash appeared or disappeared. The local fix
  places triangles after retained analytic capacity and copies valid records on
  buffer growth. Logical light IDs, sampling order and RNG remain unchanged.
  First-time capacity growth can still allocate/copy; repeated flashes within
  capacity no longer require this full geometry rebuild.
- AMD's primary geometric-normal attachment contains the actual triangle face
  normal. Ours contained the interpolated authored normal. The gold material has
  no normal map; several small AK triangles have strongly off-plane authored
  normals. The local correction derives only the GI geometric normal from raster
  position derivatives, preserving native shading and authored shading normals.
  This fixes an input mismatch, not yet a demonstrated cure for every flicker.

Regression fixtures cover analytic-light transitions and geometric/shading normal
separation. They are prepared for an authorized runtime pass; do not interpret
their presence or a successful editor build as a GPU validation result. No game
project assets/scripts were changed during those initial source-only changes.

The combined editor rebuilt successfully in 1m34s; log:
`.artifacts/muzzle-normal-fix-build.log`. SHA-256 of the editor:
`8CF462024C9CAA55B0919F8184A9B54D772FC34A3997DE5ECF1D84A330E10911`.
Independent reviews, formatting, spelling, Python lint, shell syntax and whitespace
checks pass. The light-storage log scorer accepted its synthetic valid case and
rejected five deliberately invalid cases. The normal fixture's CPU plane math
also passes. Native runtime shader compilation, GPU fixtures and gameplay symptoms
are not yet verified. All changes remain local and uncommitted on the existing
`feature/amd-gi-emitter-performance` branch; the desktop installation is unchanged.

The subsequent source-only reflection audit found no further proven sampling,
material, compositing, pass-order or history-lifetime defect explaining the
stationary flicker. The gold material's roughness is 0.25, above the default 0.2
ray-tracing cutoff: it uses stochastic screen-probe reflection interpolation.
Saved game settings request DLSS Quality at 0.67 scale; reflections also default
to half internal resolution. The weapon can settle to an unchanged pose. Probe
hemisphere rejection and loss of tiny surfaces between sampling phases are
plausible variance sources also present in the AMD reference, not established
defects to repair by inventing filtering. The subsequent controlled comparison
of probe versus traced reflections, half versus full reflection resolution, and
reflections disabled is recorded below. One separate reference difference remains recorded:
probe-reflection fallback drops AMD's zero denoiser hint and stores one; its
virtual-point effect does not explain a truly stationary camera by itself.
The external diagnostic is at `.artifacts/reflection-isolation/`
(`run.ps1`, `profile.gd`, `README.md`). Its opt-in full-resolution
stage is diagnostic only. Gameplay stays running because the older report says
pausing settles the artifact. Captures log camera/weapon poses and actual settings;
the baseline must visibly reproduce the problem before comparisons are interpreted.
The runner records binary/script hashes and enforces a 1280x720 window after saved
video settings load. CPU-only sampling sensitivity evidence is at
`.artifacts/reflection_probe_hemisphere_sweep.py` and `.txt`, not a game reproduction.

**Authorized visual diagnostic, 2026-10-24, 21:49 EDT:** Live World, gold AK,
1280x720 display, saved DLSS Quality scale 0.667, active gameplay. Performance is
explicitly excluded because the owner had another workload running. The first
attempt stopped after baseline capture when input changed the camera. The retry
used the game's existing runtime input gate and viewport input suppression,
without pausing gameplay or editing game source/configuration. All 168 captures
have identical logged camera and weapon-root poses. Original settings were
restored after each intervention and at completion; no permanent quality change
was made. Capture directory: `.artifacts/reflection-isolation/capture-20261024-214904`.

The localized flicker was reproduced. In the manually selected small-face/edge
region `(704,419)-(756,540)`, mean consecutive-frame absolute RGB difference
(8-bit screenshot values, not linear radiance or a perceptual score) was:

| Stage | Difference |
| --- | ---: |
| Original probe reflection path | 1.9604 |
| Trace roughness cutoff 0.30 | 0.4033 |
| Original restored | 2.1000 |
| Reflections disabled | 0.1144 |
| Original restored | 3.0020 |
| Full-resolution reflections, original cutoff | 1.0317 |
| Original restored | 2.0459 |

Each stage has 24 images. The broad-side control stayed around 0.28-0.35 with
reflections enabled. Tracing reduced this localized variation about 80% against
its bracketing baselines; full resolution helped less and did not improve every
sampled region. Restoring the settings repeatedly restored the noise. This
strongly implicates probe-based reflection sampling/reconstruction, with reduced
resolution contributing, but does not isolate a specific faulty equation or prove
an AMD deviation. Clouds and other live-world activity changed between stages;
do not claim exact brightness equivalence or a complete visual cure. Evidence:
`adversarial_metrics.py` and the capture directory's `adversarial_metrics.json`.

All captures and the successful restoration marker preceded process exit
`0xc0000005`. Windows logged the recurring `nvcuda64.dll` exit fault in test PID
44548 at 21:50:14 EDT. It also logged `nvoglv64.dll` failure in the separately
running desktop editor PID 15172 at 21:50:21; this task did not control that editor
and a causal relationship is unestablished. This was not a clean-exit validation.
Those test processes are gone. The owner subsequently authorized repeat diagnostic
and fix-validation runs for this reflection issue; see the current scope above.

**Completed GPU diagnosis and project correction, 22:04–22:11 EDT:** direct
records show a concrete failure before denoising. At internal pixel `(478,302)`,
frame 344, the chosen probe normal agrees with the gold face by only 0.102. Its
tiny normal-weight is normalized because alternatives are worse. The reflected
direction falls outside that probe's hemisphere, yielding zero accepted weight,
zero raw/filtered/final reflection and no usable history. Other frames find
suitable probes and produce bright reflections. This matches the audited AMD
interpolation rules. Source audits found no new integration defect in sampling,
material response, probe lifetime or Forward+/DLSS jitter conventions. The
affected flat faces' authored and geometric normals already agree; another
normal patch would not address this evidence.

The correction sets only
`global_illumination/amd_gi/reflections/trace_roughness_threshold=0.3` in
`fps-proto/project.godot`. It routes the roughness-0.25 gold through AMD's existing
dedicated rays. No authored material, model, script, denoiser policy or engine
quality default is changed. This applies to all visible materials in roughness
range `(0.2,0.3]`, not just this weapon, and adds ray work. Performance is deliberately
unmeasured under the owner's concurrent workload.

Each subsequent capture contains 64 consecutive screenshots plus GPU records at
1280x720 display / 853x480 internal resolution, half-resolution reflections:

| Capture | Applied cutoff | Affected-strip difference | Broad-side control |
| --- | ---: | ---: | ---: |
| `gpu-capture-20261024-220713` | Runtime 0.3 | 0.3463 | 0.3526 |
| `gpu-capture-20261024-220914` | Original 0.2 repeated | 2.1750 | 0.3284 |
| `gpu-capture-20261024-221022` | Persisted 0.3, no override | 0.3473 | 0.3537 |

Values are mean adjacent-frame absolute RGB differences in 8-bit screenshot
values, measured by `.artifacts/reflection-isolation/compare_captures.py` in the
same display rectangles as above. The saved setting reduces affected-strip
variation 84.0% relative to the repeated baseline, to the broad-side control's
level. It does not claim removal of all stochastic noise. Camera/weapon poses
are controlled, but live lighting and raster jitter phases differ across runs;
do not infer exact radiance equivalence. The final saved-setting launch confirms
0.3 came from project settings rather than a diagnostic override.

A second level-facing view also completed with the saved setting
(`gpu-capture-20261024-221119`). Fine-edge variation remains: affected-strip
difference 0.8531, broad-side 0.2129. Full-resolution reflection testing in that
view (`gpu-capture-20261024-221325`) lowered those to 0.6294 and 0.1989, but
quadruples the nominal sample grid. At that stage it was restored, not persisted.
The later magazine-specific investigation below establishes why full resolution
is now saved. Four filter passes remain; a subsequent five-pass comparison did
not establish a reliable additional correction. Neither setting change claims
completely noise-free stochastic reflections or changes AMD's denoiser equations.

All these captures completed. The persisted-setting validation `221022` also
exited cleanly with code 0. The other five follow-up captures hit the recurring
NVIDIA exit-time access violation after completion, so that separate intermittent
shutdown defect remains unresolved. Binary records,
source-only analyzer tests, logs, build hashes and comparison JSON are under
`.artifacts/reflection-isolation/`. The diagnostic is opt-in and inactive during
normal editor/game use. Native generated game shaders compiled successfully in
these runs. No performance or muzzle-flash validation is implied.

**Magazine follow-up, 22:49–22:57 EDT:** all valid magazine surfaces have actual
roughness 0.25 and use dedicated rays at cutoff 0.3. The facing plate's shading
and geometric normals agree. Records rule out a roughness-routing change and
widespread primary-ray self-hits in this ROI. Narrow facets nevertheless become
exact black on particular half-resolution checker phases after spatial
reconstruction, despite valid raw traced lighting. Zero reconstructed variance
then clamps the temporal result to black. The audited equations match AMD.

The correction saves `reflections/half_resolution=false` in fps-proto. Captures
`224912` (half), `225220` (runtime full) and `225701` (saved full, no override)
use the same 31x53 internal-pixel magazine ROI and 64 frames each:

| Internal pixel | Black frames, half / runtime full / saved full | RGB temporal standard deviation, half / saved full |
| --- | --- | --- |
| (532,455) | 38 / 0 / 0 | 0.16455 / 0.02855 |
| (530,451) | 35 / 0 / 0 | 0.16339 / 0.02450 |
| (525,441) | 18 / 0 / 0 | 0.15247 / 0.03539 |
| (521,455), flat-plate control | 0 / 0 / 0 | 0.00413 / 0.00415 |

Standard deviation is calculated per output RGB channel, then averaged, in
linear diagnostic reflection values. These are selected problem pixels, not a
whole-image quality score. Normals, roughness and history acceptance do not
improve in the runtime comparison; sampling coverage does. Full resolution is
AMD's existing quality control, not a modified reconstruction/history policy.
It quadruples the nominal glossy sample grid; actual extra rays depend on
classification. Performance remains unmeasured. Four filter passes remain.

Evidence: `.artifacts/reflection-isolation/magazine-comparison.json` and
`compare_magazine.py`, plus the three `gpu-capture-20261024-*` directories.
The saved-setting run completed all records/screenshots and restored its runtime
overrides, then encountered the recurring shutdown access violation. Its test
process is closed. The existing desktop editor was not replaced or terminated.

Broader visual comparisons in `visual-capture-20261024-225003` did not hold or
record the environment state. Approximately two game hours of potential drift
were inferred from wall time and authored day length, not observed; the later
run found the clock timer stopped before isolation. Do not claim that sun drift
actually occurred in the earlier run. Cloud processing was enabled originally.
Variation also appeared with AMD reflections disabled in that uncontrolled run,
which leaves native sky/probe reflections and direct specular lighting active.
The later controlled tests below supersede that attribution. A CPU-only mesh
experiment also identifies millimeter
AMD ray-origin offsets crossing some tiny separate magazine details; this is
not GPU-confirmed and does not explain the large plate. No bias change is made.

**Remaining bright magazine bursts, controlled tests 23:00–23:08 EDT:** fixed
sun/clouds and then paused gameplay still reproduce occasional broad bright
blotches. GI reflections off reduces plate variation to approximately 0.03–0.04
8-bit code values per adjacent frame. Bilinear at the same internal scale is
worse than DLSS. Neither five nor six spatial passes consistently improves the
result; keep DLSS and four passes. Captures `visual-capture-20261024-230003`,
`230306` and `230543` include actual lighting/pose/settings assertions and
restored controls. Paused capture `230543` has a 40.25-code-value plate event at
engine frames 711–712. No claim of a fully fixed magazine is justified yet.

The subsequent `gpu-capture-20261024-230813` also disables grass and holds lighting
and gameplay fixed. It reproduces a raw reflected-lighting burst at GI frame
200 / engine frame 219. Of 381 stable plate pixels, 103 ordinary surface hits
at 0.5–5 meters receive bright samples, contributing 56% of plate radiance;
adjacent frames have none above the same threshold. Sky samples contribute
only 2.6%. Firefly cleanup changes none of the event samples. Spatial/temporal
filtering attenuates it; it originates upstream. Hit points cluster on nearby
ground and share repeated RGB values. This suggests shared lighting data, but
did not yet distinguish screen feedback from the world cache. The subsequent
provenance below resolves that distinction; no production estimator change is justified.
The grass-free capture completed 64 records/screenshots, restored runtime
controls and exited cleanly with code 0. Evidence: `raw-outlier-summary.json`
and `raw-hit-provenance-summary.json` in that capture directory.

**Final bounded investigation state, 23:24 EDT:** captures `231553` and `232041`
prove that the bursts come from shared coarse indirect cache tile 258208. At
unchanged cell 21947733, direct luminance stays approximately 0.129/0.133/0.128,
while indirect luminance changes 0/0.287/0.028. Neighbor cells show the same
indirect value and unchanged mip choices. The reflected ground is behind the
camera, excluding screen feedback at those hits. Opt-in trace provenance version
2 stores exact source/cell/mips plus a half-precision direct-luminance fraction
in unused sample storage; no new heavy-trace descriptor or production math.
All 112 offline variants pass and all 56 production binaries remain unchanged.

Repeated source audits found no established divergence from AMD in this path:
normal transforms, BRDF/PDF weights, roulette counting, pending-cache order,
temporal normalization and mip sums match. Sparse coarse indirect sampling is
the supported explanation; a specific Godot integration defect is not proven.

Rejected quality candidates: spacing 8 initially improved two visual windows,
but a fresh saved-setting capture `232130` reproduced a larger burst with about
99% of samples still selecting indirect mip 3. The temporary project setting
was removed; spacing is again the default 16. Continuation probability 1 in
`visual-capture-20261024-232237` reduced typical variation, but its repeated window
still had an 11.88-code-value worst plate brightness jump (control 15.77). It was
not persisted. Extra spatial filtering and disabling DLSS were also rejected.
No further game run was made after the owner challenged test duration. Only
cutoff 0.3 and full-resolution reflections remain saved from this investigation.
The separate magazine cache burst is **not fixed**. All test processes are
closed; the recurring exit-time access violation also remains unresolved.

Earlier automated runs also exposed a separate exit-time `nvcuda64.dll` access
violation, reproduced with the unchanged delivered editor; root cause remains
unresolved. The game's saved video settings override the project's
upscaler at runtime; Streamline initialization alone does not prove active DLSS.

A separate repeated-level stall remained with the desktop's implicit Vulkan
layers: Sandbox → Crossroads → Live World stopped at a GPU fence, with or without
DLSS. Excluding `VK_LAYER_RTSS` for the test process completed that sequence with
GI and effective DLSS mode 6 on every level. Excluding all implicit layers also
completed it; a small DLSS/MultiMesh test alone did not reproduce it. Treat this
as a tested local RivaTuner compatibility workaround, not a proven defect inside
RivaTuner or a general reason to disable overlays. The supplied desktop launcher
sets `VK_LOADER_LAYERS_DISABLE=VK_LAYER_RTSS` only in its child process environment;
no global overlay settings were changed. See the
[Vulkan loader's layer filtering documentation](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderLayerInterface.md#layer-filtering).
The independent dispatch regression still fails before the graph fix and passes
afterward with RivaTuner excluded, so that engine correction is separate.

The main AMD GI-1.2 pipeline and audited default-path corrections are implemented
for supported inputs. **Full feature coverage, Godot compatibility and production
validation are unfinished.** No claim that all reported gameplay defects are fixed.
Reference: AMD Capsaicin `914b91596cd119eda85fbc1d3c7ee6ac391b1452`, package v1.3 / GI-1.2.
The full source audit is complete; a completed audit is not proof of complete implementation.

Implemented: sparse screen probes, guiding/reuse/filtering, world radiance cache,
GridStream light selection, multibounce, default near-field screen-space GI,
reflections and AMD diffuse/reflection denoising. Native hit materials replace the
old coarse capture atlas. Supported emitter texture scaling/rotation/alternate UVs
now use their actual mapping for AMD filtering. Other mappings still have limits.

Vulkan Forward+, RT-capable hardware, MSAA off. Reuses RT shadow BLAS geometry;
GI has its own TLAS to include non-shadow-casting GI geometry. Resources are lazy;
disabled GI performs no GI collection/render passes and releases GI resources.
This is not a measured literal zero-CPU-cost claim. FSR2 has controlled coverage;
DLSS ran during local reflection diagnostics, but those captures do not certify
performance or clean shutdown. NRD/Ray Reconstruction are outside this baseline.
No authored probes, baking or special UV layout required for supported materials.

## Missing AMD features: value and effort

These are optional AMD paths/controls, not missing stages of its default pipeline.
Three agents debated every option on 2026-10-25 using the actual FPS workload.
Recommendations below are engineering judgments, not measured speedup promises.
They authorize no optional implementation in this source-only hardening pass.

| Option | Recommendation for this game | Benefit and cost |
| --- | --- | --- |
| Exclusion reports, occupancy/overflow/sample counts, indirect-only view | First diagnostic work on both machines | Explain missing or unstable lighting without changing the estimator. Keep readback opt-in; preserve direct light feeding bounces when displaying indirect-only output. |
| Cosine sky sampling | First optional sampling addition; especially attractive for 780M | Better matches diffuse angular weighting at low arithmetic cost. Baseline already samples a hemisphere, so this does not recover rays wasted on the other hemisphere. Preserve sampler/PDF agreement. |
| Importance sky sampling | Second sampling candidate on desktop; optional on 780M | The actual sky has sun-disk intensity 30 and size 0.02, making bright-direction sampling useful. Existing ordinary cubemap mips help. Hierarchy texture reads and below-surface selections can offset the gain on weaker hardware. |
| Directional GridStream cells | Do not prioritize | Can improve directional proposals, but eight partitions multiply grid memory and construction. Particularly poor first choice for 780M. |
| Intermediate GridStream resampling | Defer | Better receiver-specific proposals, with extra per-receiver light evaluations. Distinct from existing temporal reservoir reuse. |
| Random merge | Do not add now | Simpler selection can sacrifice useful importance-weighted samples; no current selection-cost problem warrants that trade. |
| Merge with replacement | Defer; retain default without replacement | Can emphasize a dominant light but reduces candidate diversity. |
| Cell-overlap weighting | Defer to a demonstrated point/spot boundary problem | Can improve proposal estimates, but needs Godot attenuation/range semantics and must preserve nonzero selection support. |
| Fast centroid construction | Retain current quality path | Saves estimation work but represents small nearby lights and cell boundaries less well. |
| Additional parallel grid builder | Do not prioritize from nominal emitter count alone | Current code is already parallel across reservoirs. AMD's alternative parallelizes inside reservoirs and needs Vulkan barrier/subgroup review. Exact-zero pruning reduced the measured 5090 grid to 0.559 ms despite 5.29 million nominal emitters. |
| Low-emission exclusion | Do not prioritize or enable | Drops real illumination while much of the emitter evaluation and 82 MiB scratch remains. AMD's base-material threshold does not directly classify procedural Godot emission. |
| Cache footprint/history controls | Expose specific controls when diagnostics identify a need | History trades responsiveness for stability; footprint trades detail for coverage. Tile ratio/bucket layout changes affect allocation and indexing and are substantially larger than scalar controls. |
| Near-field slices/steps/radius/falloff/unrolling | Keep defaults | More sampling costs GPU time; radius/falloff change local lighting. Unrolling is a compiler experiment, not missing lighting support. |
| Alpha/albedo/specular/direct debug controls | Useful developer tools after targeted diagnostics | Isolate causes, but are not shipping quality improvements. An indirect-only display must retain direct lighting as input to bounces. |
| Complete probe/cache/mip/decay/propagation visualizers | Add incrementally | Start with coverage, sample count, selected mip and overflow; avoid building redundant views before they answer a concrete question. |
| Alternative reflection denoiser, independent selection and cleanup radii | Deferred with the reflection issue | Offers different detail/noise/cost tradeoffs; not established as a remedy for current artifacts. |

Debate corrections: uniform sky sampling was initially misdescribed as sphere
sampling; it is already hemisphere sampling. Nominal emitter count alone also
overstates the case for AMD's parallel builder after exact-zero pruning. The
0.559 ms grid result is an earlier controlled RTX 5090 capture with reflections
disabled, not a current gameplay or Radeon 780M forecast. The sky disk remains
in the sky despite a separate directional sun light.

Exact frozen option/function inventory: [coverage snapshot](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-comparison-coverage).
Its old “absent” statements describe the pre-correction revision; use this page for current status.
The default near-field GI stage is now implemented. Other APIs and unrelated Capsaicin renderer features are not missing work for this Vulkan-only request.

## Godot compatibility gaps, ranked by potential impact

Ranking is conditional on actual asset use, not evidence that each category is active in the game.
The owner deferred broad compatibility expansion on 2026-10-25. This is an inventory,
not a queue of approved work. Ordinary game-used MultiMesh is already supported;
GPU-indirect geometry and full grass deformation remain separate decisions.
Skipped geometry can remain visible on screen but fail to block/bounce light or appear in ray-traced reflections.
Supported objects continue rendering GI; unsupported objects no longer suppress the whole GI scene.

| Priority / gap | Current consequence and benefit of support | Complexity |
| --- | --- | --- |
| 1. Material overlays and multipass/layered materials | Can omit the whole affected object/surface from GI. Support would restore blocking, bounce and reflected appearance, not just its decorative layer | Moderate–high: combine layer color, opacity and emission correctly. Simple decorative cases are easier. |
| 2. Custom shader geometry movement/position transforms; GPU-indirect MultiMesh | GI cannot generally follow these shapes/placements. Support would match visible moving geometry | High: evaluate positions and keep RT geometry synchronized efficiently. Ordinary CPU-managed MultiMesh, skeletal animation and blend shapes already have support. |
| 3. Particles, unshaded and additive effects | A visible flame/effect does not automatically contribute its shape/emission to GI. Separate supported lights can still contribute | High for transparent particle systems; narrower ordinary glowing-mesh cases are easier. Not every decorative effect should block light. |
| 4. Projector and distance-faded lights; unsupported light types | These contribute native direct light but are skipped by GI light sampling. Support restores the authored projected pattern/fade in bounced light | Moderate for projector/fade adapters; additional light types require their own sampling. Relevant to a flashlight only if it uses these features. |
| 5. Screen/depth/normal-buffer-dependent or raster-derivative shaders | Some materials are omitted because their appearance requires the camera image or neighboring screen pixels | High; arbitrary off-screen equivalents may not exist. Requires explicit semantics, not invented zero inputs. |
| 6. Complex emitter texture mappings | Nonlinear, texture-driven, loop/helper/partial-write and other unqualified mappings retain fallback filtering with a warning. Light can be incorrectly averaged or noisy | Moderate for selected patterns, high for arbitrary shaders. Ordinary supported affine mappings are fixed. |
| 7. General transparent glass behavior | Cutouts and some fractional coverage work; general refraction/colored transmission do not | Very high. Full glass transport expands beyond AMD GI's existing model; not a simple Godot adapter omission or automatically approved extension. |
| 8. Objects assigned baked lightmaps | Objects can be excluded; mixed baked/dynamic lighting is not integrated | Moderate–high: avoid counting baked illumination twice. Lower immediate relevance to the stated VBAO-based game. |

These are the known audited gaps, not a certification of every Godot feature.
AMD's approximate secondary material model is retained; full nested specular transport
is not an unimplemented default AMD feature. Screen normal maps remain supported.
The checked game's grass explicitly sets `GI_MODE_DISABLED`; adding deformation support
alone would not make it participate. Recheck actual local assets before diagnosing them.

## Local PC handoff: issues still requiring reproduction

The owner intends to open a new local session, pull this repository and allow direct
interaction with the game. Do not infer local checkout paths, build identity or current
settings from cloud paths. Verify engine revision, `fps-proto` revision and runtime settings.
The owner used the Windows **clang editor**, default AMD GI settings unless stated.
An earlier MSVC artifact crashed loading the project; do not assume that is resolved.

Retain all reported cases until a local before/after reproduction establishes their status:

- Sandbox prototyping level: frequent consistent spawn-platform stutter/flicker and incorrect prop lighting.
- Scavenging/shack area: indirectly lit surfaces boil with a stationary flashlight or when toggled; contribution changes with aim.
- Camera translation sometimes loses/restarts GI; turning alone did not trigger the same earlier symptom. A wall could lose GI until movement resumed.
- First-person assault rifle intersecting a wall creates a large box artifact.
- Muzzle-flash light causes surrounding GI to disappear/recover for longer than the flash lasts.
- Crossroads, Fieldway and Hideout appeared to have little/no GI while stutter remained.
- Golden AK reflections become noisy/firefly-heavy with tiny motion, settle slowly, and oddly resolve immediately on pause. Full-resolution reflections help settled noise but do not eliminate fireflies.
- Rapidly alternating electrical hazard causes severe noise. One diffuse sample/pixel reduces flashlight boiling but does not eliminate it.

Capture the actual game, settings, motion and logs; distinguish omissions, history resets,
shader compilation/scene preparation and GPU work using evidence. `GODOT_AMD_GI_TRACE_HISTORY=1`
is opt-in instrumentation. Check warnings for skipped surfaces/lights and unqualified mappings.
Do not use higher ray counts, disabled denoising or settled stills to hide defects.
The local investigation is the next task; this documentation change does not implement extra features.

## Owner constraints and hardware targets

- AMD's actual algorithms take priority. New deviations need a strong evidence-backed explanation and **explicit owner approval before implementation**; see [approved scope](AMD_GI_ADAPTER_DECISIONS.md).
- Keep GI fully optional and user-configurable. Preserve comparison with native Godot GI and a possible future separate backend. Do not mix backends for a comparison.
- Default previews: **quarter primary diffuse ray/pixel budget**, denoiser enabled. No repeated 1-sample comparison unless requested; no high-sample substitutes.
- Game preview screenshots: representative **Crossroads** location. Cloud previews use FSR2 at native render/display scale, not extra downscaling. Deliver PNGs in the preview directory, not HTML-only viewers.
- Laptop and Radeon 780M machine are the same device: Ryzen 7 7840HS. Recalled baseline ~60 FPS at 2560×1600 display, FSR2 Performance, RT shadows + VBAO, grass disabled, RT soft shadows disabled.
- GI goal ~40 FPS; lowest GI setting must stay above 30 FPS under those conditions. Neither target is validated. RTX 5090 desktop has headroom; its visual defects still matter.
- Do not describe clang/MSVC as different GI quality modes; they are compiler/build variants. Verify the commit for comparisons.

## Evidence and navigation

Software-Vulkan checks cover default quarter-budget integration, cache/hit ownership,
multibounce, moving reflections, light/sky changes, FSR2 poses, odd sizes and disable/lifetime.
Latest affine follow-up: 704 material samples pass; existing source oracle: 256 pass;
emitter room and five unsupported-mapping warning cases pass. These are sample checks,
not a high-samples-per-pixel preview. Earlier reflection regression covers 344 checked frames.
These do not prove user-game quality, hardware performance or full AMD pixel equivalence.

- [Controls](features/amd-gi.md): live settings/defaults and backend conflicts.
- [Material integration](internals/rt-materials.md): current source map and resource contract.
- [Validation](VALIDATION.md) and [harness](validation/shadow_validation/README.md): commands/scorers; proofs live in `docs/validation/amd_gi_source_proofs/`.
- [Archived corrections/evidence](history/AMD_GI_ARCHIVE.md#snapshot-amd-gi-consequential-corrections): finding IDs, measured values, failed attempts and test limits.
- Windows renderer checkpoint build: [run 40064182311](https://github.com/automata-rtx/godot-rt/actions/runs/40064182311) for `837fb30`. Check run/artifact status before claiming a downloadable build. Later documentation commits do not change the renderer.

Cloud evidence paths in the archive are not guaranteed to exist locally. Committed fixtures
and proofs are portable; regenerate outputs when needed rather than assuming those logs were pushed.
