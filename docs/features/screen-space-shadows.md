# Screen space shadows for the sun

Using the Bend Studio contact shadow: settings, tuning, limits. Elsewhere: pass structure and the
`min()` composition (`docs/internals/screen-space-shadows.md`); sweeps behind the defaults
(`docs/HISTORY.md`); measuring a change (`docs/VALIDATION.md`); symptoms
(`docs/TROUBLESHOOTING.md`).

## What it is, and what it is for

- A screen space contact shadow for **one** `DirectionalLight3D`, marched over the depth pre-pass
  buffer. Off by default. Bend Studio's technique, Apache-2.0: `thirdparty/bend_sss/bend_sss_cpu.h`
  is vendored with no code changes and the shader is a port of their HLSL.
- **Not an alternative to that light's own shadow**, raytraced or cascaded. It is laid over it and
  the two combine as whichever is darker — a `min()`, not a multiply, because an occluder in both
  the acceleration structure and the depth buffer is described by both terms and multiplying darkens
  it twice. So it can only **darken**: a pixel the march finds nothing for keeps exactly the shadow
  the light itself gave it. Mechanism and the error bound: `docs/internals/screen-space-shadows.md`.
- It serves geometry **deliberately absent from the raytracing acceleration structure**, which
  therefore casts nothing into the raytraced shadow mask.
- Dense foliage is the case it exists for: the caster gather walks every element of a `MultiMesh`
  every frame on the render thread and pushes a TLAS record per element, so a grass field costs far
  more to keep in the structure than to draw. `GeometryInstance3D.cast_shadow = Off` removes that
  per-blade CPU cost and the blade's shadow with it; this pass gives it back at fixed screen space
  GPU cost and no CPU cost. **`cast_shadow` governs casting only** — grass still *receives*
  raytraced shadows as before.
- Opaque `GPUParticles3D` is in the same position: the fork gives particles no raytraced shadow at
  all (`docs/features/rt-shadows.md`), so this is the only shadow they can cast.

## Turning it on, and the settings

- **Enabling it forces the depth pre-pass on, and forces its MSAA resolve** — that buffer is what it
  marches over (`render_forward_clustered.cpp:2706`, `:2735`); raytraced shadows force the same two.
- **Every setting here is live**, `enabled` included: all read through `GLOBAL_GET_CACHED` each
  frame, so an edit takes effect next frame. (The raytraced shadow master switch is not.)
- **No per-light property.** The pass takes the first `DirectionalLight3D` in the render's light
  list that is actually casting: `shadow_enabled` on, `shadow_opacity > 0.001`, sky-only lights
  skipped (`light_storage.cpp:991`). A second one gets nothing — the mask has one channel.

All under `rendering/lights_and_shadows/screen_space_shadows/`, registered at
`core/config/project_settings.cpp:1917-1955`. Four are Bend Studio's own values, kept; `hardness` is
not part of their technique at all.

| Setting | Default | Range / values | What it does |
| --- | --- | --- | --- |
| `enabled` | `false` | bool | Turns the pass on. Also forces the depth pre-pass and its MSAA resolve. |
| `quality` | `Medium` (1) | Low (32 Samples), Medium (60 Samples), High (96 Samples) | March length, in **samples and therefore pixels** — not a world-space distance. |
| `surface_thickness` | `0.005` | 0.0001-0.1 | How solid the depth buffer's one surface per pixel is assumed to be. Sets how **wide** the shadow is. Bend's recommended starting value. |
| `bilinear_threshold` | `0.02` | 0.001-0.2 | Edge detect sensitivity: how far two neighboring depths may differ before the pair counts as an edge and interpolation is suppressed. Bend's value; scale it with `surface_thickness`. |
| `hardness` | `1.0` | 0-1 | How much one depth sample may darken a pixel alone. Sets how **dark** the shadow is. Not Bend's — `0.0` is their behavior exactly. |
| `ignore_edge_pixels` | `false` | bool | Stops a pixel the edge detect flags from casting. |
| `restrict_casters` | `false` | bool | Only geometry outside the acceleration structure casts. See below. |
| `debug_view` | `Disabled` (0) | Disabled, Edge Mask, Thread Index, Wave Index, Caster Mask | Bend's visualizations. See below. |

