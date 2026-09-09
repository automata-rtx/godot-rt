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

Two consequences were drawn from that: that full resolution is simply affordable on desktop, and
that on weaker hardware the resolution knob can only ever address the smaller half of the cost.

**Both are wrong, and so is the solve they came from.** See "The three rung solve" below. The fixed
part is nine percent, not forty to sixty five, and the error is instructive: the derivation
subtracted three whole-frame framerates, one of which this section already flagged as the least
certain of the three, and a small error in a large subtrahend became a large error in a small
difference. A pass that can be measured directly should never be inferred from frame totals.

A second data point, from a Radeon 780M with `half_size` on and raytraced shadows running in the
same frame: the whole `Process GTAO` block is **1.43 ms** of a GPU frame of about 11.2 ms, in which
the raytraced shadow block alone is 4.49 ms. That is a whole-block figure and not a split, so it
neither confirms nor refutes the forty to sixty five percent fixed share above. What it does do is
warn against transplanting that share. If the fixed part really were dominated by full resolution
bandwidth, a part with a small fraction of a 5090's bandwidth could not fit all five dispatches into
1.43 ms at a comparable pixel count. Either the desktop solve over-estimated the fixed cost -- it
leans on the "over 1000 fps with the effect off" figure this section already flags as the least
certain of the three -- or the gather is a larger share on weak hardware than the desktop ratio
implies.

Two captures settle it on any part, with no code change and no restart: read the block with
`half_size` on and again with it off. Which pair applies depends on the shading rate, because
`half_size` on now shades a checkerboard -- half the pixels -- by default. At that default,
`F = 2*t_half - t_full` and `G_full = 2*(t_full - t_half)`; set `ground_truth/shading_rate` to
`Quarter Resolution` first and it is `F = (4*t_half - t_full)/3` and
`G_full = (4/3)*(t_full - t_half)` instead. Using the second pair against a checkerboard capture can
return a negative fixed cost, which is the sign it was the wrong pair rather than a bad reading.
Discard the first frame after the toggle, because `gather_size`
changes with `half_size` and the buffers are reallocated inside the mark.

### The three rung solve, which refutes the framerate derivation outright

Three shading rates, same RTX 5090, same camera, 3440x1440, occlusion the only variable:

| rate | pixels shaded | `Process GTAO` |
| --- | --- | --- |
| quarter resolution grid | 25% | 0.35 ms |
| checkerboard | 50% | 0.61 ms |
| every pixel | 100% | 1.11 ms |

Three points, two unknowns, so the model is over-determined and can be checked against itself.
Solving each pair for a fixed cost F and a full resolution gather G:

| pair | G | F | fixed share |
| --- | --- | --- | --- |
| quarter, checkerboard | 1.040 | 0.090 | 8% |
| quarter, every pixel | 1.013 | 0.097 | 9% |
| checkerboard, every pixel | 1.000 | 0.110 | 10% |

They agree to within four percent, and the mean solve predicts all three measurements to within
0.01 ms. **The fixed part is about nine percent of the effect and cost is essentially linear in
shading rate.** The code agrees: the gather derives its reach and its sixty four samples from the
full resolution footprint whatever the rate, so per shaded pixel work does not vary, and both
denoise passes dispatch at the gather's own size. Only the depth pyramid and the upsample are
fixed, and both are streaming passes moving on the order of ninety megabytes -- the right size for
a tenth of a millisecond on that part, and nowhere near the half millisecond the old claim needed.

The quality verdict alongside it: the checkerboard was judged indistinguishable from shading every
pixel, and the quarter resolution grid noticeably worse but acceptable. So the top rung costs 0.50
ms more than the middle one for nothing visible, and the default moved to the middle rung.

### The direct desktop measurement, which superseded the framerate derivation

Later, from the same RTX 5090 but measured properly -- the visual profiler rather than three
whole-frame framerates -- at 3440x1440 full screen with `scaling_3d/scale` at 1.0, so 4.95 Mpx, all
settings default except the occlusion running at FULL resolution, in a scene with dozens of
raytraced shadow-casting lights including the sun:

