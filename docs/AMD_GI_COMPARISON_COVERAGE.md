# AMD GI comparison coverage appendix

This appendix freezes the **pre-correction audit**. Current dispositions and validation are in [the live consequential record](AMD_GI_CONSEQUENTIAL_CORRECTIONS.md); statements such as “absent” below describe that audited revision.

Companion to [the completed source comparison](AMD_GI_FULL_COMPARISON.md). These are source dispositions, not equivalence certificates. Baselines: AMD `914b91596cd119eda85fbc1d3c7ee6ac391b1452`; fork `d932f4ac0260c49ebd1dbbc61db9b8580726dcf0` plus the preexisting local follow-up. All finding IDs refer to that report.

## Main AMD GI functions

All 70 definitions in `src/core/src/render_techniques/gi1/gi1.comp` are accounted for, including wrappers, optional modes and diagnostics. Inline ray queries map to Vulkan queries; the alternate DXR dispatch wrappers are explicitly outside the requested API scope.

| AMD function / line | Fork counterpart or explicit absence | Comparison |
| --- | --- | --- |
| `ClearCounters` :164 | AMDGI host dispatch, reset/queue initialization; debug draws/SBT dispatch absent | Host scheduling / H01-H04 |
| `GenerateDraw` :188 | AMDGI host dispatch, reset/queue initialization; debug draws/SBT dispatch absent | Host scheduling / H01-H04 |
| `GenerateDispatch` :209 | AMDGI host dispatch, reset/queue initialization; debug draws/SBT dispatch absent | Host scheduling / H01-H04 |
| `GenerateDispatchRays` :220 | AMDGI host dispatch, reset/queue initialization; debug draws/SBT dispatch absent | Host scheduling / H01-H04 |
| `ClearProbeMask` :243 | reset_cache / filter_mask / closest_probe | Probe placement and history / P01,P04,P07,P08 |
| `FilterProbeMask` :249 | reset_cache / filter_mask / closest_probe | Probe placement and history / P01,P04,P07,P08 |
| `InitCachedTileLRU` :287 | reset_cache | Probe placement and history / P01,P04,P07,P08 |
| `ReprojectScreenProbes` :293 | reproject_probe / previous_probe | Probe placement and history / P01,P04,P07,P08 |
| `CountScreenProbes` :502 | bin_cached_probe / find_cached_probe; different bin/list representation | Probe placement and history / P01,P04,P07,P08 |
| `ScatterScreenProbes` :542 | bin_cached_probe / find_cached_probe; different bin/list representation | Probe placement and history / P01,P04,P07,P08 |
| `SpawnScreenProbes` :556 | select_probe; fixed update slots, not identical compaction | Probe placement and history / P01,P04,P07,P08 |
| `CompactScreenProbes` :582 | select_probe; fixed update slots, not identical compaction | Probe placement and history / P01,P04,P07,P08 |
| `PatchScreenProbes` :616 | patch_probe | Probe placement and history / P01,P04,P07,P08 |
| `SampleScreenProbes` :647 | prepare_probe / trace_probe / sample_cell | Probe guiding and eviction / P01,P06,P08 |
| `PopulateScreenProbesHandleHit` :986 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `PopulateScreenProbesHandleMiss` :1078 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `PopulateScreenProbesTraceRay` :1086 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `PopulateScreenProbes` :1107 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `PopulateScreenProbesMain` :1161 | trace_probe / trace_hit / allocate_tile / register_ray; shared rt_gi_transport | Primary transport / T01-T05,C01-C06,L01-L06 |
| `BlendScreenProbes` :1167 | resolve_probe | Probe blend and LRU / P06-P08,C01-C06 |
| `ReorderScreenProbes` :1334 | order_cached_probes / store_cached_probe | Probe blend and LRU / P06-P08,C01-C06 |
| `FilterScreenProbes` :1357 | filter_probe (X/Y) | Probe spatial filter / P02,P04 |
| `ProjectScreenProbes` :1446 | project_probe | SH projection / P03 |
| `InterpolateScreenProbes` :1515 | interpolate_pixel / probe_irradiance; SSGI/bent-cone portion absent | Probe interpolation and near-field GI / P05,P09 |
| `PurgeTiles` :1715 | reset_cache | Cache and multibounce / C01-C06 |
| `PopulateMultibounceCellsHandleHit` :1761 | populate_secondary / secondary allocate/register; rt_gi_transport | Cache and multibounce / C01-C06 |
| `PopulateMultibounceCellsTraceRay` :1854 | populate_secondary / secondary allocate/register; rt_gi_transport | Cache and multibounce / C01-C06 |
| `PopulateMultibounceCells` :1869 | populate_secondary / secondary allocate/register; rt_gi_transport | Cache and multibounce / C01-C06 |
| `PopulateMultibounceCellsMain` :1943 | populate_secondary / secondary allocate/register; rt_gi_transport | Cache and multibounce / C01-C06 |
| `UpdateMultibounceCells` :1948 | indirect_hit / shade_indirect_hit / update_indirect | Cache and multibounce / C01-C06 |
| `UpdateMultibounceCellsMain` :1986 | indirect_hit / shade_indirect_hit / update_indirect | Cache and multibounce / C01-C06 |
| `PopulateCellsHandleHit` :1993 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `PopulateCellsHandleMiss` :2006 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `PopulateCellsTraceRay` :2022 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `PopulateCells` :2040 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `PopulateCellsMain` :2111 | shade_hit / shade_direct / gi_light_visibility | Cache and multibounce / C01-C06 |
| `GenerateUpdateTilesDispatch` :2130 | cache dispatch / update_cell / update_indirect / build_mip / resolve_probe | Cache and multibounce / C01-C06 |
| `UpdateTiles` :2143 | cache dispatch / update_cell / update_indirect / build_mip / resolve_probe | Cache and multibounce / C01-C06 |
| `ResolveCells` :2351 | cache dispatch / update_cell / update_indirect / build_mip / resolve_probe | Cache and multibounce / C01-C06 |
| `ClearReservoirs` :2394 | reservoir_reset | Light reservoirs / L01-L06 |
| `GenerateReservoirs` :2401 | resampled_direct / shade_direct at primary and secondary hits | Light reservoirs / L01-L06 |
| `GenerateMultibounceReservoirs` :2603 | resampled_direct / shade_direct at primary and secondary hits | Light reservoirs / L01-L06 |
| `CompactReservoirs` :2699 | reservoir_scan / reservoir_compact | Light reservoirs / L01-L06 |
| `ResampleReservoirs` :2713 | resampled_direct / reservoir_find_previous / reservoir_load_previous | Light reservoirs / L01-L06 |
| `TraceReflectionsHandleHit` :2801 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `TraceReflectionsHandleMiss` :2905 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `TraceReflectionsTraceRay` :2915 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `TraceReflections` :2933 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `RatioEstimator_GaussianFilter` :3014 | Split-ratio-only helper absent | Reflection tracing / R01-R06,T01-T05 |
| `AtrousRatioEstimator_GaussianFilter` :3020 | resolve_reflection exponential/Gaussian weights | Reflection tracing / R01-R06,T01-T05 |
| `MarkFireflies_BoxFilter` :3026 | mark_reflection_fireflies weights | Reflection tracing / R01-R06,T01-T05 |
| `CleanupFireflies_NeighborhoodFilter` :3031 | clean_reflection_fireflies weights | Reflection tracing / R01-R06,T01-T05 |
| `TraceReflectionsMain` :3039 | prepare_reflection / classify_reflection / trace_reflection / screen_lighting | Reflection tracing / R01-R06,T01-T05 |
| `ResolveReflections_SplitRatioEstimatorX` :3045 | Absent optional algorithm | Missing optional split-ratio estimator / O01 |
| `ResolveReflections_SplitRatioEstimatorY` :3157 | Absent optional algorithm | Missing optional split-ratio estimator / O01 |
| `ReprojectReflections` :3282 | temporal_reflection / reflection_history_at | Reflection reconstruction/history / R01-R06 |
| `ResolveReflections_AtrousRatioEstimator_First` :3448 | resolve_reflection first/iter/last pass branches | Reflection reconstruction/history / R01-R06 |
| `ResolveReflections_AtrousRatioEstimator_Iter` :3554 | resolve_reflection first/iter/last pass branches | Reflection reconstruction/history / R01-R06 |
| `ResolveReflections_AtrousRatioEstimator_Last` :3663 | resolve_reflection first/iter/last pass branches | Reflection reconstruction/history / R01-R06 |
| `MarkFireflies` :3813 | mark_reflection_fireflies | Reflection reconstruction/history / R01-R06 |
| `CleanupFireflies` :3883 | clean_reflection_fireflies | Reflection reconstruction/history / R01-R06 |
| `NoDenoiserReflections` :3958 | output_reflection_pixel with global denoiser disabled; control differs | Reflection reconstruction/history / R01-R06 |
| `ReprojectGI` :3997 | reproject_pixel / gi_denoiser_accumulate | Diffuse denoising / D01-D03 |
| `FilterGI` :4105 | filter_pixel / gi_denoiser_filter_weight | Diffuse denoising / D01-D03 |
| `ClearBucketOverflowCount` :4158 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `ClearBucketOccupancy` :4170 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `ClearBucketOverflow` :4188 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `BuildBucketStatistics` :4200 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `FormatBucketOccupancy` :4237 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |
| `FormatBucketOverflow` :4257 | Absent AMD diagnostic kernels; fork diagnostic readbacks differ | Missing AMD diagnostic kernels / O03 |

