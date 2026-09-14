# Ambient occlusion: the ground truth estimator

Using the second SSAO estimator: turning it on, what reaches it, tuning order, cost, limits.
Internals: `docs/internals/ambient-occlusion.md`. Sweeps and refuted ideas: `docs/HISTORY.md`.
Measuring: `docs/VALIDATION.md`. Symptoms: `docs/TROUBLESHOOTING.md`.

## What it is

- Slice-based horizon marching (Jimenez et al., GTAO, 2016) with a **visibility bitmask** (Therrien,
  Levesque and Gilet, 2023). A second estimator behind Godot's existing occlusion buffer, not a
  replacement — both ship, either runs. **Ships off**: an unaware project is exactly as before.
- Writes the **same texture** the legacy estimator writes, so nothing downstream knows which ran:
  ambient multiply, near field bounce, `ssao_light_affect`, `ssao_ao_channel_affect`, specular AO.
- A slice keeps a 32 sector occupancy mask over its half turn instead of one horizon angle per side:
  two occluders with sky between them stay two, and a thin surface stops occluding once the march
  passes behind it. Hence it wins on foliage, railings and slats and loses slightly on thick solid
  shapes, where a horizon march's "everything behind the first occluder is occluded" is true.

## Turning it on

- Globally: `ProjectSettings.set_setting("rendering/environment/ssao/method", 1)`. Enum `Screen
  Space (Legacy)` / `Ground Truth`, default **0 = legacy**
  (`servers/rendering/rendering_server.cpp:3757`).
- Per environment, which is what makes two environments directly comparable: `env.ssao_enabled =
  true` plus `env.ssao_method = Environment.SSAO_METHOD_GROUND_TRUTH`.
- `Environment.ssao_method`: `SSAO_METHOD_DEFAULT` = 0 (**default**) follows the project setting;
  `SSAO_METHOD_SCREEN_SPACE` = 1 forces legacy point obscurance and `SSAO_METHOD_GROUND_TRUTH` = 2
  forces this estimator, both whatever the project setting says. `DEFAULT` keeps a scene saved
  before this property existed on the method the project picked, not silently on a new renderer.
- `ssao_enabled` still gates everything; the method only chooses which estimator fills the buffer.
- Servers API: `RenderingServer.environment_set_ssao_method(env, method)`, with
  `RenderingServer.ENV_SSAO_METHOD_DEFAULT` / `_SCREEN_SPACE` / `_GROUND_TRUTH`.
- **Every setting here is live — none is restart-required.** The method is re-evaluated per frame;
  settings are read through `GLOBAL_GET_CACHED`, which re-reads on a `ProjectSettings` version bump.

## Which stock settings reach it

| Setting | Default | Ground truth |
| --- | --- | --- |
| `Environment.ssao_enabled` | `false` | Same — gates both. |
| `Environment.ssao_power` | `1.5` | Same. Applied first, as `pow(visibility, power)`. |
| `Environment.ssao_radius` | `1.0` | **Reinterpreted** — see below. |
| `Environment.ssao_intensity` | `2.0` | **Scaled by `ground_truth/intensity_scale`** — below. |
| `ssao_light_affect`, `ssao_ao_channel_affect` | `0.0` both | Same — downstream, scene UBO. |
| `ssao_detail`, `ssao_horizon`, `ssao_sharpness` | `0.5`, `0.06`, `0.98` | **Legacy. Inert.** |
| `rendering/environment/ssao/half_size` | `true` | Same — asks for a reduced shading rate. |
| `.../fadeout_from`, `.../fadeout_to` | `50.0`, `300.0` | Same. |
| `.../quality`, `.../adaptive_target` | `2` (Medium), `0.5` | **Legacy only. Inert.** |
| `.../blur_passes` | `2` | **Legacy only. Inert** — the denoise self-sizes. |

- **`ssao_radius` is not a world distance here** under the default `scale_radius_with_distance`: it
  multiplies `ground_truth/screen_radius`, a share of the screen. It scales both halves of the march
  — the on-screen span the steps walk and the world distance it corresponds to — because those are
  one march; moving one alone truncates or overshoots. Scaling off, it is a world distance again.
- **`ssao_intensity` is multiplied by `ground_truth/intensity_scale` (0.5) first**, so the shipped
  `2.0` arrives as `1.0`. That `2.0` is a legacy calibration constant: the legacy obscurance is a
  distance-weighted proximity average, not a visibility integral, and measures a fraction of the
  real deficit, so it needs multiplying up. This estimator reports the deficit directly.
- The three inert `Environment` ones are hidden in the inspector whenever ground truth will run,
  including when it defers to the project setting (`scene/resources/environment.cpp:1206`).

## `rendering/environment/ssao/ground_truth/`

