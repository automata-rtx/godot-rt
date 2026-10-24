# AMD GI emitter performance: evaluation and implementation

2026-10-24, RTX 5090, Windows, Vulkan 1.4.357, NVIDIA driver 621.01.
Branch `feature/amd-gi-emitter-performance`, split from the pushed
`feature/amd-gi` checkpoint `9f4386ed09`. Local MSVC editor, `optimize=speed_trace`,
`dev_build=no`, debug symbols enabled, D3D12/AccessKit disabled.
The unchanged delivered editor (`e308dc7193`, including the freeze corrections)
is the performance control; the later checkpoint commits only added documentation.
Game: fps-proto `0361687d`, Crossroads, 1280x720 windowed, native render scale.
No authored game scripts/assets or saved settings were edited in this work.

## Adversarial evaluation

The [preceding synchronized profile](../amd_gi_profile_2026_10_24/README.md)
found 5,291,940 emitter triangles, 12,563 batches, 256 light-grid cells, and only
56 changed batch transforms in one snapshot. The bottleneck was the repeated
serial candidate walk and full emitter regeneration, not the diffuse ray budget.

| Candidate | Challenge / failure mode | Decision |
| --- | --- | --- |
| Rebuild only changed native emitter batches | Stale transforms, skinned geometry, moved analytic prefix, source IDs, buffer replacement or changed layout could corrupt light records. | Implement. Compare existing batch geometry revisions, buffers, offsets and transforms; force full rebuild on invalidation/backend or batch-count changes. Validate active bytes against full regeneration. Legacy capture path keeps full updates when changed. |
| Evaluate native proposal emission once per frame, then skip provable zero candidates in order | Atomic append would scramble strata/order/RNG. Permanent black classification would miss animation. Quantized color or an intensity threshold changes weights. Zero times nonfinite geometry need not be zero. | Implement full-float proposal RGB plus two levels of ordered per-stratum bit masks. Retain original IDs, count, RNG and weights. Reevaluate every frame/viewport. Only remove exact RGB zero with conservative finite-geometry bounds, or nonpositive-area records already rejected by the reference. Ambiguous geometry remains in the original stream. |
| Cache emitter emission across frames | Time, uniforms and dynamic textures require broader invalidation; a stale proposal can omit a newly lit emitter. | Reject for this change. Only geometry persists; proposal colors are always refreshed. |
| Drop dim emitters, classify entire black atlases, or disable emission | Texture area is not triangle coverage; dim and animated light would be lost. | Reject. No threshold, material exclusion or quality-setting reduction. |
| Change GridStream mode, merge parallel reservoirs, reduce cells/strata | Changes the estimator or deterministic stream. More parallel work alone did not fix the measured scan cost. | Defer; unnecessary to achieve the measured gain and outside unchanged-algorithm scope. |
| Reduce GI resolution/rays, disable bounce/denoising | Earlier controls barely affected the dominant work and would sacrifice quality. | Reject as a fix. Keep runtime GI settings. |

The finite-zero guard is deliberately conservative: extreme coordinates/areas,
tiny nonzero cell extents, nonfinite data and locations close to grid corners
keep the original candidate. Its bounds only disable the optimization; they do
not clamp RGB, tracing distance, geometry or sampling weights. Negative, dim and
HDR nonzero RGB retain their original evaluation. Zero-weight candidates never
advance the reference reservoir RNG, so removing them leaves its stream intact.

## Measurements

Each timed run warms 100 frames after settings application and collects 90 GPU
frames with a fixed seed/camera through the actual menu. Runtime settings are in
[results.json](results.json); individual samples are in [frames.csv](frames.csv).
GI, emissive sampling, multibounce and denoising are enabled; probe spacing 16,
quarter primary diffuse ray budget, reflections disabled by this game's settings.
RTSS is excluded only from the child process, as in the earlier freeze workaround.

| Normal execution | Median whole GPU frame |
| --- | ---: |
| Unchanged delivered editor, same harness | 135.604 ms |
| Candidate repeat 1 | 3.509 ms |
| Candidate repeat 2 | 3.496 ms |
| Final build, profiling instrumentation removed | 3.505 ms |

This is about 97.4% less whole-frame GPU time in this specific view. It is not
a 39x gameplay-FPS claim: CPU work, pacing, scene loading and other workloads
remain. No Radeon 780M or full-resolution performance claim is established.

A separate instrumented run inserts all-command barriers around timestamps,
preventing work crossing labels. It costs extra synchronization: median whole
GPU frame 3.866 ms. Do not mix its intervals with normal execution totals.

| Synchronized stage | Candidate median | Previous synchronized baseline |
| --- | ---: | ---: |
| Prepare current-frame native emission | 0.484 ms | Repeated inside grid construction |
| Build upper mask level | 0.006 ms | Not present |
| Grid dispatch and ordered reservoir construction | 0.559 ms | 120.804 ms |
| Native emitter geometry update | 0.092 ms | 16.780 ms dispatches + 0.309 ms clear |
| GI TLAS | 0.202 ms | 0.200 ms |
| Remaining GI passes after grid | 0.721 ms | Not aggregated in the preceding report |

