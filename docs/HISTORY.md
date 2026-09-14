# History: what was measured, what the numbers refused

Every measurement this fork rests on, every idea tried and refused, every published figure later
superseded or retracted. Read it before re-attempting anything that looks obvious from the code
alone — several of these already were, and failed. Not here: using a feature (`docs/features/`), how
one works (`docs/internals/`), running the harnesses (`docs/VALIDATION.md`), diagnosing a symptom
(`docs/TROUBLESHOOTING.md`).

## Provenance tags

Every number carries one; a number with no tag is an opinion and does not belong in this file.

| Tag | Means |
| --- | --- |
| `[shadow_validation]` | Rendered under Xvfb + lavapipe by `docs/validation/shadow_validation/`, scored in linear light. |
| `[ao_validation]` | Same, by `docs/validation/ao_validation/`. |
| `[denoiser_sim]` | **Simulated**, not rendered — `docs/validation/shadow_validation/denoiser_sim.py`, a numpy reimplementation of `rt_shadow_temporal.glsl`. |
| `[gtao_sim]` | CPU model of the occlusion gather, `docs/validation/ao_validation/gtao_sim.py`. Reproduces the engine to within 0.001 MAE every time it has been checked. |
| `[profiler]` | Editor Visual Profiler, on the named hardware. |
| `[framerate]` | Whole-frame framerates from one shot. Retired as a method; see the occlusion cost entry. |
| `[game]` | Observed in a game on the owner's machine. No rig here can produce it. |
| `[arithmetic]` | Derived from shipped constants. Not a run. |
| `[code]` | Read from the source, not measured. |
| `[unreproducible]` | Recorded as measured, but no committed harness implements the scorer. |

All four `denoiser_sim.py` modes (no flag, `--kernels`, `--radius`, `--window`) were re-run against
this document; every figure below matches what the script prints.

---

# Ambient occlusion

## Refuted

| Idea | What the numbers said | Tag |
| --- | --- | --- |
| **Widening the occlusion denoise unconditionally** | Already sized from the effect radius and the slice count. A 7x7 reconstruction gains 3% at silhouettes (0.03984 against 0.04095) for five times the taps — at a reduced rate the problem is missing samples, not too few candidates. | `[unreproducible]` |
| **Replacing the occlusion dither** | The slice offset is already interleaved gradient noise, optimal over a 3x3 by construction, and the residual is already blue: autocorrelation -0.41 at one pixel, zero by four. Tiled, stratified and blue-noise-pair alternatives all measured within a few percent. | `[ao_validation]` |
| **A 4x4 tiled dither, which looks smoother** | Deviates **2.3x** further from the resolved signal, because a fixed pattern imprints structure a weighted filter cannot remove. A tile wider than the filter is worse than white noise: a repeating pattern reads as structure, noise as film grain. | `[ao_validation]` |
| **Rebalancing `slices` against `steps_per_slice`** | At a large radius, doubling `steps_per_slice` changes grain by nothing measurable (0.00690 -> 0.00696), while the same 64 taps split 8x4 instead of 4x8 is 18% smoother and **35% less accurate** against a ray trace (0.0983 against 0.0726). Steps buy accuracy, slices buy smoothness, and the grain metric cannot see the half it is not measuring. Split stays 4x8. | `[ao_validation]` |
| **A-trous multi-pass filtering for occlusion** | Three passes reach lower grain than two and a worse deviation from the true signal (0.0076 against 0.0059) — smoothness bought by removing contact detail. | `[ao_validation]` |
| **Adopting the legacy estimator's composition order with its `shadow_clamp`** | Moves the mean by 0.008 and still leaves 3% of the frame below 0.05, because a plateau at 0.003 reads as black on screen. Tidiness, not a fix. | `[ao_validation]` |
| **Moving the strength remap out of the gather into the upsample** | A no-op for grain, and it *increased* the count of exactly-black pixels — averaging already-clamped values was the only thing lifting them off zero. | `[ao_validation]` |
| **Removing `ssao/ground_truth/intensity_scale` because its only correct value is its default** | Declined on judgment. Derived constant: `0.5` puts the shipped `Environment.ssao_intensity` default of `2.0` at exactly `1.0`, the identity of the strength curve. Removing it doubles occlusion in every existing scene, and `docs/validation/ao_validation/main.gd` reads it back and solves for the value that cancels it — so the harness would keep scoring at the old strength while the game got darker. | `[code]` |

## Superseded

### The framerate derivation of occlusion cost — retired, kept so the failure mode stays on record

| Measurement | What it gave |
| --- | --- |
| **1. `[framerate]` — refuted.** One shot on an RTX 5090: quarter resolution around 620 fps, full resolution mid-to-low 500s, (less confidently) over 1000 with the effect off. | Robust figure: full resolution costing **+0.27 to +0.33 ms** over quarter. Solving `quarter = F + G/4` and `full = F + G` gave a full-resolution gather `G` around 0.37 ms and a fixed cost `F` of 0.4 to 0.7 ms — **40 to 65% fixed**. Two conclusions drawn, both wrong: that full resolution is simply affordable on desktop, and that on weak hardware the resolution knob can only address the smaller half of the cost. |
| **2. `[profiler]` — the three-rung solve, which refutes it outright.** Same RTX 5090, same camera, 3440x1440, occlusion the only variable; the three rung costs and the ~9% headline are in `docs/features/ambient-occlusion.md`. | Three points against two unknowns, so the model is over-determined and checks against itself (table below). The code agrees `[code]`: the gather derives its reach and its 64 samples from the full resolution footprint whatever the rate, so per-shaded-pixel work does not vary, and both denoise passes dispatch at the gather's own size. Only the depth pyramid and the upsample are fixed, and both are streaming passes moving on the order of ninety megabytes. |
| **3. `[profiler]` — the direct desktop capture, which superseded it.** Same RTX 5090, Visual Profiler rather than framerates, 3440x1440 full screen at `scaling_3d/scale` 1.0 (4.95 Mpx), all default except occlusion at FULL resolution, dozens of raytraced shadow-casting lights. | Figures in `docs/features/ambient-occlusion.md`; the two 1.12 ms entries there coinciding is a coincidence. |

| pair | G | F | fixed share |
| --- | --- | --- | --- |
| quarter, checkerboard | 1.040 | 0.090 | 8% |
| quarter, every pixel | 1.013 | 0.097 | 9% |
| checkerboard, every pixel | 1.000 | 0.110 | 10% |

Agreement within four percent; the mean solve predicts all three measurements to within 0.01 ms.
**The sweep's 1.11 ms and this capture's 1.12 ms are two different measurements in two different
scenes**, agreeing to within a hundredth of a millisecond. Do not merge them.

**Why the derivation failed, and the general rule:** it subtracted three whole-frame framerates, one
of them the least certain reading of the three, and a small error in a large subtrahend became a
large error in a small difference. Its RATIO prediction survived — quarter at roughly two thirds of
full, which against a 1.12 ms full block puts quarter near 0.75 and the gap near 0.37 against the
0.3 it claimed. Its SPLIT into fixed and variable did not. **A pass that can be measured directly
must never be inferred from frame totals.** To re-derive the split with no code change and no
restart, read `Process GTAO` with `half_size` on and then off; the two solve formulas, which pair
applies at which shading rate, and the discard-the-first-frame caveat are in `docs/VALIDATION.md`.

### "93% of the grain is structure"

Measured at the small radius the effect first shipped with; does not generalize. At that radius only
**31%** of visible grain is removable by dithering at all; at a large radius that inverts and
**70%** is dither-removable — why a wider filter helps far more at a large radius. `[ao_validation]`

## Measured

### Three defects a traced reference found, none of which looked like bugs

All steady biases that read as the effect working. `[ao_validation]` + `[gtao_sim]`