- Quality tiers, per `servers/rendering/renderer_rd/effects/screen_space_shadows.cpp:58-60`: sample
  count 32 / 60 / 96, last 5 / 8 / 12 faded out so a shadow ends rather than being cut off, first 4
  samples trusted alone at every tier.
- `contrast` and `strength` are **no longer settings**: constants at Bend's 4.0 and 1.0. `contrast`
  saturated when swept and `strength`'s zero was a second undocumented way to switch the pass off
  (`docs/HISTORY.md`). There is no third darkness knob.

## Tuning

Two knobs, in this order. **`hardness` sets how dark; `surface_thickness` sets how wide.** They are
independent: over the sweep `hardness` moved per-pixel darkness 2.1x while moving area 5%
`[shadow_validation]`; per-rig ratios in `docs/HISTORY.md`.

- **`hardness` is the knob for a shadow that reads too faint.** Bend average the march into four
  buckets, so a pixel needs four samples' worth of agreement before it is fully shadowed — right
  when a stray sample is likelier than a real one-sample occluder. Grass inverts that: samples are
  one pixel apart, so a narrower blade *is* a one-sample occluder and the average holds its shadow
  well short of a trace of it. `hardness` blends that average against the **minimum** of the same
  four buckets: `0.0` is Bend's behavior exactly, the default `1.0` lets one sample shadow, matching
  the trace, and the fatter the blade the closer `1.0` sits to it. Turn it down if a scene speckles
  — on 15,000 overlapping thin blades, near worst case, nothing did `[shadow_validation]`.
- **`hardness` does not recover shadow AREA.** On that 15,000-blade field it covers 95,517 shadowed
  pixels to the trace's 132,257 `[shadow_validation]`. The missing quarter is occluders off the top
  of the frame or further along the ray than the tier reaches, which no march over a depth buffer
  can find — what the `SHADOWS_ONLY` proxies below are for.
- **`surface_thickness` next.** A depth buffer records one surface per pixel and says nothing about
  how solid it is; this stands in for that. Too high and everything casts a thick shadow onto what
  is behind it; too low and shadows thin out. Move it in multiples of two, `bilinear_threshold` the
  same direction. Scaling it with the occluder's real depth looks right and **is not**: it trades a
  near-field error against a far-field one and only matches averaged over a frame. Keep `0.005`;
  per-band measurements in `docs/HISTORY.md`.
- Tune it against **total shadow mass**, not against how dark a shadow looks: the pass overshoots
  darkness while undershooting area, which is what a `min()` that can only darken looks like.
- **Raising `quality` has a side effect.** It widens the overlap with the raytraced shadow into the
  region where the penumbra has genuinely opened up, so a grass pixel under a wall can end up with a
  **harder** shadow edge than the terrain beside it.
- **Do not tune any of this by screenshot** — an eye judging "too dark" or "too light" reads one of
  those two quantities and not the other. `docs/validation/shadow_validation/` renders the scene
  with and without the pass and scores it against a raytraced reference; `docs/VALIDATION.md` and
  that directory's README list the numbers a change must not move. Measure with **MSAA off** as the
  control (the shipping configuration anyway): a resolved MSAA depth at a blade silhouette is an
  average or a least-frequent sample, not a real surface depth.
- **Leave `ignore_edge_pixels` off for foliage.** It thins genuine shadows at silhouettes, exactly
  the geometry this serves. Worth trying only on scenes of mostly large flat surfaces at grazing
  angles, where the edge detect misfires along them.

## What it cannot do (none of it tunable, none of it a bug)

- **Only occluders on screen and in front cast.** Grass just above the top of the viewport casts
  nothing, so shadows appear as the camera turns toward their caster.
- **Shadow length is bounded in PIXELS by the quality tier**, not in world units, so a low sun wants
  shadows longer than any affordable sample count reaches. Those are **internal** pixels — the pass
  dispatches at `get_internal_size()` (`render_forward_clustered.cpp:2230`), so under a 3D scale
  below 1.0 it reaches proportionally less far across the output (`docs/internals/dlss.md`).
- **Forward+, single view, one directional light.**
- **The complement for the first two: `SHADOWS_ONLY` clump proxies.** Where a long or off-screen
  grass shadow matters (grass at distance, a raking sunrise), add a second `MultiMeshInstance3D` of
  a few hundred low-poly clump proxies at `GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY`
  (inspector: Shadows Only). The gather rejects only `SHADOW_CASTING_SETTING_OFF`
  (`renderer_scene_cull.cpp:144`), so they cast a real raytraced shadow while drawing nothing.

