# AMD GI implementation

This is an experimental Vulkan Forward+ implementation of AMD GI-1.x, adapted from
Capsaicin v1.3 at `914b91596cd119eda85fbc1d3c7ee6ac391b1452`. The main default pipeline and audited corrections are implemented for qualified inputs; full feature parity and hardware/gameplay qualification remain incomplete.
The [full source comparison](../AMD_GI_FULL_COMPARISON.md) is complete; its
[coverage appendix](../AMD_GI_COMPARISON_COVERAGE.md) accounts for every stage
and control. The [live consequential correction record](../AMD_GI_CONSEQUENTIAL_CORRECTIONS.md) tracks every correction, approval, validation result and remaining limitation. The prior
[correction ledger](../AMD_GI_REFERENCE_AUDIT.md) is historical, not a fidelity certificate.
Target-hardware qualification and shipping presets are also unverified.
It uses sparse directional screen probes,
a world-space radiance cache, multibounce cache feedback, reconstruction, and
temporal/spatial GI denoising, sky lighting, and a separate glossy-reflection path. It does not render a high-sample path-traced image
as a substitute for those stages.

The [gameplay audit](../AMD_GI_GAMEPLAY_AUDIT.md) records failures in `3038a14`.
Current corrections remove persistent light-ID remapping and restore AMD light-settings transitions. They add native previous-surface inputs, reference probe filtering/LRU and irradiance units, default near-field SSGI, independent reflection feedback, compact GI work and exact shared triangle-buffer access. Native source shading now replaces coarse material capture; its ordinary and affine emitter-mapping cases have controlled GPU qualification; arbitrary custom mappings remain limited.
Software-Vulkan regressions cover these stages, with game-scene checks for the
reported collection/history failures. Historical checkpoint stills do not establish
current quality or target-hardware stability.

The controls below describe current behavior. Default-path algorithm corrections and approved numerical/native adapter exceptions are recorded in the live correction ledger. Optional quality modes are not claims of AMD baseline equivalence. Approved distance handling restores full participating-scene coverage; the extended sky-removal test passes while reporting its early residual.
Default reflection feedback is now independent of `screen_feedback`; default SSGI
also consumes previous opaque lighting. Comparisons use the default quarter primary
ray budget and keep the denoiser enabled.

## Enable and configure