| | GPU |
| --- | --- |
| whole frame | 3.41 ms |
| `Process GTAO`, full resolution | 1.12 ms |
| `Raytraced Shadows` | 1.12 ms |
| `Render Opaque Pass` | 0.64 ms |

The two headline entries landing on the same figure is a coincidence and nothing more. The
comparison that is not a coincidence is this one: the same frame's shadow block with
`denoiser/enabled` off reads **0.34 ms**, so tracing roughly one ray per pixel for dozens of lights
across 4.95 Mpx costs a third of a millisecond, and **the screen space occlusion estimator costs
3.3 times that**. On hardware with ray accelerators, the cheapest thing in this renderer is the ray
tracing.

That 0.34 ms also splits the shadow block for the first time: trace 0.34, denoiser **0.78** -- the
denoiser is 70% of the block and 23% of the whole GPU frame, and it costs 2.3 times the signal it
is cleaning. It is the single largest lever in the frame.

The old framerate derivation above survives contact with this: it predicted quarter resolution at
roughly two thirds of full, which for a 1.12 ms full-resolution block puts quarter near 0.75 and the
gap near 0.37, against the 0.3 it claimed. Consistent, and now the derivation can be retired in
favor of the direct numbers.

### Shading a checkerboard beats shading a coarser grid

`half_size` halves each dimension, so it evaluates a QUARTER of the pixels, not half. Shading a
checkerboard at full resolution instead evaluates half of them, and the difference is not only the
count: a reconstructed pixel's neighbors are one pixel away rather than two, and both it and they
have their own full resolution depth and normal.

Reconstruction error against a fully shaded frame, interior scene, at the radius a real scene wants:

| scheme | shaded | overall | at silhouettes |
| --- | --- | --- | --- |
| quarter resolution grid, 2x2 reconstruction (what shipped then) | 25% | 0.01745 | 0.04095 |
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

### Scored again against the shipped implementation, not the prototype

The table above was measured on a prototype. Re-scored against the mapping and reconstruction the
shaders actually run -- packed texel `(u, y)` holds pixel `(2u + (y & 1), y)`, shaded pixels copied
through untouched, the rest averaged from four neighbors with the same plane weights -- on the
interior scene at the shipped defaults, against a fully shaded frame:

| scheme | overall | at silhouettes |
| --- | --- | --- |
| quarter resolution grid, 2x2 reconstruction | 0.00713 | 0.02472 |
| checkerboard, 4 neighbors | 0.00502 | 0.01180 |

Overall, 29.6% better, against the 29% the prototype measured -- close enough to say the shipped
arithmetic is the arithmetic that was scored. The silhouette figure comes out further ahead than
the prototype's 33%, but that one is not comparable: the mask here is "any pixel whose 3x3
neighbourhood spans more than five percent of its own depth", which is this harness's definition
and not the prototype's, and it selects 1.0% of the frame. Trust the overall column for
cross-checking the two, and the silhouette column only for comparing the two schemes within this
run.

The mapping itself was checked exhaustively rather than by sampling: for every width to 129 and
height to 69, the packed texels and the shaded pixels are in bijection, every unshaded pixel's
on-screen neighbors are shaded and map into range, and exactly half the pixels are shaded. The
only waste is one texel per odd row of an odd width buffer, which the gather clamps and nothing
reads.

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
| 0.5 | 0.0236 | 0.0318 |
| 1.0 | 0.0605 | 0.0605 |
| 2.0 | 0.0771 | 0.1151 |

Doubling the radius used to buy 28% more occlusion, all of it thickness; it now buys 91%, which is
what doubling the reach should give. The default is 1.0, so the two agree exactly there and no
existing scene changes.

What caught it was three descriptions of one setting: the guide, the class reference and
`filter_radius_for()` all said the radius multiplies the on-screen reach, and only the shader
disagreed. A comment audit found a code defect rather than a documentation defect, which is the
argument for auditing comments against the code rather than tidying them.

### The CPU model was measuring a differently oriented estimator on any non-square scene

