# B3 before/after GPU comparison — November 6, 2026

## 3440×1440, exact-fit scope crop

On updated build `cc4648aab03f0c7cb2fe3c6fc68bb8567dc8fe3a9d9b3493bed29a7277ee5d2b`,
the B3 viewport measured 8.315 ms at full native, 8.467 ms at full native with
blur and 3.763 ms with the native scope and blurred half-per-axis background.
All three modes used the same camera, grass off, AA off and 1.0 resolution scale.
Each had two 600-frame windows. Native with blur measured 8.471 and 8.466 ms,
and regional measured 3.735 and 3.775 ms. The active crop reported origin
(1336, 352) and size 736×896 with a 1720×720 background. Capture readback and
the overlay occurred after timing. Local evidence is `.artifacts/hybrid-pip/b3-edge-3440*`.

## Completed 1080p comparison and 720p repeat

On the updated build the regional path saved **0.859 ms at 1080p (22.7%)** and
**0.040 ms at 720p (2.1%)**. The native and regional paths used the same depth
blur within each build. Times are median GPU milliseconds for the 3D viewport.

| Resolution | Build | Native, no blur | Native with blur | Regional with blur | Saved by regional |
| --- | --- | ---: | ---: | ---: | ---: |
| 1280×720 | Before | 1.885 | 2.460 | 2.435 | 0.024 (1.0%) |
| 1280×720 | After | 1.881 | 1.927 | 1.887 | 0.040 (2.1%) |
| 1920×1080 | Before | 3.700 | 4.278 | 3.414 | 0.863 (20.2%) |
| 1920×1080 | After | 3.676 | 3.779 | 2.919 | 0.859 (22.7%) |

Savings use the unrounded medians. On the updated build, the two 1080p windows
gave 3.784 and 3.775 ms for native with blur and 2.921 and 2.918 ms for regional.
Paired in traversal order, regional saved 0.863 and 0.857 ms. The previous
build showed a similar 1080p saving. Separately, moving to the
updated build saved 0.499 ms for native with blur and 0.495 ms for regional.

The original 720p test ran the previous build first with Overwatch open. Each
resolution in this session ran the updated build first with Overwatch closed
at preflight and Game Director holding competing tests. The original and
reverse-order 720p runs gave 0.0404 and 0.0399 ms of regional savings on the
updated build, and 0.0223 and 0.0245 ms on the previous build. The original
0.274 ms improvement in plain native rendering shrank to 0.003 ms on repeat.
This comparison does not establish a substantial standalone GI speedup.

Each of the four new launches completed 4,800 unique timed frames, including
1,200 per mode across two counterbalanced windows. Manifests passed and recorded
the same binary hashes as the original 720p comparison. Resolution, GI readiness
and region status were checked at the window boundaries. At 1080p the native
crop was 720×832 and the background was 960×540. The normalized optic, FOV,
AA and scale settings matched the 720p run. Including overlap, the two regions
covered 53.9% of native pixel count at 1080p and 59.8% at 720p. The measurements
apply to B3 on the RTX 5090. Raw samples and manifests are in the four
`b3ab-{after,before}-benchmark-{1080,720}-r2*` artifacts. The earlier interrupted
1080p run was excluded. Per-run windows are in `blur-comparison/timings.json`.

## Original 720p session and blur captures

RTX 5090, Vulkan, Systems Sandbox fixed B3 camera, 1280×720, 35° FOV, scale
1.0, grass/AA/VRS/frame generation off. Same scene and external harness. Old
and updated native controls use their corresponding blur shaders. Regional
uses in-engine presentation; the native reference uses a compositor callback.
The region actually stayed active at the sampled boundaries: 640×360 background,
528×608 native crop. Each case had two 600-frame windows after 240 warm frames.
Viewport GPU timestamps only, no screenshots in timing runs.

| GPU frame time, median | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Native, no scope blur | 2.171 ms | 1.897 ms | 0.274 ms |
| Native with matching blur | 2.470 ms | 1.946 ms | 0.524 ms |
| Regional with blur | 2.447 ms | 1.905 ms | 0.542 ms |
| Prepared, ADS inactive, no blur | 2.194 ms | 1.909 ms | 0.285 ms |

After the fixes, regional saved 0.040 ms versus matching native blur; before,
0.022 ms. The native blur premium over plain native went from 0.298 to 0.048 ms.
These are differences of medians, not direct pass timings. Overwatch remained
open with ~20–21% background GPU utilization outside tests. One launch per
build, old first; the owner stopped testing before reversed-order repeats or a
matched 1080p comparison. Plain native also benefits from GI access changes,
so this does not isolate their contribution from cross-launch drift. Neither
the ~0.54 ms total improvement nor the small regional advantage is a clean-hardware
prediction. Do not use data from the interrupted 1080p launch as a comparison.

Reviewed separately captured full images, 2× details and three matched camera
movement frames in both modes. Scope aperture is sharp, nearby and far signs
retain similar blur width. Small bright peripheral lettering differs slightly;
widely spaced snapshots do not prove temporal equivalence. Independent renders
also differ with blur disabled, so image differences cannot all be attributed
to the blur.

Local artifacts: `.artifacts/hybrid-pip/blur-comparison/` (comparisons, image
metrics and per-window timings); `b3ab-{before,after}-benchmark-720-r1*` and
`b3ab-{before,after}-visual-720-v1*` (raw samples, PNGs, logs and successful
manifests). Before SHA-256 `17DFEF4FC8395D3A314BE76A4BBDC7363B2D13219A582CFD2A00292818781F1A`;
after `66A687C38A1B3ACEE87D95A47E84F1D3BB347994032DC211703D4D5ED918AB5D`.