| Defect | Mechanism, and what it cost |
| --- | --- |
| **The sector weights had no Jacobian** | Each of 32 sectors was worth its share of the arc. Sweeping a slice about the view direction turns each sector into a ring whose circumference goes with the sine of the angle from that axis, so a sector pointing back at the camera sweeps almost no solid angle and one at the edge of the arc sweeps the most. The two sectors either side of the normal were counted about **ten times** too heavily. `cos(t - n)*\|sin t\|` integrates in closed form, so the weights are now evaluated outright. |
| **The march read a nearest sampler and reconstructed somewhere else** | The depth returned describes the middle of whichever texel the step landed in, not the point the step asked for. Pairing that depth with the asked-for direction put every sample off its own surface by up to half a texel of depth slope; on a plane at a glancing angle half of those land above the shaded point. The floor occluded itself by a flat **three percent** everywhere. |
| **Steps were spaced quadratically** | A horizon march can crowd steps near the shaded point because one early hit stands in for everything behind it. A mask cannot: an occluder between two steps is absent, not approximated. Spreading the same eight steps evenly roughly **halved** the error. |

| **The non-bitmask path had the horizon inverted** | Closing the arc between the outermost occluders instead of outside the innermost ones. **0.63** too dark, unusable as the toggle it is meant to be. |
| **The slice basis was probed with a UV-sized step while the march walks in pixels** | So on any non-square viewport every elevation was measured against an axis the samples did not lie on. |

### The strength curve, which looked like an estimator failure and was not

First version: `pow(v, power)` then `1 - (1 - v)*intensity`. Hard floor — at the stock intensity of
2.0, every visibility at or below **0.63**, roughly what an ordinary concave corner *is*, lands on
exactly zero; in an interior, 3% of the frame on one flat black value, inside the gather, before any
filter saw it. Settled in one step by putting a **flawless ray-traced occlusion** through the same
curve: the artifact survived, **6.97%** of a perfect frame going black. `[ao_validation]`

| | mean absolute error | frame driven to black |
| --- | --- | --- |
| raw estimator, interior scene | 0.0104 | 0.00% |
| through the old curve at shipped knobs | 0.0500 | 3.20% |
| through the ratio curve at the same knobs | 0.0152 | 0.00% |

Correlation barely moved (0.939 -> 0.940): the estimator was always right about *where* occlusion
belongs, the curve destroying *how much*. **If occlusion ever looks crushed and speckled, suspect
the transfer before the estimator** — put a traced reference through the same curve and see whether
the artifact survives.

### What did work for the denoise

Real renders of an interior at the radius a real scene wants. `[ao_validation]`

| | grain | mean absolute error |
| --- | --- | --- |
| one 3x3 pass, relative-depth weights | 0.00356 | 0.0705 |
| separable two-pass, width from the radius, plane-distance weights | 0.00193 | 0.0701 |

Error moved slightly the right way, so this is not smoothness bought by blurring the signal away.
**About half the improvement came from the plane-distance weight rather than the extra width** — a
relative-depth test has no notion of orientation, so on a surface at a glancing angle it discards
neighbors lying on that very surface while keeping neighbors across a shallow step that is a real
silhouette.

### Shading a checkerboard beats shading a coarser grid

> **Standing caveat, covering both tables below.** An audit found that **nothing committed in
> `docs/validation/ao_validation/` implements the checkerboard packing, either filter pass, the
> reconstruction, the silhouette mask, or the exhaustive bijection check** — `gtao_sim.py` models
> the gather only. The one place here that breaks the rule the rest keeps: recorded as measured and
> **not** retracted, but unverified until the scorer is committed, and not to be cited as the
> harness's output. Closing it means committing the reconstruction scorer and the bijection check,
> or extending `gtao_sim.py` to cover both filter passes. `[unreproducible]`

`half_size` halves each dimension, so it evaluates a QUARTER of the pixels, not half; a checkerboard
at full resolution evaluates half. Not only the count differs: a reconstructed pixel's neighbors are
one pixel away rather than two, and both it and they have their own full resolution depth and
normal. Reconstruction error against a fully shaded frame, interior scene, at the radius a real
scene wants, on a **prototype**: `[unreproducible]`

| scheme | shaded | overall | at silhouettes |
| --- | --- | --- | --- |
| quarter resolution grid, 2x2 reconstruction (what shipped then) | 25% | 0.01745 | 0.04095 |
| quarter resolution grid, 7x7 reconstruction | 25% | 0.01488 | 0.03984 |
| checkerboard at full resolution, 4 neighbors | 50% | 0.01238 | 0.02724 |
| checkerboard at full resolution, 12 neighbors | 50% | 0.01238 | 0.02724 |

- Widening the reconstruction at quarter resolution gains 3% at silhouettes for five times the taps,
  refuting the idea that the 2x2 is simply too narrow — **no sample was ever taken near the edge,
  and a filter cannot invent one**.
- A checkerboard's reconstruction is COMPLETE at four taps: twelve changes nothing to five decimal
  places, every unshaded pixel already having all four immediate neighbors shaded. No tuning surface
  there to get wrong.

Re-scored against the mapping and reconstruction the **shipped shaders** run — packed texel `(u, y)`
holds pixel `(2u + (y & 1), y)`, shaded pixels copied through untouched, the rest averaged from four
neighbors with the same plane weights — interior scene, shipped defaults, against a fully shaded
frame: `[unreproducible]`

| scheme | overall | at silhouettes |
| --- | --- | --- |
| quarter resolution grid, 2x2 reconstruction | 0.00713 | 0.02472 |
| checkerboard, 4 neighbors | 0.00502 | 0.01180 |

- Overall **29.6% better**, against the prototype's 29% — close enough to say the shipped arithmetic
  is the arithmetic that was scored. Use the overall column to cross-check the two runs.
- The silhouette figure is **not** comparable to the prototype's 33%: the mask here is "any pixel
  whose 3x3 neighborhood spans more than five percent of its own depth", this scorer's own
  definition, selecting 1.0% of the frame. Use that column only within this one run.
- Mapping checked **exhaustively**, not by sampling: for every width to 129 and height to 69, packed
  texels and shaded pixels are in bijection, every unshaded pixel's on-screen neighbors are shaded
  and map into range, and exactly half the pixels are shaded. Only waste: one texel per odd row of
  an odd-width buffer, which the gather clamps and nothing reads.
- Cost is real — twice the gather of quarter resolution — and it wants the checkerboard packed into
  a half-width buffer, because dispatching full resolution threads and exiting half of them spends
  the saving on wave divergence.
- **Quality verdict** `[profiler]`: checkerboard indistinguishable from shading every pixel, quarter
  resolution grid noticeably worse but acceptable. The top rung costs 0.50 ms more than the middle
  for nothing visible, so the default moved to the middle rung.

### What the synthetic scenes missed

Both original scenes are viewed from outside and above, over one large flat floor with open sky in
every direction, so a *correct* occlusion barely enters the range the output transfer operates on.
`[ao_validation]`

| scene | mean traced visibility | fraction of frame below 0.63 |
| --- | --- | --- |
| solid boxes | 0.9909 | 0.73% |
| thin geometry | 0.9943 | 0.27% |
| interior room | 0.9336 | 6.97% |

A ten-to-twenty-five-fold coverage gap — why four independent symptoms passed validation twice. Both
were also square, so no aspect-dependent defect could appear, and the effect radius under
`scale_radius_with_distance` was anchored to screen **width**, making it 1.8x larger on a 16:9
viewport than on the square one everything was tuned against. The `room` scene closes both gaps and
is deliberately 1280x720. The first real interior the effect was pointed at wanted a `screen_radius`
around **0.25** and ran out of slider before it `[game]` — why the default moved to 0.1 and the
range reaches 0.5.

### `ssao_radius` was scaling half of the march

Under `scale_radius_with_distance` the gather derives two quantities from `screen_radius`: how many
pixels the march walks, and the world distance that walk corresponds to, which is what the sample
cutoff and the back-face thickness are measured against. `Environment.ssao_radius` multiplied only
the second, so the march walked the same span on screen whatever the radius was set to. Above 1.0
the cutoff moved somewhere the steps never reached, leaving thickness as the only thing that
changed; below it the cutoff truncated the march while the steps stayed spread over the full span.
Both read as the setting working, because thickness alone does move the picture. Mean occlusion
against `ssao_radius`, interior scene: `[ao_validation]`

