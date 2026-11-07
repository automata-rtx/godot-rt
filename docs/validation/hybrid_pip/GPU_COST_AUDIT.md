# HybridPiP GPU cost audit — 2026-11-06

Frozen pre-change investigation. The first two recommendations subsequently
received [source-only implementation and checks](GPU_OPTIMIZATIONS.md); the
measurements and source-hash snapshot here still describe the pre-change state.

Source and saved-data investigation only. No Godot launch, GPU capture, renderer
change or new performance result. Working implementation is the same dev8 source
described in [RESULTS](RESULTS.md). Branch base: `91c24b8bd6`.

The current path cuts regional pixel work, but retains substantial world/scene
work and adds another sequence of screen passes. Its presentation blur is also
expensive. The evidence does not support a promised percentage improvement from
any unimplemented fix.

## Actual pixel budget

Final saved benchmark status confirms that the fixed native capacity is also
the active render extent (`HybridPiPLayout::create_fixed`), not just allocation.

| Surface | Pixels | Fraction of native 1280×720 |
| --- | ---: | ---: |
| Native output | 921,600 | 100% |
| Half-per-axis background, covering the entire view | 230,400 | 25% |
| Native scope crop, 528×608 | 321,024 | 34.83% |
| Total regional surface pixels | 551,424 | **59.83%** |
| Protected scope rectangle alone, 368×448 | 164,864 | 17.89% |

The crop protects the entire scope mesh, not only its opening. Filter guards,
alignment and fixed movement capacity add 156,160 native pixels beyond the
protected rectangle. The coarse background also exists underneath the scope.
An idealized protected rectangle plus quarter-resolution remainder, with no
guard or overlap, would be 38.42% of native. That is a geometric lower bound,
not a safe implementation or a timing prediction. Omitting the whole background
under the protected rectangle would save only 4.47% of native pixels; retaining
a 64-pixel inward guard reduces that opportunity to about 2.08%.

## Saved timing ledger

The final dev8 pooled GPU medians remain 2.449ms for native plus matching blur
and 2.431ms for regional plus blur: **0.019ms**, within run-window variation.

The earlier dev5 profile provides stage intervals, with a smaller 512×576 crop.
The following are arithmetic means from the same 1,200 samples per case, rather
than sums of unrelated stage medians. They are not final-dev8 subpass timings.

| Timestamp interval | Native plus blur | Regional plus blur |
| --- | ---: | ---: |
| AMD GI / AMD GI Regional Batch | 1.5761ms | 1.5170ms |
| Composition/blur interval | 0.4088ms | 0.4283ms |
| RT acceleration structures | 0.1430ms | 0.1443ms |
| Sky setup | 0.1420ms | 0.1437ms |
| GTAO | 0.1409ms | 0.1296ms |
| Opaque rendering | 0.0696ms | 0.0727ms |
| RT shadows | 0.0658ms | 0.0694ms |
| Depth prepass | 0.0501ms | 0.0535ms |
| Transparent rendering | 0.0116ms | 0.0225ms |
| Entire viewport | 2.7316ms | 2.7035ms |

The regional composition interval is labeled `Process Post Transparent Compositor
Effects`: the built-in composition/blur/copy follows that timestamp. It is not
evidence of an unexpected custom compositor. The reference uses the same shaders
through an external callback; the intervals have slightly different boundaries.
GPU timestamp intervals can include synchronization and work crossing labels.
They locate the main region of cost but do not establish exact execution times
for individual kernels. Do not transfer the old October 24 Crossroads per-pass
profile to this scene/build.

[Audit data](gpu_cost_audit.json) retains the stage means, source hash and offline
shader metadata. Local reproduction: `.artifacts/hybrid-pip/audit_gpu_sources.py`
reads saved JSON/SPIR-V only.

## Findings in the active path