## Companion source and dependency contracts

| AMD source family | Fork source / disposition | Findings |
| --- | --- | --- |
| `gi1.cpp/.h`, `gi1_shared.h`, `gi1.hlsl` | `environment/amd_gi.cpp/.h`, shader layouts and RD dispatches; allocations, formats, options, bindings, constants, clears, swaps, GUI/termination reviewed | H01–H04, O01–O04 |
| `screen_probes.hlsl` | Probe structures, masks, SH, hemisphere mapping, cache allocator in `amd_gi.glsl` | P01–P09 |
| `hash_grid_cache.hlsl` | Cache key/read/allocation/mips in `amd_gi.glsl`, `amd_gi_cache_inc.glsl` | C01–C06 |
| `world_space_restir.hlsl` | `amd_gi_reservoirs_inc.glsl`, `amd_gi_lights_inc.glsl` | L04–L05 |
| `glossy_reflections.hlsl` | `amd_gi_reflections_inc.glsl` | R01–R06 |
| `gi_denoiser.hlsl` | `amd_gi_denoiser_inc.glsl`, pixel histories/filters | D01–D03 |
| `gi1.frag/.vert` | Native Forward+ final shading; AMD debug screen/cache/reflection draws absent | R01, T05, O03 |
| `gi1.rt` | Raygen/hit/miss wrappers route to the same core; fork Vulkan inline queries, no DXR SBT | H03, T02–T03 |
| `light_sampler_grid_stream/*` | Bounds/build/proposal helpers in `amd_gi_lights_inc.glsl`, host buffers | L01–L06 |
| `light_sampler_grid_cdf/*`, `light_sampler_uniform/*` | Inspected as alternative component contracts; not default GI1 stages; no claimed port | O04 |
| `light_builder/*`, `lights/*` | `rt_gi_emitters.glsl`, `rt_gi_scene.cpp`, light target/volume/visibility helpers; uniform triangle/area PDF and default environment formulas present; alternate modes explicitly missing | L01–L06, T03–T05 |
| `materials/*` | Rough dielectric BRDF and bounded GGX helpers present; source hit material/texture/packing replaced by captured atlas | T01, C04,C06,L03,L04 |
| `geometry/*`, `ray_tracing/*` | Shared `rt_geometry`, transport ray query/alpha/hit reconstruction, material expansion/capture and culling | T01–T04, H04 |
| `math/*`, random generator, blue-noise sampler | Hemisphere/SH/quaternion/hash/PCG/blue-noise/VNDF helper contracts; same tables, different routing/precision at call sites | P03,P06,P07,C04,L04 |
| `ssgi/*` | Default near-field radiance, horizon occlusion and bent-cone path absent; all five options missing | P09 |
| VisibilityBuffer and previous buffers | Native geometry/detail normals, depth, velocity, previous surface and primary material attachments | P07,R03,D02,H01 |
| Combine, BRDF LUT, environment, exposure | Native Forward+ response/feedback/sky/exposure adapter; no blanket equivalence | D03,T05 |
| PrefilterIBL | Bound by AMD host but prefiltered texture unused by GI1 shaders; ordinary cube is used | O04 |
| GI1Renderer graph / remaining postprocessing | Native atmosphere/skybox/FSR2 or DLSS/exposure/bloom/tone mapping services; not missing GI transport stages | O04 |