The model probes the slice basis by stepping off the shaded point and reading where that lands in
view space. The shader steps eight PIXELS; the model stepped a fixed 0.01 of UV. On the two square
720x720 scenes those are the same direction and the model was exact. On the 1280x720 interior they
are not: at a slice azimuth of 45 degrees the two bases differ by about 15 degrees, so every room
scene number the model produced was scoring an estimator rotated slightly away from the one that
ships.

It moved the numbers by less than 0.0002, which is why nothing caught it: the estimator is close to
isotropic, so re-orienting its slices barely changes the mean. The table above is the corrected
model. The lesson is the one the harness exists for -- a model that agrees with the engine to three
decimal places can still be wrong in a way that would matter on a scene that was not nearly
isotropic, and the only defense is checking it clause by clause against the shader rather than by
how well the totals agree.

---

## Raytraced shadows

The pre-implementation design document is `PLAN.md`. It is historical: several of its decisions
were not taken, and `FORK_GUIDE.md` plus `PORTING.md` supersede it. It is kept because it
records the reasoning behind the shape of the system, not because it describes the system.

### Three things the closed-form reference refused

The reference is geometric rather than another render — a lamp of known radius over a post of known
size, scored on the 10–90 penumbra width. None of these three would have been caught by an RMSE
against a rendered reference, because a rendered reference has them too.

**Two probe rays cannot decide whether a pixel is inside a penumbra.** The trace used to fire two
rays at opposite points on the emitter's rim and stop there when they agreed, which is a large
saving because most of any frame is wholly lit or wholly shadowed. But no pair of points answers for
a disk: where a fifth of the emitter is covered the two rim probes still agree about a third of the
time, and the binary answer they hand back pulls that pixel to fully lit. The same happens on the
umbra side. Measured against the geometry it returned **72% of the true penumbra width at sixteen
samples per light** — a shadow that hardens as the sample count *rises*. It was removed rather than
tuned. Removing it cost nothing at the shipped default of one sample per light, which never reached
the early out, and costs exactly the rays asked for at any higher count. A cheaper path has to know
the penumbra is not there before it stops, and that cannot come from the rays it is trying to avoid.

**A Vogel sample pinned to the center of its radial stratum draws a ring, not a disk.** With a fixed
0.5, the single ray of the shipped default sits at √0.5 of the emitter's radius on every frame and
only the angle moves, so the temporal average converges on the shadow of a ring at 0.707r. The width
barely suffers — a ring at 0.707r spans nearly the same 10–90 as the disk containing it — but the
falloff comes out S-shaped, because a ring's projection piles up at its two extremes where a disk's
bulges in the middle. Jittering the radius inside the stratum fixes it, and is the better estimator
at higher counts too.

**Two quantization defects, each worth about as much as the estimator's own error.** An unfloored
variance clamp removed a third of every penumbra: with a handful of rays the 3×3 neighborhood agrees
outright in a penumbra's shallow ends, so the measured spread is exactly zero and clamping to a
window of no width pins the accumulation to that binary answer. And an 8-bit accumulator that
re-reads its own rounded output made the stock penumbra about 15% too wide, because the step it
stalls on is not symmetric.

### Blue noise for the emitter offsets, measured

The baked 32×32 void-and-cluster mask replaced interleaved gradient noise for the emitter sampling
offsets. Measured on the mask, high frequency power exceeds low by a factor of **2179**; for the
interleaved gradient noise it replaced the figure is **16.6**. The spatial filter downstream removes
high frequency error well and low frequency error hardly at all, so that ratio is the whole reason
one ray per pixel resolves.

### Two more the denoiser refused

**Widening a freshly disoccluded pixel to the maximum penumbra.** A pixel whose history was just
thrown away has one ray to go on and does need widening, but widening it to `MAX_PENUMBRA_PIXELS`
outright smeared a contact shadow whose true penumbra is a fifth of a pixel across thirty-one of
them — the exact mistake the penumbra estimate exists to prevent, made one line after it was
computed. The widening is now bounded by a multiple of the measured penumbra as well, which leaves
it at full reach wherever it was doing real work and folds it away at a contact edge.

**Shortening the history-fill decay.** Spreading it over a few frames rather than the whole
accumulation window made freshly disoccluded pixels visibly grainy: at one sample per light the
noise it hides outlives the first handful of frames.

