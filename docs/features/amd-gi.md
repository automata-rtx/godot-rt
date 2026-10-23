# AMD GI implementation

This is an experimental Vulkan Forward+ implementation of AMD GI-1.x, adapted from
Capsaicin v1.3 at `914b91596cd119eda85fbc1d3c7ee6ac391b1452`. The scoped pipeline is
implemented; target-hardware qualification and shipping presets are unverified.
It uses sparse directional screen probes,
a world-space radiance cache, multibounce cache feedback, reconstruction, and
temporal/spatial GI denoising, sky lighting, and a separate glossy-reflection path. It does not render a high-sample path-traced image
as a substitute for those stages.

The [gameplay audit](../AMD_GI_GAMEPLAY_AUDIT.md) records failures in `3038a14`.
The current implementation adds stable light-ID remapping, native previous-surface
reprojection, GPU material expansion/residency, adaptive atlas budgeting, explicit
emitter sampling, reflection outlier cleanup, and compacted glossy-ray dispatch.
Software-Vulkan regressions cover these stages, with game-scene checks for the
reported collection/history failures. Historical checkpoint stills do not establish
current quality or target-hardware stability.

## Enable and configure

RT shadow support must already be enabled at engine startup, so shared mesh buffers
have acceleration-structure usage. Use Vulkan Forward+, a WorldEnvironment, and no
MSAA. All controls below are live `ProjectSettings` values under
`rendering/global_illumination/amd_gi/`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Creates the GI scene consumer and cached pipeline only when requested. |
| `probe_spacing` | `16` | Budget one 64-ray probe update per 8×8, 16×16, or 32×32 screen tile: approximately 1, 1/4, or 1/16 primary GI ray per internal pixel per frame. Stored probes always use an 8-pixel grid. |
| `cache_all_hits` | `true` | Shade and accumulate every registered cache hit. Disabling keeps one selected hit per cell and releases hit lists/sample records. Primary ray count is unchanged; visibility, continuation, shading and memory costs can decrease. |
| `screen_feedback` | `true` | Reuse previous native opaque lighting for compatible visible secondary/reflection hits. Adds one RGBA16F target and opaque attachment; disabling releases it. Requires multibounce or reflections. Per-light indirect-energy multipliers other than 1 select the explicit world-cache fallback. |
| `multibounce` | `true` | Populate secondary world cells from a subset of primary cache updates, shade their direct light, and propagate indirect light through separate histories. Disabling skips seven stages and frees continuation/indirect storage. |
| `continuation_probability` | `0.3` | Probability of an additional continuation per registered primary hit (per selected cell hit with all-hit updates off); contributions are probability compensated. |
| `minimum_cell_size` | `0.1` | Minimum world-space cache cell size. Actual size also depends on distance, resolution, and field of view. |
| `denoiser` | `true` | Temporal reprojection and adaptive spatial GI denoising. Probe reconstruction/filtering remains part of the GI algorithm. Progress captures leave this enabled. |
| `importance_sampling` | `true` | Guide diffuse probe rays using reprojected radiance times the surface cosine. Keeps the same primary ray count; disabling uses stratified angular samples. Switching resets history. |
| `brdf_sampling` | `true` | Guide probe angular samples with native metalness/roughness and reprojected radiance, using diffuse cosine and GGX specular weights. Requires importance sampling; no extra primary rays. |
| `adaptive_sampling` | `true` | Redirect existing updates from reusable probes or empty sky slots to uncovered screen tiles. Does not add rays. Switching resets history. |
| `probe_cache` | `true` | Retain up to 4,096 displaced probes with least-recently-used eviction. Turning this off releases the pool and skips its binning, ordering, and store stages; histories reset. |
| `light_resampling` | `true` | Select a light using eight spatial-hierarchy RIS candidates and compatible previous world-cell reservoirs, then trace its current visibility. While enabled, reserves 8 MiB for double-buffered proposals plus a bounded light tree (up to 96 KiB). Disabling releases proposals/tree nodes and evaluates every light; the shared 4 KiB identity-remap prefix remains while GI is active. Zero/one-light scenes bypass resampling automatically. |
| `reflections/enabled` | `true` | Enable the separate glossy path. Turning it off skips all glossy stages and releases reflection-sized resources. |
| `reflections/half_resolution` | `true` | One glossy sample per 2×2 internal pixels, with rotating sample locations; disabling uses full internal resolution. Independent of diffuse probe spacing. |
| `reflections/probe_roughness_threshold` | `0.6` | Reuse directional probe radiance above this roughness where compatible probes exist. Lower thresholds reduce tracing but lose reflected detail. Uncovered pixels still trace. |
| `reflections/firefly_filter` | `true` | Separate geometry-aware outlier marking and cleanup before ratio reconstruction. Runs only with reflections and the denoiser enabled. |
| `reflections/ray_compaction` | `true` | Classify sky/probe-reused pixels, compact the remaining glossy samples on GPU, and dispatch tracing indirectly. Changes scheduling, not sample count or the estimator. |
| `emissive_sampling` | `true` | Build/reuse a GPU triangle-emitter hierarchy and sample it explicitly at screen probes and world receivers. Adds visibility rays; avoids waiting for diffuse rays to hit thin bright geometry. |
| `reflections/filter_passes` | `3` | One to three variance-guided a-trous iterations. Lower values reduce filtering work and may retain noise. |
| `material_atlas_mb` | `128` | Live atlas limit in MiB (8–512). Allocates layers on demand and shrinks when lowered. Excludes capture targets, expanded geometry, BLASes, and GI histories. Preflight adapts capture resolution when allowed; remaining overflow reports a warning before preparing pages. |
| `material_preparation_budget` | `64` | Maximum new 1024-triangle capture chunks per scene update (1–4096). Retains completed chunks and starts GI once the whole collected scene is ready. Bounds preparation count, not time; existing dynamic material redraws are separate. |
| `material_tile_size` | `8` | Maximum material-capture texels per triangle side: 8 or 4. Using 4 quarters atlas/capture-target texel storage at the cost of texture, cutout and interpolated-normal detail. Geometry and primary ray budgets stay unchanged. Live changes recapture materials and reset GI history. |
| `material_adaptive_resolution` | `true` | Automatically reduce material captures to 4 or 2 pixels per triangle side to stay within the atlas limit. Compact captures preserve geometry and native materials but lose within-triangle texture/alpha/normal detail. Disable for strict fixed-resolution comparisons. |
| `max_distance` | `50` | Camera-centered collection bounds and maximum tracing distance. |

