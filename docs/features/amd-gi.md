# AMD GI controls

For current status, missing features, approvals and local testing, read [the handoff](../AMD_GI_IMPLEMENTATION.md).
The controls below are experimental, not verified hardware presets. Old progress captures and pipeline diaries are in [the archive](../history/AMD_GI_ARCHIVE.md#snapshot-amd-gi).

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
