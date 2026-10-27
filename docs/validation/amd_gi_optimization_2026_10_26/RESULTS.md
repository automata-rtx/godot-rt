# GI preparation and reflection optimization results

Implemented on top of `66bd97e00d`, 2026-10-26. This report covers only the three
approved changes in [the plan](PLAN.md). Static emissive evaluation caching and
animated BLAS refitting remain deferred. Porting contracts are in
[AMD GI internals](../../internals/amd-gi.md).

## Outcome

All three changes are retained. They preserve quality settings, sample budgets,
material evaluation, GPU dependencies, reflection cleanup and reconstruction.
The practical gain in this Live World view is modest: approximately **4–5% less
CPU renderer time**, with about **0.01 ms less GPU GI time**. These are measurements
on the machine below, not a general FPS prediction or a fix for the separately
reported reflection motion artifacts.

| Active Live World metric | Original build, two run medians | Final build, two run medians |
| --- | --- | --- |
| CPU render span | 6.459 / 6.347 ms | 6.204 / 6.032 ms |
| CPU RT scene/AS preparation | 4.168 / 4.085 ms | 3.916 / 3.750 ms |
| GPU AMD GI | 1.982 / 1.982 ms | 1.972 / 1.974 ms |
| GPU frame | 3.159 / 3.160 ms | 3.149 / 3.150 ms |
| Observed wall frame interval | 8.740 / 8.605 ms | 8.480 / 8.265 ms |

CPU render span is the interval covered by rendering-device CPU timestamps; it
does not include all game simulation/main-thread work. GPU and CPU times overlap
and must not be added. The wall interval includes the benchmark's frame callbacks.

## Contribution of each change

1. **Scene reuse:** unchanged MultiMesh placement/bounds and repeated source
   geometry preparation are reused. The stage-1 clean run reduced active scene/AS
   preparation from 4.168 to 3.968 ms and paused-world preparation from 3.764 to
   3.406 ms. A same-executable bypass confirmed the direction of improvement;
   that bypass retains refactoring overhead and is not a replacement for the
   original-build comparison. Repeated instances benefit most; the complete
   per-instance material/lifetime and transport-record work still happens.
2. **Binding reuse:** complete resource requests are compared once, then valid
   borrowed descriptor handles are reused per pass. In the final executable,
   disabling only this optimization gave 1.712 ms active / 1.701 ms paused CPU
   AMD GI setup, versus 1.655–1.677 / 1.616–1.639 ms with reuse. This is a small
   saving, roughly 0.04–0.09 ms in that comparison. It does not eliminate graph
   buffer-read registration or other command setup.
3. **Exact-default firefly shortcut:** at thresholds 0/1, neighbor ranking cannot
   mark an outlier. Its original negative-distance marking and following cleanup
   remain. Against stage 2, this saved roughly 0.006–0.008 ms GPU GI time. In the
   isolated 1280×720 test with every pixel eligible, marking fell from 0.094132 to
   0.008296 ms; half-resolution marking fell from 0.022896 to 0.002884 ms. Custom
   thresholds retained the original path and approximately unchanged timings.
   The isolated result is not a whole-game speedup.

Stage-2 active-world timing was 6.065 ms CPU render span and 1.980 ms GPU GI.
Its paused-world repeat had an unexplained CPU timing excursion (8.157 ms render
span); adjacent final-build repeats with identical CPU code did not reproduce it.
Retain this limitation when interpreting small differences. Headline comparisons
use the active gameplay phase, not this diagnostic paused phase.

## Test conditions and isolation

- Windows, Ryzen 7 7800X3D, RTX 5090, Vulkan; optimized MSVC editor build:
  `platform=windows target=editor arch=x86_64 dev_build=no debug_symbols=no optimize=speed accesskit=no d3d12=no -j8`.
- Live World, 62 NPCs, fixed camera, grass off; 1280×720 window, DLSS Quality,
  853×480 internal rendering, full-resolution reflections relative to that
  internal size. No quality setting changed between binaries.
- External harness, isolated user data, deterministic simulation delta/seed,
  warmup, then 480 samples per phase. VSync and FPS cap off. Screenshots and
  synchronous diagnostic readbacks are outside performance sample windows.
- A private snapshot of fps-proto tracked revision
  `0361687daec58ed8709971962f6ab693519d7378` was used after the other game task
  began rebuilding its native component. Native debug DLL SHA-256:
  `92c4271f029b3218a97957d038e4269aeeaff8418cef68a5e50c8e7d71d749ec`.
  Snapshot settings SHA-256:
  `a3d6a527242da295254955f61c0957c288d9198872208eeac4ac477c1c98f9af`.
  The actual game project's source, assets and saved settings were not edited.