| `ssao_radius` | before | after |
| --- | --- | --- |
| 0.5 | 0.0236 | 0.0318 |
| 1.0 | 0.0605 | 0.0605 |
| 2.0 | 0.0771 | 0.1151 |

Doubling the radius used to buy 28% more occlusion, all of it thickness; it now buys 91%, what
doubling the reach should give. The default is 1.0, so the two agree exactly there and no existing
scene changes. **What caught it was three descriptions of one setting:** the guide, the class
reference and `filter_radius_for()` all said the radius multiplies the on-screen reach, and only the
shader disagreed. A comment audit found a code defect rather than a documentation defect — the
argument for auditing comments against the code rather than tidying them.

### Four more measured results

| Result | Detail | Tag |
| --- | --- | --- |
| **Why `ssao_intensity`'s 2.0 default is wrong for this estimator** | A legacy calibration constant. ASSAO's obscurance is a distance-weighted proximity average over a screen disk, not a visibility integral, and on the same geometry measures roughly **a fifth** of the real deficit — the 2.0 multiplies that back up. This estimator reports the deficit directly, so the same number doubles a figure already right. Hence `intensity_scale`, rather than changing the `Environment` default the legacy path still needs. | `[ao_validation]` |
| **Half resolution was misregistered by half a pixel** | The gather evaluates full-resolution pixel `k*stride`; the upsample computed `(pos + 0.5)*scale - 0.5`, which assumes texel `k` sits at the *center* of its block. Cross-correlating a half-resolution render against a full-resolution one put their best alignment at exactly **(-0.5, -0.5)**, matching the arithmetic. Separately, the upsample's bilateral guide was the nearest gather texel's depth, quantizing every silhouette to the coarse grid — **that, not the reduced sample count, was most of why half resolution read as low resolution rather than merely soft**. | `[ao_validation]` |
| **The CPU model was measuring a differently oriented estimator on any non-square scene** | `gtao_sim.py` probes the slice basis by stepping off the shaded point and reading where that lands in view space. The shader steps eight **pixels**; the model stepped a fixed 0.01 of UV. On the two square 720x720 scenes those are the same direction and the model was exact; on the 1280x720 interior they are not — at a slice azimuth of 45 degrees the two bases differ by about **15 degrees**, so every room-scene number the model produced scored an estimator rotated slightly away from the one that ships. It moved the numbers by **less than 0.0002**, which is why nothing caught it: the estimator is close to isotropic, so re-orienting its slices barely changes the mean. All model figures above are the corrected model. Lesson: a model agreeing with the engine to three decimal places can still be wrong in a way that would matter on a scene that was not nearly isotropic, and the only defense is checking it clause by clause against the shader rather than by how well the totals agree. | `[gtao_sim]` |
| **A second hardware data point, which needed no special explanation once the share came down** | The Radeon 780M capture — `Process GTAO` as a share of the frame beside the raytraced shadow block, and the caution to read it as a ratio and not a budget — is in `docs/features/ambient-occlusion.md`. Recorded here because it is what first made the desktop share look untransplantable: if the fixed part really were dominated by full resolution bandwidth, a part with a small fraction of a 5090's bandwidth could not fit all five dispatches into that time at a comparable pixel count. It stopped needing an explanation once the fixed share came down to nine percent. | `[profiler]` |

---

# Raytraced shadows

## Refuted

| Idea | What the numbers said | Tag |
| --- | --- | --- |
| **Early-outing the trace on a pair of agreeing probe rays** | Two rays at opposite points on the emitter's rim, stopping when they agree. No pair of points answers for a disk: where a fifth of the emitter is covered the two rim probes still agree about a third of the time, and the binary answer pulls that pixel to fully lit; same on the umbra side. Against a closed-form reference it returned **72% of the true penumbra width at sixteen samples per light** — a shadow that *hardens* as the sample count rises. Removed rather than tuned; removal cost nothing at the shipped default of one sample, which never reached the early-out. A cheaper path has to know the penumbra is not there before it stops, and that cannot come from the rays it is trying to avoid. | `[shadow_validation]` |
| **Averaging shadow visibility in sqrt space** | The mask stores a square root for precision, but filtering the roots and squaring darkens every penumbra by Jensen's inequality. Encode and decode bracket the storage only. | `[code]` |
| **Feeding the a-trous result back into the temporal history** | Compounds without bound: a two pixel kernel becomes a twenty pixel smear and contact hardening is the first thing lost. The history stores the accumulation, never the filtered output. | `[code]` |
| **Widening the clamp's moment gather unconditionally** | First shipped unconditional because the widening was scored in the penumbra *interior*. Its cost is at the **shoulder**: twenty-five taps straddle the step into the flat region and the clamp pins the pixel to what they averaged across it. See the 3x3/5x5 table below; the gate that shipped instead is `sample_count < 4.0 && clamp_sigma <= 1.0` (`rt_shadow_temporal.glsl:247`). | `[denoiser_sim]` |
| **Weighted 5x5 kernels** | They sit ON the same tradeoff line rather than beating it — less noise reduction bought with proportionally less shoulder bias. Table below. | `[denoiser_sim]` |
| **Choosing the gather width per pixel at one ray per light** | Half the taps deterministically 0 and half deterministically 1 has *exactly* the variance of every tap being an independent `p = 0.5` draw, so the decomposition subtracts all of it and reports no structure. Meanwhile the difference between the 3x3 and 5x5 means has a standard deviation of **0.133** — larger than the shoulder signal it would have to detect. The 3x3 mean is contained in the 5x5 one, so the variance of their difference is the difference of their variances, `0.25 * (1/9 - 1/25)`. | `[arithmetic]` |
| **Widening a freshly disoccluded pixel to `MAX_PENUMBRA_PIXELS`** | A pixel whose history was just thrown away has one ray to go on and does need widening, but widening to the maximum outright smeared a contact shadow whose true penumbra is a fifth of a pixel across thirty-one of them — the exact mistake the penumbra estimate exists to prevent, made one line after it was computed. The widening is now bounded by a multiple of the measured penumbra as well. | `[shadow_validation]` |
| **Shortening the history-fill decay** | Spreading it over a few frames rather than the whole accumulation window made freshly disoccluded pixels visibly grainy: at one sample per light the noise it hides outlives the first handful of frames. | `[shadow_validation]` |
| **Pinning a Vogel sample to the center of its radial stratum** | With a fixed 0.5 the single ray of the shipped default sits at `sqrt(0.5)` of the emitter's radius every frame and only the angle moves, so the temporal average converges on the shadow of a **ring at 0.707r**. The 10-90 width barely suffers — a ring at 0.707r spans nearly the width of the disk containing it — but the falloff comes out S-shaped, because a ring's projection piles up at its two extremes where a disk's bulges in the middle. Jittering the radius inside the stratum fixes it and is the better estimator at higher counts too. | `[shadow_validation]` |
| **Scaling the ray-origin normal offset by camera distance instead of light distance** | Declined on judgment. The reasoning is sound — the offset covers depth-reconstruction error, which scales with the camera — but the arithmetic does not reach a pixel at any reachable bias. Comment fix at most. | `[arithmetic]` |
| **Treating the 128-lights-per-tile overflow as a denoiser-history problem** | The claim that the surviving set is re-rolled every frame was *asserted rather than measured*, and sits awkwardly beside this harness being byte-for-byte deterministic. Measure it before acting on it. The ceiling itself is in `docs/features/rt-shadows.md`. | `[code]` |

Weighted kernels, at `clamp_sigma` 0.3, samples 1, temporal 32 (`denoiser_sim.py --kernels`). The
box is the far end of a curve, not a bad point on it. `[denoiser_sim]`

| kernel | effective taps | flat noise | 2 px bias | |
| --- | --- | --- | --- | --- |
| 3x3 box | 9.0 | 0.1972 | 0.1499 | |
| 5x5 box | 25.0 | 0.1224 | 0.2796 | 0.62x noise for 1.86x bias |
| 5x5 tent (1,2,3,2,1) | 18.2 | 0.1615 | 0.2040 | 0.82x noise for 1.36x bias |
| 5x5 binomial (1,4,6,4,1) | 13.4 | 0.1853 | 0.1707 | 0.94x noise for 1.14x bias |

