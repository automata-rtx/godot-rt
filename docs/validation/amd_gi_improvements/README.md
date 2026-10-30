# Optional GI improvement validation

Owner-authorized implementation, 2026-10-30, on `feature/amdgi-improvements`.
The frozen tag/branch still point to `1c069bd46ab7aaf8fef76591d5c788d913babad2`.
All three [public switches](../../../GodotForkDocs/features/amd-gi-improvements.md)
default off. This is an experimental checkpoint, not shipping or hardware acceptance.

The subsequent [FPS refinement suite](FPS_REFINEMENT.md) is the latest evidence:
actual flashlight visibility, mixed lighting, camera/NPC motion, muzzle flashes,
emissive hazards and polished weapon stress. Results below describe the initial
controlled-room checkpoint; that fixture changes indirect light energy, not the
visible flashlight beam. Do not label its light-off captures as actual beam-off.

## Implementation

- **Response:** three consecutive significant luminance observations confirm brightening/darkening;
  compact confidence then decays. Cache history is reduced before accumulation,
  probe energy confirmation relaxes outlier hysteresis, and reconstructed confidence
  reduces final diffuse history before adding the new sample. Absent observations
  are not zero samples. Exact-zero analytic-light certification is deliberately
  limited to no sampled sky/emitters and at most eight lights.
  Observations are updates, not necessarily frames; equal-luminance color changes
  and changes below the fixed dark-signal threshold do not trigger this detector.
- **Scheduling:** local bounded selection favors missing history, aged change demand,
  and overdue probes. A just-refreshed probe gets no change priority. Preserve
  within-probe jitter and hole patching, protecting overdue selections from patching.
  The maximum primary-ray allowance is unchanged; filling previously unused slots
  can increase the actual ray count. Deadline proofs assume stable reprojection.
- **Transitions:** admit an immediate finer estimate smoothly over 75–100% of the
  existing sample threshold; never admit an empty cell as black. No extra RGB
  cache, ray, or persistent storage. Existing mip traversal already loads both
  estimates. Counts, allocation, and mip construction remain intact.

Response metadata: 88 bytes/tile per active direct/indirect cache, totaling 44 MiB
at default capacity with multibounce. Existing probe/pixel padding carries response
without increasing those allocations. Atomics protect packed neighboring cell
writes; mip/resolve consumers use ordinary reads after the appropriate barriers.

## Executed checks

- Full Linux release-style editor build; initial build 6m55s, incremental renderer
  rebuilds approximately 50s. Existing shadowed-variable warning remains.
- All 59 GLSL variants compiled to Vulkan 1.2 SPIR-V with a constant material stub.
- `check.py` executes extracted production scalar policies as C++: isolated bright
  outliers, alternating noise, both transition directions, recovery, continuity,
  stable-region starvation bounds, packed-byte ownership, and exact-zero guards.
  The lighting guard uses controlled light values; it is not a native material test.
- Class reference regenerated into an isolated directory using the matching editor;
  `ProjectSettings.xml` matched the maintained descriptions exactly.
- Actual software-Vulkan fixture: llvmpipe LLVM 19.1.7, native 640x360, quarter
  sampling, GI denoiser/multibounce/reflections on, FSR2/TAA/VBAO off. Separate
  original/response/scheduling/transitions/combined runs, including both switch
  directions, motion, return/disocclusion, cold cache, and four-frame light pulses.
- Live option/resource matrix at 321x181 and 333x187: individual/combined switches,
  retained probes, adaptive patching, multibounce, all-hit caching, reflections,
  spacing 8/16/32, GI off and restoration. GPU probe counters remained within budget;
  the existing ownership/LRU oracle found no duplicate or out-of-range selections.
  Changing improvement flags with GI off left buffer allocation unchanged.

## Findings and limits

The first response implementation improved switch-on but failed complete-darkness
switch-off. Keeping that failed run exposed the distinction between no lighting
proposal and known zero lighting. The narrow exact-zero certificate addresses the
tested analytic-light case without interpreting sky/emissive sampling misses as black.

The first combined version prioritized recently refreshed changing probes too
strongly and lost much of the response benefit. Accounting for update age and
tightening the overdue rule recovered it. Intermediate captures remain available;
do not label them as the final combined implementation.

In the revised combined fixture, approximately 26% of the settled bounce appeared
by frame 16 after switch-on (original: 11%). About 24% remained at frame 32 after
switch-off (original: 53%). These are **display-image measurements**, normalized
to each run's 256-frame settled result, not radiometric accuracy or GPU time.
The first few frames were not uniformly faster. Darkness still takes time to resolve.

The final 16-frame steady-state measurement found approximately 6% brighter
displayed bounce and 14% higher temporal standard deviation with all upgrades
enabled. Absolute mean temporal deviation was small (0.000198 vs 0.000225 in
display-linear luminance); this is one controlled fixture, not a perceptual score.
Do not describe this as a free quality gain. Cache-transition stills show subtle changes; they do not establish
a broad reduction of visible popping. Scheduling cannot discover changes in
unsampled regions instantly or overcome the fixed spatial resolution.

No RTX 5090/780M timing, VRAM residency profile, Windows build, Crossroads gameplay,
moving weapon/NPC, dynamic emitter-atlas, multiple-viewport, DLSS, or final FSR2
presentation acceptance is established by these tests. Existing material exclusions
and polished-reflection limitations remain. Do not promote these switches to
shipping defaults based on the fixture alone.

## Reproduce / inspect

```sh
python3 docs/validation/amd_gi_improvements/check.py
python3 docs/validation/amd_gi_tuning/compile_shaders.py --all-passes --compiler glslangValidator
GI_SETTLE_FRAMES=256 GI_CAPTURE_STEADY=1 \
  docs/validation/amd_gi_improvements/run.sh baseline /absolute/output/baseline
# Repeat with response, scheduling, transitions, or combined in a separate folder.
GI_TEST_RIG=amd_gi_improvements_lifecycle GI_TEST_RESOLUTION=321x181 \
  GODOT_AMD_GI_VALIDATE_CACHE=1 \
  docs/validation/amd_gi_improvements/run.sh combined /absolute/output/lifecycle
```

For matched final analysis, name the two output directories `final-baseline` and
`final-combined` beneath one directory, set `GI_CAPTURE_STEADY=1` on both runs, then
run `python3 docs/validation/amd_gi_improvements/compare.py /absolute/output`.
It requires NumPy, Pillow, and DejaVu Sans. It verifies frame/settings/executable
matching and identical direct-only controls before writing native-pixel paired
PNGs and `final-metrics.json`. The labels are outside the captured pixels.

`GODOT_BIN`, `XVFB_BIN`, `VK_ICD_FILENAMES`, `GI_TEST_DISPLAY`, and `GI_TEST_CACHE`
select the local executable/display/driver/cache. These scripts launch Godot; use
the current session's execution authorization. Timings under software Vulkan are
not target-GPU performance evidence. The lifecycle fixture uses a smaller hash
capacity; image captures use the default capacity. Do not compare those costs.

Local PNGs/logs/metadata: `/workspace/preview/amdgi-improvements/`. The directory
is not included in a repository clone. Capture JSON records settings/frame counts;
each run has an executable SHA-256. Final paired PNGs retain native image pixels
and identical exposure, with labels added outside the captures.