```gdscript
ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
```

Primary probe rays are not the total ray count: cache updates also issue visibility
rays for lights, and multibounce adds continuation rays and sometimes another light
visibility query. Explicit emitter sampling adds up to one visibility ray per probe primary sample and one per shaded world receiver (zero when no eligible emitter contributes). Glossy primary, visibility, and fallback continuation rays are also additional. Partial screen tiles are rounded up. The controls are experimental
quality knobs, not measured 780M presets.

Native SDFGI, VoxelGI, SSIL, and lightmaps must be absent when using this path. Native
settings are preserved; conflicts suppress RT GI rather than silently combining
backends. AMD GI takes precedence over the separate `rt_validation/enabled`
diagnostic setting if both are requested. The existing default `GI_MODE_STATIC` and `GI_MODE_DYNAMIC` both participate automatically and support movement. Explicit `GI_MODE_DISABLED` excludes an object from transport while keeping visible surfaces as screen-space receivers; this honors the game's existing grass/outline/tracer settings. No bake, authored probes, or special UV layout is required.

## Implemented pipeline

`RaytracingGIScene` owns the shared hit-material/light adapter, material atlases,
and GI TLAS. It shares BLASes with RT shadows through `RaytracingGeometry`.
`RTGIValidation` now contains only the separate diagnostic renderer.

`AMDGI` owns lazily compiled compute pipelines. Each viewport owns its caches,
probe and pixel histories, and intermediate textures through render-buffer custom
data. Forty-two specialized stages use explicitly ordered dispatches; the probe-mask
stage dispatches once per mip level:

1. Age/clear world-cache tiles and reset update ownership.
2. Reproject an 8-pixel stored probe grid using all 64 candidate screen positions
   per tile. Retain compatible histories independently of the tracing budget.
   Select sparse updates using a repeating Halton sequence, then match uncovered
   tiles to reusable update slots. Matching is one-to-one, with no duplicate
   destinations or extra rays. Bin cached world-space probes into the current
   screen grid. Reproject hits from a compatible 3×3 current reprojected-probe neighborhood
   plus the closest compatible displaced probe into the selected probes. Build a
   64-cell cumulative distribution from radiance times the surface
   cosine. Trace 64 guided, jittered equal-area hemi-octahedral samples per probe,
   reading native materials at triangle hits. Cells without reusable history and
   completely dark distributions fall back to stratified samples.
3. Allocate directional world-space tiles in a bounded spatial hash. Keep complete
   keys and four candidate slots per bucket; a hash collision cannot silently
   identify unrelated geometry. Publication and subsequent lookup are separate passes.
4. Register every primary hit in a bounded per-cell list. By default, shade each
   hit independently and accumulate its contribution/evidence in the cache. With
   multibounce on, each registered primary hit can schedule one continuation,
   according to `continuation_probability`. `cache_all_hits=false` retains one
   selected update/continuation candidate per touched cell as a lower-cost option. Allocate/register the secondary hits
   as additional world-cache receivers. Primary owners win when both reach a cell.
5. Shade direct light for the primary and newly populated secondary receivers.
   Separate direct and indirect histories prevent feedback races. Store
   reflected radiance only: emission is added at the exact ray hit so the spatial
   cache does not enlarge emitters. Rays shorter than a world-cache cell bypass
   filtered readback, including continuation rays, to reduce leaks at thin walls.
   With light resampling enabled, eight spatial-hierarchy light proposals form a fresh RIS
   reservoir. Merge up to four distinct normal-compatible previous world cells,
   re-evaluating their targets at this hit and clamping each previous confidence
   to 20. Trace only the chosen light's visibility; never reuse visibility from
   another surface. Reservoir reads/writes are double-buffered and have one writer
   per base cache cell; the remaining hits reuse proposals without writing them. Uncached continuation shading uses the same estimator.