## Every fork pass

| Pass | Disposition |
| --- | --- |
| `PASS_ALLOCATE` | Primary transport/cache membership; T01–T03,C02–C03 |
| `PASS_ALLOCATE_SECONDARY` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_BIN_CACHED` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_BLUR_X` | Diffuse denoiser; D01–D02 |
| `PASS_BLUR_Y` | Diffuse denoiser; D01–D02 |
| `PASS_FILTER_X` | Probe reconstruction; P02–P05,P09 |
| `PASS_FILTER_Y` | Probe reconstruction; P02–P05,P09 |
| `PASS_INDIRECT_MIP1` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_INDIRECT_MIP2` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_INDIRECT_MIP3` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_INTERPOLATE` | Probe reconstruction; P02–P05,P09 |
| `PASS_LIGHT_BOUNDS` | GridStream; L01–L03,L06 |
| `PASS_LIGHT_BOUNDS_RESET` | GridStream; L01–L03,L06 |
| `PASS_LIGHT_GRID` | GridStream; L01–L03,L06 |
| `PASS_MASK` | Probe reconstruction; P02–P05,P09 |
| `PASS_MIP1` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_MIP2` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_MIP3` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_ORDER_CACHED` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_PATCH` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_POPULATE` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_PREPARE` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_PROJECT` | Probe reconstruction; P02–P05,P09 |
| `PASS_REFLECTION_BUILD_DISPATCH` | Reflection dispatch/tracing; H02,R01–R04 |
| `PASS_REFLECTION_CLASSIFY` | Reflection dispatch/tracing; H02,R01–R04 |
| `PASS_REFLECTION_CLEAN_FIREFLIES` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_FIRST` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_ITER` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_LAST` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_MARK_FIREFLIES` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_OUTPUT` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_TEMPORAL` | Reflection reconstruction/output; R01–R06,D03 |
| `PASS_REFLECTION_TRACE` | Reflection dispatch/tracing; H02,R01–R04 |
| `PASS_REGISTER` | Primary transport/cache membership; T01–T03,C02–C03 |
| `PASS_REGISTER_SECONDARY` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_REPROJECT` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_RESERVOIR_COMPACT` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESERVOIR_RESET` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESERVOIR_SCAN` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESERVOIR_SCAN_BLOCKS` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESERVOIR_SCAN_TOP` | World-space reservoir allocation/scan/compaction; L04–L05 |
| `PASS_RESET` | Host clear/cache purge/LRU initialization; C01,H01–H02 |
| `PASS_RESOLVE` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_SELECT` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_SHADE_HITS` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_SHADE_INDIRECT_HITS` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_STORE_CACHED` | Probe placement/history/cache; P01,P06–P08 |
| `PASS_TEMPORAL` | Diffuse denoiser; D01–D02 |
| `PASS_TRACE` | Primary transport/cache membership; T01–T03,C02–C03 |
| `PASS_UPDATE` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |
| `PASS_UPDATE_INDIRECT` | Cache/direct/continuation/mip/handoff; C01–C06,L01–L05 |

