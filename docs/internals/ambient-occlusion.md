# Ground truth ambient occlusion — internals

Five dispatches, the buffers between them, the arithmetic in each, the invariants a change must not
break. Tuning: `docs/features/ambient-occlusion.md`. Measurements, costs, refuted ideas:
`docs/HISTORY.md`. Harness and scoring: `docs/VALIDATION.md`. Porting: `docs/PORTING.md`, stage 18.

## Code map

| File — paths relative to `servers/rendering/` | What it holds |
| --- | --- |
| `renderer_rd/effects/gtao.h` | `Settings`, `Buffers`, three push constant structs and their `static_assert` sizes, `DEPTH_MIP_COUNT = 5`. |
| `renderer_rd/effects/gtao.cpp` | Pipelines, projection terms, `filter_radius_for`, `gather_size_for`, `render()` — the five dispatches in order. |
| `renderer_rd/shaders/effects/gtao_prefilter.glsl` | Linear view depth pyramid, 5 mips, farthest-biased. |
| `renderer_rd/shaders/effects/gtao_gather.glsl` | Slice march, 32-sector occupancy mask, sector weight, strength curve. |
| `renderer_rd/shaders/effects/gtao_filter.glsl` | `MODE_DENOISE` (separable plane-aware blur), `MODE_UPSAMPLE` (reconstruction into the shared buffer). |
| `renderer_rd/forward_clustered/render_forward_clustered.cpp` | `_use_gtao`, `_ensure_gtao_buffers`, `_process_gtao`, the call site, the legacy-downsample skip. |
| `rendering_server.cpp` | `rendering/environment/ssao/method` and the `ground_truth/*` settings, 3757-3802. |
| `scene/resources/environment.cpp` (repo root) | `SSAOMethod`; `_validate_property` at 1206 hides `ssao_detail` / `ssao_horizon` / `ssao_sharpness` once this estimator will run. |

## Where it runs in the frame

| Where | Detail |
| --- | --- |
| Gated twice | `using_ssao` (render_forward_clustered.cpp:2712) requires the **depth pre-pass**, a valid `Environment`, `ssao_enabled`, **not a reflection probe**. `_use_gtao` (1473) then picks the estimator: false if the effect failed to compile, false above one view, then `Environment.ssao_method` if not `DEFAULT`, else the project setting. |
| Stage | Inside `_pre_opaque_render`, same block as SSIL/SSR, before the opaque pass. |
| Profiling | `RENDER_TIMESTAMP("Process GTAO")` wraps it and the five dispatches sit inside `draw_command_begin_label("GTAO")`, so a label-reading profiler gets per-dispatch numbers with nothing added. |
| Legacy depth downsample | **Skipped** when this is the only screen space effect running (2071) — this estimator builds its own pyramid and cannot read the deinterleaved one. |
| Back to legacy | `clear_context(RB_SCOPE_GTAO)` (2086) releases the depth pyramid (full resolution `R32_SFLOAT` with mips); toggling per frame thrashes it. |

## Buffers

Created in `_ensure_gtao_buffers`, usage `SAMPLING | STORAGE | CAN_COPY_TO` on all three —
`CAN_COPY_TO` because `texture_clear` refuses a texture without it and the failure path clears.

| RID | Scope / name | Format | Size |
| --- | --- | --- | --- |
| `depth_pyramid` (+ 5 slices) | `RB_SCOPE_GTAO` / `depth_pyramid` | `R32_SFLOAT` | full internal, 5 mips |
| `ao_a`, `ao_b` | `RB_SCOPE_GTAO` / `ao_a`, `ao_b` | `R16G16_SFLOAT` | gather size |
| destination | `RB_SCOPE_SSAO` / `RB_FINAL` | `R8_UNORM` | full internal |

| Rule | Detail |
| --- | --- |
| Destination is shared | It is **the texture the legacy estimator writes**, so nothing downstream — ambient occlusion in the forward shader, light affect, specular occlusion — knows which ran. Different scope from the gather targets, so it survives their `clear_context`. |
| Allocation failure | `_process_gtao` clears `RB_FINAL` to **white** and returns. Unoccluded is the only safe fallback: the buffer otherwise holds undefined contents and the forward pass multiplies ambient light by it unconditionally. |
| Resize / rate change | Caught by comparing `ao_a`'s stored format against `gather_size_for()` and dropping the whole scope. |
| `gather_size_for(full, half_resolution, checkerboard)` | Full with `half_resolution` off; `((W + 1) / 2, H)` checkerboard — half width, **full height**; `((W + 1) / 2, (H + 1) / 2)` quarter grid. Rounded **up** so an odd dimension still covers every pixel — hence the stride is passed in a push constant, never recovered in the shader: integer division rounds down, so at an odd width the two disagree and the recovered stride collapses to 1. |

