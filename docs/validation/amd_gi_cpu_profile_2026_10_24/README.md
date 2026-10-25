# Live World CPU profiling

2026-10-24. One explicitly authorized profiling launch, now closed (exit 0).
**Ask the owner before any further game launch.** The earlier standing permission
was revoked; authorization for this pass does not restore it.

Engine `4ca77d59c7`, with temporary CPU instrumentation, local MSVC speed build.
fps-proto `0361687d`, Live World Crossroads, 62 configured NPCs (48 guards),
runtime initialization reports ready with no failure. Ryzen 7 7800X3D / RTX 5090.
1280x720 windowed, native scale, VSync disabled and no engine FPS cap. GI on/off
overrides were process-local. NPC simulation and RT shadows stayed enabled.
No authored project scripts/assets or saved settings were changed.

## Finding

The large CPU cost is **GI scene preparation**, not animated NPC BLAS rebuilds
in this test. The profiler's `Update RT Acceleration Structures` label includes
scene collection, material-context preparation, hit-record construction/uploads,
emitter preparation and actual acceleration-structure commands.

The sampled steady frames processed 16,528 GI surfaces and made **98,534 buffer
device-address queries per frame**. Static surfaces are still walked and their
native contexts/hit records rebuilt every frame. The previous optimization
removed redundant GPU emitter work; it did not cache this CPU-side scene work.

Every detailed steady sample recorded **zero skinned BLAS refreshes and zero
new BLAS builds**, in both GI-on windows. Current `npc_live_world.gd` explicitly
selects `simple_bodies=true`; NPCs do not use the posed visual backend here.
Moving NPCs can still change top-level instance transforms. That work is much
smaller than the full GI surface preparation in this measured configuration.
This does not establish the cost of a different NPC model/animation backend.

## Current performance

Each phase warmed 120 frames and collected 240 frame intervals. An initial
300-frame scene warmup preceded the first phase. The second GI-on phase checks
that the result survives disabling/re-enabling GI while NPCs continue running.

| Median | GI on | GI off | GI restored |
| --- | ---: | ---: | ---: |
| Frame interval | 19.619 ms | 5.802 ms | 19.384 ms |
| CPU RT preparation label | 14.908 ms | 0.312 ms | 14.695 ms |
| CPU render span | 17.194 ms | 0.881 ms | 16.998 ms |
| Whole GPU frame | 3.843 ms | 0.839 ms | 3.816 ms |

This is approximately **51 FPS in the measured stationary view with GI on**.
It is not a full-level gameplay benchmark or a prediction for another resolution,
camera, machine or NPC configuration. GPU time alone does not predict frame rate
when CPU work takes roughly five times as long. The 5.8 ms GI-off result is a
diagnostic baseline, not an achieved GI-on target or a proposed quality preset.

CPU scopes sampled only every eighth RT update. The other seven updates omit
the inner clocks; the all-frame median therefore mostly reflects those frames.
The sampled updates cost about 19.3–19.6 ms in the RT preparation scope, versus
14.7–14.9 ms for the ordinary timestamp median. **Instrumentation overhead is
material**, particularly for the ~98,500 tiny address-query calls. Do not quote
the inner scope values as exact uninstrumented costs or use the inflated p90 as
a gameplay hitch measurement. A pristine repeat would require another authorized
launch. The earlier interrupted/concurrent runs are excluded from this report.

## Where the sampled CPU work goes

Representative medians from the first GI-on window, including timer overhead:

| Scope | Time | Interpretation |
| --- | ---: | --- |
| GI collection/sort/pose requests | 2.407 ms | Recollects the participating scene, including off-screen objects. |
| GI surface loop | 15.706 ms | Main CPU hotspot: static and dynamic surfaces both rebuild records. |
| Native material contexts | 6.667 ms | Subset of the surface loop; one call per GI surface. |
| Buffer-address queries | 5.017 ms | Overlaps material contexts and other record construction; high timer overhead. |
| GI geometry lookup | 0.531 ms | Subset of the surface loop; cached geometry, not new BLAS creation. |
| GI TLAS submission | 0.351 ms | CPU preparation/submission, not GPU build duration. |
| Emitter update | 0.265 ms | Incremental geometry path from the previous fix. |
| Shadow scene update | 0.167 ms | Includes its own geometry lookup and TLAS submission. |

Nested scopes overlap: **do not add these rows**. The restored phase shows a
similar distribution. Exact sample counts, call counts and medians are in
[results.json](results.json); raw measurements are in [detail.csv](detail.csv),
[render.csv](render.csv) and [wall.csv](wall.csv).

## Highest-value fix candidates

1. Cache reusable native surface/material metadata and stable buffer addresses.
   `RaytracingMaterialSource::add_surface()` and GI hit-record construction ask
   for the same buffer addresses across many instances. The Vulkan implementation
   currently calls `vkGetBufferDeviceAddress` on every request. A lifetime-aware
   cache can avoid repeated lookup/API work; its benefit needs measurement.
2. Reuse static instance/surface records and update changed fields/ranges. Preserve
   source IDs and ordering; invalidate on geometry/attribute revision, buffer
   replacement, material changes, instance parameters, transforms and membership.
   Keep time-dependent materials and uniform/texture updates live. Do not skip
   necessary geometry validation or retain freed GPU handles.
3. Reduce repeated collection, temporary allocation and sorting using explicit
   scene-change tracking. Preserve all participating off-screen geometry: reducing
   GI range or dropping static objects would change the current algorithm.

NPC BLAS refitting, fewer NPCs and lower GI ray counts are not supported as the
first fix by this pass. There is no measured post-fix FPS target yet. No production
optimization was implemented during this investigation.

## Reproduction and cleanup

[profile.gd](profile.gd) is an external menu-driven harness. It does not edit or
save the game. [instrumentation.patch](instrumentation.patch) adds sampled CPU
scopes only; it does not change shading or insert extra GPU barriers. Apply with
`git apply --ignore-space-change` to the engine checkpoint and rebuild. After
obtaining new launch permission, use the environment below and absolute paths:

```powershell
$env:VK_LOADER_LAYERS_DISABLE = 'VK_LAYER_RTSS'
$env:GODOT_RT_CPU_PROFILE = '1'
$env:CPU_PROFILE_LEVEL = '1'
$p = Start-Process $editor -ArgumentList "--path $project --script $harness --gpu-profile --windowed --resolution 1280x720 --rendering-driver vulkan --audio-driver Dummy --log-file $log" -PassThru
$p.WaitForExit()
```

Clear unrelated GI diagnostic overrides before launch. Run
`python summarize.py <log>` to recreate the evidence files. The full local log
is `.artifacts/cpu-profile/authorized-live.log`. This run reached
`CPU_PROFILE_END` and exited 0; the separate shutdown fault observed in other
harnesses is not thereby proven fixed.

All temporary engine source edits have been removed and the ordinary editor
rebuilt. The installed desktop performance build was not replaced. No game
process from this pass remains running.