The separate environment conversion shader has base conversion and mip-generation branches (T05). `rt_gi_emitters.glsl` builds the sampled triangle list (L03); `rt_material_expand.glsl` expands native geometry for capture (T01). Forward+ writes the native primary inputs and pre-fog feedback and composites diffuse/specular outputs (T05,H03). Shared transport also serves the separate RT-validation backend; unused helpers or its uncached estimator are not additional AMD stages.

## Every AMD GI option

Defaults are read from AMD `GI1::RenderOptions`. “Fixed” means the default value exists but the corresponding AMD control is not exposed; it is not a complete control port.

| AMD option | Default | Fork mapping / disposition |
| --- | --- | --- |
| `gi1_use_dxr10` | `false` | Vulkan inline queries only; authorized API scope (H03) |
| `gi1_use_resampling` | `false` | `light_resampling=false`; branch differences L04–L05 |
| `gi1_disable_alpha_testing` | `false` | No independent equivalent; inherited AMD visibility option; T03,O02 |
| `gi1_use_direct_lighting` | `true` | No identical debug switch; native direct lighting retained and GI emission/NEE enabled; L02,O02 |
| `gi1_use_temporal_feedback` | `false` | `screen_feedback=false`; reflection coupling and diffuse-feedback/multibounce exclusivity differ; R02 |
| `gi1_use_multibounce` | `true` | `multibounce=true`; C04 |
| `gi1_disable_albedo_textures` | `false` | No equivalent independent reference debug switch; O02,T01 |
| `gi1_disable_specular_materials` | `false` | No equivalent independent reference debug switch; O02,T01 |
| `gi1_hash_grid_cache_cell_size` | `32.0F` | Fixed 32-pixel cache footprint; O02 |
| `gi1_hash_grid_cache_min_cell_size` | `1e-1F` | `minimum_cell_size=0.1` |
| `gi1_hash_grid_cache_tile_cell_ratio` | `8` | Fixed 8; same default, no general tile-ratio control |
| `gi1_hash_grid_cache_num_buckets` | `14` | `cache_bucket_exponent=14` (2^14) |
| `gi1_hash_grid_cache_num_tiles_per_bucket` | `4` | Fixed 2^4=16; same default |
| `gi1_hash_grid_cache_max_sample_count` | `16.0F` | Fixed 16; same nominal cap, C03–C05 inputs differ |
| `gi1_hash_grid_cache_discard_multibounce_ray_probability` | `0.7F` | Complement of `continuation_probability=0.3`; random comparison differs, C04 |
| `gi1_hash_grid_cache_max_multibounce_sample_count` | `16.0F` | Fixed 16; same nominal cap, C03–C05 inputs differ |
| `gi1_hash_grid_cache_debug_mip_level` | `0` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_hash_grid_cache_debug_propagate` | `false` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_hash_grid_cache_debug_max_cell_decay` | `0` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_hash_grid_cache_debug_stats` | `false` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_hash_grid_cache_debug_max_bucket_overflow` | `64` | Missing corresponding AMD visualization/statistics/control; O03 |
| `gi1_reservoir_cache_cell_size` | `16.0F` | Fixed 16-pixel footprint; same default; L04–L05 |
| `gi1_glossy_reflections_halfres` | `true` | `reflections/half_resolution=true` |
| `gi1_glossy_reflections_denoiser_mode` | `1` | Default a-trous present; split mode absent; independent off mode absent; R06,O01 |
| `gi1_glossy_reflections_cleanup_fireflies` | `true` | `reflections/firefly_filter=true`; R05 |
| `gi1_glossy_reflections_low_roughness_threshold` | `0.2F` | `reflections/trace_roughness_threshold=0.2` |
| `gi1_glossy_reflections_high_roughness_threshold` | `0.6F` | `reflections/probe_roughness_threshold=0.6`; R01 |
| `gi1_glossy_reflections_atrous_pass_count` | `4` | `reflections/filter_passes=4` |
| `gi1_glossy_reflections_full_radius` | `11` | Split-estimator radii absent with estimator; O01 |
| `gi1_glossy_reflections_half_radius` | `11` | Split-estimator radii absent with estimator; O01 |
| `gi1_glossy_reflections_mark_fireflies_half_radius` | `3` | Fixed matching default selected by resolution; independent controls absent; R05–R06 |
| `gi1_glossy_reflections_mark_fireflies_full_radius` | `2` | Fixed matching default selected by resolution; independent controls absent; R05–R06 |
| `gi1_glossy_reflections_mark_fireflies_half_low_threshold` | `0.0F` | Single `reflections/firefly_low_threshold=0`; modes coupled |
| `gi1_glossy_reflections_mark_fireflies_full_low_threshold` | `0.0F` | Single `reflections/firefly_low_threshold=0`; modes coupled |
| `gi1_glossy_reflections_mark_fireflies_half_high_threshold` | `1.0F` | Single `reflections/firefly_high_threshold=1`; modes coupled |
| `gi1_glossy_reflections_mark_fireflies_full_high_threshold` | `1.0F` | Single `reflections/firefly_high_threshold=1`; modes coupled |
| `gi1_glossy_reflections_cleanup_fireflies_half_radius` | `2` | Fixed matching default selected by resolution; independent controls absent; R05–R06 |
| `gi1_glossy_reflections_cleanup_fireflies_full_radius` | `1` | Fixed matching default selected by resolution; independent controls absent; R05–R06 |