RT shadow support must already be enabled at engine startup, so shared mesh buffers
have acceleration-structure usage. Use Vulkan Forward+, a WorldEnvironment, and no
MSAA. The current input path requires eight color attachments, eleven storage-image bindings and 16-bit storage support. All controls below are live `ProjectSettings` values under
`rendering/global_illumination/amd_gi/`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Creates the GI scene consumer and cached pipeline only when requested. |
| `probe_spacing` | `16` | Budget one 64-ray probe update per 8×8, 16×16, or 32×32 screen tile: approximately 1, 1/4, or 1/16 primary GI ray per internal pixel per frame. Stored probes always use an 8-pixel grid. |
| `cache_all_hits` | `true` | Shade and accumulate every registered cache hit. Disabling keeps one selected hit per cell and releases hit lists/sample records. Primary ray count is unchanged; visibility, continuation, shading and memory costs can decrease. |
| `screen_feedback` | `false` | Optional diffuse hit feedback; effective only with multibounce disabled and compatible native indirect-light multipliers. Reflection hit feedback and default near-field SSGI remain active independently. Previous opaque lighting is retained for those default consumers while GI is enabled. |
| `multibounce` | `true` | Populate secondary world cells from a subset of primary cache updates, shade their direct light, and propagate indirect light through separate histories. Disabling skips seven stages and frees continuation/indirect storage. |
| `continuation_probability` | `0.3` | Probability of an additional continuation per registered primary hit (per selected cell hit with all-hit updates off); contributions are probability compensated. |
| `minimum_cell_size` | `0.1` | Minimum world-space cache cell size. Actual size also depends on distance, resolution, and field of view. |
| `denoiser` | `true` | Temporal reprojection and adaptive spatial GI denoising. Probe reconstruction/filtering remains part of the GI algorithm. Progress captures leave this enabled. |
| `importance_sampling` | `true` | Guide diffuse probe rays using reprojected radiance times the surface cosine. Keeps the same primary ray count; disabling uses stratified angular samples. Switching resets history. |
| `brdf_sampling` | `true` | Use native albedo, metalness and roughness for AMD’s Fresnel-weighted choice between a bounded-VNDF GGX sample and diffuse radiance guiding. No extra primary rays. |
| `adaptive_sampling` | `true` | Redirect existing updates from reusable probes to uncovered screen tiles. Does not add rays. Switching resets history. |
| `probe_cache` | `true` | Retain one displaced-probe slot per internal 8×8 screen tile, with least-recently-used eviction. Turning this off releases the pool and skips its binning, ordering, and store stages; histories reset. |
| `light_resampling` | `false` | Enable reuse of up to four previous hit reservoirs from AMD’s independent spatial hash. Fresh GridStream RIS remains enabled in both modes. Hash headers use 96 MiB across both frames, plus 64 bytes per hit slot and scan scratch; disabling releases that temporal storage. |
| `cache_bucket_exponent` | `14` | World-cache bucket count is 2 to this power, with 16 tiles per bucket. AMD’s default is 16,384 buckets / 262,144 tiles. Values 8–14 expose the reference capacity tradeoff: fewer buckets reduce memory but increase collision overflow and missing cache coverage. Live changes recreate history. |
| `reflections/enabled` | `true` | Enable the separate glossy path. Turning it off skips all glossy stages and releases reflection-sized resources. |
| `reflections/half_resolution` | `true` | One glossy sample per 2×2 internal pixels, with rotating sample locations; disabling uses full internal resolution. Independent of diffuse probe spacing. |
| `reflections/trace_roughness_threshold` | `0.2` | Trace below this roughness. Between this and the high threshold, use AMD’s stochastic GGX lookup in four screen probes. Missing probe coverage falls back to tracing. |
| `reflections/probe_roughness_threshold` | `0.6` | At or above this threshold, use the diffuse probe irradiance approximation. Missing coverage falls back to tracing. Keep this at least as high as the trace threshold. |
| `reflections/firefly_filter` | `true` | AMD’s rank-based marking and plane-weighted cleanup before reconstruction. Runs only with reflections and the denoiser enabled. |
| `reflections/firefly_low_threshold` / `firefly_high_threshold` | `0.0` / `1.0` | Reference rank thresholds. The reference defaults do not reject ordinary rank outliers; narrower bounds enable more rejection. |
| `reflections/ray_compaction` | `true` | Classify sky/probe-reused pixels, compact the remaining glossy samples on GPU, and dispatch tracing indirectly. Changes scheduling, not sample count or the estimator. |
| `emissive_sampling` | `true` | Include GPU-built triangle emitters in the shared GridStream distribution for world receivers. Primary hits contribute emission directly. Adds selected visibility rays; disabling retains primary hit emission. |
| `reflections/filter_passes` | `4` | Two to eight a-trous passes: first reconstruction, zero or more intermediate passes, then full-resolution reconstruction. Reference default is four. |
| `material_atlas_mb` | `128` | Legacy uncached transport-validator capture control only. AMD GI source shading ignores it. |
| `material_preparation_budget` | `64` | Legacy uncached transport-validator capture control only. AMD GI source shading ignores it. |
| `material_tile_size` | `8` | Legacy uncached transport-validator capture control only. AMD GI source shading ignores it. |
| `material_adaptive_resolution` | `true` | Legacy uncached transport-validator capture control only. AMD GI source shading ignores it. |
| `max_distance` | `1000000000` | Maximum ray distance, matching AMD. The participating scene is collected independently of the camera. Smaller explicit values are nonbaseline quality limits. Screen-probe reprojection stores distances up to 65504; actual hits retain their distances. |

```gdscript
ProjectSettings.set_setting("rendering/global_illumination/amd_gi/enabled", true)
ProjectSettings.set_setting("rendering/global_illumination/amd_gi/probe_spacing", 16)
```

Primary probe rays are not the total ray count: cache updates also issue visibility
rays for lights, and multibounce adds continuation rays and sometimes another light
visibility query. Unified light sampling adds at most one selected visibility ray per shaded world receiver. Glossy primary rays are also additional. Partial screen tiles are rounded up. The controls are experimental
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
data. Specialized stages use explicitly ordered dispatches; the probe-mask
stage dispatches once per mip level:

1. Age/clear world-cache tiles and reset update ownership.
2. Reproject an 8-pixel stored probe grid using all 64 candidate screen positions
   per tile. Retain compatible histories independently of the tracing budget.
   Select sparse updates using a repeating Halton sequence, then match uncovered
   tiles to reusable update slots with the reference random atomic exchange.
   Competing holes can overwrite a slot; sky seeds are culled and no extra rays are added. Bin cached world-space probes into the current
   screen grid. Reproject hits from a compatible 3×3 current reprojected-probe neighborhood
   plus all qualifying displaced probes into the selected probes. Build a
   64-cell cumulative distribution from radiance times the surface
   cosine. Trace 64 guided, jittered equal-area hemi-octahedral samples per probe,
   reading native materials at triangle hits. Cells without reusable history and
   completely dark distributions fall back to stratified samples.
3. Allocate directional world-space tiles using AMD's PCG bucket hash, xxHash
   checksum and 16 candidate slots per bucket. Publication and subsequent lookup
   are separate passes. Checksums follow the reference collision behavior; full
   keys are retained for diagnostics, not used to change identity matching.
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
   Fresh light proposals use GridStream: 16 cells along the largest axis, up to 64
   strided reservoirs per cell, expanded-cell volume weights, jittered lookup and
   at most eight non-overlapping segments. Analytic lights, emissive triangles and
   the environment share this distribution. Triangle samples retain barycentrics
   and area-measure PDFs. One selected visibility ray evaluates each fresh reservoir.
   Optional world-space reservoir reuse re-evaluates at most four compatible previous
   reservoirs and caps their confidence at 20. Reference light indices are retained;
   environment/zero-light-class settings transitions reset GI.
   Godot analytic attenuation, layers and shadow-opacity semantics remain native.
6. Update packed-half direct and indirect cache sums using the reference temporal
   equation and integer-quantized contributions. Build the three coarser mips and
   choose the finest mip with 16 samples. Persistent storage updates only touched
   tiles. Continuation rays read the updated secondary direct cache and write
   probability-compensated contributions to the next frame’s indirect update buffer,
   matching AMD’s one-frame multibounce handoff. Continuation misses and emissive hits
   do not add another light estimator on top of NEE. Primary emissive hits inject Le
   directly into probes; they bypass filtered cache radiance.
7. Resolve probe radiance and average samples landing in each angular cell. Apply
   AMD's empty-cell radiance backup and shadow-preserving temporal hysteresis,
   followed by horizontal/vertical filters with plane and hit-direction rejection.
8. Build the valid-probe mask hierarchy before filtering, then project radiance
   into nine spherical-harmonic coefficients. Run the default near-field SSGI
   and bent-cone integration. Reconstruct incoming diffuse irradiance from four
   neighboring probes using AMD's depth/normal weights and plane-constrained lookup
   blue-noise jitter. Four spatial dimensions are precomputed from Capsaicin's
   Sobol/ranking/scrambling tables; the shader retains its golden-ratio temporal
   rotation. The shared buffer contains the 64 KiB spatial table followed by deterministic MT19937 seed data, with a minimum 1920×1080 seed allocation. It exists only while AMD GI is active.
   Relaxed interpolation fills otherwise uncovered pixels, with a low-confidence
   hint that prevents those fallback estimates from growing temporal history.
   Cache displaced surface probes, update reused entries, and reorder the bounded
   pool so unused entries are evicted first. A stable GPU prefix scan preserves
   frame-granularity least-recently-used order without CPU readback or sorting.
9. Reproject GI history using AMD’s accumulated radiance sums, sample eviction,
   confidence vignette and fallback rules. The blur radius uses pre-update history.
   Apply the reference relative-view-depth and normal-weighted horizontal/vertical
   filters, then composite before fog, tone mapping, DLSS or FSR.
10. Trace bounded-VNDF GGX samples below the low roughness threshold. Between the
    two thresholds, stochastically look up four screen probes; above the high
    threshold, use filtered diffuse irradiance divided by pi. Hit radiance comes from native screen
    feedback or the world cache, with hit emission and sky handled separately.
    AMD’s default a-trous path filters compressed radiance and RGB second moments,
    performs full-resolution reconstruction, then combines surface and virtual-ray
    temporal histories. The alternative split estimator is not ported. Native
    Forward+ applies the primary material BRDF before fog and temporal upscaling.