| Declines in | Behavior |
| --- | --- |
| Multiview / XR | Declines with a one-time warning. |
| Reflection probe renders | Declines silently — no render buffers of their own to hold a mask. |
| **Orthographic** cameras, editor Top/Front/Side included | Declines with a one-time warning: an orthographic projection gives a direction vector a clip `w` of exactly zero and the march takes its direction from that sign, so a sun in front and a sun behind are indistinguishable to it. Forcing the sign is not enough either; stage 19 of `docs/PORTING.md` derives both halves. |

## Cost

**Not measured on hardware**: no millisecond figure exists, on either target machine or anything
else, so measure before budgeting. Fixed with respect to scene complexity (a compute march over
depth, indifferent to how many blades made it); scales with internal resolution and tier samples.

## `restrict_casters`

Makes only geometry the acceleration structure will **not** hold cast a screen space shadow. Ships
off, a settled decision rather than work in flight.

- **Nothing needs authoring.** The set is the exact complement of the raytracing caster gather
  (`renderer_scene_cull.cpp:142-159`): an instance casts a screen space shadow exactly when the
  structure rejects it — `cast_shadow` is `Off`, or it is not a mesh or multimesh, or its material
  cannot cast shadows. Grass set up the way this feature expects is already in the set.
- The argument for it is correctness, not only cost: on a wall the screen space term is a wrong dark
  smudge over an already-correct traced answer, since `min()` means its own error can only darken
  such a pixel past the trace. On grass the same term is the best answer available.
- **Why it ships off:** `surface_thickness` and `hardness` were both calibrated with *every* opaque
  pixel casting, so their defaults describe the unrestricted pass, and the restriction moves the
  very quantity they were tuned to match. Flipping it honestly needs a scene with real props among
  the grass at `cast_shadow = On`, both knobs re-derived on **both** sides of the toggle in linear
  light, and the default flipped only if the restricted side wins. Not run (`docs/HISTORY.md`).
- **The A/B you can run today moves a single pixel, and that is not evidence.** On all four
  committed rigs the toggle changes one pixel `[shadow_validation]` — they are grass on an empty
  ground plane, so the only structure geometry is a flat plane, and a flat plane cannot occlude
  itself from a 38 degree sun. Do not read it as the toggle doing nothing;
  `docs/validation/shadow_validation/field.gd` is the closest start on a rig that could settle it.
- **One real authoring cost: alpha-scissor foliage is in the structure**, so it stops casting a
  screen space shadow when this is on: a leaf card casts a correctly cut-out contact shadow today
  while its raytraced shadow is the whole quad, and afterwards keeps only the quad. Author such
  foliage with `cast_shadow = Off` as well if that matters.
- **First-sight hitch.** It switches the depth pre-pass to a variant writing an extra `R8_UNORM`
  target at internal resolution, and that variant is **not precompiled** — the pipeline pre-warm has
  no bit for this pass mode — so every material compiles its pre-pass pipeline the first time it is
  drawn. A hitch on first sight of new geometry, not a per-frame cost.
- Worth turning on per project where the scene is mostly structure geometry with a little foliage.
  **It declines, leaving every surface casting, in three cases**, all warning except the first:

| Case | Why |
| --- | --- |
| Sun not raytraced (`raytraced_shadows/directional/enabled` off) | The structure then holds only geometry near raytraced lamps, so restricting would take contact shadows away from geometry getting none from anywhere else. |
| A **VoxelGI** is visible | The depth pass mode chain gives the VoxelGI variant priority and nothing then writes the caster mask. |
| **MSAA** on | Until the caster flag's resolve is written: it has to follow the depth's own `best_index` sample, and averaging or OR-ing it casts from a surface that was never a caster. |

## `debug_view` — how to bring the pass up, rather than guess at it

| Mode | What it is for |
| --- | --- |
| `Wave Index` | **First.** Draws the compute wavefront layout, which must fan out from the sun's position on screen. If it does not, the light's projected coordinate is wrong and nothing else is worth tuning. |
| `Edge Mask` | Where the edge detect is firing. This is what `bilinear_threshold` controls. |
| `Caster Mask` | Which pixels are allowed to cast: white is a caster. With `restrict_casters` off it is white everywhere. |
| `Thread Index` | Bend's thread layout visualization. |
