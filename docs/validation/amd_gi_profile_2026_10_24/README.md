# AMD GI GPU cost investigation — RTX 5090, 2026-10-24

## Finding

The bottleneck is **preparing emissive lights**, not tracing/shading the diffuse
GI hits. Crossroads supplies 5,291,940 emissive triangles. The light grid scans
them independently for 256 cells every frame. A small transform change also
causes every emitter geometry batch to be regenerated.

This **supersedes the earlier attribution of about 122 ms to hit shading and
19 ms to acceleration-structure updates**. Ordinary GPU timestamp boundaries
allowed work to cross the labels. With explicit GPU synchronization around
timestamps, the cost moves to its actual producer stages. Diagnostic removal
of those producers independently confirms the attribution.

## Measured baseline

Harness: [profile.gd](profile.gd), external to fps-proto. Windows, RTX 5090,
NVIDIA driver 621.01, MSVC speed_trace editor based on `e308dc7193` plus the
[temporary instrumentation patch](instrumentation.patch). fps-proto `0361687d`.
Crossroads is entered through its existing main-menu actions. Native 1280×720,
upscaler and screen AA off, default quarter primary ray budget, multibounce on,
GI reflections off, RT shadows on. Streamline initializes but DLSS is inactive.
RivaTuner's implicit Vulkan layer is excluded only for each child process.

After 100 settling frames, the harness records 90 distinct GPU frames. The
camera is stationary at approximately `(300, 8.4516, -262)`; gameplay/animation
continues. These are **GPU elapsed times, not achievable gameplay FPS**.

| Stage | Median ms | 90th percentile ms |
| --- | ---: | ---: |
| Entire GPU frame | 140.688 | 141.410 |
| GridStream light-grid construction, pass 17 | 120.804 | 121.002 |
| Emitter geometry dispatches | 16.780 | 17.300 |
| Emitter buffer clear | 0.309 | 0.500 |
| GI TLAS build | 0.200 | 0.203 |
| GI material/context uploads | 0.107 | 0.107 |
| Primary hit shading, pass 18 | 0.080 | 0.084 |
| Secondary hit shading, pass 18 | 0.090 | 0.095 |

This table uses `final-0`. Separate synchronized baseline runs measured roughly
117–121 ms for grid construction and 136–141 ms total. The original unsynchronized
baseline also measured about 140 ms total, so serialization does not account for
the large overall cost. Per-stage medians should not be summed as a frame sample.

## Why the list is so large

The GPU scene has 16,402 surface instances and 12,563 emitter batches. Materials
with an EMISSION program contribute **all of their triangles**, including triangles
whose sampled emission is zero. Material shader IDs and texture RIDs were recorded
in the run metadata, then matched to resources through read-only scene inspection.

| Emission source | Triangles |
| --- | ---: |
| `PolygonApocalypse_01_Emissive.png`, two native material variants | 5,227,496 |
| `Vehicle_01_Emissive.png` | 64,420 |
| Constant cyan emission | 24 |
| Total | 5,291,940 |

The raw PNGs are respectively 99.652% and 99.883% exactly black, measured with
[texture_stats.py](texture_stats.py). Texture area is not triangle coverage.
A separate one-cell GPU diagnostic found **6,135 positive emitter proposal
weights**, about 0.116% of the full triangle list, at its sampled frame. This
is a scoped diagnostic, not a proof that the other triangles never emit.
Filtered texture sampling, animation, and material changes must remain correct.

In `amd_gi_lights_inc.glsl`, `build_light_grid()` assigns one 64-thread workgroup
to each grid cell. Every lane walks a strided portion of the complete light list.
For this scene that is approximately **82,687 candidates per lane**, sequentially.
Across 256 cells, the triangle portion alone is **1,354,736,640 candidate
evaluations per frame** (arithmetic from the measured dispatch/list counts).
Each candidate can reconstruct native emission and evaluate the eight-corner
volume weight. The native emission lookup at the triangle centroid does not
depend on the grid cell, yet is repeated for each cell.

## Why emitter geometry is rebuilt

At the baseline diagnostic snapshot, only **56 of 12,563 batches** differed from
the previous frame: 56 transforms, zero geometry revisions, zero pixel revisions,
and zero layout/source-buffer changes. Another diagnostic snapshot had 48 dirty
transforms. `RaytracingGIScene::update_emitters()` stops checking at the first
change, clears the entire power-of-two emitter allocation, and dispatches every
batch again. For this list the clear covers **512 MiB**; the dispatch loop costs
much more than the clear itself.

The capture proves broad regeneration after a small change. It does not prove
that all unchanged batches can always be retained: membership, source indices,
transforms, geometry revisions and allocation changes need explicit handling.

## Controlled diagnostic comparisons

Each row uses the same menu, camera, resolution, settling interval and 90-frame
measurement window. These are ablations, not shipping presets or validated fixes.