## Shared reconstruction terms

Computed once in `render()`, handed to the gather and both filter passes:

    uv_to_view_mul = ( 2 / P[0][0], -2 / P[1][1] )      uv_to_view_add = ( -1 / P[0][0], 1 / P[1][1] )
    view = (uv_to_view_mul * uv + uv_to_view_add) * z,  z in the z component   (ortho: without the * z)

| Term | Detail |
| --- | --- |
| Source | The **raw** projection, not the depth-corrected one, and a UV in 0..1 rather than NDC. `uv_to_view_mul.x` is `2 * tan(fovy/2) * aspect`, `.y` is `-2 * tan(fovy/2)`: view space width and height of the frustum at unit depth, y negated because a UV runs down the screen. |
| `z` | **Linear view depth, positive away from the camera**, everywhere. |
| Linearization | From the depth-**corrected** projection: `linearize_mul = -corrected[3][2]`, `linearize_add = corrected[2][2]`, sign-matched. Orthographic replaces both with the raw near and far planes. |
| Invariant | **All three shaders must reconstruct identically.** The filter plane-fits the point a gather texel claims to describe; half a pixel of disagreement makes it reject the gather's own samples along every slope. |

## Pass 1 — depth prefilter (`gtao_prefilter.glsl`)

`((W+1)/2, (H+1)/2)` threads, local size 8x8: one thread per 2x2 full resolution pixels, one group
per 16x16 tile, reduced in `shared float tile_depth[16][16]`. Each coarser level is a weighted mean
of four biased toward the **farthest**:

    furthest = max of the quad;  falloff_mul = -1 / max(ssao_radius, 0.0001);  falloff_add = 1
    w_i = clamp((furthest - d_i) * falloff_mul + falloff_add, 0, 1)
    out = total > 0.0001 ? dot(w, d) / total : furthest

| Element | Detail |
| --- | --- |
| Mip 0 | **Full internal resolution** whatever `half_size` and the shading rate say; those reduce the gather only. |
| The falloff | The farthest always weighs exactly 1. It is a **depth continuity threshold**, not the march's reach — under distance scaling the reach follows depth instead. `total > 0.0001` guards a degenerate quad, not ordinary geometry. |
| Farthest-biased | A coarse texel reporting the nearest of its four dilates thin geometry across its whole footprint, and a march reading one such texel early keeps that horizon for every step after it. Intel's technique, from XeGTAO. |
| No reuse of the legacy pyramid | That one is half resolution based, deinterleaved into array slices a straight-line march cannot address, and biased toward the nearest. |
| Sampled **nearest** downstream | `NEAREST_WITH_MIPMAPS` — what forces the texel-center reconstruction in the gather. |
| Barriers | Both `barrier()` calls sit **outside** the live-thread conditional; a barrier reached by only some invocations of a group is undefined. |

### The mip-bound trap

Store guard is `level_max = max(screen_size >> level, 1) - 1`, **not** `(screen_size - 1) >> level`.
They agree only when a dimension is a multiple of `2^level`; the wrong one is larger, so it admits a
store one texel past the end of the row.

- An internal render size need not divide by `2^level`, and Godot truncates it
  (`servers/rendering/renderer_viewport.cpp:315`), so DLSS Quality at 3440x1440 gives **2304x964**
  (`CLAUDE.md`). 3440x1440 is clean at every level — why this was invisible on the desktop target.
  964 is `2^2 x 241`, so the old guard over-admitted at **levels 3 and 4 in height**; 1920x1080
  misses the same way at level 4 (1080 is 67.5 texels there).
- **Check any new pass building a mip chain or tiling a dispatch against an awkward size, not the
  native one.** Arbitrary render sizes reach this code only through DLSS — `docs/internals/dlss.md`.

## Pass 2 — gather (`gtao_gather.glsl`)