Sky input converts Godot's unfiltered octahedral radiance into a GI-owned cubemap
with a complete ordinary mip chain. This preserves Capsaicin's environment cone
sampling instead of substituting the native GGX roughness prefilter. Fresh light
selection uses `4*pi/(8*1.5)` and resampling/final shading use
`4*pi/(8*12000)`; grid volume weights use the coarsest mip of all six faces.
Sky-ray misses still use level zero. Conversion follows native sky revisions;
TIME/position/light-dependent skies update each frame. Orientation and exposure
remain native inputs. The cubemap and conversion exist only while GI is enabled. Camera movement, sky/light changes and material-atlas repacking do not
force a global history reset. AMD's surface reprojection, cache updates and decay
handle scene changes. Initialization, resource recreation and explicit quality
configuration changes reset the relevant history. When sky ambient
is enabled, GI replaces that unoccluded ambient term and preserves the environment's
remaining color-ambient mixture. Reflection sky selection follows the environment's
reflection source independently.

The default hash has 16,384 buckets, 16 tiles per bucket, and 85 cells per tile including
mips. Bucket selection uses the reference PCG chain and checksum uses xxHash. Base-cell history is limited to 16 updates, tile lifetime to 50 unused frames,
and final GI history to at most 64 samples with adaptive reduction. These are live
temporal histories, not unlimited accumulation for screenshots. Histories reset on
allocation, resource recreation and relevant quality/light-settings changes. Ordinary camera motion or camera replacement does not globally reset GI; surface/probe reprojection rejects incompatible history. Reference light-settings changes include environment presence and crossing zero/nonzero light-class counts, not every brightness or light-count change. Native surface reprojection rejects incompatible geometry; the fork’s swept-bounding-box probe-history wipes have been removed. Smooth lighting changes retain history; small camera motion reprojects existing histories. Material colors refresh
through new cache samples and the reference temporal weighting.
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

These are current implementation facts, not approved departures from AMD.
The [reference audit](../AMD_GI_REFERENCE_AUDIT.md) tracks corrections and the
evidence needed before reference fidelity can be claimed:

- Reprojection retains the visible 8-pixel grid. Guiding gathers a 3×3 reprojected
  neighborhood and every qualifying displaced-cache candidate in those bins.
  Integer atomic angular accumulation uses AMD’s 10,000 quantization factor.
  The displaced pool matches the screen-probe count; it no longer expires at an
  arbitrary 50-frame age. World radiance tiles retain AMD’s separate 50-frame decay.
  Primary albedo and metalness now come from a GI-only native prepass attachment,
  supporting the reference diffuse/specular sampling choice.
- Cache updates accumulate all registered primary/secondary hits by default.
  The optional one-hit-per-cell control remains a non-reference quality mode.
  The custom analytic and emissive proposal trees and probe-origin emitter estimator
  are removed. GridStream unifies light selection; `light_resampling` controls previous
  reservoir reuse only and defaults off, as does screen feedback.
  Secondary shading evaluates AMD’s fully rough dielectric BRDF including Fresnel
  compensation and specular energy. Multibounce sampling carries BRDF/PDF weights.
  Reference deterministic MT19937 seeds and PCG output/state ordering replace the
  previous ad hoc per-pass seeds.
- Glossy transport, ratio reconstruction, temporal rejection, and a-trous denoising
  are implemented. The matte room alone cannot validate them; use the dedicated
  mirror/glossy-floor rig. This is an adaptation, not an exact port of all Capsaicin
  reflection heuristics. Native primary materials retain their BRDF; secondary
  shading uses GI-1's rough diffuse approximation, including metallic hit base color.
  This avoids black metallic receivers without adding nested specular rays; it is
  not layered/anisotropic or general nested specular transport. Reflection-only
  hits read the world cache; upstream Capsaicin also performs cache lookup here
  rather than inserting those hits. The custom uncached reflection-lighting fallback has been removed. Compatible screen hits can reuse
  visible native specular lighting, but this is view-dependent feedback rather
  than general nested specular transport.
  Half-resolution mirrors can show reconstruction artifacts.
- Native source material programs read uniforms, textures and packed attributes at
  hits. AMD GI does not prepare capture pages or wait for an atlas budget. Source
  emitter sampling follows point/triangle/cone LOD. Affine UV0/UV2, rotation/scaling/translation, supported aliases and varying mappings are qualified by 704 GPU samples. Arbitrary warped, texture-driven, helper/loop-dependent or other unqualified mappings retain a diagnosed fallback; full native material coverage remains incomplete.