## Every dependency option

| AMD dependency option | Default | Fork disposition |
| --- | --- | --- |
| `ssgi_slice_count_` | `1` | SSGI stage and control absent (P09) |
| `ssgi_step_count_` | `2` | SSGI stage and control absent (P09) |
| `ssgi_view_radius_` | `0.2F` | SSGI stage and control absent (P09) |
| `ssgi_falloff_range_` | `0.05F` | SSGI stage and control absent (P09) |
| `ssgi_unroll_kernel_` | `false` | SSGI stage and control absent (P09) |
| `light_grid_stream_num_cells` | `16` | Fixed matching 16; bounds domain differs (L01) |
| `light_grid_stream_lights_per_cell` | `64` | Fixed matching 64 (L01) |
| `light_grid_stream_octahedron_sampling` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `light_grid_stream_resample` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `light_grid_stream_merge_type` | `1` | Only default mode 1, without replacement; modes 0/2 absent (L06) |
| `light_grid_stream_parallel_build` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `light_grid_stream_centroid_build` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `light_grid_stream_cell_overlap` | `false` | Nondefault mode absent; default false behavior only (L06) |
| `delta_light_enable` | `true` | Analytic lights included; no independent category-enable equivalent (L02) |
| `area_light_enable` | `true` | `emissive_sampling=true`; evaluation/cap differences (L03) |
| `environment_light_enable` | `true` | Native environment source/energy contract; proposal always reserved (L01,T05) |
| `environment_sampling_mode` | `static_cast<uint8_t>(EnvironmentSamplingMode::Uniform)` | Uniform implemented; cosine/importance modes absent (L06) |
| `low_emission_area_lights_disable` | `false` | No equivalent AMD low-emission culling option (L06) |
| `low_emission_threshold` | `1.0F` | No equivalent control; inactive upstream by default (L06) |

