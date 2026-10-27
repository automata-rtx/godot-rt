# RT CPU preparation results

Both approved candidates are implemented and retained on top of `66bd97e00d`
and the preceding local GI optimizations. The reviewed [plan](PLAN.md) preserves
AMD GI algorithms and existing shadow/AS update policy. Changes remain local;
this task does not publish branches or replace the desktop editor.

## Measured outcome

In the frozen Live World view, the mean of the two run medians gives **5.7% less
CPU rendering time** and **7.7% less CPU RT scene/AS preparation time**. The wall
frame interval improved about 4.3%. GPU time was essentially unchanged. This is
a modest CPU improvement, not a claim that the remaining rendering cost is solved.

| Live World metric | Baseline, two run medians | Final, two run medians |
| --- | --- | --- |
| CPU rendering span | 6.113 / 6.143 ms | 5.792 / 5.767 ms |
| CPU RT scene/AS preparation | 3.803 / 3.819 ms | 3.528 / 3.506 ms |
| GPU GI | 1.973 / 1.973 ms | 1.977 / 1.972 ms |
| GPU frame | 3.153 / 3.153 ms | 3.155 / 3.148 ms |
| Observed wall frame interval | 8.457 / 8.512 ms | 8.134 / 8.110 ms |

CPU span is the interval between rendering-device CPU timestamps, not all game
simulation work. CPU and GPU overlap; do not add them. Wall intervals include
the harness callbacks. No quality setting, caster coverage, ray budget, geometry
update frequency, AMD transport algorithm or GPU build/refit policy was reduced.

## Attribution and limits

1. Shadow preparation reuses MultiMesh transforms/bounds, successful geometry
   resolution within an update and unchanged instance hash contributions. The
   complete RD list is assembled only when a shadow TLAS build is needed.
   Stage-1 live spans were 6.053 / 6.175 ms: that overlaps baseline variability.
   Its paused spans improved from 5.433 / 5.462 to 5.387 / 5.317 ms. The stronger
   attribution is the final executable's shadow-only bypass: RT preparation
   increased from 3.506–3.528 to 3.606 ms, roughly 0.08–0.10 ms.
2. Shared RD submission retains validated BLAS dependencies and native instance
   bytes, repacking changed inputs while preserving full uploads and graph reads.
   Disabling only this reuse raised final live RT preparation to 3.774 ms and
   rendering span to 6.014 ms. The controlled preparation difference was roughly
   0.25–0.27 ms. Separate controls are not strictly additive estimates.

The second shadow-only run had an unexplained CPU excursion (mean rendering span
7.070 ms, 95th percentile 10.323 ms) despite no monitored competing processes.
It remains part of the evidence, not an excluded failure. Final repeats and bypass
controls support the median gain; they do not establish that every frame improves
or that existing frametime spikes are eliminated. The CPU GI-command bucket also
fell about 0.047 ms without a direct change to that code in this pass, another
reason not to claim an exact causal sum for every microsecond saved.

The final paused rendering spans were 5.292 / 5.322 ms. Diagnostic instrumentation
confirmed that GI scene preparation remains a large part of CPU cost; moving
NPCs are not its only cause. Profiling logs include instrumentation/printing
overhead and are deliberately excluded from headline comparisons.

The 16,000-instance native stress check measured both reuse and forced invalidation:

| CPU submission case | Reuse enabled | Original-path bypass |
| --- | --- | --- |
| Stable BLAS order, 64 moving inputs | 0.355 ms | 0.421 ms |
| Same BLAS rebuilt before every call | 0.471 ms | 0.420 ms |

These medians include identical script-binding conversion and exclude GPU waits.
Native preparation/upload averages were 0.114 versus 0.179 ms for the first case,
and 0.227 versus 0.176 ms for forced invalidation. Each phase contains 120 calls;
the first reuse call is cold. Every instance shares one BLAS, so this is not a
bound on all topology/animated-geometry workloads. The roughly 0.05 ms cold-path
penalty is accepted against the measured game benefit. Both independent reviewers
advised against another invalidated-byte cache state machine without evidence
that this fallback dominates actual animated NPC gameplay. CPU memory grows with
retained per-TLAS instance records; resource lifetimes remain bounded by the TLAS.
A dependent BLAS rebuild invalidates the retained TLAS preparation cache, so gains
may shrink with fully animated NPC meshes; the measured game snapshot uses simple
NPC bodies.

## Correctness evidence

- Both stages passed 29 shadow lifecycle states / 33 captures: **6,941,931 pixels
  exactly matched baseline**. Mutations cover mesh/MultiMesh transforms, shared
  parents, bulk/layout/count changes, masks/material eligibility, lights/camera,
  source-content edits/replacement/free, empty scenes and independent viewports.
  Shadow controls changed 1,451 / 1,234 / 1,234 pixels, ruling out a vacuous test.