| Setting | Default | Range |
| --- | --- | --- |
| `screen_radius` | `0.1` | `0.005 … 0.5` |
| `thickness` | `0.3` | `0.01 … 2` |
| `shading_rate` | `1` = `Checkerboard` | `Quarter Resolution`, `Checkerboard` |
| `scale_radius_with_distance` | `true` | bool |
| `visibility_bitmask` | `true` | bool |
| `slices` | `4` | `1 … 8` |
| `steps_per_slice` | `8` | `1 … 16` |
| `intensity_scale` | `0.5` | `0.05 … 2` |

- **`screen_radius`** — share of screen **height** the march spans, times `Environment.ssao_radius`.
  Height because a camera holds vertical FOV fixed; anchored to width the same value would reach
  nearly twice as far on 16:9 as on a square viewport. The denoise widens to match: taps, not grain.
- **`thickness`** — how far behind a sample its back face sits, as a fraction of the effect radius;
  what lets light pass behind a thin surface instead of treating every occluder as infinitely deep.
  The one genuine tradeoff: raise toward `1.0` for thick solid shapes, lower for foliage, railings
  and slats. `0.3` is the joint optimum across both scenes in `docs/validation/ao_validation/`.
- **`shading_rate`** — read **only when `half_size` is on**; chooses how a reduced rate is spent,
  not whether there is one. `Checkerboard` shades half the pixels and reconstructs each of the rest
  from four neighbors one pixel away; `Quarter Resolution` shades a quarter, from two pixels away.
- **`scale_radius_with_distance`** — holds the march to a fixed share of screen at every depth. Off,
  the on-screen span shrinks as a surface recedes until the steps land on the same texel and the
  occlusion quietly disappears; that is what buys coverage at distance, and why it is on. Off also
  **narrows the denoise**, whose width derives from the on-screen reach and falls back to a constant
  (`GTAO::filter_radius_for`, `servers/rendering/renderer_rd/effects/gtao.cpp:92`): five taps per
  axis at the shipped radius, three with the scaling off `[arithmetic]`.
- **`visibility_bitmask`** — off falls back to horizon behavior. Worth a look on an all-solid scene.
- **`slices` / `steps_per_slice`** — the whole sample budget; cost is linear in both. Not
  interchangeable: **steps buy accuracy, slices buy smoothness.** Raise whichever you are short of.
  Rebalancing one into the other was measured and trades a real quantity away — `docs/HISTORY.md`.
- **`intensity_scale`** — the multiplier above. Derived, not fitted: `0.5` puts the shipped `2.0` at
  exactly `1.0`, the identity of the ratio transfer, and every published occlusion number was
  measured through it. Not a tuning knob — `Environment.ssao_intensity` is the per-scene one.

## Tuning order

1. **`screen_radius`.** The default is sized for a test scene. The first real interior this was
   pointed at wanted about **0.25** and ran out of slider before it; that is why the default moved
   to 0.1 and the range now reaches 0.5. `[game]`
2. **`shading_rate`**, if the frame is short — the first knob on weak hardware, cost near-linear in
   it (see Cost). **Drop to `Quarter Resolution` on an integrated GPU, where the same model puts the
   checkerboard about a millisecond dearer** `[arithmetic]`; judged noticeably worse but acceptable.
3. **`thickness`**, once the radius is right, according to how thick the scene's geometry is.
4. **`Environment.ssao_intensity` / `ssao_power`** for overall strength. Leave `intensity_scale`.
5. **`slices`** for residual grain, **`steps_per_slice`** for occluders missing outright.

Never tune it by screenshot. `docs/validation/ao_validation/` traces the scene on the CPU two ways
and scores against both in linear light; `docs/VALIDATION.md` has that rule and the numbers to beat.

## Accuracy

Mean absolute error / correlation against a CPU ray trace of the real geometry, estimator at unity
intensity; lower error and higher correlation are better. `docs/validation/ao_validation/`

| scene | bitmask | bitmask off | legacy |
| --- | --- | --- | --- |
| thin: louver, fin, table on thin legs | **0.0134 / 0.947** | 0.0346 / 0.875 | 0.0433 / 0.845 |
| solid boxes | 0.0307 / 0.796 | **0.0235 / 0.859** | 0.0515 / 0.693 |
| interior room, camera inside it | **0.0104 / 0.936** | — | 0.0367 / 0.653 |

- At the shipped intensity and power rather than at unity, the interior scores **0.0152 / 0.940**.
- **Contact on thick solid geometry reads about 0.03 too bright**, roughly a third of that inherent
  to screen space rather than to this implementation — a reference that sees only what the camera
  sees misses the same occlusion. `thickness` is the knob.

## Cost

Direct GPU profiler captures of `Process GTAO`; never inferred from frame totals, a derivation that
was made, was wrong, and is retired in `docs/HISTORY.md`.