## Every Godot AMD GI setting

Prefix: `rendering/global_illumination/amd_gi/`. Defaults and declarations are captured verbatim in the machine-readable evidence. These rows also identify fork-only quality departures, not just upstream controls.

| Setting | Default | Disposition |
| --- | --- | --- |
| `enabled` | `false` | Required off gate; H03 |
| `probe_spacing` | `16` | 8/16/32 map to AMD compile-time one/quarter/sixteenth budgets; default 16 matches |
| `material_atlas_mb` | `128` | Fork-only material budget; T01,T04; unapproved quality/suppression behavior |
| `material_tile_size` | `8` | Fork-only coarse material representation; T01 |
| `material_adaptive_resolution` | `true` | Fork-only automatic material-detail reduction; T01 |
| `material_preparation_budget` | `64` | Fork-only native preparation scheduling/readiness; T04,H04 |
| `multibounce` | `true` | AMD default enabled; C04 |
| `screen_feedback` | `false` | AMD diffuse option default off; incorrectly also controls reflection reuse (R02) |
| `cache_all_hits` | `true` | True matches all-hit intent; false owner-only estimator is a departure (C03) |
| `cache_bucket_exponent` | `14` | AMD default 14; adjustable capacity (C02–C03) |
| `denoiser` | `true` | Global coupled diffuse/reflection switch; no independent reflection mode parity (R06) |
| `importance_sampling` | `true` | Default reference radiance guiding present with P06 differences; disable is a fork-only quality mode |
| `adaptive_sampling` | `true` | Default reference adaptive placement intent; P01,P08; disable is a fork-only quality mode |
| `probe_cache` | `true` | Default reference off-screen reuse intent; P08; disable is a fork-only quality mode |
| `light_resampling` | `false` | AMD optional world-space reuse, default off; L04–L05 |
| `reflections/enabled` | `true` | Requested independent feature toggle; disabled path must release its resources (H03) |
| `reflections/half_resolution` | `true` | AMD matching default true; R04–R05 |
| `reflections/trace_roughness_threshold` | `0.2` | AMD low threshold; default matches |
| `reflections/firefly_low_threshold` | `0.0` | AMD low thresholds collapsed to one control; default matches |
| `reflections/firefly_high_threshold` | `1.0` | AMD high thresholds collapsed to one control; default matches |
| `reflections/probe_roughness_threshold` | `0.6` | AMD high threshold; R01 fallback differs |
| `reflections/filter_passes` | `4` | AMD default four a-trous passes; R04–R06 |
| `reflections/firefly_filter` | `true` | AMD cleanup switch; R05 boundary differences |
| `reflections/ray_compaction` | `true` | Work scheduling toggle; prior equivalence regression, H02 |
| `emissive_sampling` | `true` | Area proposal category; default enabled; L03/T01 |
| `brdf_sampling` | `true` | Default reference BRDF guiding intent; disable is a fork-only quality mode |
| `minimum_cell_size` | `0.1` | AMD minimum cell size; default matches |
| `continuation_probability` | `0.3` | Complement of AMD discard probability; C04 |
| `max_distance` | `50.0` | Fork-only finite tracing/collection limit, default 50; T02 |