6. Build the three coarser levels of each 8×8 cache tile. Preserve summed sample
   counts and select the finest mip with 16 accumulated samples, falling back to
   the coarsest level while evidence is sparse, as in AMD's filtered readback.
   Then reuse compatible previous native screen lighting at a secondary receiver,
   or current secondary direct light plus previous secondary indirect cache data
   when it is unavailable. Propagate that outgoing radiance into the primary
   receiver's indirect history, with probability compensation.
   Discarded continuations contribute zero; actual misses sample the configured sky. Build independent indirect mips
   before resolving the sum. Secondary-only receivers have no newly traced indirect
   sample and clear stale indirect history; further bounce feedback therefore
   depends on receivers also populated by primary probes over time.
7. Resolve probe radiance and average samples landing in each angular cell. Apply
   AMD's empty-cell radiance backup and shadow-preserving temporal hysteresis,
   followed by horizontal/vertical filters with plane and hit-direction rejection.
8. Project radiance into nine spherical-harmonic coefficients and build a complete
   hierarchy of valid-probe masks. Reconstruct incoming diffuse lighting from four
   neighboring probes using AMD's depth/normal weights and plane-constrained lookup
   blue-noise jitter. The two spatial dimensions are precomputed from Capsaicin's
   Sobol/ranking/scrambling tables; the shader retains its golden-ratio temporal
   rotation. This adds a shared 32 KiB buffer only while AMD GI is active.
   Relaxed interpolation fills otherwise uncovered pixels, with a low-confidence
   hint that prevents those fallback estimates from growing temporal history.
   Cache displaced surface probes, update reused entries, and reorder the bounded
   pool so unused entries are evicted first. A stable GPU prefix scan preserves
   frame-granularity least-recently-used order without CPU readback or sorting.
9. Reproject GI history with position/normal rejection, neighborhood clamping,
   and a lighting-change response. Apply adaptive horizontal/vertical spatial
   filtering, then composite before fog, tone mapping, DLSS, or FSR.
10. Trace GGX visible-normal glossy samples, or integrate the 64 directional probe
    bins for sufficiently rough surfaces. Resolve incoming hit radiance from the
    current world cache, with uncached hit shading as fallback and sky on misses.
    Reconstruct neighboring glossy samples with a BRDF/PDF ratio estimator.
    Reproject smooth finite-hit reflections through their virtual image points and
    rough reflections through their receiver positions. Reject incompatible geometry,
    clamp history, and run variance-guided a-trous filters before geometry-aware
    upsampling. Native Forward+ applies the receiving material's Fresnel and DFG;
    reflections enter its existing binding 35 before fog and temporal upscaling.

Sky misses sample the existing unfiltered native octahedral radiance view, including
orientation, borders, and Forward+'s exposure normalization. No additional sky bake
is created. Static sky material updates invalidate GI histories through the sky radiance
version. TIME/position/light-driven skies update their lighting without resetting
history on every redraw. Gradual light motion, intensity, color and sky orientation
changes also retain history; large discontinuities and light-list/mask changes reset it. When sky ambient
is enabled, GI replaces that unoccluded ambient term and preserves the environment's
remaining color-ambient mixture. Reflection sky selection follows the environment's
reflection source independently.

The hash has 1,024 buckets, four tiles per bucket, and 85 cells per tile including
mips. Base-cell history is limited to 16 updates, tile lifetime to 50 unused frames,
and final GI history to at most 64 samples with adaptive reduction. These are live
temporal histories, not unlimited accumulation for screenshots. Histories reset on
allocation, resize, quality changes, large camera cuts and discontinuous lighting
changes. Geometry additions/removals, topology/material edits and object motion invalidate local regions and cached ray connections;
unchanged regions retain history. Smooth lighting changes retain history; small camera motion reprojects existing histories. Material colors refresh
through new cache samples and the lighting-change response.
GI collection is sorted by stable instance and light IDs before building the
signature and material layout; spatial-tree traversal permutations must not
invalidate history. The focused cache harness verifies this explicitly.

Disabling destroys the GI scene consumer and its shader pipelines, releases GI-only
BLASes, and clears rendered viewports' GI custom data and texture scopes. Shared
shadow geometry survives. A never-enabled viewport allocates none of these resources.
Native material-bake buffer pools can remain warm after use; deferred destruction
follows RenderingDevice's usual lifetime rules. Exact image restoration is not a
hardware timing measurement.

## Supported scope and port differences

The implementation follows AMD's two-level caching architecture, with these
Godot integration choices and limits:

- Reprojection retains the visible 8-pixel grid, and guiding gathers a 3×3
  current reprojected neighborhood plus the nearest compatible displaced-cache entry.
  Preparation finishes before any tracing workgroup publishes its new probe seed. The bounded
  pool keeps 4,096 entries and expires radiance after 50 frames without a trace
  refresh. Fine surfaces sharing a screen tile still compete for its stored probe.
  Native metalness/roughness now guide the diffuse/specular angular mixture; the probe still stores incoming radiance independently of the receiving material. The cache
  also retains the previous tile's surface when disocclusion prevents reprojection.