**RTX 5090, 3440x1440 fullscreen, 3D scale 1.0 (4.95 Mpx), occlusion forced to FULL resolution, all
else default, dozens of raytraced shadow-casting lights** `[profiler]`: whole frame **3.41 ms**,
`Process GTAO` **1.12 ms**, `Raytraced Shadows` 1.12 ms, `Render Opaque Pass` 0.64 ms — a third of
the GPU frame, the two 1.12 ms entries matching by coincidence. The same frame's shadow block with
the denoiser off reads **0.34 ms**: with ray accelerators this estimator costs **about 3.3x what
tracing the shadows costs**.

**Shading rate, same RTX 5090, same camera, 3440x1440, occlusion the only variable** `[profiler]`:

| rate | pixels shaded | `Process GTAO` |
| --- | --- | --- |
| `Quarter Resolution` | 25% | 0.35 ms |
| `Checkerboard` (default) | 50% | 0.61 ms |
| every pixel (`half_size` off) | 100% | 1.11 ms |

- **Essentially linear in shading rate**; the fixed part is about **9%** — only the depth pyramid
  and the upsample do not scale. Three rungs against two unknowns, so the solve checks against
  itself (`docs/HISTORY.md`). The top rung costs 0.50 ms more than the default for nothing judged
  visible; the checkerboard was judged indistinguishable from shading every pixel.

**Radeon 780M, one capture, at the `Quarter Resolution` rung** (not the default — a stock capture
shades a checkerboard and reads higher) `[profiler]`: the whole `Process GTAO` block is **1.43 ms**
of a GPU frame of about **11.2 ms**, in which the raytraced shadow block alone is **4.49 ms**.

- **Read that as a ratio, not a budget**: embedded in the editor, so the render size was a fraction
  of shipping and the editor drew its own interface on the same integrated GPU and memory. What
  transfers is the shape — occlusion roughly an eighth of the frame and the third largest of four
  passes, the shadow stage the large one. An iGPU frame that is too slow does not start here.

## Limits and surprises

- **Forward+, single view only.** A stereo or XR viewport **silently falls back to the legacy
  estimator**: the occlusion buffer is a layer per eye and the gather has no notion of a second one.
- **Do not use it under an orthographic camera — use the legacy estimator there.** No fallback, no
  warning; the answer is wrong, increasingly so with distance. Three places still assume
  perspective — two in `servers/rendering/renderer_rd/shaders/effects/gtao_gather.glsl`, one in
  `servers/rendering/renderer_rd/shaders/effects/gtao_filter.glsl`. The `scale_radius_with_distance`
  world radius grows with depth where an orthographic extent does not, inflating the sample cutoff
  and the back-face thickness; `view_dir` carries the opposite sign to the perspective one,
  reversing the term that lets thin surfaces pass light; and the filter reconstructs view positions
  with no orthographic case, so its plane weights measure a warped plane.
- **`AreaLight3D`, reflection probes, and the Mobile and Compatibility renderers** never see this
  estimator; they get whatever the legacy path gives them.
- **Half resolution costs less quality than it sounds like.** Every world space quantity the gather
  uses derives from the full resolution pixel footprint, so halving resolution changes only how many
  pixels get their own answer — the march reaches as far, its first step lands as close. Quarter and
  full differ by 0.26 of 255 on average on an interior and score the same against a ray trace. The
  cost is **sharpness at silhouettes**, not coverage or noise — what the checkerboard closes.
- **The strength curve is a ratio, not a subtraction**, so occlusion approaches black without ever
  reaching it and a corner stays a gradient; at intensity 1.0 it is the identity. If occlusion looks
  crushed and speckled, suspect the transfer before the estimator — put a traced reference through
  the same curve and see whether the artifact survives (`docs/HISTORY.md`).
- **The denoise sizes itself** from the effect radius and the slice count, and weights neighbors by
  distance from the shaded point's **plane** rather than by depth difference, which is what lets a
  surface seen at a glancing angle keep its own neighbors. No width setting; `blur_passes` is inert.
- **Step spacing is even, not quadratic.** A horizon march can crowd steps near the shaded point
  because one early hit stands in for everything behind it; a mask cannot, so an occluder between
  two steps is absent, not approximated. `steps_per_slice` matters more here than in a stock GTAO.
- **Some grain survives at a large radius, and a wider filter will not remove it** — the residue is
  largely deterministic estimator structure, not sampling noise. Raising `slices` helps, costing
  taps but not accuracy, though it pays for the symptom. Three obvious fixes — widening the filter
  unconditionally, replacing the dither, rebalancing `slices` against `steps_per_slice` — have each
  been measured and failed. Read `docs/HISTORY.md` before re-trying any of them.
- **Switching an environment back to the legacy estimator releases the depth pyramid**, a full
  resolution float target with mips. Switching estimators every frame would thrash it.