Stage comparison uses the preceding baseline report; the fresh 135.604 ms control
above uses ordinary whole-frame timestamps. Ordinary `AMD GI` and `Update RT
Acceleration Structures` labels are retained in JSON for transparency, but are
not reliable detailed attribution. In the instrumented run they also end at the
new intermediate markers, so their meaning differs.

The new scratch storage costs about **82 MiB additional per active GI viewport**
at 5.29 million emitters: 16 bytes per proposal plus hierarchical masks. It grows
with emitter capacity, is reused, and is released with GI viewport resources.
Dense emission still requires visiting all candidates per cell; this optimization
does not establish scalable performance for arbitrarily many bright emitters.

## Correctness and regression evidence

- Opt-in `GODOT_AMD_GI_VALIDATE_LIGHT_GRID=1` independently recomputes the original
  full scan, comparing selected ID, selected/total weight bits and random state.
  It also compares residual/none probability bits. It is disabled
  in all normal performance measurements.
- `GODOT_AMD_GI_VALIDATE_EMITTER_UPDATES=1` compares the active GPU emitter buffer
  byte-for-byte with forced full regeneration. It is diagnostic only and performs
  expensive readbacks; do not enable it for performance measurements.
- The actual Crossroads light-grid oracle reported zero mismatches over 194
  validated frames, including the completed 90-frame sample window, on the final
  implementation with the temporary profiling instrumentation removed.
- [Emitter optimization fixture](../shadow_validation/amd_gi_emitter_optimization.gd)
  exercises transform updates, dynamic uniform and texture emission, analytic and
  environment membership, resampling, signed/HDR/dim values, tiny/distant geometry,
  emitter removal/repacking, growth through 262,145 triangles, and GI lifetime.
  It exits 0 with 66 zero-mismatch grid comparisons and 56 matching emitter-buffer
  comparisons. Counts and completion markers are in [validation.json](validation.json).
- Existing consequential integration and native emitter-coordinate regressions
  exit successfully. Consequential image/ownership checks cover an independent
  viewport, odd sizes, camera replacement, empty screen and GI disable. All 704
  coordinate/material samples pass (maximum component error 0.00091337).
  These were hardware RTX 5090 runs, despite the old integration scorer's fixed
  software-Vulkan footer.
- Menu-driven Sandbox → Crossroads → Live World completed with GI enabled and
  effective DLSS mode 6, then exited with code 0. The printed FPS snapshots were
  60/48/48; these are transition checks, not a controlled CPU/FPS benchmark.

The isolated game profile harness still exits with `0xc0000005` after printing
`DEEP_PROFILE_END`, as does the unchanged control. Earlier Windows fault records
identified `nvcuda64.dll`; root cause remains unresolved. Completed timing windows
are valid, but those runs are not clean-exit validation. The successful level
sequence does not establish that every shutdown path is fixed. Existing lighting
quality/compatibility gaps in the main handoff remain open.

## Reproduce

Use absolute paths for `$editor`, `$project`, `$harness` and `$log`. For normal
measurements, clear all diagnostic `GODOT_AMD_GI_*` environment overrides first:

```powershell
$env:VK_LOADER_LAYERS_DISABLE = 'VK_LAYER_RTSS'
$env:GI_PROFILE_LEVEL = '5'
$env:GI_PROFILE_SPACING = '16'
$env:GI_PROFILE_NO_EMITTERS = '0'
$env:GI_PROFILE_NO_BOUNCE = '0'
$p = Start-Process $editor -ArgumentList "--path $project --script $harness --gpu-profile --windowed --resolution 1280x720 --rendering-driver vulkan --audio-driver Dummy --log-file $log" -PassThru
$p.WaitForExit()
```

Use [profile.gd](profile.gd); it logs runtime settings and does not save them.
[levels.gd](levels.gd) exercises the actual menu transitions with DLSS instead.
[summarize.py](summarize.py) takes completed log paths and writes the JSON/CSV.
The synchronized run applies [instrumentation.patch](instrumentation.patch)
with `git apply --ignore-space-change` to this implementation, rebuilds, and
sets `GODOT_AMD_GI_PROFILE_STRICT=1` before launch.
This patch is evidence only: it has been removed from the production engine.
Local full logs/build output are under `.artifacts/emitter-performance/`.

For correctness, use the repository's `docs/validation/shadow_validation` project,
enable both validation environment variables above, and launch
`res://amd_gi_emitter_optimization.tscn` at 320x180 with Vulkan and Dummy audio.
Require exit 0, `EMITTER_OPT complete`, no errors, zero grid mismatches and only
matching emitter records. Turn diagnostics off afterward.