- MeshInstance3D geometry, native skeletons/blend shapes and CPU-managed 3D
  MultiMesh elements are collected without the former fixed instance/light caps.
  Particle/GPU-indirect MultiMesh geometry and unsupported native shader/light
  classes remain limitations. These are reported and skipped individually rather
  than suppressing supported geometry across the entire scene. Missing classes can
  still cause incorrect visibility/lighting; no full scene-class support is claimed.
- Reprojection uses native previous-surface positions from the GI depth prepass, including previous native poses. Swept object bounds no longer erase probe history. Controlled rotation/deformation, gold-weapon motion and first-person intersection sequences have software-Vulkan coverage; this is not an exhaustive gameplay guarantee. FSR2 has
  software-Vulkan coverage; DLSS runtime compatibility remains untested.

AMD's shader copyright/license is retained in `amd_gi.glsl` and `COPYRIGHT.txt`.
Equal-area hemisphere mapping, SH projection/convolution, cache layout, probe
sampling/blending/filtering and their inputs are being compared against the cited
reference stage by stage; matching stage names alone does not establish fidelity. See
[AMD_GI_IMPLEMENTATION.md](../AMD_GI_IMPLEMENTATION.md) for the larger work plan.

Angular accumulation now uses the reference fixed-point uint atomic sums and
counts. Radiance and SH round to half precision at storage boundaries. The
reprojected angular buffer remains scratch until resolve finishes. Mask dimensions
round up at each level to retain odd-sized edge tiles. An unchanged ray budget
does not establish unchanged GPU cost.

The displaced pool uses 1,216 bytes per entry, with one entry per stored screen
probe plus transient snapshots for displaced updates. Separate ownership/list
state and double-buffered order indices prevent competing writes. Eviction follows
actual center-probe reuse, preserves reprojected radiance, and uses the reference
LRU policy without the fork's former 50-frame cached-probe expiry. World radiance
tiles retain AMD's separate decay policy.

## Progress captures

Routine game preview comparisons use GI disabled versus the default **1/4 primary
diffuse ray per pixel** (16-pixel probe spacing), with denoising enabled. Do not
add a 1-ray-per-pixel comparison unless explicitly requested; the user considers
the settled stills sufficiently similar (2026-10-23).

Cloud game previews use FSR2 Native AA at 100% render scale: internal and output
resolutions must match. Do not upscale an already-small software-rendered preview.
For Crossroads, prefer a close view of shaded surfaces beside directly lit geometry,
such as the service-yard garage interior, rather than distant buildings behind fog.
Keep the authored lighting, fog and materials. Record camera coordinates, engine
revision, primary ray budgets and settling frames alongside the PNGs in `preview/`.

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
The focused cache rig sweeps the camera out and back while keeping its displaced cache resident, then renders another 64 frames. It requires history to survive small
camera motion, and checks the disabled image exactly. This diagnostic reads
the actual GPU queues, spawn assignments, ownership, and LRU order every frame.
It rejects duplicate/out-of-range assignments and invalid permutations, verifies
the update budget, and requires both eviction and reuse to be exercised. It
synchronizes the GPU and must not be enabled for timing or shipping presets.

`./run.sh amd_gi_lights` compares exhaustive and resampled light evaluation at
the same primary-ray budget. `GODOT_AMD_GI_VALIDATE_RESERVOIRS=1` synchronously
checks actual GPU light indices, finite weights and confidence in [1, 81], plus
the complete hash prefix, unique hit ownership, multi-hit entries and compaction. The
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
through the continuous segment. Its older abrupt-removal reset expectation predates the reference correction and is not current acceptance evidence. This lighting test does not certify moving meshes; deformation and scene-churn
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
For the uncached transport validator, transform-independent captures store local normals, transformed by the ray hit's
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

Swept bounds are collected only under `GODOT_AMD_GI_TRACE_HISTORY` for diagnostics.
They do not reject probe, diffuse or glossy history. Native previous-surface
positions provide reprojection; world-cache lighting uses AMD's UpdateTiles
weighting, including zero-update aging in touched tiles. Geometry and lighting
changes converge through fresh samples and the reference rejection/filter rules.

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

### Light proposal grid