## Superseded

### The tight clamp's contrast expansion — retracted; the two settings are no longer coupled

Old guidance: `history_clamp_sigma` and `temporal_frames` were coupled, a tight clamp only safe with
a short window, so raising the frame count meant raising sigma with it. It cited a true
0.25/0.50/0.75 penumbra reading **0.15/0.49/0.85** at sigma 1.0 over 32 frames and
**0.19/0.50/0.82** at 12.

**Those figures came from the estimator that shipped BEFORE the variance decomposition, and the
mechanism behind them is gone.** That estimator floored the window at the uncertainty in the mean
alone, so wherever the nine binary taps happened to agree — at a true visibility of 0.25 and one ray
per light, all nine come back blocked on the same frame about once in thirteen — the window
collapsed to that floor and yanked a correct history to the binary answer, nothing pulling the other
way. The decomposed window carries the per-tap binomial term as a subtraction rather than the raw
spread as a total, and no longer collapses where the taps agree.

`denoiser_sim.py --window` re-runs it on 8, 16 and 32 pixel penumbrae at `clamp_sigma` 2.0, 1.0 and
0.3, over both 32 and 12 frame windows. **Every converged value lands within 0.05 of the truth and
most within 0.02, and the deviation does not grow as the clamp tightens or the window lengthens** —
the largest, 0.55 for a true 0.50 on the 16 px penumbra, is at the LOOSEST setting of both. No
contrast expansion left to warn about. `[denoiser_sim]`

### Three more superseded claims

| Old claim | Correction |
| --- | --- |
| "Reach for `lag_response` first against ghosting" | Reasoned from the code and wrong. At the shipped `samples_per_light = 1` the clamp could not fire at all, so `history_clamp_sigma` narrowed a window nothing was ever tested against and `lag_response` scaled a term that was zero. Both were **inert**. Current answer: `history_clamp_sigma` first; see the decomposition below. `[game]` |
| "`min_filter_pixels`: too soft at contact? lower it" | Answered only the opposite question, for a value the inspector will not produce — the hint range starts at 1.0 and anything below renders identically. Correcting it produced a **worse** error in an intermediate draft, selling *raising* it as a free lever for a noisy contact shadow. It is not free: it fringes every contact edge, and the ladder of what a step edge reads at each value is in `docs/features/rt-shadows.md`. |
| `denoiser_sim.py`'s own scope | It omits the a-trous pass on the grounds that a contact shadow early-outs of every pass. True at the shipped `min_filter_pixels` of 1.0 and **false at 2.0**. Its tables describe the default, not a project that has raised it. `[code]` |

## Measured

### The history clamp could not fire at one ray per light

From a first-person weapon in a game, not from a harness — no rig here measures temporal behavior
(`docs/VALIDATION.md` has that blind spot and the other one). `[game]`

- **The variance clamp is the only defense against a shadow sliding across a receiver that did not
  move**: there the reprojection is exact, the depth test passes, nothing else rejects the stale
  tap.
- **At `samples_per_light = 1` the clamp could not fire.** Its window was built from the raw spread
  of the 3x3 neighborhood of the traced visibility, so all nine taps are binary. With 2 of 9 blocked
  that spread is **0.416**, and two sigma either side of the tap mean at the shipped
  `history_clamp_sigma` of 2.0 is **`[-0.05, 1.61]`** — wider than the whole valid range. Nine
  binary samples genuinely cannot separate "penumbra at 0.5" from "this shadow moved".
- `samples_per_light = 4` with `temporal_frames = 12` took the same shadow from badly smeared to
  acceptable. Brute force: raising the count does not improve the estimator, it makes each tap an
  average and starves the noise term holding the window open.

### The variance decomposition that fixed it

The spread of those nine taps is two quantities added together, wanting opposite treatment: the
penumbra genuinely varying across them, which the clamp must not flatten, and the binomial scatter
of each tap being a count of blocked rays, which says nothing about the shadow. At one ray per light
a tap is a hard 0 or 1, so that scatter is `sqrt(p(1-p))` — 0.5 in mid-penumbra — and **it does not
shrink however many taps are averaged**, being the spread of a Bernoulli draw and not an uncertainty
in a mean. Charging it to the radius held the window wider than the valid range; it is predictable,
so it is now subtracted.

Two-sigma clamp window in mid-penumbra, 3x3 gather (`denoiser_sim.py --radius`): `[denoiser_sim]`

| `samples_per_light` | raw spread (old) | decomposed (shipped) |
| --- | --- | --- |
| 1 | 0.93 | 0.27 |
| 2 | 0.65 | 0.28 |
| 4 | 0.46 | 0.21 |
| 8 | 0.32 | 0.15 |

**The decomposed window at ONE sample is tighter than the raw one was at eight.** Confirmed on the
owner's machine rather than in a rig: tightening `history_clamp_sigma` to 0.3 at one sample almost
removed a first-person weapon's ghosting, for slightly more noise — `docs/features/rt-shadows.md`.
`[game]`

**Residual, expected and not removable:** strafing is consistently worse than turning, because
turning pivots a camera-attached object about the camera while strafing translates it through the
world, and a fixed camera angle keeps history long exactly where the shadow is sliding. Bounding it
is what the clamp does; removing it is not something a temporal filter can do.

### The 3x3 versus 5x5 moment gather

**Why it only became worth arguing about after the decomposition:** while the radius came from the
raw spread of these same taps, a wider gather inflated the window as much as it improved the center
and the two canceled. With the clamp centered on a mean it trusts, once the window is tight the
accumulated value essentially IS that mean, so both the mean's noise and its bias reach the screen.
A tap mean's standard error is `sqrt(p(1-p)/n)`: twenty-five binary taps carry **0.100** in
mid-penumbra where nine carry **0.167**. `[arithmetic]`