One invocation per gather texel, local size 8x8. `gather_to_full()` gives the full resolution pixel
it answers for; **every world-space quantity derives from that full resolution footprint**, so a
reduced rate changes how many pixels get their own answer and nothing else.

**Fade**, before the march and able to end the invocation:
`fade = clamp(1 - (z - fade_from) * fade_inv_span, 0, 1)`,
`fade_inv_span = 1 / max(fade_to - fade_from, 0.0001)`; at zero, store `(1.0, z)` and return. **No
sky test anywhere in the estimator** — sky takes this branch because the far plane linearizes past
`fadeout_to`. Green is written here as on every path: denoise and upsample plane-fit against it, and
an unwritten texel lets a neighbor be accepted straight across a silhouette.

**One radius read from two ends; `ssao_radius` scales both.**

    on (default): screen_radius_px = ssao_radius * screen_radius * full_height
                  world_radius     = ssao_radius * screen_radius * |uv_to_view_mul.y| * z
    off:          world_radius     = ssao_radius
                  screen_radius_px = (world_radius / max(|uv_to_view_mul.x|*z, 0.0001)) * full_width
    both:         clamp(screen_radius_px, 2, full_width)

| Element | Detail |
| --- | --- |
| Two ends, one march | Pixel span is what the steps walk, world radius a hard `dist > world_radius` rejection. Scale one alone and a raised radius widens a cutoff the steps never reach, a lowered one truncates the march while its steps still spread over the full span. |
| Anchor | The scaled branch takes `uv_to_view_mul.y`, screen **height**, because a camera holds vertical FOV fixed; the fixed branch is aspect invariant already and **must not** get an aspect correction. |
| Thickness | `thickness * world_radius`, pushed along the shaded point's own view ray (`back_delta = delta - view_dir * thickness`). Scales with the radius because a march reaching ten times further at distance would crowd every back face into one shallow shell and the mask would read almost solid. |

**The dither is one hash of the gather texel, with no frame counter:**

    a = fract(52.9829189 * fract(dot(vec2(pos), vec2(0.06711056, 0.00583715))))   -> slice angle
    b = fract(float((pos.x ^ pos.y) * 1103515245u % 1024u) * (1.0 / 1024.0))      -> first step

Interleaved gradient noise for the slice, xor-hash times an LCG multiplier for the step offset. The
omission is deliberate and load-bearing: nothing downstream is temporal, so an animated pattern has
nothing to resolve it and reads as a crawl; no frame counter exists in the push constant to
reintroduce one with.

**Per slice.** `phi = (slice + a) * pi / slices`, `slice_dir = (cos phi, sin phi)` — one real trig
call per slice. Basis probed **8 full-resolution pixels** along `slice_dir`, unprojected at the
shaded point's own depth, then orthonormalized as
`bitangent = normalize(cross(in_plane, view_dir)); tangent = cross(view_dir, bitangent)` — because a
constant-depth step along the slice lies in the plane but is not perpendicular to the view direction
under perspective, which measures elevations against a skewed axis. Probed in **pixels**, what the
march walks in; a UV-sized step points elsewhere on a non-square viewport. The normal is projected
into the plane; a slice with `projected_len < 0.0001` is **dropped from both sums**, not counted
open. `n_angle = atan(dot(n_p, tangent), dot(n_p, view_dir))`.

**March: even spacing, both sides.** `t = (step + b) / steps_per_slice`,
`offset_px = max(t * screen_radius_px, 1.0)` — **uniform in t, deliberately not geometric or
quadratic**: a horizon march may crowd steps near the shaded point since one early hit stands in for
everything behind it, a mask may not, an occluder between two steps being absent rather than
approximated. Leaving the screen **breaks** the ray rather than skipping the step. Mip is
`clamp(floor(log2(offset_px)) - 3, 0, 4)` — mip 0 until a step reaches 16 px, then one level per
doubling; `4` is the top level, written literally. Each sample, in order:

| # | Step | Why |
| --- | --- | --- |
| 1 | **Reconstructed at the center of the texel its depth came from**, not where the step asked. Not optional. | The pyramid is sampled nearest, so the depth describes the texel's middle; pairing it with the asked-for direction offsets the sample by up to half a texel of depth slope, in a direction set only by where the step fell, and on a plane seen at a glancing angle half of those land above the shaded point. |
| 2 | Rejected when `dist < 0.0001` or `dist > world_radius`. | Outside the march's world radius. |
| 3 | Rejected when `dot(delta, normal) < dist * ANGLE_BIAS`, `ANGLE_BIAS = 0.03`. | A sample at or below the shaded plane cannot occlude the hemisphere above it, and a coplanar neighbor reconstructs to either side of that plane at random, so the half landing above marks sectors and a flat floor occludes itself. |
| 4 | Given a back face at `thickness` — solid between front and back, open beyond. | The entire reason thin geometry works. |
| 5 | Measured **inside the slice plane, signed**, `atan(dot(d, tangent), dot(d, view_dir))`, once for `delta` and once for `back_delta`. | An unsigned 3D angle against the view direction puts a sample lying flat on the shaded surface into the middle of the arc and darkens every flat plane. |
| 6 | Mapped to the slice coordinate `(angle - n_angle + pi/2) / pi` clamped to `[0,1]`, then `first = floor(lo * 32)`, `count = ceil((hi - lo) * 32)` clamped into range, OR'd as a bit run into a 32-bit `occupancy`. | A count of 32 or more sets all bits. |

**Open sectors.** With `use_bitmask`, `open = ~occupancy` — the whole difference from horizon
marching. Off, the fallback walks **outward from the normal** (sector 15 down to 0, 16 up to 31),
stops at the first occupied sector each side, keeps only the unbroken open run around the normal.
Inverting it — closing the arc between the outermost occluders rather than outside the innermost —
is an easy mistake and measurably far too dark (`docs/HISTORY.md`).

**The sector weight is not a share of the arc.** Sweeping the slice about the view direction makes
each sector a ring whose circumference goes with the sine of the angle from the view axis, so a
sector facing back at the camera sweeps almost no solid angle; a sector is worth the integral of
`cos(t - n) * |sin t|` across it:

    A(t) = -cos(2t - n)/4 + t*sin(n)/2            antiderivative where sin t >= 0
    W(t) = A(b0) - A(t)                           for t <= 0   (the integrand folds at t = 0)
         = A(t) - 2*A(0) + A(b0)                  for t >  0
    b0   = n - pi/2,  A(b0) = cos(n)/4 + b0*sin(n)/2,  A(0) = -cos(n)/4

| Element | Detail |
| --- | --- |
| Boundaries | `b_i = n - pi/2 + i*pi/32`, `i = 0..32` — **33 of them**, `W(b0) = 0` carried as the running `prev_weight` rather than evaluated. Sector `i` is worth `W(b_{i+1}) - W(b_i)`; open ones accumulate into `arc_open`, and the final `prev_weight` is the whole arc. |
| Rotation trick | Only `cos(2t - n)` varies per boundary, and stepping `t` by `pi/32` steps `2t - n` by `pi/16`, so one fixed rotation replaces a trig call: `ROT_COS = 0.98078528040`, `ROT_SIN = 0.19509032201`, initialized to `(-cos n, -sin n)` because `2*b0 - n = n - pi`. **Those two constants belong to the sector weight, not to the slice rotation.** |
| The Jacobian | Dropping `\|sin t\|` is wrong everywhere anything is occluded, does not average out, and does not shrink with more samples. |

**Resolve: a ratio of two sums**, not a mean of per-slice fractions and not a population count. Each
surviving slice adds `projected_len * arc_open` to one and `projected_len * total_arc` to the other,
both from one running accumulation so they cannot disagree; visibility is `open_sum / total_sum`
where `total_sum > 0.000001`, else 1.0. Projected length makes slices through the steep direction of
a tilted surface matter more than slices across it; weighting each slice into **both** sums is what
makes an unoccluded surface come out at exactly one whatever its orientation and whatever the dither
picked.

**The strength curve, entirely here**, there being no later stage to hang it on:

    visibility = clamp(open_sum / total_sum, 0.0, 1.0);   open = pow(visibility, power);
    visibility = open / max(open + (1.0 - open) * intensity, 0.0001);
    visibility = mix(1.0, visibility, fade);   store (visibility, z)