GridStream builds volume-weighted strided reservoirs on GPU over current traced
hit bounds. Analytic, area and environment lights share the grid. A jittered lookup
merges disjoint segments into fresh RIS; optional previous-reservoir reuse is
separate and off by default. The former analytic binary tree, emissive tree and
probe-origin area-light estimator have been removed. See the pipeline above for
proposal counts and remaining native material/cone-sampling limitations.

### Native screen-lighting feedback

Opaque Forward+ draws optionally write their combined HDR lighting to a fourth
color attachment before fog, tone mapping, and temporal upscaling. GI reads that
texture on the following frame, matching the previous pixel geometry and removing
the previous exposure. Background/transparent pixels have no valid coverage.
Native current-to-previous UV displacement, relative depth and normal agreement
reject invalid reuse. The reference diffuse thresholds are 5% depth and 0.5 normal
agreement; glossy uses 1% and 0.95. Reflections retain the world-cache fallback;
continuations currently also retain explicit shading fallbacks under audit; the system does not require everything to remain on screen.

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
continuation estimates; secondary-only cells receive direct lighting. Counts are capped at 16 by the reference temporal update. The update averages
this frame’s hit batch, then blends with weight 1/capped_count; it does not weight
the frame by its hit count. Unsampled cells inside a touched tile age as upstream.
Each shaded hit now publishes its own light reservoir into the independent spatial
hash; the radiance cell’s owner no longer determines the sole reusable light sample.

The optional storage is one additional head per world cell plus 48 bytes per primary
hit slot (and per secondary slot when multibounce is on). The lower-cost mode skips
both per-hit shading passes and releases this storage. It preserves the original
one-update-per-cell behavior. Primary diffuse rays are identical between modes;
additional visibility and continuation rays must be included when profiling.
`amd_gi_hit_updates` reads actual GPU lists to verify every registered hit is present
exactly once, all samples are shaded, and toggling releases the extra buffers.

### Historical capture-atlas memory (superseded for AMD GI)

Material capture is a separate quality/memory axis from screen-probe ray density.
`material_tile_size=4` uses 128×128 array layers with the same 32×32 triangle layout;
8 uses 256×256 layers. Addressing derives the tile size from the actual texture.
Live changes discard old captures/atlas textures while
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
The current correction no longer uses persistent light-ID remapping. Ordinary index changes retain history; reference environment/zero-count light-settings boundaries reset it. Lighting changes use the reference cache accumulation; the former forced fast-refresh weighting has been removed. Explicit quality/resource changes reset history; camera and environment changes use reference reprojection and cache updates.

`GODOT_AMD_GI_TRACE_HISTORY=1` logs reset reasons and dirty-region counts without
GPU readback; it is opt-in and only runs in the enabled GI path. `amd_gi_scene_churn`
checks collection-boundary crossings, rotation, additions/removals and material
edits. `amd_gi_flashlight` checks continuous spotlight movement, indirect light,
resampling against exhaustive light shading and removal of light after switch-off.
Both use the quarter primary budget with denoising enabled. They do not establish
hardware timing or final gun-mounted flashlight quality in fps-proto.

## Earlier integration additions (2026-10-23)

Historical record: the capture-atlas and emitter hierarchy descriptions below predate the current native source-material/GridStream path. Use the live correction record for current behavior.

Historical checkpoint: the stable-ID policy described below was subsequently removed.
Use the [live correction record](../AMD_GI_CONSEQUENTIAL_CORRECTIONS.md) for current
behavior, input formats, default SSGI/feedback, evidence and remaining gaps.

The lighting buffers now carry full light-instance identities. Each viewport maps
its previous light indices to current indices before using reservoirs. Removing a
light invalidates its proposals, not all GI histories. Reference temporal cache
weighting now handles changed lighting without the former custom fast-refresh rule. Keeping proposal storage in zero/one-light scenes avoids reallocating
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
filters. The reference rank thresholds, bounded-VNDF sampling and default a-trous
reconstruction/dual-history equations have now replaced the custom rules. Full
transport/material parity remains under audit; a passing history-count check alone
does not establish reflection quality.

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

AMD GI hit normals now come directly from native packed source/pose buffers and shared triangle positions, with separate geometric and interpolated vertex normals. The authored-light/material boundary and the narrow upstream transform correction have owner approval. Native source-texture evaluation and the approved coverage correction are implemented. Final qualification and outstanding consequential findings remain in the [live correction record](../AMD_GI_CONSEQUENTIAL_CORRECTIONS.md); this is not a complete-baseline or hardware-performance claim.