## Compile-time and alternate branch accounting

- `USE_INLINE_RT`: Vulkan inline path is the requested backend; DXR pipeline wrappers are excluded by API scope, not silently forgotten.
- `USE_MULTI_BOUNCE`: both enabled/disabled source paths are present; C04 covers remaining enabled-path differences.
- `USE_RESAMPLING`: default false and optional true are both compared; L04–L05 remain open.
- `DISABLE_SPECULAR_MATERIALS`, alpha and albedo disable controls: reference debug alternatives are not completely exposed/equivalent (O02). Their material packing differs too (L04).
- `DEBUG_HASH_CELLS`, `DEBUG_HASH_STATS`: reference visualizers/statistics are absent (O03).
- GI1 optional occlusion/near-field inputs: supplied in the default AMD renderer; absent here (P09).
- The dead `#if 0` alternative inside `NoDenoiserReflections` is not an active AMD algorithm requirement.
- Optional GridStream/environment modes are explicitly listed above. General library BRDF/sampling helpers not called by these paths are not additional GI1 stages.

## Evidence and reproducibility

`/workspace/gi-validation/amd-source-audit-2026-10-23/build_inventory.py` regenerates the inventories and checks source hashes without modifying renderer source. `write_coverage.py` generates this appendix from explicit, exhaustiveness-checked mappings. `checks.json` records the blue-noise/counter/algebra checks. Source hashes cover shared files that also contain non-GI routines; listing such a file is not a claim that unrelated renderer behavior was audited.