### The BLAS cache, and the device lock

The per-surface cache used to confirm a cached BLAS by calling
`RenderingDevice::acceleration_structure_is_valid()`. That is a `_THREAD_SAFE_METHOD_`, so it took
the device lock once per surface per frame — twice in practice, because the caller checked again —
and in a scene of a couple of thousand casters that was three quarters of the time the caster loop
spent and about a quarter of the whole raytraced path's CPU cost. Comparing the surface's current
source vertex buffer RID against the one the structure was built from replaced it outright:
`RID_Owner` bumps a generation counter when it reuses a slot, so an RID that still compares equal is
the same buffer and the structure depending on it is therefore still alive.

### Lamps enclosed by the sun's caster volume are the common case, not a corner one

Under a raytraced `DirectionalLight3D` the caster volume is the camera frustum swept towards the
light, and in an interior, a street or a town square it swallows every lamp in the scene. In one
interior with sixteen such lamps, their own index queries were making three fifths of the geometry
index visits during the gather and reached no caster the sun's query had not already reached.
Skipping a query whose bounds are enclosed by one that is about to run changes the gathered set not
at all.

### A push constant that mismatches by a trailing pad fails whole, not partly

`lag_response` was added to the temporal pass by taking the C++ struct's trailing `pad` and
renaming it, and adding a field to the shader block beside a `pad` that was left there. Every real
field still landed on the same byte offset on both sides; the only difference was four bytes of
padding at the end that nothing reads. That looks like the safest kind of mismatch, and it is the
opposite.

`RenderingDevice::compute_list_set_push_constant` compares the size it is given against the size the
shader reflected and rejects the call outright when they differ, and the dispatch that follows then
fails its own check for a push constant having been supplied. Both are under `DEBUG_ENABLED`, so
this is every editor build and every debug template, and not an exported release one — where the
smaller push simply lands in the larger range and the padding is never read. So the failure appears
only where the work is done, is invisible in a shipped build, and takes out the entire pass rather
than corrupting one field of it.

What it looked like from the outside: an entirely dark scene with no shadow shapes anywhere and
lamps that lit nothing, which turning the denoiser off cured. The temporal pass never ran, its
target held the zero it was cleared to at creation, the spatial passes carried that zero to the
mask, and a mask of zero is every raytraced light fully occluded at every pixel. Two frames of
console errors said so, in a log nobody was reading.

Two things follow. The reflected size is the block's exact end, not a size rounded up to sixteen:
push constant blocks are parsed with the flag that suppresses that rounding, so a trailing `pad`
changes the reflected size where in a uniform block it would not. And a C++-side assertion is worth
having but cannot see the half that broke, so it has to carry the pairing and the way to check it —
`glslangValidator -V <shader> -q` prints the block size.

### The mask has to be written every frame, and lit is the safe default

Four paths through the raytraced shadow pass could return without writing the mask, and the forward
shader samples it unconditionally with nothing to tell it the value is stale. A texture is created
cleared to zero and a zero mask reads as fully occluded, so every one of those paths turned a
recoverable failure — no acceleration structure, an allocation that did not fit on a 4 GB card, a
light list truncated to nothing — into the worst picture available rather than a degraded one.

The asymmetry is the point and it is not obvious from inside the pass: failing to shadow costs some
contact darkening, failing to light costs the whole image. So the pass reports whether it wrote the
mask and the caller lights it when it did not, rather than each early return being individually
careful. The denoiser's own buffers stay exempt, because losing those already degrades correctly to
the trace's raw output — noise instead of nothing.

### Occlusion culling compounds here, because a culled lamp takes its casters with it

Reported from a laptop test scene on a Radeon 780M: an interior that had been running in the low
thirties reached 80–110 fps at half render scale after `OccluderInstance3D` planes were added around
the level. That is a larger effect than the saved draw calls explain, and the extra comes from a
path that has nothing to do with rasterization.

