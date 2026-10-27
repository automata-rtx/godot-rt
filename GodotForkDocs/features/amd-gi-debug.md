# AMD GI diagnostics and advanced controls

Read [setup and normal controls](amd-gi.md) first. All short setting names here use
`rendering/global_illumination/amd_gi/` and are live global `ProjectSettings` values.
Diagnostics are opt-in and do not automatically write capture files.

## Runtime overlay API

```gdscript
const GI := "rendering/global_illumination/amd_gi/"

func choose_debug_view(mode: int) -> void:
    ProjectSettings.set_setting(GI + "debug/view", clampi(mode, 0, 31))

func enable_reports(enabled: bool) -> void:
    ProjectSettings.set_setting(GI + "debug/statistics", enabled)
    ProjectSettings.set_setting(GI + "debug/exclusion_reports", enabled)

func read_diagnostics() -> Dictionary:
    return RenderingServer.viewport_get_amd_gi_diagnostics(
        get_viewport().get_viewport_rid()
    )
```

Poll at a modest rate, such as 4 Hz. The query returns a detached per-viewport
snapshot and synchronizes with the render thread; it does not request a new GPU
readback. An empty dictionary means no available diagnostics, including both
reporting switches off. Top-level `frame` is the latest GI frame; `gpu.frame` is
the sampled frame. `scene` describes transport candidates, while `collection`
reports earlier collection exclusions. Each exclusion stage provides exact totals
and up to 4096 detailed entries; collection entries include object IDs.

GPU fields include occupied/active tiles, occupied/full buckets, sampled cells,
64-bit sample sum, maximum count, valid/updated screen probes, valid retained probes,
primary/secondary compacted hit records, and 17-bin occupancy/overflow histograms.
Overflow counts are **failed attempts**, not unique missing tiles.

| Setting | Default | Behavior |
| --- | --- | --- |
| `debug/view` | `0` | Display selector below. Does not reset GI history. |
| `debug/statistics` | `false` | Full cache scan and synchronous GPU readback on sampled frames. Exclude those frames from performance comparisons. |
| `debug/readback_interval` | `60` | GI render frames between snapshots, range 1-3600. First enabled frame samples immediately. |
| `debug/exclusion_reports` | `false` | Enable CPU collection/transport exclusion details. |
| `debug/mip` | `0` | Raw cache mip 0-3; adaptive filtered views select their own mip. |
| `debug/indirect_cache` | `false` | Inspect indirect rather than direct cache. Propagation always uses indirect; black when multibounce is off. |
| `debug/max_age` | `60` | Age heatmap scale and tile visibility limit. Zero shows only currently touched tiles. |
| `debug/atlas_page` | `0` | Page through occupied tiles, buckets, or retained probes. Missing pages are black. |
| `debug/exposure` | `0` | Radiance-view EV, -16 to 16. Native material/direct/indirect displays retain scene tonemapping. |
| `debug/sample_scale` | `32` | Count/overflow heatmap maximum; does not change ray budgets. |

Disabling a compute display frees its full-size output texture. Disabling statistics
releases its full counter buffer, retaining a tiny inactive binding. Overflow view
uses counters without requesting readback. Normal rendering performs no diagnostic
GPU readback or exclusion reporting.

## Display values

