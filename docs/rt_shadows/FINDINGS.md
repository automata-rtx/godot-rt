# Findings: what was measured, and what turned out to be wrong

This is the working record, not the reference. `FORK_GUIDE.md` describes what the fork *is*;
this describes how it got there — which hypotheses were tested, which measurements settled
them, and which plausible ideas were abandoned because the numbers refused them.

It exists so the same wrong turns are not taken twice. Nothing here is needed to *use* the
engine, and none of it should migrate back into the guide.

---

## Ambient occlusion

### The validation method, and why there are two references

Screen-space occlusion has two independent error sources, and one reference conflates them:
what the method cannot know because the camera never saw the occluder, and what the code gets
wrong. So the harness traces two.

| | traces | the gap to it measures |
| --- | --- | --- |
| `ao_truth.py` | the real geometry, cosine sampled | the ceiling: what any screen-space method could reach |
| `ao_screen_truth.py` | the same rays against a depth buffer from the camera's own view | the implementation, with the method's blind spots held fixed |

A third piece, `gtao_sim.py`, is a CPU transcription of the gather. It exists because the loop
of "edit shader, rebuild, software render, score" takes minutes and this takes seconds, and
because a disagreement between it and the engine *localizes* a fault: if they disagree the
plumbing is wrong; if they agree but both miss the reference the estimator is wrong. Every
defect below was found that way. It has reproduced the engine to within 0.001 mean absolute
error every time it has been checked.

### Three defects the traced reference found

None of these looked like bugs. All three were steady biases that read as the effect working.

**The sector weights had no Jacobian.** Each of the 32 sectors was worth its share of the arc.
Sweeping a slice about the view direction turns each sector into a ring whose circumference
goes with the sine of the angle from that axis, so a sector pointing back at the camera sweeps
almost no solid angle and one at the edge of the arc sweeps the most. The two sectors either
side of the normal were counted about ten times too heavily. The integral of
`cos(t − n)·|sin t|` has a closed form, so the weights are now evaluated outright.

**The march read a nearest sampler and reconstructed somewhere else.** The depth returned
describes the middle of whichever texel the step landed in, not the point the step asked for.
Pairing that depth with the asked-for direction put every sample off its own surface by up to
half a texel of depth slope; on a plane seen at a glancing angle half of those land above the
shaded point. The floor occluded itself by a flat three percent everywhere.

**Steps were spaced quadratically.** A horizon march can crowd its steps near the shaded point
because one early hit stands in for everything behind it. A mask cannot: an occluder between
two steps is absent, not approximated. Spreading the same eight steps evenly roughly halved
the error.

Two more found alongside them: the non-bitmask path had the horizon inverted, closing the arc
between the outermost occluders instead of outside the innermost ones (0.63 too dark, unusable
as the toggle it is meant to be); and the slice basis was probed with a UV-sized step while the
march walks in pixels, so on any non-square viewport every elevation was measured against an
axis the samples did not lie on.

### The strength curve, which looked like an estimator failure and was not

The first version scaled occlusion by subtracting a multiple of its distance from white:
`pow(v, power)` then `1 − (1 − v)·intensity`. That form has a hard floor. At the stock intensity
of 2.0, every visibility at or below 0.63 — roughly what an ordinary concave corner *is* — lands
on exactly zero. In an interior that put 3% of the frame on one flat black value, inside the
gather, before any filter saw it, so no filter could recover it. It read as hard black wedges
with speckled edges, and it was blamed on the estimator.

The measurement that settled it in one step: put a **flawless ray-traced occlusion** through the
same curve. The artifact survived. 6.97% of a perfect frame went to black.

| | mean absolute error | frame driven to black |
| --- | --- | --- |
| raw estimator, interior scene | 0.0104 | 0.00% |
| through the old curve at shipped knobs | 0.0500 | 3.20% |
| through the ratio curve at the same knobs | 0.0152 | 0.00% |

Correlation barely moved either way (0.939 → 0.940): the estimator was always right about
*where* occlusion belongs; the curve was destroying *how much*.

Two things that did not help and were rejected. Adopting the legacy estimator's composition
order together with its `shadow_clamp` moves the mean by 0.008 and still leaves 3% of the frame
below 0.05, because a plateau at 0.003 reads as black on screen — tidiness, not a fix. And
moving the remap out of the gather into the upsample measured as a no-op for grain and
*increased* the number of exactly-black pixels, because averaging already-clamped values was the
only thing lifting them off zero.