1. **Shared GI work does not scale directly with pixels.** `AMDGI::render_regions`
   performs world-cache maintenance, combined hit registration/update, light-grid
   preparation and logical-frame advancement once. It correctly keeps screen
   histories regional. The world hash footprint stays tied to the logical parent
   camera, so peripheral resolution does not coarsen the shared lighting cache.
   `build_light_grid` covers the grid's world-space bounding box (up to 16³
   cells); each cell traverses retained light candidates. The same visible world
   can yield similar bounds at both resolutions. Existing zero-emission proposal
   pruning and prepared colors are already implemented.
2. **Regional screen work repeats its pass sequence.** Two depth/color passes,
   two sets of screen-probe filters, reflection processing and shadow filters
   retain dispatch/draw/dependency overhead even on smaller surfaces. Scene lists
   and AS preparation are shared; the parent-visible geometry is still submitted
   to both regional raster passes. Do not claim two full scene traversals or two
   complete world-GI renders.
3. **Resource access declarations overstate writes.** Shared cache/light/work
   buffers are broadly declared writable in `amd_gi.glsl`. Saved offline SPIR-V
   for FILTER_X/FILTER_Y retains cache bindings 17/18/35, light-grid binding 44
   and batch-work binding 69 without `NonWritable`, despite no direct loads or
   access chains to those variables in these variants. Their input source hashes
   still match the checkout. `RenderingShaderContainer::reflect_spirv` enumerates
   descriptors and derives writability from decorations; RD maps these to
   `RESOURCE_USAGE_STORAGE_BUFFER_READ_WRITE`. This makes otherwise independent
   consumers appear to modify shared resources. It is a concrete dependency
   optimization candidate, not proof of its individual GPU duration. Offline
   material stubs are not a capture of the live renderer's complete graph.
4. **Presentation still runs at full output resolution.** Composition reconstructs
   the two HDR surfaces; blur evaluates an aperture polygon and uses 96 bilinear
   color taps per blurred output pixel, even for a roughly two-pixel radius.
   It then copies the full result into the parent target. Tone mapping/display
   stay full size too. The blur alone can issue tens of millions of texture
   samples at 720p. The measured ~0.4ms interval includes composition/copy, not
   just the blur kernel. Both fair comparison cases pay this cost: it explains
   absolute scope overhead, not the entire native-blur versus regional gap.

## Recommended order

### 1. Correct GI resource access and regional dependency scheduling

Make resource declarations pass-specific: omit unused bindings where practical,
and declare actual readers read-only. Audit cache-key aging/atomics, reservoir
reset, queue counters and feedback before changing any declaration. Retain true
producer-to-consumer barriers. Only then consider interleaving independent work
from both regions; never simply remove all `compute_list_add_barrier` calls.
Pass-specific declarations also need matching function guards: a parsed writer
function cannot legally assign through a read-only buffer even when uncalled.
That API ends/restarts a list and restores bindings; dependencies are tracked by
the render graph, not merely the apparent GLSL ordering.

**Value:** targets the dominant GI interval and repetition introduced by regional
rendering; can also help native rendering and CPU submission. Intended output is
identical, with no ray-budget/history/AMD-estimator change. High confidence in the
source issue, medium confidence in material GPU benefit until timed. Reflection
metadata checks can precede runtime validation; synchronization errors require
real motion/material/lifecycle tests before accepting a fix.

### 2. Replace the brute-force blur workload; remove the final copy

Use reduced-resolution or multiscale blur for broad radii, retaining full-resolution
depth/aperture control and a suitable near-field path. Preserve the accepted
depth curve and maximum radius; sampling the sharp image inside the aperture
must stay exact. Write the final blur into the parent target when its usage and
lifetime allow, rather than copying another full-size intermediate. A native
1:1 composition fetch is another small exact-output opportunity.