| Experiment | Light grid median ms | GPU frame median ms | Interpretation |
| --- | ---: | ---: | --- |
| Baseline (`final-0`) | 120.804 | 140.688 | Full current path |
| Skip hit shading (`strict-6`) | 117.023 | 136.483 | Hit shading is not the large cost |
| Replace grid construction with empty entries (`strict-7`) | 0.006 | 19.187 | Grid construction accounts for the dominant cost |
| Constant emitter color inside grid weighting (`grid-simple-emission`) | 86.490 | 106.477 | Removing native emission evaluation helps, but the long scan remains expensive |
| Disable emissive-light sampling (`no-emitter-sampling`) | see results JSON | 2.817 | Both expensive preparation stages disappear; this removes lighting and is not the fix |
| Probe spacing 32 (`spacing-32`) | 120.869 | 140.686 | Quartering the primary ray budget does not shrink this emitter list/grid |
| Return early for zero emitter luminance (`final-9`) | 114.181 | 134.091 | A simple early return saves only a small fraction |
| Build only one grid cell (`final-10`) | 118.236 | 138.049 | A single group's long serial scan still takes nearly the same wall time |

The last result is consistent with long per-lane dependency chains and limited
parallelism inside each cell. **Hardware occupancy, cache misses and instruction
stall counters were not captured**, so a specific register/spill/bandwidth claim
would be premature. Ablation deltas are not additive component costs: compiler
decisions, lighting, histories and scheduling can change between variants.

The initial attempts to bypass visibility rays, hit materials, emitter target
materials and accumulation all left the large cost. Their ordinary timestamp
labels were misleading; they are not evidence for expensive hit shading.

## Recommended fix work

1. Update only dirty emitter geometry batches when layout is stable, with a
   correct full rebuild for membership/layout changes. This targets the measured
   16–17 ms regeneration loop without reducing lighting quality.
2. Evaluate cell-independent native emitter proposal data once, using enough
   parallel workgroups, then avoid scanning known zero-contribution candidates
   in every cell. Preserve original source IDs, 64-way strata, candidate order,
   RNG consumption, PDFs and dynamic material updates. An exact-zero compaction
   design needs equivalence tests; dropping dim lights or changing GridStream
   modes would be a different algorithm decision.
3. Reprofile after those changes before spending effort on ray queries, hit
   materials, denoising, resolution or bounce budgets. No performance target is
   established by these diagnostic removals.

No production optimization was installed by this investigation. Temporary
instrumentation was removed from the engine source and the normal engine rebuilt.
fps-proto scripts, assets and saved settings were not changed in this profiling
turn; rendering overrides existed only in the test processes.

## Reproduction and evidence

- [results.json](results.json): aggregate timings and scene/counter metadata.
- [frames.csv](frames.csv): selected raw per-frame GPU timings for nine runs.
- [profile.gd](profile.gd): menu-driven measurement and material inspection.
- [summarize.py](summarize.py): extracts full timing summaries from run logs.
- [instrumentation.patch](instrumentation.patch): diagnostic source changes against
  `e308dc7193`; apply with `git apply --unidiff-zero` only in a profiling
  checkout at that revision, then rebuild. It includes
  explicit all-command GPU barriers immediately around Vulkan timestamps.
- Full local logs: `.artifacts/deep-profile/`. The copied CSV/JSON preserve the
  reported evidence without requiring the entire local artifact directory.

Example PowerShell environment and invocation after applying/building the patch:

```powershell
$env:VK_LOADER_LAYERS_DISABLE = 'VK_LAYER_RTSS'
$env:GODOT_AMD_GI_PROFILE_PASSES = '1'
$env:GODOT_AMD_GI_PROFILE_STRICT = '1'
$env:GODOT_AMD_GI_PROFILE_COUNTS = '1'
$env:GODOT_AMD_GI_PROFILE_MODE = '0'
# Use absolute paths for the project, external script and log.
$p = Start-Process $editor -ArgumentList "--path $project --script $harness --gpu-profile --log-file $log" -PassThru
$p.WaitForExit()
```

Mode 0 is unaltered shading; 1 bypasses pass-18 visibility; 2 substitutes hit
material values; 3 substitutes selected emitter material values; 4 bypasses direct
lighting; 5 bypasses direct accumulation; 6 skips hit shading; 7 writes an empty
light grid; 8 substitutes grid emitter color; 9 exits early for zero luminance;
10 builds/counts only cell zero. Harness environment controls:
`GI_PROFILE_NO_EMITTERS=1`, `GI_PROFILE_SPACING=32`, `GI_PROFILE_NO_BOUNCE=1`,
and `GI_PROFILE_LEVEL` (default Crossroads index 5).

### Exit-time limitation

All measured runs completed their sample window and printed `DEEP_PROFILE_END`,
then exited with `0xc0000005`. Windows recorded the fault in `nvcuda64.dll`.
The **unchanged delivered editor** reproduced the same exit fault with this
harness and emissive sampling disabled, so it is not isolated to the shader
ablations or synchronized timestamps. This is a separate unresolved shutdown
issue; fault-module attribution alone does not establish its root cause.
It does not erase the completed steady-state timings, but these runs must not
be described as clean-exit validation. Two intermediate runs also had a diagnostic
log formatting error; that was corrected before `final-0` and the reported dirty
batch snapshot.
