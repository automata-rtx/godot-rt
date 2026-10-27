> Historical snapshot from `66bd97e00d` before the 2026-10-26 documentation audit. Claims and line numbers may be superseded. Do not use as current configuration guidance.

# AMD GI controls

For current status, missing features, approvals and local testing, read [the handoff](../AMD_GI_IMPLEMENTATION.md).
The controls below are experimental, not verified hardware presets. Old progress captures and pipeline diaries are in [the archive](../history/AMD_GI_ARCHIVE.md#snapshot-amd-gi).

## Enable and configure

RT shadow support must already be enabled at engine startup, so shared mesh buffers
have acceleration-structure usage. Use Vulkan Forward+, a WorldEnvironment, and no
MSAA. The current input path requires eight color attachments, twelve storage-image
bindings, 38 storage buffers per stage and pipeline layout, and 16-bit storage support.

Orthographic cameras are explicitly unsupported: they retain native lighting and
have no AMD GI output. Negative/subtractive lights retain their native direct
effect but do not contribute to AMD GI sampling or screen-light feedback.
Ordinary CPU-managed 3D MultiMesh is supported, including bulk transforms and
per-element color/custom data. GPU-indirect MultiMesh and shader-deformed ray
geometry are separate unsupported paths; the game's grass currently opts out of
transport while remaining eligible to receive GI on screen.

All controls below are live `ProjectSettings` values under
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
| `denoiser` | `true` | Diffuse temporal reprojection and adaptive spatial GI denoising. Reflections now have an independent selector. Probe reconstruction/filtering remains part of the GI algorithm. |
| `importance_sampling` | `true` | Guide diffuse probe rays using reprojected radiance times the surface cosine. Keeps the same primary ray count; disabling uses stratified angular samples. Switching resets history. |
| `brdf_sampling` | `true` | Use native albedo, metalness and roughness for AMD’s Fresnel-weighted choice between a bounded-VNDF GGX sample and diffuse radiance guiding. No extra primary rays. |
| `adaptive_sampling` | `true` | Redirect existing updates from reusable probes to uncovered screen tiles. Does not add rays. Switching resets history. |
| `probe_cache` | `true` | Retain one displaced-probe slot per internal 8×8 screen tile, with least-recently-used eviction. Turning this off releases the pool and skips its binning, ordering, and store stages; histories reset. |
| `light_resampling` | `false` | Enable reuse of up to four previous hit reservoirs from AMD’s independent spatial hash. Fresh GridStream RIS remains enabled in both modes. Hash headers use 96 MiB across both frames, plus 64 bytes per hit slot and scan scratch; disabling releases that temporal storage. |
| `cache_bucket_exponent` | `14` | World-cache bucket count is 2 to this power, with 16 tiles per bucket. AMD’s default is 16,384 buckets / 262,144 tiles. Values 8–14 expose the reference capacity tradeoff: fewer buckets reduce memory but increase collision overflow and missing cache coverage. Live changes recreate history. |
| `reflections/enabled` | `true` | Enable the separate glossy path. Turning it off skips all glossy stages and releases reflection-sized resources. |
| `reflections/half_resolution` | `true` | One glossy sample per 2×2 internal pixels, with rotating sample locations; disabling uses full internal resolution. Independent of diffuse probe spacing. |
| `reflections/trace_roughness_threshold` | `0.2` | Trace at or below this roughness. Between this and the high threshold, use AMD’s stochastic GGX lookup in four screen probes. Missing probe coverage returns no reflected contribution; it does not request a fallback ray. |
| `reflections/probe_roughness_threshold` | `0.6` | Above this threshold, use the diffuse probe irradiance approximation. Keep this at least as high as the trace threshold. |
| `reflections/firefly_filter` | `true` | AMD’s rank-based marking and plane-weighted cleanup before reconstruction. Independent of the reflection denoiser selector. |
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


## Runtime sampling, reflection filters, and diagnostics

Added 2026-10-25. Source-only validation includes an editor build, offline GLSL
compilation and numerical/layout checks. No GPU or visual acceptance was performed.
The gold AK motion/detail issue remains open; another denoiser is a comparison
option, not a proven correction.

All names below use `rendering/global_illumination/amd_gi/`. Change them with
`ProjectSettings.set_setting()`; no restart, save, or project-source edit is needed.
Changes affect every eligible viewport. Histories and diagnostic snapshots are per viewport.

| Option | Default | Behavior and tradeoff |
| --- | --- | --- |
| `sky_sampling` | `1` cosine | `0` uniform hemisphere preserves the previous baseline; `1` cosine better matches diffuse weighting with little arithmetic; `2` AMD luminance importance samples bright sky regions such as the sun disk. Importance adds six face reads and four reads per mip per fresh sky candidate. Changes reset history. This samples environment light at world-cache hits, independently of probe `importance_sampling`. |
| `reflections/denoiser` | `1` a-trous | `0` AMD split-ratio X/Y, `1` AMD a-trous, `2` disabled. Independent of diffuse `denoiser`. Default a-trous and temporal equations are unchanged. Split filtering can reduce filtering work but trades detail/stability and can exhibit striping; no hardware gain is claimed. Switching recreates resources and resets history. |
| `reflections/split_radius_full`, `_half` | `11`, `11` | Radius in full-resolution pixels, range 1-32. Split mode only. Half-resolution split mode uses a full-width, half-height intermediate. |
| `reflections/firefly_mark_radius_full`, `_half` | `2`, `3` | Sample-grid neighborhood radius, range 0-16. Zero is center-only. |
| `reflections/firefly_cleanup_radius_full`, `_half` | `1`, `2` | Sample-grid cleanup radius, range 0-16. Radii changes reset history. Existing thresholds and cleanup enable switch apply. |
| `debug/view` | `0` off | Display selector below. View changes do not reset GI history. |
| `debug/statistics` | `false` | Opt-in GPU counters. Full cache scans and synchronous readback occur only on sampled frames. Do not use these frames for performance measurements. |
| `debug/readback_interval` | `60` | GI render frames between snapshots, range 1-3600. The first enabled frame samples immediately. |
| `debug/exclusion_reports` | `false` | Collection-stage object and transport-stage surface exclusions. Exact aggregate counts plus up to 4096 details per stage; collection entries include object IDs. |
| `debug/mip` | `0` | Raw cache atlas mip 0-3. Adaptive filtered views choose their own mip. |
| `debug/indirect_cache` | `false` | Inspect multibounce cache instead of direct cache. Propagation always selects multibounce. Black when multibounce is disabled. |
| `debug/max_age` | `60` | Age heatmap scale and cache tile visibility limit. Zero shows only currently touched tiles. |
| `debug/atlas_page` | `0` | Page through occupied tiles, buckets or retained probes. Out-of-range pages are black. |
| `debug/exposure` | `0` stops | Radiance-view exposure, -16 to 16 EV. Native material/direct/indirect views retain scene tonemapping. No estimator/exposure changes. |
| `debug/sample_scale` | `32` | Heatmap maximum for counts/overflow attempts; does not change ray budgets. |

Diagnostics are off by default. Disabling a compute display frees its full-size
output texture. Disabling statistics releases the full counter buffer, leaving a
tiny inactive binding. Overflow view enables counters without requesting readback.
Normal rendering does no diagnostic GPU readback or exclusion reporting.

### Display modes

| Value | View | Interpretation |
| --- | --- | --- |
| 0 | Normal rendering | Recommended shipping default. |
| 1 | Indirect only | Native ambient/diffuse GI and indirect reflections. Direct light and emission hidden after complete feedback is captured. |
| 2 | Reflections | Resolved AMD reflection radiance. |
| 3-4 | Screen probes / directions | Radiance atlas or the same direction across screen probes. |
| 5-6 | Probe coverage / age | Active probe validity and last-traced age. |
| 7-8 | Cache radiance / samples | Raw cache cells at selected mip. |
| 9-12 | Filtered cache / filter gain / filtered samples / selected mip | Adaptive reconstruction and its evidence. |
| 13-15 | Tile occupancy / tile age / coverage | Filled cells, last-touched tile age, cells with evidence. Tile age is not cell radiance age. |
| 16-17 | Bucket occupancy / overflow | Fullness and failed allocation attempts this frame. Attempts are not unique missing tiles. |
| 18-21 | Albedo / alpha / specular F0 / direct only | Native display isolation after feedback capture. Alpha shows surviving fragments; discarded fragments have no sample. Direct-only excludes emission/indirect light. |
| 22 | Propagation | Actual accumulated multibounce cache radiance. |
| 23 | Unfiltered reflections | Sample radiance before spatial/temporal filtering; firefly cleanup may already have run. Disable cleanup to inspect untreated samples. |
| 24-26 | Shading normals / geometry normals / roughness | Native receiver inputs. |
| 27 | Previous feedback | Outgoing lighting used by feedback; black on reset. Includes direct, emission and indirect light. |
| 28-31 | Retained probe radiance / seed age / occupancy / LRU activity | Displaced probe pool in incoming LRU order. Seed age can predate a radiance update. Gray unclaimed, blue reused, green new/evicted, red invalid. |

Cache visualizers are paged atlases of real directional cache tiles, not guessed
lookups over visible scene surfaces. Each 8-by-8 block contains base cache cells;
coarser mip values cover larger blocks. Page membership changes as tiles expire.
Heatmaps run red at low values through blue to green at high values. Coverage is
green for valid evidence and red for missing. Native material views and atlas
presentation are Godot adaptations; AMD normalization/mip selection remain the basis.

### Overlay API

```gdscript
const GI := "rendering/global_illumination/amd_gi/"

func choose_sky(mode: int) -> void:
    ProjectSettings.set_setting(GI + "sky_sampling", clampi(mode, 0, 2))

func choose_reflection_filter(mode: int) -> void:
    ProjectSettings.set_setting(GI + "reflections/denoiser", clampi(mode, 0, 2))

func choose_debug_view(mode: int) -> void:
    ProjectSettings.set_setting(GI + "debug/view", clampi(mode, 0, 31))

func enable_counters(enabled: bool) -> void:
    ProjectSettings.set_setting(GI + "debug/statistics", enabled)

func read_diagnostics() -> Dictionary:
    return RenderingServer.viewport_get_amd_gi_diagnostics(
        get_viewport().get_viewport_rid()
    )
```

Poll at a modest rate (for example 4 Hz). The query returns a detached snapshot
without initiating GPU readback, but synchronizes with the rendering thread.
Top-level `frame` is the latest GI frame; `gpu.frame` is the sampled frame. Empty
means no diagnostics available, including both reporting switches off. `scene`
describes transport candidates; `collection` explains earlier exclusions. GPU
fields include occupied/active tiles, occupied/full buckets, sampled cells,
64-bit sample sum, maximum count, valid/updated screen probes, valid retained probes,
primary/secondary compacted hit records and occupancy/overflow histograms.
No capture files are written automatically.

The isolated `docs/validation/shadow_validation/amd_gi_options.tscn` fixture
covers live switching, 32 views and a 36-combination sampler/filter matrix.
It is prepared but unrun under the owner's source-only restriction.
