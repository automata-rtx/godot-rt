# GI CPU retention and command preparation results

Validated on 2026-10-26, Windows, Ryzen 7 7800X3D / RTX 5090. Both changes are
enabled in the local editor. In the final coordinated Live World window, rendering
CPU time fell from **5.771 ms to 4.158–4.393 ms**, a **24–28% reduction** beyond
the preceding RT CPU optimization build. GPU time remained essentially unchanged.
This is rendering CPU time, not total game CPU time or a promised FPS increase.

## What changed

1. **Retain unchanged scene records.** Stable ordinary instances and complete
   MultiMesh parents keep their dense material Context, Hit, AS and emitter
   records. Current shared resources still refresh, and changed groups rebuild.
   Native uniform/texture/TIME evaluation, material eligibility, deformation and
   failed-preparation recovery remain live. Emitter records hold source/geometry
   identities; evaluated emission is not cached.
2. **Prepare repeated buffer dependencies once per render.** GI resolves owner
   kinds for its buffer-device-address sources once, then performs typed full-RID
   lookups against current transfer/graph state at every original consuming pass.
   All reads, dispatches and barriers remain. No raw resource pointer is cached.

AMD GI sampling, ray counts, update frequency, shader algorithms and quality
settings were unchanged by this work. Designs and adversarial acceptance rules:
[scene](SCENE_PLAN.md), [commands](COMMANDS_PLAN.md), [shared plan](PLAN.md).

## Final measurements

Frozen Live World snapshot, 62 simple-body NPCs, grass off, 1280×720 window,
DLSS Quality (853×480 internal), fixed camera/seed/simulation delta, uncapped and
without VSync. Each phase has 90 warmup and 480 measured frames after initial
240-frame warmup. Captures/readbacks occur outside measured windows. The paused
phase freezes simulation; it does not remove the scene.

Game Director explicitly acknowledged all three quiet windows and their releases.
No other engine/compiler process was observed in the final timing windows by the
runner's two-second process monitor. This monitor is not proof of zero unrelated
system activity. No builds or other correctness runs overlapped final timings.

All numbers below are milliseconds. Final serial order was revised-01,
scene-off, commands-off, baseline-05, revised-02, then diagnostic coverage.

| Live phase | Original baseline-05 | Revised-01 | Revised-02 |
| --- | ---: | ---: | ---: |
| Rendering CPU median | 5.771 | 4.393 | 4.158 |
| Rendering CPU mean | 5.924 | 4.397 | 4.247 |
| Rendering CPU p95 | 6.258 | 4.733 | 4.663 |
| Scene/AS preparation CPU median | 3.534 | 3.013 | 2.817 |
| GI command CPU median | 1.622 | 0.750 | 0.745 |
| Whole-frame wall median | 8.041 | 6.627 | 6.408 |
| GI GPU median | 1.974 | 1.973 | 1.972 |
| Whole-frame GPU median | 3.152 | 3.149 | 3.149 |

| Paused phase | Original baseline-05 | Revised-01 | Revised-02 |
| --- | ---: | ---: | ---: |
| Rendering CPU median | 5.380 | 3.951 | 3.806 |
| Rendering CPU mean | 5.414 | 3.971 | 3.866 |
| Rendering CPU p95 | 5.662 | 4.331 | 4.627 |
| Scene/AS preparation CPU median | 3.206 | 2.591 | 2.494 |
| GI command CPU median | 1.606 | 0.743 | 0.742 |
| Whole-frame wall median | 6.254 | 6.031 | 5.929 |
| Whole-frame GPU median | 2.901 | 2.900 | 2.898 |

The old-build comparison supports about **0.52–0.72 ms less scene preparation**
and **0.87 ms less GI command preparation** in the live phase. CPU/GPU work
overlaps; these spans must not be added to predict total frame time. In particular,
paused wall time improves much less than rendering CPU time.

Independent bypass controls, using the same revised executable:

| Live control | Rendering CPU | Scene preparation CPU | GI command CPU |
| --- | ---: | ---: | ---: |
| Scene retention disabled | 5.651 | 4.295 | 0.743 |
| Buffer-read grouping disabled | 5.171 | 2.937 | 1.638 |

Both controls establish that their optimization contributes independently. The
scene-off preparation span is **0.761 ms slower than the original executable's
full path**. Its approximately 1.3 ms enabled/disabled gap is therefore not the
old-build saving. The new reconstruction path has additional record/cursor work;
source review also identifies extra Context initialization/copy work, without
isolating its cost. Launch-to-launch variation also remains; this comparison does
not establish a universal 0.761 ms intrinsic fallback penalty. Fully changing
scenes can pay reconstruction overhead and need their own timings. Do not claim
universal speedup for high-churn scenes.

The coverage run is excluded from timing conclusions. During its live phase,
median reuse was **16,411 / 16,528 surfaces (99.3%)**, with 12,567 emitter batches.
Paused reuse was **16,528 / 16,528 surfaces**, with 12,619 emitter batches covering
5,327,318 triangle records. This skips CPU record reconstruction, not GPU light
evaluation. One zero-surface group was not reused; it does not reduce surface
coverage.

## Correctness evidence

The final `fc2b5242...` executable passed these routes:

- **Metadata, original emissive and nonemissive variants:** current-record CPU
  and GPU oracles throughout the material/shader/next-pass, uniform/TIME/texture,
  region-write, MultiMesh count/layout/bulk/interpolation, mask, resource and
  viewport mutation matrix. Subject-RID scoring additionally verifies retained
  candidates in required settled stages; excluded material stages cannot reuse.
  Emission/sampling toggles and
  earlier emitter triangle-count/membership changes exercise downstream offsets.
  Each variant records six deliberate late-preparation failures followed by
  recovery and repeated subject-specific oracle matches.