The raytraced caster gather queries the geometry index with the bounds of every raytraced light in
`scene_cull_result.lights` -- the loop in `RendererSceneCull` that pushes each raytraced-candidate
light's `transformed_aabb` into the gather's bounds scratch, and the `aabb_query` over
`Scenario::INDEXER_GEOMETRY` that runs over that scratch -- and that list is built inside the
visible-instance cull, in the same branch that tests `OCCLUSION_CULLED` before pushing an instance
into `cull_result.lights`. A lamp whose bounds are occluded is therefore
absent from it, its query never runs, and every caster that was in the structure only on its account
leaves too. The saving is then paid four times over: a smaller structure to build, fewer nodes for
every ray in the frame to descend — including the sun's — fewer candidates in the per-pixel light
selection loop, and one less light competing for the mask's four channels.

Which also means occlusion culling attacks the lamp-density cost directly, and it is the cheapest
thing to reach for before any of the raytracing settings.

Two limits. It does not reach a raytraced `DirectionalLight3D`: the sun's caster volume is derived
from the camera frustum and `scenario->directional_lights` is a scenario-level list that the
per-frame occlusion test never sees. And it cannot cost a shadow, because a caster is in the
structure on the strength of a light reaching it rather than the camera seeing it — the geometry
behind a wall still casts into view. What can be lost is the lamp itself, which is stock Godot
behavior for every light and not particular to this path.

### The denoiser's history can be stale, and heals itself

The history textures are cleared on the frame they are created and never again. Any frame
`RTShadows::render` returns early leaves them holding whatever they held before, to be reprojected
as though they were last frame's. The reachable route is not a settings toggle: it is every
raytraced light simply leaving the camera's visible set and returning, which happens by walking
around a corner.

It self-heals within a frame or two and is not worth code. The reprojection compares a stored view
depth against an expected one and rejects a tap that disagrees by more than the tolerance, the
variance clamp pulls what survives into the range this frame actually sees, and `lag_response` at
its default of 1.0 collapses the accumulation window as soon as the clamp fires. So the artifact is
brief and low contrast rather than a smear.

Recorded because it is the one place where "stale history read as current" is genuinely reachable in
ordinary play, and someone who sees it should know it is understood rather than go hunting. If it
ever does need fixing, the minimal change is to clear **only** the history meta texture, and only on
the transition back: zeroed meta alone makes the depth comparison fail for every tap, which rejects
the stale history without touching anything else. Clearing the whole scope would also take out the
mask, the index and the hit distance, which are needed every frame.

## Screen space shadows

### Every ratio in this section was first measured in the wrong space

A PNG is sRGB encoded. Differencing two of them measures gamma space rather than light, so a
shadow's darkness relative to a reference read off that difference is not the ratio of light the
two shadows remove. Every number in this section was first taken that way. They have been
re-derived by decoding each capture to linear before differencing, and the corrected values are
what appears below.

The rigs were re-rendered rather than recomputed from old files, and the scoring was run in both
spaces so the old number and the new one come from the same pixels. The prism hardness sweep
reproduces to three decimals in the old space, 105.8 and 35.5 included, as does the azimuth sweep;
the chunky-blade table reproduces to within 0.005. The contrast sweep and the two square posts do
not reproduce exactly, because their rig parameters were not recorded and had to be reconstructed --
their numbers below are fresh measurements rather than corrections of the old ones, and the
conclusion each supported is unchanged. So the harness was never at fault and the renders were never
wrong; only the arithmetic applied to them was.

Gamma compresses the dark end, so every ratio against the trace came out **lower** than the truth:
the technique consistently looked further from the reference than it is. What survives unchanged:
`hardness` 1 is the right default, `surface_thickness` 0.005 is the right default, and `hardness`
moves darkness while barely moving area. What does not survive is one piece of numerology, retracted
where it stood.

The measurement that caught it was unrelated -- a `shadow_opacity` probe whose shadow-map control
must be exactly linear and read 0.336. A control missing a value it cannot miss is the measurement
failing, not the code.

### The shadow was under half as dark, and neither thickness nor contrast could fix it

Measured against this fork's own raytraced shadow, which is the useful reference here: the same
prisms, the same sun, one render with them in the acceleration structure and one with them out of it
and the screen space pass on. Twenty upright prisms 2.2 cm across and 4 mm deep, 90 cm tall, on open
ground at about 7.7 m, hard sun (`light_angular_distance = 0`), denoiser off, no MSAA, lavapipe.

