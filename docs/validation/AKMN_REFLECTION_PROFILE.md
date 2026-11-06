# AKMN reflection cutoff on the RTX 5090

On 4 November 2026 the project used a roughness cutoff of 0.30. A cutoff of 0.45 sent more of the wooden handguard and nearby metal through AMD's direct glossy-ray path. The earlier yard motion comparison measured 92% less brightness fluctuation on the upper wood, 83% less on the adjacent metal and 44% less on the receiver cover.

## Performance

Times are milliseconds from the main viewport's renderer timestamps. Each cell gives the pooled median at 0.30 followed by the median at 0.45. GPU p95 is the 95th percentile of whole-viewport GPU time.

| Location and output | Internal resolution | Viewport GPU | AMD GI GPU | Viewport CPU | GPU p95 |
| --- | --- | ---: | ---: | ---: | ---: |
| Building Sandbox yard, 1280×720 | 640×360 | 2.054 → 2.062 | 1.156 → 1.163 | 0.905 → 0.926 | 2.543 → 2.555 |
| Building Sandbox yard, 2560×1440 | 1280×720 | 3.439 → 3.450 | 2.052 → 2.062 | 0.923 → 0.931 | 3.963 → 3.975 |
| Live World Crossroads, 2560×1440 | 1280×720 | 3.737 → 3.747 | 2.243 → 2.252 | 3.716 → 3.734 | 4.192 → 4.198 |

The test used Vulkan Forward+, DLSS Performance, full internal-resolution reflections, the original AKMN, grass off and the wall-fix editor (SHA256 `334ebee11dcd49313d7260e5e4ca4768ab4d11c5d311d6651255b1710b87c35d`). Crossroads reported 62 actors. Each condition had eight warmed laps in ABBA BAAB order and 172 distinct GPU frames per lap. All laps replayed the same 60 Hz movement and turn inputs. Sampled body and camera poses matched. The first sandbox lap had a longer warmup and a slightly different weapon idle phase. Excluding the first pair kept the median viewport GPU difference below 0.02 ms in all three conditions.

GPU timings use the root viewport begin/end markers and the AMD GI marker up to the following Screen Space Shadows marker. Image capture, the roughness counter and probe readbacks were disabled for timing. The difference between pooled medians is about 0.01 ms. Individual matched pairs varied, including some with a negative difference. Material coverage, ray hits, GPU clocks and hardware affect the result.

## Stationary 100-rifle pile

In a separate sandbox with a matte floor, sky and one directional light, 100 rigid bodies fell into a pile using shared convex collision proxies fitted to the AKMN. All 100 slept naturally for 60 consecutive physics ticks before timing. The renderer accepted all 6,400 rifle mesh parts and the floor. Body transforms stayed identical through all eight timing blocks at each resolution. The camera stayed fixed on the pile and DLSS Performance was active.

| Output | Internal resolution | Median viewport GPU, 0.30 → 0.45 | Difference | GPU p95, 0.30 → 0.45 |
|---|---|---:|---:|---:|
| 1280×720 | 640×360 | 1.6431 → 1.6546 ms | +0.0115 ms | 2.1251 → 2.1277 ms |
| 2560×1440 | 1280×720 | 3.2821 → 3.3565 ms | +0.0744 ms | 3.7893 → 3.8603 ms |

Each median pools 616 distinct timed frames per cutoff. At 1440p the four paired block differences ranged from +0.057 to +0.089 ms. At 720p the differences varied in sign. Two post-timing readbacks of the measured 1440p view put eligible pixels at 3.93% for 0.30 and 29.54% for 0.45, about 236,000 additional glossy rays per frame.

## What happened on the upper wood

A separate 48-frame shader readback at 0.30 tracked 8,896 interior upper-handguard samples in the yard. About 94% used probe reflections. Every one of those found a nearby probe. Approximately 84% retained essentially all interpolation weight after directional checks, and 5.8% retained at most 1%. The median measured roughness was 0.408.

For consecutive samples reprojected onto the same wood, with closely matching shading normals and at least 99% of probe weight accepted in both frames, median absolute raw luminance change was 0.023 when the dominant probe and angular cell stayed the same (321 pairs) and 0.114 when either changed (4,933 pairs). These are incoming radiance values before filtering. The comparison includes changes in sampled reflection direction. It measures the association with changing samples rather than assigning all variance to any one interpolation or denoising step.

The implementation stores light by direction in an 8×8 hemisphere per probe. A moderately rough finish still has a directional highlight. As nearby screen probes and sampled directions change, their estimates can differ appreciably across a small curved object. Tracing from the visible surface improves that estimate. Raising the cutoff replaces probe lookup work for the affected pixels, so the change in ray count alone cannot predict GPU time. [AMD's screen-probe interpolation shader](https://github.com/GPUOpen-LibrariesAndSDKs/Capsaicin/blob/914b91596cd119eda85fbc1d3c7ee6ac391b1452/src/core/src/render_techniques/gi1/gi1.comp#L1636-L1702)