`python3 docs/validation/shadow_validation/denoiser_sim.py` reprints this whole table. Simulated,
not rendered: samples_per_light 1, temporal_frames 32, lag_response 1.0, static camera, temporal
pass only, binary taps, sqrt-encoded 8-bit storage, dithered store (without which a bias figure
reads the accumulator's ratchet rather than the filter). `[denoiser_sim]`

| scene | `clamp_sigma` | metric | 3x3 | 5x5 | ratio |
| --- | --- | --- | --- | --- | --- |
| flat p = 0.5 | 2.0 | noise | 0.1029 | 0.0628 | 0.61 |
| flat p = 0.5 | 0.3 | noise | 0.1972 | 0.1224 | 0.62 |
| 32 px penumbra | 2.0 | noise | 0.0434 | 0.0293 | 0.68 |
| 32 px penumbra | 0.3 | noise | 0.0932 | 0.0578 | 0.62 |
| 2 px penumbra | 2.0 | peak bias | 0.0576 | 0.1878 | 3.26 |
| 2 px penumbra | 0.3 | peak bias | 0.1499 | 0.2796 | 1.86 |
| 4 px penumbra | 2.0 | peak bias | 0.0435 | 0.0979 | 2.25 |
| 4 px penumbra | 0.3 | peak bias | 0.0729 | 0.1293 | 1.77 |
| 8 px penumbra | 2.0 | peak bias | 0.0355 | 0.0510 | 1.43 |
| 8 px penumbra | 0.3 | peak bias | 0.0467 | 0.0645 | 1.38 |
| 16 px penumbra | 2.0 | peak bias | 0.0474 | 0.0321 | 0.68 |
| 16 px penumbra | 0.3 | peak bias | 0.0347 | 0.0370 | 1.07 |
| 32 px penumbra | 2.0 | peak bias | 0.0608 | 0.0228 | 0.37 |
| 32 px penumbra | 0.3 | peak bias | 0.0258 | 0.0234 | 0.90 |

- **The ratio is the robust output; the absolute figures belong to this scene.** The wide gather
  cuts noise to 0.61-0.68x, and to 0.62x in both rows at the tight window the gate actually enables
  it in.
- Its cost is at the penumbra **shoulder**, not the interior; it falls with width, is gone by
  sixteen pixels and reverses by thirty-two.
- **The gate is on the window as well as the sample count.** Below `clamp_sigma` 1.0 the 3x3 already
  pays most of the shoulder cost — 0.150 against the 5x5's 0.280 — because a tight window pins the
  value whatever it is centered on, so the noise reduction only makes an already-made trade
  affordable. At the shipped 2.0 the 3x3 is nearly unbiased and widening would buy a cost nothing
  asked for.

### Three things a closed-form reference refused

Geometric rather than another render — a lamp of known radius over a post of known size, scored on
the 10-90 penumbra width. **None would have been caught by an RMSE against a rendered reference,
because a rendered reference has them too.** Two are the probe-ray early-out and the pinned Vogel
stratum, both under Refuted above; the third is two quantization defects, each worth about as much
as the estimator's own error: `[shadow_validation]`

- **An unfloored variance clamp removed a third of every penumbra.** With a handful of rays the 3x3
  neighborhood agrees outright in a penumbra's shallow ends, so the measured spread is exactly zero,
  and clamping to a window of no width pins the accumulation to that binary answer.
- **An 8-bit accumulator re-reading its own rounded output made the stock penumbra about 15% too
  wide**, because the step it stalls on is not symmetric.
- At the defaults with all three fixed, the 10-90 penumbra comes out at **17/28/38/47/55/51/52**
  pixels where the geometry asks for **16.3/26.2/36.0/45.9/51.5/51.5/51.5**, and at sixteen samples
  per light it reproduces the geometry exactly. Softness belongs to the light, not the denoiser.

### Eight more measured results

| Result | Detail | Tag |
| --- | --- | --- |
| **Raising `min_filter_pixels` is a trade, not a free lever** | At the default of 1.0 a pixel whose measured penumbra is narrower than a pixel is filtered in NO a-trous pass at all: every pass early-outs where `reach_pixels <= step_size` (`rt_shadow_atrous.glsl:189`) and the first already steps one. That is what makes a contact edge exact, and the temporal pass's output is what reaches the screen there. Raising the floor switches spatial filtering on for those pixels **and fringes every contact edge in the same move**, because the floor applies wherever a penumbra was measured at all. The fringe ladder — on the shipped kernel `0.375/0.25/0.0625` (`rt_shadow_atrous.glsl:81`), its per-tap reach taper and the early-out, not a render and not from `denoiser_sim.py` — is in `docs/features/rt-shadows.md`. Raise it when the contact shadow reads noisy; leave it when it reads crisp. | `[arithmetic]` |
| **Occlusion culling compounds here, because a culled lamp takes its casters with it** | From a laptop test scene on a Radeon 780M: an interior running in the low thirties reached **80-110 fps at half render scale** after `OccluderInstance3D` planes were added around the level — larger than the saved draw calls explain. The extra comes from a path unrelated to rasterization: the caster gather queries the geometry index with the bounds of every raytraced light in `scene_cull_result.lights`, and that list is built inside the visible-instance cull, in the same branch that tests `OCCLUSION_CULLED`. A lamp whose bounds are occluded is absent from it, its query never runs, and every caster in the structure only on its account leaves too. Paid four times over: a smaller structure to build, fewer nodes for every ray in the frame to descend (including the sun's), fewer candidates in the per-pixel light selection, one less light competing for the mask's four channels. Two limits — it does not reach a raytraced `DirectionalLight3D`, whose caster volume comes from the camera frustum with `scenario->directional_lights` a scenario-level list the per-frame occlusion test never sees; and it cannot cost a shadow, a caster being in the structure on the strength of a light reaching it rather than the camera seeing it. | `[game]` + `[code]` |
| **Blue noise for the emitter offsets** | The baked 32x32 void-and-cluster mask replaced interleaved gradient noise for the emitter sampling offsets. On the mask, high frequency power exceeds low by a factor of **2179**; for the interleaved gradient noise it replaced, **16.6**. The spatial filter downstream removes high frequency error well and low frequency error hardly at all, so that ratio is the whole reason one ray per pixel resolves. | `[shadow_validation]` |
| **The BLAS cache was taking the device lock per surface per frame** | The per-surface cache confirmed a cached BLAS with `RenderingDevice::acceleration_structure_is_valid()`, a `_THREAD_SAFE_METHOD_`, so it took the device lock **once per surface per frame — twice in practice**, the caller checking again. In a scene of a couple of thousand casters, **three quarters of the time the caster loop spent** and about **a quarter of the whole raytraced path's CPU cost**. | `[profiler]` |
| **...replaced by an RID comparison** | Compare the surface's current source vertex buffer RID against the one the structure was built from (`rt_scene.cpp:485`): `RID_Owner` bumps a generation counter when it reuses a slot, so an RID that still compares equal is the same buffer and the structure depending on it is therefore still alive. The two surviving `acceleration_structure_is_valid()` calls are on teardown paths only (`rt_scene.cpp:232`, `:555`). | `[code]` |
| **Lamps enclosed by the sun's caster volume are the common case** | Under a raytraced `DirectionalLight3D` the caster volume is the camera frustum swept toward the light, and in an interior, a street or a town square it swallows every lamp in the scene. In one interior with sixteen such lamps, **their own index queries were making three fifths of the geometry index visits during the gather** and reached no caster the sun's query had not already reached. Skipping a query whose bounds are enclosed by one about to run changes the gathered set not at all. `renderer_scene_cull.cpp:3723-3730`. | `[profiler]` |
| **The denoiser is the largest GPU lever in the frame** | Same direct desktop capture as the occlusion one, RTX 5090, 3440x1440, 4.95 Mpx, dozens of raytraced lights: the shadow block with `denoiser/enabled` **off** reads **0.34 ms**. So trace **0.34 ms**, denoiser **0.78 ms** — the denoiser is **70% of the block and 23% of the whole GPU frame**, costing 2.3 times the signal it is cleaning. | `[profiler]` |
| **Ray tracing is the cheapest thing in this renderer** | Tracing roughly one ray per pixel for dozens of lights across 4.95 Mpx costs a third of a millisecond, and **the screen space occlusion estimator costs 3.3 times that** — on hardware with ray accelerators. | `[profiler]` |

### CPU cost of the raytraced path, and which lever moves it

A deliberately hostile scene — three thousand props over a 200 m field, sixteen lamps of 25 m range,
a raytraced sun and a spotlight on the camera — on a slow CPU. CPU milliseconds, **the shape of the
curve rather than figures that transfer**. `[profiler]`

| change | RT CPU per frame |
| --- | --- |
| as described above | 1.28 ms |
| `directional_shadow_max_distance` 100 -> 50 | 0.99 ms |
| ... -> 25 | 0.54 ms |
| raytraced sun off entirely | 0.45 ms |
| `directional/caster_distance_scale` 2.0 -> 0.5 | 1.12 ms |

**The raytraced sun is two thirds of the cost, and the sun's shadow distance is the lever, not
`caster_distance_scale`.** A lamp bounds its casters with its range; a sun has no range, so the
volume swept for it is the camera frustum out to the shadow distance, pushed back toward the light.
Shortening the shadow distance shrinks that volume in every direction at once — why halving it does
far more than quartering the sweep.

### A push constant that mismatches by a trailing pad fails whole, not partly

`lag_response` was added to the temporal pass by taking the C++ struct's trailing `pad` and renaming
it, and adding a field to the shader block beside a `pad` left there. Every real field still landed
on the same byte offset on both sides; the only difference was four bytes of end padding nothing
reads. The safest-looking kind of mismatch, and the opposite. `[code]`

| | |
| --- | --- |
| **The rejection is total** | `RenderingDevice::compute_list_set_push_constant` compares the size it is given against the size the shader reflected and rejects the call outright when they differ; the dispatch that follows then fails its own check for a push constant having been supplied. |
| **Visible only where the work is done** | Both checks are under `DEBUG_ENABLED`, which no shippable configuration has (`CLAUDE.md`) — fatal in an editor build, invisible in a shipped one. |
| **What it looked like from outside** | An entirely dark scene, no shadow shapes anywhere, lamps that lit nothing, cured by turning the denoiser off. The temporal pass never ran, its target held the zero it was cleared to at creation, the spatial passes carried that zero to the mask, and a mask of zero is every raytraced light fully occluded at every pixel. Two frames of console errors said so, in a log nobody was reading. |
| **The reflected size is the block's exact end, not rounded up to sixteen** | Push constant blocks are parsed with the flag that suppresses that rounding, so a trailing `pad` changes the reflected size where in a uniform block it would not. |
| **An assertion has to carry the pairing** | A C++-side assertion cannot see the half that broke, so it must name how to check it: `glslangValidator -V <shader> -q` prints the block size. |

### Three defensive results, all `[code]`

| Result | Detail |
| --- | --- |
| **The mask has to be written every frame, and lit is the safe default** | Four paths through the raytraced shadow pass could return without writing the mask, and the forward shader samples it unconditionally with nothing to tell it the value is stale. A texture is created cleared to zero and **a zero mask reads as fully occluded**, so every one of those paths turned a recoverable failure — no acceleration structure, an allocation that did not fit on a 4 GB card, a light list truncated to nothing — into the worst picture available rather than a degraded one. **The asymmetry is the point and is not obvious from inside the pass: failing to shadow costs some contact darkening, failing to light costs the whole image.** So the pass reports whether it wrote the mask and the caller lights it when it did not, rather than each early return being individually careful. The denoiser's own buffers stay exempt, because losing those degrades correctly to the trace's raw output — noise instead of nothing. |
| **The denoiser's history can be stale, and heals itself** | History textures are cleared on the frame they are created and never again, so any frame `RTShadows::render` returns early leaves them holding whatever they held before, to be reprojected as though they were last frame's. **The reachable route is not a settings toggle: it is every raytraced light leaving the camera's visible set and returning, which happens by walking around a corner.** Self-heals within a frame or two and is not worth code: the reprojection rejects a tap whose stored view depth disagrees with the expected one by more than the tolerance, the variance clamp pulls what survives into the range this frame actually sees, and `lag_response` at its default of 1.0 collapses the accumulation window as soon as the clamp fires. Recorded because it is the one place "stale history read as current" is genuinely reachable in ordinary play. If it ever does need fixing, the minimal change is to clear **only** the history meta texture, and only on the transition back — zeroed meta alone makes the depth comparison fail for every tap, where clearing the whole scope would also take out the mask, the index and the hit distance, needed every frame. |
| **Two `shadow_opacity` consumers faded a raytraced sun twice — both fixed** | Kept because the shape of the mistake recurs: **anything that consumes the directional shadow term has to know that the trace already faded it.** (1) The shadowmask REPLACE and OVERLAY arms applied `smoothstep(fade_from, fade_to, vertex.z)` when the trace had already faded its own visibility across that identical window; REPLACE was the worse, crossfading toward fully lit and then toward the bake, so ground shadowed in both read a **lit band peaking at 0.25** mid-window. Both now branch on `rt_shadowed`. (2) A sun with `shadow_opacity` of zero was granted a mask slot anyway, so `rt_shadowed` was true, it traced a full set of rays for an answer nothing read, and on the vertex-lighting path it could keep a contact shadow that no second loop was there to multiply away; slot acquisition and screen-space marking now both test the opacity. **Still open, deliberately:** `shadow_opacity` is ignored entirely under `render_mode vertex_lighting`, because the second directional loop — the single place the fade is applied — is compiled out on that path. Upstream Godot does the same on the cascade path, so the fork matches it rather than being the only path that honors it. |

---

# Screen space shadows

## Superseded and retracted

### Every ratio in this section was first measured in the wrong space

Every number in this section was first differenced in sRGB and has been re-derived by decoding each
capture to linear first. **The values below are the linear ones.** The rule, the decode, and the
control that must read `0.500`, are in `docs/VALIDATION.md`.

| | |
| --- | --- |
| **Direction of the error** | Gamma compresses the dark end, so every ratio against the trace came out **LOWER** than the truth — the technique consistently looked further from the reference than it is. |
| **What survives unchanged** | `hardness` 1 is the right default, `surface_thickness` 0.005 is the right default, and `hardness` moves darkness while barely moving area. |
| **The rigs were re-rendered, not recomputed from old files** | Scored in both spaces so the old number and the new one come from the same pixels. The prism hardness sweep reproduces to three decimals in the old space, 105.8 and 35.5 included, as does the azimuth sweep; the chunky-blade table reproduces to within 0.005. |
| **The contrast sweep and the two square posts do not reproduce exactly** | Their rig parameters were not recorded and had to be reconstructed, so their numbers below are fresh measurements rather than corrections. The conclusion each supported is unchanged. |
| **The harness was never at fault and the renders were never wrong** | Only the arithmetic applied to them was. |
| **It does not reach the ambient occlusion numbers** | The first thing to check on finding an error like this, and the answer is no: `ao_compare.py` decodes to linear in its own `to_linear()` before it divides, `main.gd` renders under `TONE_MAPPER_LINEAR` with ambient light only, and the decode was present in the first commit that added the script. Nothing published for occlusion predates it. |

### Retracted: the quarter-shadow numerology

The gamma-space version of the chunky-blade table read **0.681** for `hardness` 0, published
alongside the observation that one filled bucket of four predicts a quarter shadow, near enough.
**That was arithmetic between two different spaces and the agreement was a coincidence of the
encoding.** In linear the same measurement is **0.802** and supports no such reading. The
quarter-shadow mechanism is still what the shader does — visible in the bimodal distribution below,
a *shape* rather than a ratio — but **no measured number in this repository confirms the 0.25
figure, and none is claimed to**. Any text saying Bend's default reaches "about a quarter" of the
trace is this retraction.

### `contrast` and `strength` were settings until they were measured

Both now constants at the values everything was measured with, Bend's **4.0** and **1.0**
(`screen_space_shadows.h:107`, `render_forward_clustered.cpp:1935`). `contrast` saturated (below)
and `strength` scaled the whole term, with a zero that switched the pass off rather than fading it.
**There is no third darkness knob; `hardness` is the knob.** `[code]`

## Refuted

The baseline these all attack: at Bend's defaults the screen space shadow removed **0.445 of the
light per pixel that the trace did, spread over 1.49x the area** — not too thick, which is what it
looks like, but too *faint* across too many pixels. (In the gamma space it was first measured in,
35.5 per pixel against the trace's 105.8, a ratio of 0.335.) `[shadow_validation]`

| Idea | What the numbers said | Tag |
| --- | --- | --- |
| **`contrast` saturates almost immediately** | Swept 4, 6, 8, 12, 16 in one run: shadow mass moved 0.664 to 0.734 of that run's trace and per-pixel darkening 0.445 to 0.466 — **11% and 5% for a fourfold change**. It only widens the window around an exact depth match; it cannot make a sample that did hit count for more. | `[shadow_validation]` |
| **`surface_thickness` buys darkness only by buying width** | Raising it from 0.005 to 0.012 took mass past the trace to **1.347**, but the shadow then covered **2.4x** the traced area while still reading only **0.545** as dark per pixel. Mass and width could not both be matched, at any value. | `[shadow_validation]` |
| **The sun's azimuth is not the explanation** | Sweeping 0, 35, 60 and 90 degrees moved per-pixel darkening only 0.445 to 0.532 of the trace — not the degenerate case of a sun nearly behind the camera. | `[shadow_validation]` |
| **Occluder size is not the explanation** | A 30 cm and an 80 cm square post still reached only **0.596** and **0.571**. | `[shadow_validation]` |
| **It is not a cap somewhere in the composition** | The darkest screen space pixels do reach the trace's value: on the 80 cm post the distribution is **bimodal**, p90 at **0.991** of the trace's per-pixel darkening and p50 at **0.501**. | `[shadow_validation]` |
| **The prediction that the hardness deficit would vary within one frame** | Weaker where a blade is 12 px deep, stronger where it is 1.5 px — measured and wrong. Darkness is flat across the frame: **0.93 to 1.01** for `hardness` 1 and **0.67 to 0.79** for `hardness` 0, at every distance. The deficit is set by how many march samples land inside the depth window, which the blade's screen footprint does not determine. A threshold somewhere below one pixel of blade depth, not a gradient. | `[shadow_validation]` |
| **Chasing the last pixel with `surface_thickness`** | With `hardness` at 1.0, lowering it tightens the shadow to **1.386x** the traced area and then stops: 0.0025, 0.0015 and 0.001 all give 1.386 to 1.388, median width 3 px against the trace's 2 px throughout. That last pixel is the blade's *rasterized* footprint quantized to whole pixels — a blade covering 2.4 px lights three pixel centers and all three cast at full width, while the trace intersects the real triangle. **A fixed one pixel of overshoot, not a proportional error**, so it matters at 2 px of shadow and disappears at 20. | `[shadow_validation]` |
| **Moving `surface_thickness` to 0.0025 as the default** | The gain is real but small (1.57x to 1.39x of traced area), and thickness is a fraction of the depth remaining to the far plane, so the right value is scene-scale dependent in a way `hardness` is not — **0.0025 measured *worse* than 0.005 on 12 cm quads in the same rig**, overcorrecting them to 0.86 of the traced width. | `[shadow_validation]` |
| **Deleting `FLAG_USE_PRECISION_OFFSET` and `FLAG_BILINEAR_SAMPLING_OFFSET_MODE` because nothing sets them** | Declined on judgment. Bend's own options in a file that is a port of their HLSL under Apache-2.0, next to a header vendored unmodified. Deleting them makes the port diverge from its upstream for no gain. | `[code]` |

**`surface_thickness` looked like it wanted retuning with occluder depth, and does not.** At 1.0 cm
of blade depth, 0.010 lands global mass at 1.177 against 0.832 for the default, so scaling it with
the occluder looks obviously right. Stratifying by distance shows two errors canceling:
`[shadow_validation]`

| band | blade depth in px | mass, t=0.005 | mass, t=0.010 |
| --- | --- | --- | --- |
| 0.5-0.9 m | 12.3 | 0.410 | 0.548 |
| 1.9-2.7 m | 3.8 | 1.102 | 1.554 |
| 3.8-5.2 m | 1.9 | 1.522 | 2.182 |

Near the camera every variant undershoots, a 25 cm blade at 0.7 m throwing a shadow longer than the
High tier's 96 pixel march so the tail is not reached; far away every variant overshoots, the fixed
one pixel of rasterization overshoot being proportionally huge on a blade 1.9 px deep. Thickness
widens everything, so it trades the near error against the far one, and a global average over a
frame whose near bands carry most of the mass reads as a match. Mean absolute per-band mass error
puts 0.010 last at **0.61**, 0.005 at **0.32** and 0.0025 at **0.31** — a tie between the two lower
values, which global mass breaks decisively the other way: **0.832 for 0.005 against 0.609 for
0.0025**. Keep 0.005; reach for 0.010 only when the camera sits close and the foreground dominates,
knowing it compensates truncation with excess width rather than matching the trace.

## Measured

### The cause was Bend's four accumulators, and the fix is a knob they do not have

The march accumulates into `shadow_value[i & 3]` and finishes with `dot(shadow_value, 0.25)`: four
samples' worth of agreement to fully shadow a pixel, so one stray sample cannot. **Grass inverts the
assumption.** Samples are one pixel apart along the ray, so a blade narrower than that *is* a
one-sample occluder — one bucket reaches zero, three stay at one. The bimodal distribution above is
exactly this: full strength where the occluder is thick enough along the ray to fill all four
buckets, quantized everywhere else. `hardness` blends `dot(shadow_value, 0.25)` against `min` of the
same four buckets — the same test with the evidence requirement dropped to one sample. Costs three
`min()` per march.

**`probe` rig** — 20 upright prisms 2.2 cm across, 4 mm deep, 90 cm tall, open ground at about 7.7
m, hard sun (`light_angular_distance = 0`), denoiser off, no MSAA, Medium tier, 1280x720, lavapipe;
the trace removes 0.2767 per px over 2217 px. `[shadow_validation]`

| `hardness` | darkening per px vs trace | shadow mass vs trace | area vs trace |
| --- | --- | --- | --- |
| 0.00 (Bend) | 0.445 | 0.664 | 1.49 |
| 0.25 | 0.563 | 0.867 | 1.54 |
| 0.50 | 0.685 | 1.069 | 1.56 |
| 0.75 | 0.812 | 1.273 | 1.57 |
| 1.00 (default) | **0.939** | 1.477 | 1.57 |

**Darkness moved 2.1x while area moved 5%** — what makes `hardness` and `surface_thickness`
separable: one sets how dark, the other how wide. Before this there was one knob for both and no
setting of it was right.

### Confirmed on a real field, which is also where the default comes from

**`field_thin` rig** — 15,000 prism blades 2.2 cm x 4 mm on a ground plane, `cast_shadow = Off`, sun
at 26 degrees elevation and 38 degrees off the camera axis, Medium tier, 1280x720, against a fourth
render with the blades put *into* the acceleration structure as the reference; the trace removes
0.1044 per px over 132,257 px. `[shadow_validation]`

| render | shadowed px | px lightened | darkening per px vs trace | mass vs trace |
| --- | --- | --- | --- | --- |
| `hardness` 0 (Bend) | 71,599 | 0 | 0.864 | 0.468 |
| `hardness` 1 (default) | 95,517 | 0 | **1.149** | 0.830 |
| raytraced reference | 132,257 | 0 | 1.000 | 1.000 |

- Per-pixel darkness reaches the trace and passes it, by 15% on blades this thin. **What is missing
  is area, not darkness** — 96k shadowed pixels against 132k. That gap is the documented screen
  space limit rather than anything tunable: an occluder off the top of the frame, or further along
  the ray than the tier's sample count reaches, cannot be found by a march over the depth buffer.
- **Overshooting darkness while undershooting area is the shape to expect** from a `min()`
  composition that can only darken: where the march finds the occluder it commits fully, elsewhere
  nothing at all. **Why mass, not darkness, is the number to tune `surface_thickness` against.**
- **Zero pixels lightened in any of the three** — the check that `min()` does what it claims.
- **This render is why the default is 1.0 rather than something more cautious.** The obvious risk of
  dropping the evidence requirement to one sample is speckle. On fifteen thousand overlapping thin
  blades, close to the worst case, there is none: clean directional streaks, and against the traced
  render beside them the difference is coverage, not noise.

### Checked again on chunky blades, the size a game actually scatters

**`field` rig** — 4,504 blades of 1.0 x 1.5 cm cross section, 25 cm tall (90-110% per instance), on
pale dry soil with ambient at 0.16, putting lit-to-shadowed contrast at about 7.6x so a shadow is
legible by eye; High tier, 1600x900; the trace removes 0.1595 per px over 253,632 px.
`[shadow_validation]`

| | shadow mass vs trace | shadow darkness vs trace |
| --- | --- | --- |
| `hardness` 0 (Bend) | 0.594 | 0.802 |
| `hardness` 1, thickness 0.005 (default) | 0.832 | **1.052** |
| `hardness` 1, thickness 0.010 | 1.177 | 1.051 |
| `hardness` 1, thickness 0.0025 | 0.609 | 1.043 |

The default still lands: darkness within 5% of the trace here against 15% over on the thin rig — the
fatter the blade, the closer `hardness` 1 sits. `hardness` 0 is 20% short here, 14% there.

### Where the two disagree, and two traps in the rig

| Result | Detail | Tag |
| --- | --- | --- |
| **Where the two techniques disagree** | Scoring `hardness` 1 against the trace pixel by pixel: **42.9% of shadowed pixels agree, 36.9% are shadow only the trace found, 20.3% only the march found.** A thresholded classification rather than a ratio, so it barely notices the space it is measured in — redone in linear, 42.8 / 37.2 / 20.0. Quoted as measured, unchanged. Tested rather than asserted, by mirroring the sun's azimuth from +52 to -52 degrees: the asymmetry flips, from **2.14x right-heavy to 1.09x left-heavy**, so shadow direction drives it. But 1.09 is far weaker than 2.14, so **off-screen occluders are part of the trace-only share and not all of it** — the rest is the near-field march truncation plus a fixed blade layout that is not itself left-right symmetric. | `[shadow_validation]` |
| **`Transform3D.scaled()` is a LEFT multiply** | `Basis::scale` multiplies the basis rows, so it scales along the PARENT axes. Applied after a tilt, as `t.rotated(...).scaled(...)`, it shears a leaning blade into a parallelepiped and shifts its lean by about a degree. Use `scaled_local`. Corrected, the numbers moved by less than **0.3%** because the error applies identically to every capture — but the geometry being compared was not the geometry intended. | `[shadow_validation]` |
| **The raytraced reference has two 65,536 ceilings and only one warns** | A reference silently short of casters still looks entirely plausible. Both ceilings, and which one a scene hits first, are in `docs/internals/rt-shadows.md`. **Find `MAX_RT_CASTERS` by searching the constant in `servers/rendering/renderer_scene_cull.cpp` rather than trusting a line number** — every other line citation in these documents is correct today, but this one sits where they rot. | `[code]` |

---

# DLSS and Streamline

## Refuted

| Idea | What was found | Tag |
| --- | --- | --- |
| **Tagging `get_internal_texture_reactive()` as `kBufferTypeBiasCurrentColorHint`** | Tried on hardware: **every opaque pixel went black**, leaving only alpha-blended surfaces and the HUD visible; FSR2 unaffected. The RID is an alpha-swizzled *view* sharing the color buffer's `VkImage`, so the two tags collided — mechanism, the fix, and the rule that **anything tagged for Streamline must be a texture of its own** are in `docs/internals/dlss.md`. **Do not re-attempt the view**: the first attempt was reasoned as additive and low risk, both claims about the code, and the failure was in the runtime. | `[game]` |
| **`PreferenceFlags::eUseManualHooking` suppressing `sl.dlss_g`'s swapchain hook** | Verified against the SDK source rather than assumed: it does not. The fork leaves `kFeatureDLSS_G` out of `featuresToLoad` in the editor instead — why, and what the flag is actually read by, in `docs/internals/dlss.md`. | `[code]` |
| **Reading back which DLSS model is actually running** | Checked exhaustively so nobody spends the day repeating it: the NGX parameter namespace is 393 defines and the only `Get`-prefixed keys in it are the four dynamic render extents; the whole preset surface is six keys with `Hint` in every name; the only NGX runtime query that exists returns `SizeInBytes`, `OptLevel` and `IsDevSnippetBranch`, which describe how the DLL was built rather than which model it picked; Streamline reads 25 parameter values in its entire source tree and none is preset-shaped; and `sl.dlss`'s own debug HUD prints mode, viewport, runtime and VRAM (`dlssEntry.cpp:84-91`, filled at `:772-775`). **NVIDIA's own overlay, with full access to the plugin's state, cannot print a preset letter either, because the plugin does not know it.** `sl::DLSSState` carries only `estimatedVRAMUsageInBytes`. | `[code]` |
| **Adding XeSS as a Streamline feature id** | Streamline 2.12.0 does not ship it: no `sl.xess` plugin in the source tree, and neither `include/` nor the programming guides mention it — unlike frame generation, which has no source plugin either but does ship `sl_dlss_g.h` and its own guide. The cross-vendor path inside Streamline is DirectSR, D3D12-only, which NVIDIA's own guide advises against on RTX hardware. Adding XeSS means integrating Intel's SDK directly (`libxess.dll`, `xess_vk.h`). | `[code]` |
| **Dynamic multi-frame generation** | `DLSSGMode::eDynamic` is D3D12-only in this SDK and would silently do nothing on Vulkan. Fixed 2x only. | `[code]` |
| **Pacing generated frames against V-Sync from inside Streamline** | D3D12-only too; on Vulkan it has to be forced from the driver control panel. | `[code]` |

## Superseded

### The hedging about motion vector and depth conventions is retired

DLSS super resolution was confirmed on the RTX 5090 at 3440x1440 fullscreen with a 3D scale of 0.67
— the equivalent of DLSS Quality — and opaque geometry is clean: **no ghosting, no smearing under
camera motion, no shimmer at rest.** Load-bearing, because **every convention DLSS depends on fails
visibly and in its own way**, and not one of those artifacts is present: `[game]`

| convention | how it fails when wrong |
| --- | --- |
| motion vector sign, `mvecScale` | smears under motion |
| `clipToPrevClip` transpose | ghosts with the camera still |
| jitter sign | reads as softness |
| resource tags (format, layout, extent) | black or garbage output |

**Do not describe these as unverified.** One exception: **transparency was not clean** — world-space
label text ghosted badly in that build; both fixes (the billboard previous-camera fix, the reactive
mask) were written *after* it and have not been back on the machine.

### Three more superseded entries

| Entry | Detail |
| --- | --- |
| **`MotionVectorsStore` was MetalFX-only** | DLSS needs the velocity buffer pre-filled with camera motion, so it is not. Godot's `(-1, -1)` sentinel, the patched FSR2 decode that tolerates it, and why DLSS reading it literally makes every edge crawl with a still camera are in `docs/internals/dlss.md`. `[code]` |
| **A mip bound that was invisible until the render size stopped dividing by 16** | The GTAO depth prefilter's store guard admitted one texel past the end of the row wherever a dimension is not a multiple of `2^level` — a real out-of-bounds store at two of five mip levels in height, reachable only through DLSS. Mechanism and arithmetic in `docs/internals/ambient-occlusion.md`; the truncated internal size it turns on, in `CLAUDE.md`. **DLSS is the thing most likely to expose a latent size-alignment assumption, because it is the only feature that makes the render size arbitrary** — check a new pass that builds a mip chain or tiles a dispatch against an awkward size, not the native one. `[code]` |
| **Every fork pass is budgeted in internal pixels** | Not a defect and not a change — the same tradeoff any upscaler makes — but it moves what three settings mean on screen, because every pass this fork adds dispatches from `get_internal_size()`. **A contact shadow that looks shorter with DLSS on is this, not a bug.** The three quantities and what each does at a 0.67 scale are in `docs/internals/dlss.md`. `[code]` |

---

# What is still unmeasured

Recorded as absences, so nobody quotes a figure that does not exist.

| Thing | Status |
| --- | --- |
| The screen space contact shadow's GPU cost | **No millisecond figure exists**, on a 5090 or on anything else. The pass is fixed with respect to scene complexity and scales with resolution and quality tier. Measure before budgeting. |
| DLSS frame generation | Has never run on hardware. Reachable for the first time now that super resolution runs, because it refuses without motion vectors and only a temporal upscaler fills the velocity buffer here. |
| The DLSS reactive mask, proper version | Ships off and has never run on hardware. Nothing in this repository can exercise it: the Streamline driver files compile to empty objects anywhere but Windows, so CI type-checks them and no test runs them. The shader alone is validated — `glslangValidator` compiles it to SPIR-V and reflects a 16 byte push constant block matching the `static_assert` — which says nothing about whether DLSS likes the tag. |
| DLSS at any 3D scale but 0.67 | `slDLSSGetOptimalSettings`, which returns `renderWidthMin`/`renderWidthMax` for a quality mode, is not resolved or called anywhere. The mode is picked from the 3D scale and the render size computed independently, so nothing guarantees they agree. Clean at 0.67; other scales are an untested assumption. |
| `restrict_casters` as a default | The A/B needs a rig that does not exist; the single-pixel result the committed rigs give, and why it is not evidence, are in `docs/features/screen-space-shadows.md`. |
| The 128-lights-per-tile overflow's effect on denoiser history | Asserted, never measured. |
| The checkerboard reconstruction tables | Measured, but no committed scorer reproduces them. See the caveat in the occlusion section. |
| Anything temporal, from a render | Both harnesses capture settled still frames with the denoiser off, deliberately. `denoiser_sim.py` covers the temporal pass by simulation only. `docs/VALIDATION.md` has this blind spot and the compressed-geometry one in full. |