- Cache updates now accumulate all registered primary/secondary hits by default.
  The one-hit-per-cell option remains available for performance. Light reservoirs reuse the existing directional world-cell grid; Capsaicin uses a
  separate hash of multiple hit reservoirs and its light-sampling hierarchy. This
  port uses a balanced spatial hierarchy for its bounded point/spot/sun list.
  Bounds and power guide eight fresh candidates; each RIS weight divides by the
  actual tree-walk probability. A uniform component retains support for unusual
  falloff and spot distributions. This is an adaptation of spatial light selection,
  not Capsaicin's light-grid implementation.
  Continuations now populate additional cells with separate direct/indirect
  filtering. Independent hit shading and per-cell reduction are ordered stages, so
  shared cells accumulate samples without float atomics or concurrent radiance reads. Visible receivers can reuse reprojected combined native screen lighting;
  other receivers use the previous world indirect cache. Coarse cache reuse can
  flatten indirect gradients.
- Glossy transport, ratio reconstruction, temporal rejection, and a-trous denoising
  are implemented. The matte room alone cannot validate them; use the dedicated
  mirror/glossy-floor rig. This is an adaptation, not an exact port of all Capsaicin
  reflection heuristics. Native primary materials retain their BRDF; secondary
  shading uses GI-1's rough diffuse approximation, including metallic hit base color.
  This avoids black metallic receivers without adding nested specular rays; it is
  not layered/anisotropic or general nested specular transport. Reflection-only
  hits read the world cache; upstream Capsaicin also performs cache lookup here
  rather than inserting those hits. Our uncached fallback evaluates hit lighting. Off-screen hit shading
  evaluates approximate diffuse/emissive outgoing radiance. Compatible screen hits can reuse
  visible native specular lighting, but this is view-dependent feedback rather
  than general nested specular transport.
  Half-resolution mirrors can show reconstruction artifacts.
- Expanded capture geometry and targets persist across frames with source-data
  invalidation. Static local-uniform/image-texture materials retain their pixels;
  content/transform changes redraw only dirty pages. TIME, global/instance uniforms
  and GPU-written textures refresh each frame. New preparation is bounded by a live
  chunk budget and resumes from retained pages. Triangle material tiles have an
  8-pixel default maximum, with automatic 4/2-pixel capacity adaptation; this remains
  a material-detail tradeoff.