- **Actual retained emissive MultiMesh:** direct Mesh/MultiMesh image MAE 0,
  GI normalized-sRGB MAE 0.000368; movement restoration 0.001636. Color/custom changes
  remain visible. All three settled stages have 65 consecutive complete-scene
  reuse updates with positive emitter reuse. Existing image thresholds remain.
- **Actual retained light storage:** both GPU byte-comparison oracles pass,
  with 105 complete-scene emitter-retention updates after the fixture check.
- **Actual retained deformation:** four/eight-weight posed-versus-baked and
  upscaler image comparisons pass after animation. Retained mode omits separate
  motion-region/history-reset assertions. Ordinary history-tracing runs passed
  on the earlier candidate; that diagnostic mode reconstructs and does not prove
  actual skipping.
- **Binding lifecycle:** all 21 stages pass with current owner-resolution
  validation enabled for the new buffer-read groups.
- **Native GPU buffer-read regression:** the final test build passes one case,
  120 assertions, two local devices and four upload/dispatch/lifetime rounds.
  It exercises BDA reads, immutable-to-mutable buffers, GPU-written indirect
  dispatch, repeated barriers, queued deletion/replacement, invalid preparation,
  stale handles and device isolation. Console completion and assertion counts
  were captured; GUI exit code alone was not accepted as proof.
- Build, targeted formatting/lint/type/include/ownership checks and whitespace
  checks pass. No new script API was added.

Live World baseline/revised captures were inspected. Normalized linear-RGB MAE
is 0.000326–0.000873 live and 0.000387–0.000950 paused; revised/revised differences
are 0.000599 and 0.000631 respectively. Captures are not bit-identical, and these
small whole-image averages cannot certify every reflective face or material.
No noticeable change was found in this captured view. The previously reported
weapon reflection problem is outside this optimization's acceptance claim.

**Unresolved pre-existing fixture failure:** `amd_gi_dirty_materials` renders and
completes, but its receiver color-response scorer fails on both the preserved
baseline and first candidate. Blue response increases, while the required green
decrease does not reach the existing threshold. The scorer also contains obsolete
atlas assertions, but it fails before those; do not dismiss the color failure as
an atlas-only issue. No threshold was weakened. The targeted passes above do not
resolve or certify that separate material response.

## Interim results retained

The first implementation excluded emission-writing groups. In this game that
left 12,654 / 16,528 surfaces rebuilding and retained only 3,874 paused surfaces.
It **regressed scene CPU time**: initial combined live CPU was 5.536 ms versus
5.339 ms with scene retention disabled, despite the command improvement. It was
not accepted. The final implementation adds guarded emitter-record retention and
an owning-String identity shortcut before full shader-source comparison.

Original baseline live CPU medians across runs 01–05 were 6.594, 5.993, 5.955,
5.833 and 5.771 ms. All are retained. The headline uses the fastest, closest
baseline in the final window, rather than selecting the initial slower run.
Temporary fine-grained diagnostic instrumentation perturbs timings and is not
included in the headline.

## Reproduction and provenance

Local evidence root: `.artifacts/rt-cpu-investigation-20261026/`.

- `runs/{baseline-01..05,final-*,revised-*}`: raw per-frame JSON, summaries,
  logs, images, commands, hashes and process-overlap observations.
- `runs/revised-coverage/coverage-summary.json`: bounded live/paused coverage.
- `regressions/revised-{metadata,nonemissive,retained-images,deformation,binding-lifecycle}`:
  current tests and manifests; metadata directories include subject scorers.
- `native-gpu/revised-run.log`: current 120-assertion result.
- `image-comparison.json`, `final-manifest.json`, `round1-manifest.json`,
  `revised-binary/source.patch`: comparison/provenance records.

Base Git revision `66bd97e00d6c88a07aff18a22560934ad3c28ca9`, with pre-existing
working changes preserved. The source patch contains the complete rendering
working-tree delta, including previous optimizations, not just this round.

| Artifact | SHA-256 |
| --- | --- |
| Starting editor | `a4a921ed54aa6ee0e6e38e1df649ea17631c7f616dce9b9aac78a11d3492a0cf` |
| Final editor | `fc2b5242d2f9ab670e0b25c6b616653294118a50c13153e9a7243db62be25569` |
| Final rendering source patch | `572696a159c999b9cb686a86ae000888686774a357385294e32a5036784a7e67` |
| Final native-test editor | `e47ca1873d88b7184d33a8089628992619d4bc8a9db70bb2cbc7c0e1d5a0049c` |

Project snapshot revision `0361687daec58ed8709971962f6ab693519d7378`, settings hash
`a3d6a527242da295254955f61c0957c288d9198872208eeac4ac477c1c98f9af`, native DLL hash
`92c4271f029b3218a97957d038e4269aeeaff8418cef68a5e50c8e7d71d749ec`.
All game comparisons use that isolated snapshot. Live fps-proto source/assets and
the desktop editor were not changed. The tested local editor is
`bin/godot.windows.editor.x86_64.exe`; this work is not committed or pushed.

A subsequent diagnostic-only pass identifies [remaining CPU costs and candidate
priorities](REMAINING_CPU.md). It preserves this production executable and does
not establish another implemented speedup.