- Actual cache-hit reconstruction oracles passed for shadow instances, shared
  MultiMesh values, native packed bytes, unique graph trackers and both weak
  dependency directions.
- Corrected native fixtures passed on baseline, final-with-oracle and final
  bypass: 136 mutation/query checks plus 24 upload-lifetime queries per run.
  They include repeated same-frame builds/queries, active/inactive slots, empty
  lists, reordered/shared BLAS, live fields, same-RID rebuilding and implicit
  BLAS destruction through source-buffer free. GI regressions exercise normal
  C++ refit submission; the script API does not expose that argument.
- Final GI metadata, MultiMesh, deformation and 21-stage binding lifecycle rigs
  passed with both new oracles enabled. MultiMesh direct/GI MAE was 0 / 0.000334;
  four/eight-weight deformation GI MAE was 0.001232 / 0.002604. Posed buffers,
  blend shapes, FSR2, resource replacement and independent viewports were covered.
- Live World images were visually inspected. Final versus baseline normalized
  RGB MAE was 0.000214 live / 0.000222 paused. Temporal game images are not claimed
  to be byte-identical; the deterministic hard-shadow fixture is.
- Two independent source reviews found no blocking issue. Applicable repository
  hooks passed. This task changes no bound API/property requiring XML regeneration.

Initial fixture failures remain recorded. The first two shadow captures requested
a null mesh on a live dirty MultiMesh and triggered an existing bounds assertion;
the fixture now destroys and recreates the resource correctly. Both native scripts
initially omitted device-address buffer usage, producing zero BLAS vertex addresses
and GPU device loss on **both** baseline and final. The scripts now request the
required usage and assert a nonzero address before building. Corrected runs passed;
no production workaround or error suppression was added. The earlier native script's
existence must not be mistaken for previous runtime acceptance.

## Conditions and reproducibility

- Windows, Ryzen 7 7800X3D, RTX 5090, Vulkan 1.4.357. Optimized editor build:
  `platform=windows target=editor arch=x86_64 dev_build=no debug_symbols=no optimize=speed accesskit=no d3d12=no -j8`.
- Same frozen fps-proto revision `0361687daec58ed8709971962f6ab693519d7378`
  and native component as the [preceding report](../amd_gi_optimization_2026_10_26/RESULTS.md).
  Live World, 62 NPCs in that snapshot's simple-body configuration, grass off,
  1280x720 window, DLSS Quality, 853x480 internal resolution, full reflections
  relative to internal size. The current mutable game checkout was not edited.
- Isolated user data, deterministic simulation delta/seed, uncapped/VSync off,
  240 warmup frames followed by 90 settling and 480 samples per live/paused phase.
  Image readbacks occur after timing windows. All headline/control windows had
  no competing Godot/compiler processes recorded. Game Director explicitly held
  the baseline, stage-1, final and native-stress windows, and was released afterward.
- User project settings SHA-256 remained
  `9030fa767a25f525a632c2d3cab4da87acf10a029dd0aa96816e8cbf750489d7`.
  Executable and source patches, manifests, raw samples, screenshots, diagnostic
  logs, excluded fixture attempts and stress data are local under
  `.artifacts/rt-cpu-opt-20261026/`. They are not present in every clone.
- Portable correctness entry points: [run_lifecycle.py](run_lifecycle.py),
  [score.py](score.py), [run_native.py](run_native.py), and the preceding
  [GI regression runner](../amd_gi_optimization_2026_10_26/run_regressions.py).
  Stress fixture: [tlas_cpu_stress.gd](../shadow_validation/tlas_cpu_stress.gd).
  Set `RT_TLAS_STRESS_OUT` to a report path and use the documented bypass/profile
  switches. Profiling output is diagnostic; keep it off game timing samples.

| Preserved executable | SHA-256 |
| --- | --- |
| Baseline | `c15d6f3b64ac765f7bccb95ac714cb369835bc5fab030f2c3617526faf756c74` |
| Shadow preparation | `db70fe7790657771056fb2dcbf655692c360146013f67725c7dbbe2cd46d51c8` |
| Final | `a4a921ed54aa6ee0e6e38e1df649ea17631c7f616dce9b9aac78a11d3492a0cf` |

The final executable is also `bin/godot.windows.editor.x86_64.exe`. All these
builds embed the same base revision; use checksums and captured source patches
to distinguish local changes. Rebuild contracts are in
[RT shadow internals](../../internals/rt-shadows.md#shared-cpu-submission-reuse)
and [TLAS reuse notes](TLAS_REUSE.md).