| Element | Detail |
| --- | --- |
| Ratio, not subtraction | Shape first, strength second. Subtracting a multiple of visibility's distance from white has a hard floor — at intensity 2 every visibility at or below 0.63 lands on exactly zero inside the gather, before any filter sees it, and no filter recovers a value never stored. |
| Why the ratio works | Same slope at the white end, so it asks nothing new of an artist's tuning, and it approaches zero without arriving, so a corner stays a gradient. At intensity 1 it is the identity, which is what the harness measures. |
| `intensity` | Already `Environment.ssao_intensity * intensity_scale` by the time the shader sees it; that multiply is in `_process_gtao`. |

## Passes 3 and 4 — denoise (`gtao_filter.glsl`, `MODE_DENOISE`)

Separable, **across then down**, at the gather's own resolution, ping-ponging `ao_a` -> `ao_b` ->
`ao_a`. Width is derived on the CPU in `filter_radius_for()` because gather variance rises with the
march's on-screen reach and falls with the slice count; tap weight is a tent times a plane term:

    reach         = scale_radius_with_distance ? screen_radius * max(ssao_radius, 0) : 0.05
    filter_radius = clamp(round((reach * 4 / max(slices, 1)) / 0.06), 1, 3)
    kernel        = filter_radius + 1 - |i|
    plane         = max(1 - |dot(n_c, p_tap - p_c)| / max(0.02 * z_c, 0.0001), 0)

| Element | Detail |
| --- | --- |
| Depth source | The AO buffer's **green channel** (the center tap's, and each tap's own), not the pyramid; green passes through from the center tap untouched. This is why every gather path must write green, fade early-out included. |
| Widths | At the shipped `screen_radius` 0.1 / radius 1.0 / 4 slices, `filter_radius` is 2 — five taps per axis; 1 at the smallest radius and 3 at the largest `[arithmetic]`. **With distance scaling off the constant 0.05 stands in and at four slices the width comes out at 1 — turning distance scaling off NARROWS the filter** rather than holding it where it was. |
| `plane_tolerance` | A fixed `0.02f` set in `render()`. |
| `p_tap` | Reconstructed from the tap's own stored depth **and the full resolution pixel that gather texel answers for**, so the filter needs the view normal buffer and the projection terms bound as well as the AO buffer. |
| Plane, not depth difference | Weighting on distance from the shaded point's plane lets a surface seen at a glancing angle keep its own neighbors while a shallow silhouette still separates; a depth-difference test gets both backwards. |

## Pass 5 — upsample (`gtao_filter.glsl`, `MODE_UPSAMPLE`)

Writes `RB_FINAL` at full internal resolution, judging each candidate gather texel against the
**full resolution** depth and normal of the pixel being filled, not the nearest gather texel's —
that would quantize every silhouette to the coarse grid. Full resolution depth comes from mip 0 of
the pyramid (`texelFetch(source_depth, pos, 0)`), already linear. At matching resolutions every
weight collapses onto the pixel's own texel and the pass degenerates to a copy.

| Rate | Reconstruction |
| --- | --- |
| Quarter grid | `source_pos = pos / gather_stride`, a 2x2 bilinear weighted by the same plane term. Gather texel `k` answers for pixel `k * stride`, whose center sits at `k * stride + 0.5`, so the inverse is `pos / stride`; the obvious `(pos + 0.5) * scale - 0.5` assumes texel `k` represents the **center** of its block and is wrong by half a full resolution pixel per axis. Where the weights sum to `<= 0.0001` — every candidate on another surface — it takes the tap the fractional position rounds to, **whole**, because a floor mixed into the weights would drag a silhouette's own value toward whatever lies across it. |
| Checkerboard | Not a filter for half the pixels: `((x + y) & 1) == 0` is shaded and is copied through untouched. The rest average their four immediate neighbors one pixel away, plane-weighted the same way; an off-screen neighbor is **skipped rather than clamped**, because clamping lands on an unshaded pixel and duplicates the tap opposite it, so an edge pixel simply blends two or three. Where every neighbor is rejected, the first on-screen one is taken whole. |

## Shading rate

`_process_gtao` reads `half_size`, then `ground_truth/shading_rate` only if it is on — the rate
chooses how a reduced rate is spent, not whether there is one.
`checkerboard = half_size && shading_rate == 1`, and `1` is the shipped default, so **the
checkerboard is the default whenever half resolution is on**; the quarter grid is the fallback rung.
Packing: pixel `(2u + (y & 1), y)` lives in gather texel `(u, y)` — row 0 shades even columns, row 1
odd ones. Consequences:

| Element | Detail |
| --- | --- |
| Stride | The gather is **half width and full height**, so `gather_stride.y` is 1 on this path while `gather_stride.x` stays 2. Gather and filter ignore the stride entirely on the checkerboard branch and use the packing directly. `full_to_gather_checker(p) = ((p.x - (p.y & 1)) >> 1, p.y)` is valid only for a pixel the checkerboard actually shaded. |
| Odd width | The last texel of an odd row addresses a pixel past the right edge. It is clamped, and no full resolution pixel maps back to it, so the upsample never reads it — **but the horizontal denoise walks the gather's own grid and taps it as a neighbor, so it must still be written.** Skipping that lane puts an uninitialized value into one column of the result. |

## Push constants

Sizes asserted in `gtao.h`: `PrefilterPushConstant` 32 (`gtao_prefilter.glsl`), `GatherPushConstant`
96 (`gtao_gather.glsl`), `FilterPushConstant` 80 (`gtao_filter.glsl`). Those `static_assert`s are
the only thing catching a C++/GLSL mismatch in a shipping build, where such a mismatch is a silently
skipped pass (`CLAUDE.md`). Two of the three grew a field for the checkerboard rate — the class of
edit that once blacked out a scene (`docs/HISTORY.md`).

## Invariants a change must not break

- Every gather path writes green (view depth), fade early-out included; gather, both denoise passes
  and the upsample reconstruct view positions with the same two projection terms and the same
  `(pos + 0.5) / full_size` UV.
- A gather texel's world-space quantities come from the **full resolution** pixel it answers for,
  never from the gather grid; the stride is passed, never recovered by dividing the gather size.
- The march's pixel span and its world radius are one quantity; anything scaling one scales both.
- Sector weights carry the `|sin t|` Jacobian; samples are reconstructed at texel centers; the
  strength curve is a ratio. All three read as the effect working when wrong.

## Open items

- **`Environment.ssao_intensity = 0` inverts occlusion instead of disabling it.** At zero the
  `max(..., 0.0001)` floor takes over the divide (`gtao_gather.glsl:438-439`) and a fully occluded
  pixel comes out black rather than lit; zero is reachable from the inspector. **Fix shape: an
  explicit degenerate case, not a floored divide.**
- **Orthographic is wrong, silently** — three perspective assumptions, no fallback, no warning,
  stated in `docs/features/ambient-occlusion.md`. At code level: the gather's orthographic
  `view_dir` is `(0, 0, 1)` where the perspective branch's `normalize(-center_pos)` points the
  opposite way along z; the distance-scaled radius branch multiplies by depth with no orthographic
  guard although the fixed branch has one; `gtao_filter.glsl` has no orthographic path and its push
  constant carries no such flag. A fix must address all three or gate on
  `Projection::is_orthogonal()`. Stereo/XR is handled instead: `_use_gtao` returns false above one
  view and legacy runs, also without warning.
- **The denoiser is good enough, not finished.** Spatial only, no temporal component — deliberate,
  nothing here resolves a changing dither. Grain surviving at a large radius is largely
  deterministic estimator structure, so a wider filter and more steps will not remove it, and
  raising `slices` pays for the symptom. Three candidates, none measured to a conclusion; attacking
  them is what would let the sample budget come **down** rather than up:
  1. **Mip level transitions in the march**, discontinuous because the pyramid is farthest-biased.
  2. **The hard accept/reject at the elevation bias** (`ANGLE_BIAS`) — a sample near the threshold
     flips between marking several sectors and marking none.
  3. **Sector quantization** — 32 sectors over a half turn snap every occluder to a 5.6 degree grid.

## Measurements

None restated here. Accuracy against a CPU ray trace, cost splits on both target machines, the
shading-rate solve, and the three denoiser fixes the numbers refused (a better dither, rebalancing
slices against steps, widening the filter unconditionally) are in `docs/HISTORY.md`; per-rate costs
in `docs/features/ambient-occlusion.md`. Harness `docs/validation/ao_validation/`, scoring rules in
`docs/VALIDATION.md`; `docs/validation/ao_validation/gtao_sim.py` is a CPU model of this shader and
must be audited clause by clause against it, not by how well the totals agree.