**Value:** this is a measured, substantial presentation budget with clear excess
sampling. High confidence that work can be reduced; medium confidence in matching
the accepted blur appearance without image validation. A multiscale filter can
change bokeh/edge leakage and must not bleed blur into the opening. Optimizing it
benefits the native-blur control too, so it cannot by itself establish a regional
rendering advantage. The entire ~0.4ms interval is an upper bound, not recoverable
savings. The copy removal alone is a smaller opportunity.

### 3. Reduce native guard/overlap work where dependencies permit

Preserve full scope coverage. Separate the extent each effect actually needs
from the maximum extent currently used by all effects. Trace finite filter
footprints, alignment and motion requirements before introducing smaller work
rectangles/masks; retain preallocated capacity for ADS. A background interior
mask is worthwhile only when its guard/history/probe dependencies are satisfied.

**Value:** strongest direct way to improve the actual 59.83% pixel ratio, but
moderate confidence and more complexity than the first two changes. The 64-pixel
GI guard has real consumers; reducing it arbitrarily risks scope-edge lighting,
reflection seams and temporal instability. Hidden-overlap removal alone has a
small ceiling. Do not rewrite the renderer into a packed atlas on this evidence.

### Conditional follow-up: demand-driven light-grid cells

If later subpass measurements place substantial time in grid construction,
consider building only cells that this frame's shading can request, retaining
original cell IDs, random streams, bounds and candidate order. All jittered
neighbors, primary/secondary hits and fallback consumers must be included. This
could preserve results while avoiding unused spatial cells, but adds mask/list
work and may do little in a dense scene. No active-cell ratio or individual grid
cost was captured in the B3 profile, so this is not yet an implementation priority.

## Rejected explanations and shortcuts

- The four-million-entry reservoir reset/scan is **disabled in this configuration**.
  `light_resampling` defaults false; the project and benchmark do not enable it,
  and dispatch skips these passes. Its scan is less work-efficient than the pinned
  AMD/GFX reference, but optimizing it cannot explain/fix this benchmark. An early
  investigation lead was withdrawn after checking the active settings.
- Prepared native ray capacity is not a full-native ray dispatch every frame.
  Active work uses compacted indirect counts. Cache update/mip passes use active
  tile lists; purge uses occupied tiles. Large allocated buffers do not prove
  that the entire allocation is scanned or shaded.
- Reducing cache quality, rays, denoising or bounce frequency is a quality tradeoff,
  not a correction for integration overhead. Coarsening the shared world cache
  independently per region also changes cache identity and risks seams.
- Moving all denoising after composition would increase its pixel extent and
  disrupt regional histories. It is not automatically a cheaper schedule.

## Source anchors

- `servers/rendering/renderer_rd/hybrid_pip_layout.h`: `create_fixed`.
- `servers/rendering/renderer_rd/environment/amd_gi.cpp`: `get_region_guard_pixels`,
  `prepare_render_context`, `dispatch_render_passes`, `configure_batch_contexts`,
  `render_regions`.
- `servers/rendering/renderer_rd/shaders/effects/amd_gi.glsl`: storage declarations,
  `world_angular_footprint`, cache dispatch lists.
- `servers/rendering/renderer_rd/shaders/effects/amd_gi_lights_inc.glsl`:
  `light_grid_configuration`, `prepare_light`, `build_light_grid`.
- `servers/rendering/renderer_rd/shaders/effects/hybrid_pip.glsl`: both modes.
- `servers/rendering/rendering_shader_container.cpp`: `reflect_spirv`;
  `servers/rendering/rendering_device.cpp`: `uniform_set_create`,
  `compute_list_add_barrier`; `rendering_device_graph.cpp`: resource dependencies.
- `core/config/project_settings.cpp`: AMD GI defaults. Read-only game checks:
  `project.godot`, `features/debug/gi_tuning.gd`; external B3 harness settings.
- Local AMD reference commit `914b91596cd119eda85fbc1d3c7ee6ac391b1452`:
  `gi1.cpp` reservoir maintenance and `third_party/gfx/gfx.cpp` scan kernels.