### Why `ssao_intensity`'s 2.0 default is wrong here

That default is a legacy-estimator calibration constant. ASSAO's obscurance is a distance-weighted
proximity average over a screen disk, not a visibility integral, and on the same geometry it
measures roughly a fifth of the real deficit — the 2.0 exists to multiply that back up. This
estimator reports the deficit directly, so the same number doubles a figure that is already
right. Hence `intensity_scale`, rather than changing the `Environment` default the legacy path
still needs.

### The denoiser, and two intuitive fixes the numbers refused

At the small radius the effect first shipped with, only 31% of the visible grain was removable
by dithering at all — the rest is deterministic estimator structure. At a large radius that
inverts: 70% is dither-removable. The earlier conclusion that "93% of the grain is structure"
was measured at the small radius and does not generalize, which is why a wider filter helps so
much more at a large radius than the first measurement suggested.

**A better dither is not the lever.** The slice offset is already interleaved gradient noise,
which is optimal over a 3×3 by construction, and the residual is already blue — autocorrelation
−0.41 at one pixel, decaying to zero by four. Every alternative measured within a few percent:
tiled, stratified, blue-noise pairs. Worse, a 4×4 tiled dither *looks* smoother while deviating
2.3× further from the resolved signal, because a fixed pattern imprints structure that a
weighted filter cannot remove. A tiled pattern with a filter narrower than its tile is worse
than white noise, because a repeating pattern reads as structure where noise reads as film grain.

**Rebalancing the sample budget toward slices is a trap.** At a large radius, doubling
`steps_per_slice` changes the grain by nothing measurable (0.00690 → 0.00696) while the same 64
taps split 8×4 instead of 4×8 is 18% smoother. But scored against a ray trace at that radius,
8×4 is **35% less accurate** (0.0983 vs 0.0726). Steps buy accuracy, slices buy smoothness, and
the grain metric cannot see the half it is not measuring. The split stays 4×8.

**A-trous multi-pass filtering also fails the same way.** Three passes reach a lower grain figure
than two and a worse deviation from the true signal (0.0076 vs 0.0059): it is buying smoothness
by removing contact detail.

What did work, measured on real renders of an interior at the radius a real scene wants:

| | grain | mean absolute error |
| --- | --- | --- |
| one 3×3 pass, relative-depth weights | 0.00356 | 0.0705 |
| separable two-pass, width from the radius, plane-distance weights | 0.00193 | 0.0701 |

Error moved slightly the right way, so this is not smoothness bought by blurring the signal
away. About half the improvement came from the plane-distance weight rather than from the extra
width — a relative-depth test has no notion of orientation, so on a surface seen at a glancing
angle it discards neighbors lying on that very surface while keeping neighbors across a
shallow step that is a real silhouette.

### What the effect actually costs, as far as anyone knows

From framerates in one shot on an RTX 5090: quarter resolution around 620 fps, full resolution in
the mid-to-low 500s, and (less confidently) over 1000 with the effect off.

The robust figure is the one that does not involve the uncertain number: full resolution costs
**+0.27 to +0.33 ms** over quarter resolution.

Solving `quarter = F + G/4` and `full = F + G` for a fixed cost F and a full-resolution gather cost
G gives G around 0.37 ms and F somewhere between 0.4 and 0.7 ms depending on what the off figure
really is. F is the larger or comparable term across every plausible value, which is the useful
conclusion: **more than half the cost does not scale with gather resolution.** It is the full
resolution depth pyramid, the upsample that always runs at full resolution, and the barriers
between five dispatches.

Two consequences. On desktop hardware full resolution is simply affordable and the quality question
answers itself. And on weaker hardware, reaching for the resolution setting can only ever address
the smaller half of the cost -- the fixed part has to be measured per pass before it can be
attacked.

### Shading a checkerboard beats shading a coarser grid

`half_size` halves each dimension, so it evaluates a QUARTER of the pixels, not half. Shading a
checkerboard at full resolution instead evaluates half of them, and the difference is not only the
count: a reconstructed pixel's neighbors are one pixel away rather than two, and both it and they
have their own full resolution depth and normal.

Reconstruction error against a fully shaded frame, interior scene, at the radius a real scene wants:

| scheme | shaded | overall | at silhouettes |
| --- | --- | --- | --- |
| quarter resolution grid, 2x2 reconstruction (what ships) | 25% | 0.01745 | 0.04095 |
| quarter resolution grid, 7x7 reconstruction | 25% | 0.01488 | 0.03984 |
| checkerboard at full resolution, 4 neighbors | 50% | 0.01238 | 0.02724 |
| checkerboard at full resolution, 12 neighbors | 50% | 0.01238 | 0.02724 |

Two results worth keeping. Widening the reconstruction at quarter resolution gains three percent at
silhouettes for five times the taps, which refutes the plausible idea that the 2x2 is simply too
narrow -- the problem is that no sample was ever taken near the edge, and a filter cannot invent
one. And a checkerboard's reconstruction is COMPLETE at four taps: going to twelve changes nothing
to five decimal places, because every unshaded pixel already has all four immediate neighbors
shaded. There is no tuning surface there to get wrong.

The cost is real: twice the gather of the quarter resolution mode. It also wants the checkerboard
packed into a half width buffer, because dispatching full resolution threads and exiting half of
them wastes the saving on wave divergence.

### Half resolution was misregistered by half a pixel

The gather evaluates full-resolution pixel `k·stride`; the upsample computed
`(pos + 0.5)·scale − 0.5`, which assumes texel `k` sits at the *center* of its block. Cross
correlating a half-resolution render against a full-resolution one put their best alignment at
exactly (−0.5, −0.5), matching the arithmetic. Separately, the upsample's bilateral guide was
the nearest gather texel's depth, which quantised every silhouette to the coarse grid — that,
not the reduced sample count, was most of why half resolution read as low resolution rather
than merely soft.

### What the synthetic scenes missed

Both original scenes are viewed from outside, from above, over one large flat floor with open
sky in every direction. Their mean occlusion is under one percent, so a *correct* occlusion
barely enters the range the output transfer operates on:

| scene | mean traced visibility | fraction of frame below 0.63 |
| --- | --- | --- |
| solid boxes | 0.9909 | 0.73% |
| thin geometry | 0.9943 | 0.27% |
| interior room | 0.9336 | 6.97% |

A ten-to-twenty-five-fold coverage gap, which is why four independent symptoms passed validation
twice. Both were also square, so no aspect-dependent defect could appear — and the effect radius
under `scale_radius_with_distance` was anchored to screen *width*, making it 1.8× larger on a
16:9 viewport than on the square one everything was tuned against. The `room` scene exists to
close both gaps and is deliberately 1280×720.

The harness now scores every scene twice: once at unity, which measures the estimator, and once
at the shipped intensity and power, which measures what a player sees. `ao_compare.py` prints
the fraction of the frame below one 8-bit code, because a clipping transfer looks fine on every
average and terrible on screen.

The first real interior the effect was pointed at wanted a `screen_radius` around 0.25 and ran out
of slider before it. That is why the default moved to 0.1 and the range now reaches 0.5.

### `ssao_radius` was scaling half of the march

Under `scale_radius_with_distance` the gather derives two quantities from `screen_radius`: how many
pixels the march walks, and the world distance that walk corresponds to, which is what the sample
cutoff and the back-face thickness are measured against. `Environment.ssao_radius` multiplied only
the second, so the march walked the same span on screen whatever the radius was set to.

Above 1.0 the cutoff moved somewhere the steps never reached, leaving thickness as the only thing
that changed. Below it the cutoff truncated the march while the steps stayed spread over the full
span, spending the budget outside the volume being measured. Both read as the setting working,
because thickness alone does move the picture.

Measured on the interior scene, mean occlusion against `ssao_radius`:

| `ssao_radius` | before | after |
| --- | --- | --- |
| 0.5 | 0.0236 | 0.0317 |
| 1.0 | 0.0604 | 0.0604 |
| 2.0 | 0.0770 | 0.1152 |

Doubling the radius used to buy 28% more occlusion, all of it thickness; it now buys 91%, which is
what doubling the reach should give. The default is 1.0, so the two agree exactly there and no
existing scene changes.

What caught it was three descriptions of one setting: the guide, the class reference and
`filter_radius_for()` all said the radius multiplies the on-screen reach, and only the shader
disagreed. A comment audit found a code defect rather than a documentation defect, which is the
argument for auditing comments against the code rather than tidying them.

---

## Raytraced shadows

The pre-implementation design document is `PLAN.md`. It is historical: several of its decisions
were not taken, and `FORK_GUIDE.md` plus `PORTING.md` supersede it. It is kept because it
records the reasoning behind the shape of the system, not because it describes the system.