- Original/final clean comparisons are `snapshot-baseline-01/02` and
  `snapshot-final-01/02`. The later tests recorded competing Godot/compiler
  processes and their observation times, and confirmed clear timed windows.
  The Game Director task held a coordinated quiet window for the final repeats.
- Runs `scene-01` and `scene-bypass-01` are invalid: the concurrently rebuilt
  project temporarily lacked its native NPC class. Runs `snapshot-scene-01` and
  `snapshot-bindings-01/02/03` had competing processes and are not used for the
  headline comparison. Their logs remain available rather than being deleted.
  `snapshot-scene-02` and `snapshot-scene-bypass-01` were clean.

## Correctness evidence

- Scene metadata reconstruction oracle passed, including shared MultiMesh
  parents, transforms, colors/custom data, bulk writes, custom mesh bounds,
  same-resource layout reallocation, physics interpolation, viewport separation,
  base-type replacement, material/mesh replacement and GI toggling.
- MultiMesh versus independent MeshInstance reference passed: direct image MAE
  0, GI MAE 0.000299; motion restoration and live element input changes passed.
  Skinned/blend-shape and FSR2 deformation references passed for both four/eight
  bone influences (GI MAE 0.001352 / 0.002539).
- Binding lifecycle passed all 21 stages and actual ordinary-cache comparison
  oracles. Texture contents/replacement/destruction, shader versions, history
  parity, odd resize, diagnostic allocations, sky changes, GI off/on and multiple
  independent viewports were exercised. Existing metadata and runtime-options
  rigs also passed with binding validation enabled.
- Failed preparation was injected at the last pass, both initially and after
  GI re-enable. Both recovered. The first fixture attempt incorrectly allowed
  fewer frames than the existing one-second retry backoff; only its bounded
  recovery wait was corrected. All original mutation assertions remain. The
  corrected run recorded successful readiness after 2.117 / 1.291 seconds.
- The final build passed the extracted GPU shader comparison: **1,000 cases,
  83,040 pixels, byte-identical masks**, including default/custom/NaN thresholds,
  nonfinite radiance, negative hit distances, full/half modes, odd dimensions and
  maximum supported radius. Independent CPU proof passed 593,505 count pairs
  and 83,040 pixel/control-flow comparisons.
- The final production reflection rig also passed: 344 GPU sample checks,
  moving off-screen emitters, restored/toggled reflections, half/full resolution,
  and compacted/direct dispatch. Half/full image MAE was 0.002534; compacted/direct
  linear RGB MAE was 0.000781. Binding validation remained enabled.
- Before/after Live World images were visually inspected. Final versus original
  normalized RGB image MAE was approximately 0.00019–0.00024; live temporal output
  is not asserted to be bit-identical.
- All applicable repository hooks passed over the changed production files,
  fixtures and implementation/results documentation; no API/XML change required
  class-reference regeneration.

The lifecycle fixture does not forcibly free borrowed native descriptors while
keeping an identical request. Per-use native validity checking protects that case;
resource replacement/destruction paths and ordinary-cache equivalence were tested.

## Reproduction and artifacts

Use [the regression runner](run_regressions.py), [binding fixture](bindings/README.md)
and [firefly proof](firefly/README.md). Internal diagnostic switches are
`GODOT_AMD_GI_DISABLE_SCENE_REUSE=1`, `GODOT_AMD_GI_TRACE_SCENE_REUSE=1`,
`GODOT_AMD_GI_VALIDATE_SCENE_CACHE=1`, `GODOT_AMD_GI_DISABLE_BINDING_REUSE=1`, and
`GODOT_AMD_GI_VALIDATE_BINDINGS=1`. Keep validation/tracing off performance runs.

Local raw evidence lives under `.artifacts/gi-opt-20261026/`: preserved binaries
and source patches, `runs/*/{manifest,summary,live,static}.json`, screenshots,
regression manifests/logs/captures, and `firefly/gpu-20261026-142555/`. These local
artifacts are not part of a clone. The generic proof/fixture sources are tracked
alongside this report; the game-specific snapshot/harness are local only.

| Executable stage | SHA-256 |
| --- | --- |
| Original | `4ede8767341a9fd6a243bd76fb16e88d73c6d1c27ba05c3a50c5f043d4e1bf21` |
| Scene reuse | `20db275a13177377a619285c4e500840e03ba00cdfdcc62c83055471c5442b2d` |
| Binding reuse | `4bdcb7276f21aff17cc2dbd66669e58e93229230cff0b1e463d71d4975c49f03` |
| Final | `c15d6f3b64ac765f7bccb95ac714cb369835bc5fab030f2c3617526faf756c74` |

The original executable embeds `73864a817`; the preserved local build already
contained the subsequent shutdown fix. New binaries embed `66bd97e00d` plus the
working changes identified by their captured patches and hashes. Do not use the
embedded commit alone to identify these uncommitted builds.