Two numbers, because a thresholded width quantizes to 2 or 3 px at this scale and cannot resolve a
tuning step. **Shadow mass** is the total luminance the shadow removes from the ground, summed;
dividing it by the shadowed area gives **darkening per shadowed pixel**, which separates a shadow
that is the wrong size from one that is the wrong darkness.

At Bend's defaults the screen space shadow removed **0.445 of the light per pixel that the trace
did, spread over 1.49x the area**. So it was not too thick, which is what it looks like: it was too
*faint*, across too many pixels. (In the gamma space this was first measured in, 35.5 per pixel
against the trace's 105.8 -- a ratio of 0.335.)

Two knobs looked like they should fix it and neither does.

- `contrast` saturates almost immediately. Swept 4, 6, 8, 12, 16 in one run, shadow mass moved 0.664
  to 0.734 of that run's trace and per-pixel darkening moved 0.445 to 0.466 of it -- 11% and 5% for a
  fourfold change. It only widens the window around an exact depth match; it cannot make a sample
  that did hit count for more.
- `surface_thickness` buys darkness only by buying width. Raising it from 0.005 to 0.012 took mass
  past the trace to 1.347, but the shadow then covered 2.4x the traced area while still reading only
  0.545 as dark per pixel. Mass and width could not both be matched, at any value.

Three controls were also ruled out as explanations before the cause was found. The sun's azimuth
does not matter: sweeping it 0, 35, 60 and 90 degrees moved per-pixel darkening only 0.445 to 0.532
of the trace, so this is not the degenerate case of a sun nearly behind the camera. Occluder size
does not fix it: a 30 cm and an 80 cm square post still only reached 0.596 and 0.571. And it is not a
cap somewhere in the composition, because the darkest screen space pixels do reach the trace's
value -- on the 80 cm post the distribution is bimodal, with p90 at 0.991 of the trace's per-pixel
darkening and p50 at 0.501.

### The cause is Bend's four accumulators, and the fix is a knob they do not have

The march accumulates into `shadow_value[i & 3]` and finishes with `dot(shadow_value, 0.25)`. That is
deliberate: it takes four samples' worth of agreement to fully shadow a pixel, so one stray sample
cannot, and it is why only the first `HARD_SHADOW_SAMPLES` of the march are trusted on their own.

Grass inverts the assumption the design rests on. Samples are one pixel apart along the ray, and a
blade narrower than that *is* a one-sample occluder — so one bucket reaches zero, three stay at one,
and the pixel comes out at 0.75, a quarter shadow. The bimodal distribution above is exactly this:
full strength where the occluder is thick enough along the ray to fill all four buckets, quantized
to a quarter or a half everywhere else.

`hardness` blends `dot(shadow_value, 0.25)` against `min` of the same four buckets, which is the same
test with the evidence requirement dropped to one sample. It costs three `min()` for the whole
march. Swept against the trace, prisms as above, `surface_thickness` at Bend's 0.005:

| `hardness` | darkening per px vs trace | shadow mass vs trace | area vs trace |
| --- | --- | --- | --- |
| 0.00 (Bend) | 0.445 | 0.664 | 1.49 |
| 0.25 | 0.563 | 0.867 | 1.54 |
| 0.50 | 0.685 | 1.069 | 1.56 |
| 0.75 | 0.812 | 1.273 | 1.57 |
| 1.00 | **0.939** | 1.477 | 1.57 |

The point is not only that 1.0 lands on the trace's darkness. It is that **darkness moved 2.1x while
area moved 5%**, so `hardness` and `surface_thickness` are finally separable: one sets how dark, the
other how wide. Before this there was one knob for both and no setting of it was right.

### Confirmed on a real field, which is also where the default comes from

The prism rig is twenty well separated blades chosen so a shadow can be measured. The case the
feature exists for is fifteen thousand of them, so it was rendered too: 15,000 prism blades on a
ground plane, `cast_shadow = Off`, sun at 26 degrees elevation and 38 degrees off the camera axis,
against a fourth render with the blades put *into* the acceleration structure as the reference.

| render | shadowed px | px lightened | darkening per px vs trace | mass vs trace |
| --- | --- | --- | --- | --- |
| `hardness` 0 (Bend) | 71,599 | 0 | 0.864 | 0.468 |
| `hardness` 1 | 95,517 | 0 | **1.149** | 0.830 |
| raytraced reference | 132,257 | 0 | 1.000 | 1.000 |

Per-pixel darkness reaches the trace and passes it, by 15% on blades this thin. What is still
missing is **area**, not darkness -- 96k shadowed pixels against the trace's 132k. That gap is the
documented screen space limit rather than anything tunable: an occluder off the top of the frame, or
further along the ray than the tier's sample count reaches, cannot be found by a march over the
depth buffer. It is the case the `SHADOWS_ONLY` clump proxies in section 10.3 of the guide exist
for.

Overshooting darkness while undershooting area is the shape to expect from a `min()` composition
that can only darken: where the march does find the occluder it commits fully, and where it does
not there is nothing at all. It is why mass, not darkness, is the number to tune `surface_thickness`
against.

Zero pixels lightened in any of the three, which is the check that the `min()` composition is doing
what it claims: this pass can only ever darken.

This render is also why the default is 1.0 rather than something more cautious. The obvious risk of
dropping the evidence requirement to one sample is speckle -- a stray sample now shadows a pixel
outright. On fifteen thousand overlapping thin blades, which is close to the worst case for it,
there is none: the shadows read as clean directional streaks, and against the traced render beside
them the difference is coverage, not noise.

### Checked again on chunky blades, which is the size a game actually scatters

The rig above uses 2.2 cm x 4 mm blades, which are nearly razor thin. A game wanting visual density
without millions of primitives scatters something far fatter, so the whole comparison was rebuilt at
1.0 x 1.5 cm cross section, 25 cm tall (90-110% per instance), 4,504 of them on pale dry soil with
ambient at 0.16, which puts lit-to-shadowed contrast at about 7.6x so a shadow is legible by eye.

| | shadow mass vs trace | shadow darkness vs trace |
| --- | --- | --- |
| `hardness` 0 (Bend) | 0.594 | 0.802 |
| `hardness` 1, thickness 0.005 | 0.832 | **1.052** |
| `hardness` 1, thickness 0.010 | 1.177 | 1.051 |
| `hardness` 1, thickness 0.0025 | 0.609 | 1.043 |

The default still lands: shadow darkness within 5% of the trace, against 15% over on the thin rig,
so the fatter the blade the closer `hardness` 1 sits to the reference. `hardness` 0 is 20% short
here and 14% short there.

**Retracted:** the gamma-space version of this table read 0.681 for `hardness` 0, and it was
published alongside the observation that one filled bucket of four predicts a quarter shadow, near
enough. That was arithmetic between two different spaces and the agreement was a coincidence of the
encoding. In linear the same measurement is 0.802 and supports no such reading. The quarter-shadow
mechanism is still what the shader does -- it is visible in the bimodal distribution above, which is
a shape rather than a ratio -- but no measured number in this document confirms the figure, and none
is claimed to.

**Thickness looked like it wanted retuning and does not.** At 1.0 cm of blade depth, 0.010 lands
global mass at 1.177 against 0.832 for the default, and 0.005 was calibrated on blades 4 mm deep, so
scaling it with the occluder looks obviously right. Stratifying by distance shows it is two errors
canceling:

| band | blade depth in px | mass, t=0.005 | mass, t=0.010 |
| --- | --- | --- | --- |
| 0.5-0.9 m | 12.3 | 0.410 | 0.548 |
| 1.9-2.7 m | 3.8 | 1.102 | 1.554 |
| 3.8-5.2 m | 1.9 | 1.522 | 2.182 |

Near the camera every variant undershoots, because a 25 cm blade at 0.7 m throws a shadow longer than
the High tier's 96 pixel march and the tail is simply not reached. Far away every variant overshoots,
because the fixed one pixel of rasterization overshoot is proportionally huge on a blade 1.9 px deep.
Thickness widens everything, so it trades the near error against the far one; a global average over a
frame whose near bands carry most of the mass then reads as a match. Mean absolute per-band mass
error puts 0.010 clearly last at 0.61, with 0.005 at 0.32 and 0.0025 at 0.31 -- a tie between the two
lower values rather than a win for the default. Global mass breaks that tie decisively the other way:
0.832 for 0.005 against 0.609 for 0.0025. **Keep 0.005.** Reach for 0.010 only when the camera sits
close and the foreground dominates, knowing it is compensating truncation with excess width rather
than matching the trace.

Shadow DARKNESS, unlike mass, is flat across the frame: 0.93 to 1.01 for `hardness` 1 and 0.67 to
0.79 for `hardness` 0, at every distance. A prediction that the hardness deficit would vary within
one frame -- weaker where the blade is 12 px deep, stronger where it is 1.5 px -- was measured and is
wrong. The deficit is set by how many march samples land inside the depth window, which the blade's
screen footprint does not determine. The size dependence is a threshold rather than a gradient
somewhere below one pixel of blade depth, and above it `hardness` 0 sits flat at about 0.8 of the
trace whatever the blade's screen footprint.

### Where the two techniques disagree, drawn rather than summarized

Scoring `hardness` 1 against the trace pixel by pixel: 42.9% of shadowed pixels agree, 36.9% are
shadow only the trace found, 20.3% only the march found. This one is a thresholded classification
rather than a ratio, so it barely notices the space it is measured in -- redone in linear it is
42.8 / 37.2 / 20.0. Quoted here as measured, unchanged. The trace-only share concentrates on one
side of the frame, which suggests occluders off the screen edge on the sun side -- something a march
over the depth buffer cannot ever find.

Tested rather than asserted, by mirroring the sun's azimuth from +52 to -52 degrees. The asymmetry
does flip, from 2.14x right-heavy to 1.09x left-heavy, so shadow direction drives it. But 1.09 is far
weaker than 2.14, so off-screen occluders are **part** of the trace-only share and not all of it; the
rest is the near-field march truncation above, plus a fixed blade layout that is not itself
left-right symmetric.

### Two traps in the measurement rig, both of which produced plausible wrong pictures

`Transform3D.scaled()` is a LEFT multiply -- `Basis::scale` multiplies the basis rows -- so it scales
along the PARENT axes. Applied after a tilt, as `t.rotated(...).scaled(...)`, it shears a leaning
blade into a parallelepiped and shifts its lean by about a degree. Use `scaled_local`. Corrected, the
numbers moved by less than 0.3% because the error applies identically to every capture, but the
geometry being compared was not the geometry intended.

The raytraced reference has a ceiling. `MAX_RT_CASTERS` is 65536 (`renderer_scene_cull.cpp:3530`) and
one MultiMesh instance is one caster, so a field denser than that stops casting into the reference.
It does warn (`WARN_PRINT_ONCE`, same file, line 3710) rather than failing silently, but a warning in
a render log is easy to miss and the resulting reference looks entirely plausible.

### What is left is one pixel of rasterization, and it is a floor

With `hardness` at 1.0, lowering `surface_thickness` tightens the shadow to 1.386x the traced area
and then stops: 0.0025, 0.0015 and 0.001 all give 1.386 to 1.388, and the median width sits at 3 px
against the trace's 2 px throughout.

That last pixel is not tunable and should not be chased. The screen space caster is the depth
buffer, so it is the blade's *rasterized* footprint, quantized to whole pixels — a blade covering
2.4 px lights three pixel centers and all three cast at full width, while the trace intersects the
real triangle. It is a fixed one pixel of overshoot, not a proportional error, so it matters at
2 px of shadow and disappears at 20.

`surface_thickness` was left at Bend's 0.005 rather than moved to 0.0025. The gain is real but small
(1.57x to 1.39x of traced area) and thickness is a fraction of the depth remaining to the far plane,
so the right value is scene-scale dependent in a way `hardness` is not — 0.0025 measured *worse* than
0.005 on 12 cm quads in the same rig, overcorrecting them to 0.86 of the traced width.
