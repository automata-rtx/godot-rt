# GI access and scope blur optimizations — 2026-11-06

**Latest runtime evidence** covers the completed 720p and 1080p GPU comparisons
and the 720p blur captures. The build and setup notes below are historical.
[B3 performance and blur results](B3_GPU_COMPARISON.md)

**Earlier setup:** renderer permission was briefly granted, then withdrawn during
comparison setup. The updated D7114FFE build completed all 19 lifecycle stages
with zero failures/errors and process exit 0. The wrapper's false result reflects
an incorrect expected completion string; the actual completion marker and full
log are retained in `.artifacts/hybrid-pip/gpu-opt-lifecycle-run/`. No new GPU
comparison or accepted blur screenshots were obtained. A separate visual attempt
used the wrong binary while a rebuild was pending and exposed an external harness
API error; discard it. The harness was corrected but not rerun. Renderer launches
are now prohibited until renewed owner permission.

The updated source has been restored and rebuilt successfully; desktop shortcut
points to that latest editor. Current executable SHA-256:
`66A687C38A1B3ACEE87D95A47E84F1D3BB347994032DC211703D4D5ED918AB5D`.
The implementation/offline record below describes the original D7114FFE build.

Implemented after the [source audit](GPU_COST_AUDIT.md), with the owner's ban on
render runs still active. **No new GPU timings, rendered quality acceptance or
ADS runtime validation.** Historical timings in [RESULTS](RESULTS.md) describe
the previous dev8 build, not this candidate.

## GI dependencies

Shared world buffers now use read-only access declarations during probe
reprojection/selection/preparation and post-resolve screen consumers. Producer
stages retain conservative writable access. The previous radiance cache is
always read-only. Reflection tracing retains writable cache keys because it
refreshes tile lifetime; its radiance-cache access remains read-only.

Writer function definitions are gated, with declarations retained. A future
read-only variant that actually reaches a writer must fail shader linking.
GI dispatch order, true producer barriers, ray budgets, random numbers,
estimators, cache aging and history algorithms were not changed. Unused
descriptor bindings remain present, now read-only during consumer phases;
this does not claim every possible false dependency has been removed.

Source review confirmed that descriptor reuse is per pass and cleared on shader
version changes. The ordinary cache keys include the shader RID, and RD uniform
format comparison includes writable access, preserving these distinctions.

Offline verification compared all 117 normal/regional variants against their
saved pre-change SPIR-V. **Every non-name/non-decoration instruction, including
its IDs and operands, is identical.** Existing decorations are retained; the
only added decoration is `NonWritable`. Explicit access checks cover 58
consumer variants and the reflection-key exception. These checks use the same
offline material stubs as previous validation, not every generated game material.

## Presentation

- Replaced 96 native-image blur taps with 16 taps over a prepared color mip
  pyramid. At 720p, the pyramid contains full, half and quarter levels.
- Kept the depth curve, aperture feather and near/far radius settings. Clear
  aperture pixels use the sharp base image. LOD blends continuously; sample
  radius compensates for the pyramid's added variance.
- Four-point radial quadrature with fourfold angular symmetry gives zero
  centroid and equal horizontal/vertical spread. An earlier opposite-pair
  sampling draft was rejected numerically for anisotropy before completion.
- The normalized kernel's per-axis variance is 0.169697 versus the old kernel's
  mean-axis 0.169703 (under 0.004% difference). Radius-compensation checks cover
  small/large radii and mip transitions. This does not prove equal bokeh,
  high-frequency rejection, odd-size footprints or motion appearance.
- Blur writes directly into the parent HDR target, removing the full-screen
  copy and separate blurred-color allocation. Expected texture reduction at
  1280×720 is 5,068,800 bytes, before other allocation changes; not a measured
  VRAM result. Native 1:1 protected composition uses an exact texel fetch.
- Mip views and pipelines are prepared in advance. Distinct compute lists
  avoid restoring incompatible push constants between composition, the
  zero-push-constant downsampler and blur. RD retains resource dependencies.

This is not a sixfold frame-time claim: trilinear sampling can touch two mip
levels, building the pyramid has a cost, and unrelated rendering is unchanged.

## Offline checks and delivery

- 58 native + 59 regional GI shaders compiled. Composition, blur, downsampling
  and four Forward+ shader variants compiled offline.
- [Verification script](check_gpu_optimizations.py): executable SPIR-V equality,
  writable-access exceptions and numerical kernel/variance tests passed;
  [machine-readable results](gpu_optimization_checks.json).
- Windows optimized MSVC editor with development warnings-as-errors built.
  Desktop shortcut verified against the newly built `bin/` editor; the Actions
  folder was not changed. This editor has **not been launched**.
- Editor SHA-256:
  `D7114FFE8843B93CB29A092E2645FA7567653DECDEB49E1347ED13430CF95EE1`.
- All three affected release-template objects compiled with development warnings
  treated as errors (`.artifacts/hybrid-pip/template-gpu-opt.log`); no packaged
  export test claimed.
- Local build/source evidence: `.artifacts/hybrid-pip/build-gpu-opt-final.log`,
  `gpu-opt-shader-check.log`, `gpu-opt-baseline/`, `gi-shader-check/`,
  `shader-check/`. These ignored files are not distributed with a clone.
- External native-blur benchmark reference was updated to the same pyramid,
  kernel and direct output. It has not been parsed or executed by Godot.

When render runs are authorized, verify the existing lifecycle fixture including
odd resize, blur toggles and independent views; inspect scope edges, small
highlights, sharp aperture and motion; then measure against a matched native-blur
control. Keep visual and timing runs separate. The feature remains experimental
and off by default. Do not reuse old blur timings as candidate results.