| Value | Display | Interpretation |
| --- | --- | --- |
| 0 | Normal rendering | Default. |
| 1 | Indirect only | Native ambient/diffuse GI and indirect reflections. Complete feedback is captured before direct light/emission are hidden. |
| 2 | Reflections | Resolved AMD reflection radiance. |
| 3 / 4 | Screen probes / directions | Radiance atlas / the same direction across probes. |
| 5 / 6 | Probe coverage / age | Validity / last-traced age. |
| 7 / 8 | Cache radiance / samples | Raw directional cells at selected mip. |
| 9 / 10 / 11 / 12 | Filtered cache / filter gain / filtered samples / selected mip | Adaptive reconstruction and its supporting evidence. |
| 13 / 14 / 15 | Tile occupancy / age / coverage | Filled cells / last-touched tile age / cells with evidence. Tile age is not cell radiance age. |
| 16 / 17 | Bucket occupancy / overflow | Fullness / failed allocations this frame. |
| 18 / 19 / 20 / 21 | Albedo / alpha / specular F0 / direct only | Native display isolation after feedback capture. Alpha shows surviving fragments, not discarded fragments. Direct-only excludes emission and indirect light. |
| 22 | Propagation | Actual accumulated multibounce cache radiance. |
| 23 | Raw reflections | Before spatial/temporal reconstruction; firefly cleanup may already have run. Disable cleanup to inspect untreated samples. |
| 24 / 25 / 26 | Shading normals / geometry normals / roughness | Native receiver inputs. |
| 27 | Previous feedback | Previous outgoing direct, emission, and indirect lighting; black on reset. |
| 28 / 29 / 30 / 31 | Retained probe radiance / seed age / occupancy / LRU activity | Incoming LRU order. Seed age may predate a radiance update. Gray: unclaimed; blue: reused; green: new/evicted; red: invalid. |

Cache displays are paged atlases of actual directional 8x8 tiles, not estimated
lookups over visible surfaces. Coarser mip cells cover larger blocks. Tile expiry
can change page membership. Heatmaps run red through blue to green as values rise;
coverage is green for valid evidence and red for missing evidence.

## Advanced quality controls

| Setting | Default | Meaning |
| --- | --- | --- |
| `screen_feedback` | `false` | Optional diffuse-hit feedback, effective only with multibounce off and compatible native indirect-light multipliers. Default near-field SSGI and reflection-hit feedback remain independent consumers of previous opaque lighting. |
| `continuation_probability` | `0.3` | Probability of a secondary continuation; contributions are probability-compensated. Clamped 0.05-1. |
| `minimum_cell_size` | `0.1` | Minimum world-cache cell size; actual size also depends on distance, resolution, and FOV. |
| `cache_bucket_exponent` | `14` | 2^exponent buckets, 16 tiles per bucket; range 8-14. Default 262144 tiles. Smaller caches save memory but increase overflow and missing coverage. |
| `max_distance` | `1000000000` | AMD reference ray limit. Lower values are a nonbaseline quality tradeoff and do not reduce CPU scene collection. Only stored probe reprojection distance is capped at 65504. |
| `reflections/trace_roughness_threshold` | `0.2` | At or below this roughness, trace. Middle roughness uses stochastic lookup in four screen probes; missing coverage does not request a fallback ray. |
| `reflections/probe_roughness_threshold` | `0.6` | Above this, use diffuse probe irradiance approximation. Keep at least as high as the tracing threshold. |
| `reflections/split_radius_full` / `split_radius_half` | `11` / `11` | Split filter only, radius in full-resolution pixels, range 1-32. Half-resolution mode has a full-width, half-height intermediate. |
| `reflections/firefly_low_threshold` / `firefly_high_threshold` | `0.0` / `1.0` | Reference rank thresholds; defaults do not reject ordinary rank outliers. Narrower bounds enable more rejection. |
| `reflections/firefly_mark_radius_full` / `firefly_mark_radius_half` | `2` / `3` | Sample-grid radius, range 0-16; zero is center-only. |
| `reflections/firefly_cleanup_radius_full` / `firefly_cleanup_radius_half` | `1` / `2` | Sample-grid cleanup radius, range 0-16. |

Do not use `material_atlas_mb`, `material_tile_size`, `material_adaptive_resolution`,
or `material_preparation_budget` to tune production AMD GI: these settings only
control the legacy uncached RTGI validator's material capture. Production shading
uses native material source.

For sky comparisons, `sky_sampling=0` selects uniform hemisphere, `1` cosine,
and `2` luminance importance. Importance samples a separate box-mip sky hierarchy,
adding six face reads and four per traversed mip per fresh sky candidate. It can
better target a sun disk but is not universally preferable to cosine sampling.
This does not change the primary diffuse probe budget.

The engine fixture `docs/validation/shadow_validation/amd_gi_options.tscn` covers
live changes, all 32 display values, and 36 sampler/filter combinations. A prepared
fixture is not a recorded passing GPU result. Separate shader compilation/layout
checks from visual acceptance when evaluating a build.