- Scene/material support still has the limits in
  [rtgi-validation.md](rtgi-validation.md#scope-and-limitations):
  MeshInstance3D geometry including native skeletons/blend shapes, bounded material
  pages/lights, ideal point/spot/sun lights, CPU-managed 3D MultiMesh elements, no particle or GPU-indirect MultiMesh geometry or
  custom vertex-deforming/screen-reading materials.
  Unsupported scenes suppress the contribution rather than silently omit objects.
- Reprojection uses native previous-surface positions from the GI depth prepass, including previous native poses. Cached connections crossing moving geometry reject history locally. Controlled rotation/deformation, gold-weapon motion and first-person intersection sequences have software-Vulkan coverage; this is not an exhaustive gameplay guarantee. FSR2 has
  software-Vulkan coverage; DLSS runtime compatibility remains untested.

AMD's shader copyright/license is retained in `amd_gi.glsl` and `COPYRIGHT.txt`.
Equal-area hemisphere mapping, SH projection/convolution, cache layout, probe
sampling/blending/filtering, and adaptive GI denoising follow the cited reference with Godot-specific
resource, material, and visibility integration. See
[AMD_GI_IMPLEMENTATION.md](../AMD_GI_IMPLEMENTATION.md) for the larger work plan.

Angular sample accumulation uses bounded workgroup-local integer linked lists and
floating-point sums. This replaces upstream fixed-point atomic radiance sums, so
HDR inputs do not overflow those sums and no optional floating-point atomics are
required. Every lane inserts at most one sample per neighbor; a barrier separates publication
from reads and another separates reads from shared-memory reuse. The existing
scratch buffer holds reprojected angular history until resolve finishes; guiding
adds no persistent GPU allocation or dispatch. Dense stored histories, scheduling
queues, and the valid-probe mask hierarchy are allocated only while GI is active.
Mask dimensions round up at each level to retain odd-sized edge tiles. Sampling adds
work, so an unchanged ray budget does not establish unchanged GPU cost.

The displaced pool uses 1,216 bytes per entry (192-byte probe metadata/SH plus
64 radiance cells), separate ownership/list state, and double-buffered order
indices. Cache reads precede all writes. Reuse reserves one writer per entry;
eviction requests are deduplicated by previous-probe index. The scan allocates
only untouched slots and moves newly stored entries to the recent end. An
out-of-screen cached probe stays resident until expiry or eviction.

## Progress captures

From `docs/validation/shadow_validation`:

```sh
./run.sh amd_gi
```

This runs the real sparse pipeline at 16-pixel and 8-pixel probe spacing, with
multibounce, probe filtering, and GI denoising enabled. Startup and approximately
32/64-frame captures make settling visible. The two extra draw frames used by the
capture helper are part of those approximate labels. No high-sample reference pass
is enabled. Controls cover indirect-energy zero, a changed non-shadow-casting wall,
camera cuts, small camera motion, resize, and disabling/restoring the baseline. `score_amd_gi.py` checks those
lighting/restoration controls; software Vulkan timings are not GPU benchmarks.

Progress images must state their primary ray budget and enabled filtering. A raw
diagnostic image is useful only when explicitly labeled. Historical 128/512-sample
transport images are debugging references and must not represent shipping quality
or this pipeline's progress.

`./run.sh amd_gi_sampling` holds the camera, 16-pixel spacing, multibounce, and
denoiser fixed during the importance-sampling off/on/off comparisons. It also
tests an all-black history, discovers an emissive ceiling enabled by a material
uniform change, and measures residual indirect light after removing that emission.
It also toggles adaptive placement and the displaced-probe cache, and exercises
the 1/16 primary-ray schedule. A separate camera sweep and return exercises
displaced-probe reuse. Static stages get 64 settling frames plus capture synchronization. The box-front
measurement excludes the visible emitter. Sampling toggles must preserve GPU
allocation counts; disabling must restore the exact image and texture allocation.
This is an integration/response check, not an accuracy ranking between samplers.

Both that rig and `./run.sh amd_gi_cache` enable `GODOT_AMD_GI_VALIDATE_CACHE=1`.
The focused cache rig sweeps the camera out and back within the cache's expiry
window, then renders another 64 frames. It requires history to survive small
camera motion, and checks the disabled image exactly. This diagnostic reads
the actual GPU queues, spawn assignments, ownership, and LRU order every frame.
It rejects duplicate/out-of-range assignments and invalid permutations, verifies
the update budget, and requires both eviction and reuse to be exercised. It
synchronizes the GPU and must not be enabled for timing or shipping presets.

`./run.sh amd_gi_lights` compares exhaustive and resampled light evaluation at
the same primary-ray budget. `GODOT_AMD_GI_VALIDATE_RESERVOIRS=1` synchronously
checks actual GPU light indices, finite weights and confidence in [1, 81]. The
identical-light and varied-light stages retain multibounce and denoising. This is
an integration/normalization check; exhaustive light evaluation does not turn the
sparse GI pipeline into a perfect-reference renderer.


## Native comparisons

`./run.sh gi_compare` compares this pipeline at 16- and 8-pixel probe spacing
against native VoxelGI and SDFGI in the same inherited room. Multibounce, probe
filters, and GI denoising remain enabled; AMD captures follow 64 settling frames.
No uncached reference tracing is enabled.

All methods use the same 641x359 camera, materials, direct point light, hard RT
shadows, and AgX exposure. AO, sky light, and antialiasing/upscaling are absent.
The meshes are marked static only to make them eligible for native GI; the light
uses `BAKE_DYNAMIC`. No separate energy or exposure matching is applied.

| Capture | Configuration |
| --- | --- |
| `gi_disabled` | Direct lighting and RT shadows. |
| `amd_quarter`, `amd_one` | Approximately 1/4 or 1 primary probe ray per internal pixel per frame, continuation probability 0.3, denoiser on, distance limit 20. |
| `voxel_128`, `voxel_256` | Baked volume centered at `(0, 1.5, 0)`, size `(6, 4, 6)`, high cone-tracing quality, 128/256 subdivisions, interior mode, two bounces, energy 1, propagation 0.5, bias 1.5, normal bias 0. |
| `voxel_256_normal_bias` | Same 256-subdivision bake, bias 0, normal bias 1.5. |
| `sdfgi_default` | Four cascades, minimum cell size 0.2, 75% Y scale, occlusion off, sky reading off. |
| `sdfgi_fine_occlusion` | Minimum cell size 0.1, occlusion on; otherwise unchanged. |

Native methods use full-resolution composition. SDFGI uses 16 rays per probe,
30-frame convergence, light updates every frame, energy 1, feedback 0.5, and
normal/probe biases 1.1. The camera sits outside the room: minimum cell size is
not the resolution throughout the room. Each native configuration gets 120
settling frames, an early capture, 60 additional frames, and a final capture.
The scorer reports the remaining difference and requires exact disabled
restoration after each backend. These different transport models are not equal
GPU-cost configurations or ground-truth accuracy rankings.

## Sky and reflection checks

`./run.sh amd_gi_sky` checks sky illumination, occlusion against native unoccluded
ambient, live color/removal/rotation changes, and exact disabled restoration.
`./run.sh amd_gi_reflections` keeps diffuse at 1/4 primary ray/pixel and denoising on,
compares half/full glossy resolution, removes an emissive object behind the camera,
exercises camera motion, and checks reflection-buffer release. Its opt-in
`GODOT_AMD_GI_VALIDATE_REFLECTIONS=1` reads actual GPU sample records for finite
values and reports traced versus probe-reused samples. Diagnostic readback is not
part of ordinary rendering or a performance preset.

`./run.sh amd_gi_dirty_materials` checks retained material pixels against texture
updates in place, emission parameters, shader changes, TIME, and global uniforms.
Unchanged static pages must stop drawing, while only the dynamic page refreshes.
`./run.sh amd_gi_fsr2` exercises the jittered 320×179 internal image in a 641×359
FSR2 Performance viewport with diffuse, reflections, multibounce and denoising on.
DLSS and target-device timings still require the Windows/NVIDIA and 780M machines.

`./run.sh amd_gi_dynamic_lighting` animates a TIME-driven sky, sky rotation,
a directional sun and a local light. It requires exactly one initialization reset
through the continuous segment and one reset for abrupt light/sky removal. This lighting test does not certify moving meshes; deformation and scene-churn
rigs separately check local invalidation.

With the default 8-pixel material tiles, captures occupy 32-triangle rows across
dynamically allocated 256×256 atlas layers. A layer stores 1,024 triangle tiles and
costs 1.25 MiB across four channels. The 4-pixel option uses one quarter of those
texels per layer. `material_atlas_mb` bounds this atlas; native capture targets and expanded
source geometry are additional. The default permits 102 layers, allocated only as
needed. Layers and scene buffers grow geometrically, retaining pixels during growth;
lowering the live budget shrinks the atlas. The collection safety caps are 65,536
surface instances and 1,024 lights, with buffers allocated for the actual count.
These are safety limits, not recommended scene budgets or hardware measurements.

Compatible instances share material captures by mesh, surface, material, and pose.
Transform-independent captures store local normals, transformed by the ray hit's
inverse-transpose matrix. World/instance-dependent shaders, normal-map/tangent
inputs, and instance uniforms conservatively retain per-instance evaluation.
Repeated static props therefore share both geometry and material captures.
`amd_gi_material_sharing` checks repeated geometry and transform-only reuse;
`amd_gi_atlas` checks relocation, growth beyond the old 32-layer limit, and live
budget shrinkage.

CPU-managed 3D MultiMeshes collect each visible element within the GI volume.
The native capture preserves element colors, custom data, and `INSTANCE_ID`, and
tracks the element separately for material invalidation and motion. The
`amd_gi_multimesh` rig compares them against independently shaded MeshInstances,
then exercises movement and live color/custom updates. GPU-indirect MultiMeshes
and particles remain unsupported.

### Native deformation and local motion

`./run.sh amd_gi_deformation` compares four/eight-weight skeletons combined with a
blend shape against independently baked static meshes. It checks GI transport,
retained material preparation, FSR2 buffer swapping, and disabled restoration.
`GODOT_AMD_GI_VALIDATE_CACHE=1` additionally checks that each enable initializes
history once while subsequent animation reports local swept regions.

Up to eight dirty world bounds are supplied per frame; overflow merges into the
region requiring the least extra bounding volume, preserving coverage. World-cache lighting remains resident; receiver updates touching dirty bounds use reduced temporal weight. Coverage counts remain intact so a small moving object cannot empty a whole tile or force its neighbors onto a coarser spatial mip.
Stored screen-ray connections crossing them are rejected, displaced cached probes
with affected connections are retired, and newly evicted probes cannot restore
stale connections. Diffuse receivers and glossy connections reject affected pixel
history. This is conservative invalidation, not motion-vector transport: moving
surfaces must accumulate new samples. Shadow changes beyond those bounds converge
through fresh light visibility and the existing temporal response.

### Matched primary-ray comparison

`./run.sh amd_gi_budget_compare` starts both budgets from released resources and
uses the same 62 settle draws plus two capture draws. Cache diagnostics verify the
actual uninterrupted history lengths are equal. Denoising, multibounce, importance
sampling, adaptive updates, displaced-probe reuse, light resampling and reflection
settings remain identical. Primary diffuse budgets are approximately 1/4 and 1 ray
per internal pixel per frame; visibility, continuation and glossy rays are additional.
The existing matte room primarily demonstrates diffuse reconstruction, not sky or
specular fidelity. A checkpoint comparison does not mean the backend is complete.

## NRD evaluation later

NRD is not integrated. Its Vulkan compute pipelines can be driven through Godot's
RenderingDevice without replacing the scene or ray-tracing system. An integration
must supply demodulated diffuse/specular signals, suitable per-lobe ray-hit
distances, view depth, normal/roughness, motion vectors, camera/jitter and history
reset data. Sparse probes require a deliberate reconstruction/confidence adapter;
feeding them directly as per-pixel ray samples would violate that contract.
Glossy denoising is a useful first isolated comparison against the current filter.
NRD cannot correct cache bias, missing transport, or undersampled hit materials.
See [NRD's current input requirements](https://github.com/NVIDIA-RTX/NRD#inputs).
No quality/performance advantage has been measured in this fork.

## Testing on the target machines

Use an editor built from the experimental `feature/amd-gi` branch. Existing fork
builds from before that branch do not contain these controls. The Windows CI
artifacts are `windows-editor` (MSVC), `windows-editor-clang` (clang-cl) and
`windows-template`; select the matching commit,
and use the release template for export (the fork has no debug export template).
Both editor builds target Windows x86-64; the Clang executable has `.llvm.exe`
in its name. An editor job passing compilation does not by itself mean an artifact
exists: check the run's uploaded artifacts. Keep the existing Streamline runtime
setup when testing DLSS.

Start with GI disabled and reproduce the game baseline. Then enable `amd_gi/enabled`
and leave `probe_spacing=16`, denoising, importance/adaptive sampling and probe cache
on. Reflections have an independent toggle and half-resolution option; compare
diffuse alone before adding their cost. None of these values is a measured 780M
quality preset. Watch renderer warnings: unsupported materials/geometry or capacity
overflow suppress the contribution, so checking only the enabled setting is not
proof that GI is running. Test FSR2 on the laptop and DLSS on the desktop, movement,
lighting changes, scene transitions and disabling/re-enabling as well as a still.
A controlled run of `fps-proto`'s `levels/test_level.tscn` now passes with the native
extension, three NPCs, RT shadows, VBAO and FSR2 Performance. It uses a 641×359
window (320×179 internal), grass and RT soft shadows off, and frozen gameplay for
matched 64-draw quarter/one stills. Its material atlas grows to 64 layers for 34,464
triangle tiles. This is software-Vulkan integration evidence, not full gameplay,
all-map or target-hardware validation. Keep custom grass off: its opaque custom
vertex deformation remains unsupported by GI.

### Forward-only transparency

Transparent passes that neither write depth nor cast material shadows stay in the
native raster path. This includes outline shells, stencil-only masks and additive
effects. They do not become opaque GI occluders and do not disable GI for the scene.
Opaque/cutout surfaces retain normal transport. Depth-writing mix-alpha materials
use stochastic opacity: fully opaque texels remain surfaces, zero-alpha texels
transmit, and fractional texels select coverage probabilistically. The same test
applies to GI visibility rays; native RT-shadow behavior is unchanged. This is
straight-through opacity, not refraction or colored transmission. Multipass and
unsupported deformation retain strict checks. Forward-only effects do not emit GI.
`amd_gi_overlays` checks that physical-scene GI and history survive these passes.

### Light proposal hierarchy

When resampling is active, each viewport retains a spatially ordered binary tree
for the scene's analytic lights. Stable scene indices stay in the leaves, so tree
reordering does not invalidate reused light identities. The CPU rebuilds/uploads
only when light records change. Positional power and distance to a node's bounds,
plus directional power, guide traversal; a 10% uniform-count component at each
branch preserves proposal support. RIS uses the complete traversal probability and
re-evaluates the actual material, mask, attenuation and visibility. The hierarchy
is a proposal approximation, not a changed lighting model or an occlusion cache.
Disabling resampling releases the tree with the reservoir buffers. Zero/one-light
scenes bypass it. `amd_gi_lights` compares against exhaustive light evaluation,
including a six-light incomplete tree with point, spot and directional lights.

### Native screen-lighting feedback

Opaque Forward+ draws optionally write their combined HDR lighting to a fourth
color attachment before fog, tone mapping, and temporal upscaling. GI reads that
texture on the following frame, matching the previous pixel geometry and removing
the previous exposure. Background/transparent pixels have no valid coverage.
Swept motion bounds, normal/position disagreement, disocclusion and history resets
reject reuse. Reflections and continuation shading retain world-cache/explicit
fallbacks; the system does not require everything to remain on screen.

The texture exists only while feedback is active. Native feedback shader variants
compile on demand for materials that request them. Disabling GI adds no feedback
attachment, pass, trace or copy; ordinary native pipeline caches may remain warm,
but new or edited materials do not compile feedback variants unless requested.
The `ShaderRD` on-demand group is separate from global group enablement for this
reason. Feedback includes the visible material's native lighting/AO; it is an
approximate view-dependent radiance reuse, not a new exact path-tracing bounce.

`amd_gi_feedback` checks actual GPU acceptance, unfogged/unexposed radiance,
per-light indirect-energy fallback, texture release and exact disabled restoration.
Its synchronous diagnostics are opt-in with `GODOT_AMD_GI_VALIDATE_FEEDBACK` and
must not be enabled when measuring performance. The dedicated counter occupies
previously unused queue-header space; ordinary rendering does not increment it.

### All-hit cache updates

`cache_all_hits` retains bounded lists of registered hits, shades them in parallel,
and reduces their contributions per world cell. Primary hits contribute independent
continuation estimates; secondary-only cells receive direct lighting. History counts
now reflect contributing samples, capped to the existing 16-sample temporal window.
One stable hit still publishes each cell's light reservoir, avoiding write races.

The optional storage is one additional head per world cell plus 48 bytes per primary
hit slot (and per secondary slot when multibounce is on). The lower-cost mode skips
both per-hit shading passes and releases this storage. It preserves the original
one-update-per-cell behavior. Primary diffuse rays are identical between modes;
additional visibility and continuation rays must be included when profiling.
`amd_gi_hit_updates` reads actual GPU lists to verify every registered hit is present
exactly once, all samples are shaded, and toggling releases the extra buffers.

### Dense-scene material memory

Material capture is a separate quality/memory axis from screen-probe ray density.
`material_tile_size=4` uses 128×128 array layers with the same 32×32 triangle layout;
8 uses 256×256 layers. Addressing derives the tile size from the actual texture.
Live changes discard old captures/atlas textures and invalidate GI history while
retaining shared shadow geometry. The default remains 8; quality is not silently
reduced when a scene exceeds its atlas budget. Capacity warnings report tile counts.

Transform-independent captures also share repeated identical instance colors;
the exact color is part of the capture key. Shader instance IDs/custom data,
world/camera dependencies and other context-sensitive inputs retain their existing
separate captures. Tint sharing changes storage, not rendered material values.

Crossroads replaces TestLevel as the project's evaluation scene. Its Main Street
camera currently needs 545,376 material tiles at 50 m trace distance, exceeding the
8-pixel atlas's maximum 512 MiB budget. Four-pixel tiles fit with a 256 MiB budget
(the current growing atlas allocates 268,369,920 bytes). Separate capture targets,
expanded geometry, BLASes and GI histories are additional. This is a measured
correctness-test footprint, not a validated 780M quality/performance preset.

### Scene changes and history diagnostics

Geometry is matched by stable instance RID and MultiMesh element across sorted
collection lists. Entering/leaving the camera-centered collection, visibility
changes and topology/material-content edits invalidate the old/new local bounds.
They do not discard the entire screen history. Light identities are remapped per viewport; membership changes do not clear unrelated history. Lighting changes accelerate cache refresh while retaining coverage counts. Camera cuts, quality changes and environment discontinuities still invalidate history.

`GODOT_AMD_GI_TRACE_HISTORY=1` logs reset reasons and dirty-region counts without
GPU readback; it is opt-in and only runs in the enabled GI path. `amd_gi_scene_churn`
checks collection-boundary crossings, rotation, additions/removals and material
edits. `amd_gi_flashlight` checks continuous spotlight movement, indirect light,
resampling against exhaustive light shading and removal of light after switch-off.
Both use the quarter primary budget with denoising enabled. They do not establish
hardware timing or final gun-mounted flashlight quality in fps-proto.

## Current integration additions (2026-10-23)

The lighting buffers now carry full light-instance identities. Each viewport maps
its previous light indices to current indices before using reservoirs. Removing a
light invalidates its proposals, not all GI histories; changing the light set
accelerates direct/indirect cache refresh without erasing radiance or geometric
coverage. Keeping proposal storage in zero/one-light scenes avoids reallocating
all histories when a flashlight changes a scene from one light to two.

The optional GI depth variant writes native motion vectors and previous world
positions, including previous skin/blend-shape vertices. Its RGBA32F target exists
only while GI is active. Probe, diffuse-pixel, and glossy-surface reprojection use
that previous position. A receiver's own swept bound no longer automatically
rejects its reflection history. Intersecting connections remain conservative.

Emissive surfaces supply actual shared RT vertex/index buffers to a GPU extraction
pass. Native captured emission/opacity establishes triangle power, including every
covered material texel so textured emission retains sampling support. A binary hierarchy combines triangle power and receiver distance bounds. Stratified screen-probe proposals retain the exact tree-walk and area PDFs. Screen probes integrate
`Le/pdf_solid_angle` into equal-area angular cells; this avoids enlarging thin
emitters by treating importance samples as uniform angular samples. World-hit
shading adds explicit emitter irradiance. Supported diffuse hit-emission paths are
partitioned out to avoid double counting; specular primary hits retain emission.
Screen-feedback continuations subtract the already-accounted emission term.
This is explicit area sampling, not a claim of full emitter ReSTIR/MIS parity.

The hierarchy is bounded to 262,144 triangle entries (up to 32 MiB); overflow
surfaces retain ordinary hit-emission sampling. Unchanged batches reuse the GPU
hierarchy; geometry, transform, native material-pixel, and packing changes rebuild
it. No emitter dispatch occurs when there are no eligible emitters. Disabling
`emissive_sampling` releases its large buffer on the next scene update and returns
to ordinary hit sampling. Primary diffuse budgets are unchanged; visibility costs
must be counted separately.

Glossy classification resolves compatible rough probes and skips sky. Remaining
sample IDs go into a bounded appended queue and use an indirect GPU dispatch.
Compaction can be disabled independently for scheduling comparisons. Firefly
marking and cleanup use separate dispatches and immutable source neighborhoods,
followed by the existing ratio reconstruction, temporal history and a-trous
filters. Their thresholds are a Godot adaptation and require visual validation;
a passing history-count check alone does not establish reflection quality.

Atlas placements now remain stable across ordinary appearance/removal and source
resize. Free intervals admit new captures; compaction occurs only if fragmentation
prevents a preflight-proven fit. This removes whole-atlas copy churn as well as
repeated geometry preparation. Emitter storage similarly retains physical capacity
across flicker while its logical tree size follows the current active set; turning
emitter sampling off releases the large allocation.

When no temporal upscaler/compositor needs velocity, the GI prepass uses a velocity
target in its own resource scope. Disabling GI releases it with previous-position
storage. With DLSS/FSR2, the native velocity target is shared and remains owned by
the upscaler. No GI motion pass, capture, queue, denoising or composition runs when
the backend is disabled.
