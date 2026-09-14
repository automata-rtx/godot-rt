# Screen space contact shadow: internals

Pass structure, the march, light selection, the `min()` composition, the caster restriction.
Elsewhere: settings (`docs/features/screen-space-shadows.md`), sweeps (`docs/HISTORY.md`), the
port recipe (stages 19-20 of `docs/PORTING.md`), measurement (`docs/VALIDATION.md`), symptoms
(`docs/TROUBLESHOOTING.md`).

## Provenance

- Bend Studio's technique, Apache-2.0 (`thirdparty/bend_sss/LICENSE.txt`).
- `thirdparty/bend_sss/bend_sss_cpu.h` vendored with **no code changes** (only line-ending and
  trailing-whitespace normalization). Header only, so no `SCsub` entry; needs an entry in
  `thirdparty/README.md` and one `Files:` stanza in `COPYRIGHT.txt` covering the ported shader too.
- `.../shaders/effects/screen_space_shadow.glsl` ports Bend's HLSL to RD GLSL. Four deviations,
  forced by the target, listed in the shader's own header: reverse-Z with a `[0,1]` clip range
  (generic through `z_sign`); no portable GLSL equivalent of HLSL `Sample()` with a compile-time
  integer offset, so only the original's `USE_UV_PIXEL_BIAS` path survives; `DispatchParameters`
  cannot be a struct (no samplers in GLSL structs), so its scalars are the push constant and its
  textures plain bindings; the image store is bounds checked (the original's API defines an
  out-of-range write as a no-op).
- Two further inversions are invisible when wrong — "Coordinate conventions the port inverts".

## Code map

| File | What it holds |
| --- | --- |
| `thirdparty/bend_sss/bend_sss_cpu.h` | `Bend::BuildDispatchList`, the dispatch list builder. |
| `.../shaders/effects/screen_space_shadow.glsl` | The march. 421 lines. |
| `.../renderer_rd/effects/screen_space_shadows.{h,cpp}` | Pass driver: pipelines, border sampler, light projection, dispatch loop. |
| `.../renderer_rd/renderer_scene_render_rd.cpp` | `get_screen_space_shadows()` — lazy build, sticky failure. |
| `.../forward_clustered/render_forward_clustered.{h,cpp}` | `_using_screen_space_shadows`, `_using_restricted_sss_casters`, `_ensure_screen_space_shadow_mask`, `_render_screen_space_shadows`, `ensure_sss_caster_texture`, binding 39. |
| `.../storage_rd/light_storage.{h,cpp}` | `SSSLight` (picks the light), `DirectionalLightData::sss_strength` (the mark). |
| `.../shaders/scene_forward_lights_inc.glsl` | `sss_shadow_lookup()`, `RT_MASK_ANSWERS_HERE`. |
| `.../shaders/forward_clustered/scene_forward_clustered{,_inc}.glsl` | Binding 39, the `min()` composition, `MODE_RENDER_SSS_CASTER`. |
| `servers/rendering/renderer_scene_cull.cpp` | `_casts_into_acceleration_structure()`, `_is_screen_space_shadow_caster()`. |
| `renderer_geometry_instance.{h,cpp}`, `dummy/rasterizer_scene_dummy.h` | `set_screen_space_shadow_caster()`. |

## Where it runs in the frame

| Point | Detail, and what a miss does |
| --- | --- |
| Dispatch site | `_pre_opaque_render`, at `if (rb_data.is_valid() && using_screen_space_shadows)`: **after** `update_light_buffers` (which fills `LightStorage::sss_light`) and **beside** the raytraced block, not inside it. Earlier and `light.valid` is always false — no mask is ever written. |
| Not gated on raytracing | Deliberately not behind `is_raytracing_scene_available()`: the geometry it serves left the acceleration structure on purpose, so it must work with raytraced shadows off. |
| Dispatch size | `rb->get_internal_size()`. Every length here is in **internal** pixels, so a temporal upscaler shortens its reach across the output (`docs/internals/dlss.md`). |
| `_using_screen_space_shadows` runs **twice per frame** | `_render_scene` (building `force_depth_pre_pass`) and `_pre_opaque_render`. The first runs before the light buffers exist, so it **must not consult the light**: setting, reflection probe, render buffers, view count, projection, effect buildable, nothing else. An "is there a shadow-casting sun" term makes the two answers disagree — pre-pass not forced, march reading a depth buffer nothing wrote this frame. Price of the honest version: a forced pre-pass in a sunless scene. |
| Two `_render_scene` variables it must appear in, both already carrying a raytraced term | `force_depth_pre_pass` = `scene_state.used_opaque_stencil \|\| is_raytracing_scene_available() \|\| using_screen_space_shadows` — miss it and the setting does nothing unless the project enabled the pre-pass by hand. `finish_depth`, whose `else if (finish_depth)` branch calls `resolve_effects->resolve_depth` into `rb->get_depth_texture()` — miss it and the feature works with MSAA off but produces nothing, or last frame's shadows, with MSAA on. This is the one feature forcing both with raytracing off, so neither term folds into `is_raytracing_scene_available()`. |

## Declining, and why each one declines

| Condition — `_using_screen_space_shadows` tests in this order | Warns, and why |
| --- | --- |
| `screen_space_shadows/enabled` off | no |
| Reflection probe render, or `render_buffers` null | no — no buffers to hold a mask, and its camera is not the one any mask describes |
| `rb->get_view_count() > 1` | `WARN_PRINT_ONCE` — stereo needs a dispatch and a mask per eye, and the depth buffer is a 2D array the pass's `sampler2D` cannot be handed |
| `scene_data->cam_projection.is_orthogonal()` | `WARN_PRINT_ONCE`. **One exact zero read two ways that disagree.** `Projection::set_orthogonal` leaves `columns[2][3]` at the 0 `set_identity()` wrote — the element `is_orthogonal()` tests and the one `xform()` builds `w` from — so a direction vector, entering with `w = 0`, leaves with `w` exactly zero. `BuildDispatchList` clamps the magnitude up to `±FP_limit` (`0.000002f * inWaveSize`) when placing `LightCoordinate_Shader[0..1]`, putting the light on the side the sun really is, but takes the march direction from `LightCoordinate_Shader[3] = inLightProjection[3] > 0 ? 1 : -1`, where `0 > 0` is false and yields -1, "behind the camera": a sun in front produces byte-identical output to a sun behind. Forcing the sign fixes half — the march also divides every stored depth by its distance along the ray to make the light's rays parallel, which a perspective projection needs and an orthographic one (rays already parallel, depth linear) does not. Hence no contact shadow in the editor's Top/Front/Side views. |
| Effect could not be built | constructor already printed why (except `_render_buffers_can_be_storage()`, silent, unreachable in Forward+) |

## The effect object and its targets

| Thing | Detail |
| --- | --- |
| `get_screen_space_shadows()` | Builds on first use; failure is **sticky** (`screen_space_shadows_unavailable = true` set before construction, cleared only on success), so an incapable device is not retried per frame. Not built in the constructor: off by default, and building compiles three variants. |
| Four constructor failures, each with its own message | `R8_UNORM` not usable as a storage image (not in Vulkan's guaranteed set without `shaderStorageImageExtendedFormats`; widening to 4x the bandwidth silently is worse than saying so); a variant that will not compile (the in-code note names the subgroup vote as the likely cause and asserts the D3D12 SPIR-V-to-DXIL path does not handle it); pipeline creation; the border sampler. |
| Teardown | `~RendererSceneRenderRD` must `memdelete(screen_space_shadows)`; `~ScreenSpaceShadows` frees `depth_sampler` and `shader_version` (which frees the pipelines built from it). |
| Depth sampler | **Point filtered on all three filters, clamped to a transparent-black border**, not to the edge: the march reads off screen on purpose and those reads must come back "nothing here" — under reverse-Z, red reading 0.0 is the far plane. `CLAMP_TO_EDGE` smears the border texel outward and streams shadows in from the sides of the screen. |
| Mask texture | `_ensure_screen_space_shadow_mask` creates `RB_SCOPE_SCREEN_SPACE_SHADOWS` / `RB_TEX_SCREEN_SPACE_SHADOW_MASK` (`SNAME("screen_space_shadows")` / `SNAME("sss_mask")`), `R8_UNORM`, buffers' **internal** size, one layer, usage `SAMPLING \| STORAGE \| CAN_COPY_TO \| CAN_COPY_FROM`. `is_target_format_supported()` queries the first three; `CAN_COPY_TO` is what the two `texture_clear` calls need — a storage-only texture fails the clear, not the dispatch. |
| Two clears to white (fully lit), **both needed, covering different frames** | Creation covers a frame where the buffers are reconfigured and the pass does not run; the one at the top of `render()` covers early returns inside it, sitting ahead of **every remaining** early return (degenerate direction, empty dispatch list) — only two precede it, invalid effect or null depth/output texture, and a non-positive size. Because a rejected pixel is a pixel no dispatch writes, so the target must start from a known value; and a frame bailing out after a light has been marked must not leave the previous frame's shadows standing. |
| No light selected | `_render_screen_space_shadows` returns before `render()` and the mask keeps what it last held — harmless, since no light is marked to read it. The depth pre-pass is still forced, the predicate being unable to see the light. |

## The wavefront march

| Element | Detail |
| --- | --- |
| Shape of the pass | A workgroup of `WAVE_SIZE = 64` threads is laid out **along one light ray**, reads that line's depths once into shared memory, and every thread on the line then tests itself against all of them: a handful of texture fetches per pixel rather than one per step. |
| `WAVE_SIZE` | The shader's `local_size_x` — a **workgroup** size, not a hardware wave size. On a 32-wide device (an RTX 5090 is 32-wide) one workgroup spans several hardware waves, which is what the `lds_early_out` path with its two `memoryBarrierShared(); barrier();` pairs exists for. `gl_SubgroupSize` in its place breaks the match with the CPU-side layout. |
| `BuildDispatchList` inputs | The negated-Y clip vector, the viewport size, and **inclusive** full screen bounds (`{0,0}` to `{size.x - 1, size.y - 1}`): a directional light has no on-screen volume to bound, and bounding it saves no dispatches, since the shader reads and writes up to `2 * WAVE_SIZE` pixels outside whatever bounds it is given. |
| Its output | Four quadrants around the light's pixel coordinate, a non-square quadrant split on its larger axis, **at most 8 dispatches** (Bend's note: typically 1-2 with the light off screen, 4-6 on screen). `WaveOffset_Shader` is per-dispatch and routinely negative — `-bounds[2]`, `-bounds[3]` for two quadrants. |
| Dispatch loop | One `compute_list_begin()`/`compute_list_end()` around the whole loop, one pipeline bind and one uniform set bind outside it; each iteration writes only `wave_offset` into the push constant and calls **`compute_list_dispatch`, not `compute_list_dispatch_threads`** — `WaveCount[0]` is `inWaveSize` workgroups, which is how wavefronts step along their rays; dividing it by the local size runs a sixty-fourth of the work, a thin wedge of shadow near the light and nothing else. The dispatches write disjoint pixels and read only the depth buffer, so no barrier between them; one compute list per dispatch puts those barriers back. |
| `compute_wavefront_extents()` | Per thread: start pixel, the delta walking `WAVE_SIZE` pixels further along the ray, distance to the light, which axis is major. `reverse_direction = light_coordinate.w > 0.0` inverts the read order when the light is behind the camera (`thread_step` XORs the local index against `WAVE_SIZE - 1`). |
| **Wave Index draws this geometry** | `result = fract(float(gl_WorkGroupID.x) / float(WAVE_SIZE))` ramps along the workgroups stepping outward from the light, so the pattern must **fan out from the sun's screen position and track it as the camera turns**. Converging elsewhere means the light's projected coordinate is wrong — the Y negation, the direction sign, or the wrong projection — and nothing else is worth tuning. Thread Index (`gl_LocalInvocationID.x / WAVE_SIZE`) ramps along the 64 threads of one workgroup, which lie along a single ray, so it shows the ray direction and separates a light-coordinate error from a wave-offset error. All debug views suppress the early-out (so they paint the sky) and write into the mask rather than over the screen: read them on a sunlit surface. |

### Coordinate conventions the port inverts

| Inversion — the first two fail silently and plausibly | Detail |
| --- | --- |
| **Clip Y handedness** | `BuildDispatchList` maps clip Y to a pixel row with `* -0.5f + 0.5f` (`bend_sss_cpu.h`, `LightCoordinate_Shader[1]`), correct where clip `+1` is the top row. Godot's corrected projection already negates Y (`Projection::set_depth_correction` sets `m[5] = -1` under `flip_y`, against a positive-height Vulkan viewport), so its `-1` is the top row and Bend's negation on top mirrors the light vertically. Fix in `ScreenSpaceShadows::render`: build `light_projection` with `-light_clip.y`, leaving the vendored file alone — exactly equivalent, that being the only place Y is read. When wrong the pass still draws shadows, pointing away from the sun's mirror image, so a high sun reads as a low one; Wave Index shows it converging on a point mirrored about the screen's horizontal center line. |
| **Signedness of the wave offset** | `ivec2 xy = ivec2(gl_WorkGroupID.yz) * WAVE_SIZE + params.wave_offset;` — `gl_WorkGroupID` is a `uvec3` and `wave_offset` is routinely negative, so the cast must precede the add or the sum is computed unsigned and wraps. The two quadrants left of and above the light then fill with garbage while the two below and right stay correct; that asymmetry is the tell, since it otherwise looks like a wrong light coordinate. |
| **Direction** | `LightStorage::update_light_buffers` builds a directional light's `direction` as `inverse_transform.basis.xform(light_transform.basis.xform(Vector3(0, 0, 1))).normalized()` — the light basis's **+Z**, pointing back toward the light, where omni and spot store -Z — then into view space, normalized. `SSSLight::direction` is a copy; `render()` takes it as `p_light_direction_view` and passes it through **with no negation**, the march running from each pixel toward the light and converging on the light's vanishing point. Negate it and shadows radiate away from the sun, which reads as a lighting setup rather than a bug. Bend's comment asks for `float4(light, 0) * ViewProjectionMatrix`; following that literally with a world-space direction gives a plausible-looking wrong answer. |
| **Projection** | Must be `scene_data->get_cam_projection()` — corrected and **jittered**, the one the depth buffer was rasterized with, not the raw `cam_projection` member, which puts the light's screen position up to half a pixel out every frame and crawls the whole shadow field with jitter. |

## Light selection and the `sss_strength` name tag

| Point | Detail |
| --- | --- |
| Not a per-light property | One mask channel, so room for exactly one light, and `LightStorage` picks it: `sss_available = p_using_shadows && p_use_screen_space_shadows` in `update_light_buffers`, the second term being the caller's `_using_screen_space_shadows`. The first directional light with `light->shadow` set and `LIGHT_PARAM_SHADOW_OPACITY > 0.001` takes it — `sss_light.valid`, `sss_light.direction` and `light_data.sss_strength = 1.0f` written together, every other directional light keeping `sss_strength = 0.0f`. |
| Two extra parameters | `update_light_buffers(..., bool p_using_shadows, bool p_use_raytraced_shadows, bool p_use_screen_space_shadows, ...)`; `RenderForwardMobile::_render_scene` passes `false, false` for the last two. |
| The 1.0 is a constant; the field is a name tag, not a strength | It was a `screen_space_shadows/strength` setting until that was removed as a second, undocumented off switch. It cannot be folded away despite being only ever 0.0 or 1.0: it is the only thing telling the forward shader which directional light the single-channel mask belongs to. No companion index texture, as the raytraced mask has (bindings 37/38 — `docs/internals/rt-shadows.md`). |
| **Mark a light ONLY when a mask is genuinely written for it that pass** | Otherwise the sun goes out across the frame: binding 39 falls back to `DEFAULT_RD_TEXTURE_WHITE`, which is **4x4**, and `sss_shadow_lookup()` `texelFetch`es at `gl_FragCoord` — past the fourth pixel an out-of-range fetch, zero (fully shadowed) under image robustness, undefined without it. The function's `textureSize` guard returns 1.0 there, downgrading that to no contact shadow anywhere. **Keep the guard and the invariant that makes it unreachable** — the guard is not dead code. |
| `DirectionalLightData` gains a whole `vec4`, not a spare float | `sss_strength` plus three slots, after `volumetric_fog_energy`, before `shadow_bias`. The fields ahead sum to exactly 80 bytes, so `sss_strength` opens a fresh 16-byte slot and the rest close it; the `vec4` array that follows needs that alignment, and one bare float shifts every shadow matrix by four bytes on one side only. Two spare slots are now `uint rt_caster_mask` and `float rt_softshadow_angle` (the fog's own sun ray), leaving one `pad_sss`. |
| Anything added there must be written **unconditionally** | Beside the field it derives from, never inside a branch: the array is persistent and indexed by light count, so a field written only on some frames holds whichever light last occupied that index. `light_data_inc.glsl` reaches `scene_forward_clustered_inc.glsl`, `scene_forward_mobile_inc.glsl`, `volumetric_fog.glsl`, `volumetric_fog_process.glsl`. |
| **Name collision: `sss` here is *screen space shadow*, never subsurface scattering** | Upstream owns the other meaning in the same files — `scene_forward_clustered.glsl:1069` declares `specular_buffer` "specular and SSS (subsurface scatter)", and the `sss_strength` *local* (`:1302`) is subsurface strength, written to the diffuse buffer's alpha (`:3263`, sign-flipped to flag skin) and to `orm_output_buffer.a`; the name recurs in `scene_forward_mobile.glsl`, `material.cpp`, `shader_types.cpp` and the GLES3 shaders. Grepping the bare symbol is mostly false hits; this fork's marker is always qualified, `directional_lights.data[i].sss_strength`. |

## The shader

| Line — per thread, `READ_COUNT = SAMPLE_COUNT / WAVE_SIZE + 2` bilinear pairs | Detail |
| --- | --- |
| Two depth fetches per step | `depths.x` at the pixel center, `depths.y` one pixel along the ray's **minor** axis (the major-axis coordinate stays at a pixel center). |
| `depth_thickness_scale[i] = abs(far_depth_value - depths.x)` | Thickness and edge thresholds are fractions of the gap between this sample and the far plane, not of the whole depth range. |
| `use_point_filter = abs(depths.x - depths.y) > depth_thickness_scale[i] * bilinear_threshold` | What the **Edge Mask** debug view draws (white where it fires, for `i == 0`), and the only sane way to tune `bilinear_threshold`. Scale it whenever `surface_thickness` is scaled, same direction. |
| `ignore_edge_pixels` | Replaces an edge sample's shadowing depth with `edge_skip = 1e20` rather than branching. Thins genuine shadows at silhouettes, the geometry the feature serves. |
| `sample_distance[i] = pixel_distance + WAVE_SIZE * i * direction` | `direction = -light_coordinate.w`. |

**Early-out.** `early_out_pixel()` rejects `depth >= depth_bounds.y || depth <= depth_bounds.x`;
`depth_bounds` is `(0, 1)` for a directional light, culling the sky — those pixels sit exactly at
the far value. Reverse-Z lives entirely in two push constant fields, `far_depth_value = 0.0` and
`near_depth_value = 1.0`, the shader deriving `z_sign` from their relationship; nothing else in
the port assumes a direction. The vote is `subgroupAny`, promoted through `lds_early_out` in
shared memory when `gl_SubgroupSize != WAVE_SIZE`: the whole workgroup must agree before any
hardware wave leaves, since survivors read shared-memory entries the leavers would not have
written. Bend's suggestion to also skip pixels an existing shadow pass found occluded is
deliberately **not** taken — the raytraced mask is available here in `_pre_opaque_render`, but
this pass must work with raytraced shadows off, and a second code path is not worth a partial
early-out.

**Shared memory and perspective correction.** `depth_data[(i * WAVE_SIZE) +
gl_LocalInvocationID.x]` holds `stored_depth = (shadowing_depth[i] - light_coordinate.z) /
sample_distance[i]`. Dividing by distance along the ray makes every light ray parallel in that
space, which lets one line of shared depths answer for every thread on it. For `i != 0`, a sample
whose `sample_distance` is not positive has overshot the light and is replaced with the sentinel
`1e10`, "cannot shadow".

`depth_scale = min(sample_distance[0] + direction, 1.0 / surface_thickness) * sample_distance[0] /
depth_thickness_scale[0]` is the inverse width of the shadowing window: `1 / surface_thickness`
turns the user's fraction into that window, `/ depth_thickness_scale[0]` accounts for the fraction
being of the remaining depth to the far plane, the `min()` keeps the window from collapsing very
close to the light, `+ direction` biases the pixel at the light's exact center to fully lit or
fully shadowed rather than half of each. **`surface_thickness` is floored at `1e-6` in the
driver** (`MAX(p_settings.surface_thickness, 0.000001f)`), not only ranged in the project setting,
because it is that divisor: zero divides by zero across the whole frame, and
`ProjectSettings.set_setting()` ignores the range.

**Bend's four accumulators, and what `hardness` does to them.** Three loops, all accumulating
`depth_delta = abs(start_depth - depth_data[...] * depth_scale)`:

| Loop | Range | Target |
| --- | --- | --- |
| Hard | `0 .. HARD_SHADOW_SAMPLES` | `hard_shadow = min(hard_shadow, delta)` — a single sample may shadow alone |
| Bulk | `HARD_SHADOW_SAMPLES .. SAMPLE_COUNT - FADE_OUT_SAMPLES` | `shadow_value[i & 3] = min(shadow_value[i & 3], delta)` — four accumulators, round robin |
| Fade | last `FADE_OUT_SAMPLES` | same, plus `fade_out = (i + 1 - (SAMPLE_COUNT - FADE_OUT_SAMPLES)) / (FADE_OUT_SAMPLES + 1) * 0.75` so the shadow ends rather than being cut off |

Then `shadow_value = clamp(shadow_value * shadow_contrast + (1.0 - shadow_contrast), 0, 1)`, same
for `hard_shadow`: zero delta means a sample matched the reference depth exactly, and the contrast
boost spreads that so a near miss still shadows.

**Bend average the four accumulators**, so a pixel needs four samples' worth of agreement to be
fully shadowed — right when a stray sample is likelier than a genuine one-sample occluder, and
why only the first `HARD_SHADOW_SAMPLES` are trusted alone. Grass inverts that: a blade narrower
than the march's one-pixel sample spacing **is** a one-sample occluder, so the average holds its
shadow short of the trace's however the rest is tuned. `hardness` is this fork's own control, no
part of Bend's technique: the **minimum** of the same four accumulators is the identical test
with the evidence requirement dropped to one sample, and `hardness` blends between them.

    float result = mix(dot(shadow_value, vec4(0.25)),
            min(min(shadow_value.x, shadow_value.y), min(shadow_value.z, shadow_value.w)),
            params.hardness);
    result = min(hard_shadow, result);

| Knob | Detail |
| --- | --- |
| `hardness` range | `0.0` is **Bend's behavior exactly**; the default `1.0` lets any single bulk sample shadow, matching a trace of the same blades. Three `min()` for the whole march, nothing else changed. |
| `hardness` vs `surface_thickness` | It moves darkness far more than area, so the two are independent — hardness sets how dark, thickness how wide. Per-rig ratios and sweeps: `docs/HISTORY.md`. |
| `contrast` 4.0 and `strength` 1.0 are now constants | Both were settings until they were swept: `contrast` only widened the window around an exact depth match and saturated; `strength` scaled the whole term and its zero was a second, undocumented off switch (`docs/HISTORY.md`). The push constant field `shadow_contrast` and the shader arithmetic are untouched — this is a port and it keeps their parameter — and the driver writes `MAX(p_settings.contrast, 1.0f)`. |

**Store.** `imageStore(shadow_image, store_xy, vec4(result))`, guarded by an explicit in-bounds
test: the original relies on an API that drops out-of-range stores while deliberately writing up
to `2 * WAVE_SIZE` pixels outside the requested bounds. Stored **linearly**, unlike the raytraced
mask's square root — a contact term's interesting range is the whole of zero to one, not a
visibility mostly equal to one, so the sqrt would spend its eight bits in the wrong place, and
squaring on read silently lightens every contact shadow.

## Variants and the push constant

| Item | Detail |
| --- | --- |
| One compiled variant per quality tier | Sample loops are unrolled and the shared array is sized from the count, so the count cannot be a uniform or a specialization constant. Defines: `SAMPLE_COUNT` 32/60/96 with `FADE_OUT_SAMPLES` 5/8/12. `HARD_SHADOW_SAMPLES` stays at Bend's 4 in every tier — it is what grounds a blade against the surface it stands on, the last thing to trade for speed. |
| Push constant: **76 bytes**, `static_assert`ed | Order: `light_coordinate[4]`, `wave_offset[2]`, `screen_size[2]`, `inv_depth_texture_size[2]`, `depth_bounds[2]`, `surface_thickness`, `bilinear_threshold`, `shadow_contrast`, `far_depth_value`, `near_depth_value`, `flags`, `hardness`. `wave_offset` is the only field changing between dispatches of one light. |
| A size mismatch fails into a value that looks intentional | Under `DEBUG_ENABLED` RenderingDevice rejects a push constant whose size differs from the reflected block, then refuses the dispatch for having none, so the mask keeps its cleared white and the feature reads as "the setting does nothing" — fatal in the editor, invisible in every shipped configuration, which has neither check compiled (`CLAUDE.md`, on the CI matrix). |
| Flags — `ScreenSpaceShadows::Flags` must match the shader's `FLAG_` defines bit for bit, nothing but their order matching them | `IGNORE_EDGE_PIXELS 1<<0`, `USE_PRECISION_OFFSET 1<<1`, `BILINEAR_SAMPLING_OFFSET_MODE 1<<2`, `USE_EARLY_OUT 1<<3`, `DEBUG_EDGE_MASK 1<<4`, `DEBUG_THREAD_INDEX 1<<5`, `DEBUG_WAVE_INDEX 1<<6`, `RESTRICT_CASTERS 1<<7`, `DEBUG_CASTER_MASK 1<<8`. Every debug flag must appear in the early-out exclusion list, or that view is blank wherever a wave votes to leave — most of the sky, most of the shadowed ground — and looks broken while the feature works. |
| `#include <thirdparty/bend_sss/bend_sss_cpu.h>` | **Angle brackets, after the engine includes.** `validate-includes` and `clang-format` want different things here and are satisfied only by meeting both conventions at once; getting it wrong has broken the build once. |

## Composition in the forward shader

| Piece | Where it goes, and the constraint |
| --- | --- |
| `sss_shadow_lookup()` | `.../shaders/scene_forward_lights_inc.glsl`, inside the `#ifndef USING_MOBILE_RENDERER` block: it reads `gl_FragCoord`, which the vertex stage that includes `scene_forward_clustered_inc.glsl` does not have — and that file is shared with the mobile renderer. |
| Binding 39, `texture2D sss_shadow_mask` | Appended after the raytraced mask and index (37, 38) in `RENDER_PASS_UNIFORM_SET`, declared **inside the `#else` half of `scene_forward_clustered_inc.glsl`'s `#ifdef MODE_RENDER_SDF`**, not at file scope where the SDF variant would declare a binding it has no uniform for. Plain 2D in every variant, multiview included, the pass being single view. Fill it on every path through `_setup_render_pass_uniform_set`, reflection probe and no-render-buffer renders included, defaulting to `DEFAULT_RD_TEXTURE_WHITE`; a path that skips it fails uniform set validation for the whole pass, not just for this feature. |
| The composition itself | `scene_forward_clustered.glsl`, immediately after the `} // shadows` brace closing both the mask path and the cascade path, and **before** the `if (rt_shadowed \|\| shadow_opacity > 0.001)` tail. |

    if (directional_lights.data[i].sss_strength > 0.0 && RT_MASK_ANSWERS_HERE) {
        float contact = mix(1.0, sss_shadow_lookup(), directional_lights.data[i].sss_strength);
        if (rt_shadowed) {
            contact = mix(contact, 1.0, sun_fade);
        }
        shadow = min(shadow, contact);
    }

| Rule | Why |
| --- | --- |
| **`min()`, not a multiply** | An occluder both in the acceleration structure and in the depth buffer the march reads is described by **both** terms, so multiplying darkens it twice. The darker answer leaves such a pixel alone and still lets the screen space term shadow what the structure has never heard of. |
| **The remaining error is bounded by construction** | The march reaches `SAMPLE_COUNT` pixels, the contact region, which is where the sun's penumbra is narrowest: at the fork's default `light_angular_distance` of 0.25 degrees a penumbra is about **4 mm at 1 m and 4 cm at 10 m** `[arithmetic]`, so the two techniques substantially agree over the range where they overlap. Raising the quality tier widens that overlap into the region where the penumbra has genuinely opened up, so a grass pixel under a wall can end up with a harder edge than the terrain beside it. `restrict_casters` drops the redundant term on such a surface altogether. |
| **Composition can only darken** | A `--verbose` run of `docs/validation/shadow_validation/run.sh` asserts exactly that — no pixel of any variant lighter than the frame with the pass off, scored in linear light (`docs/VALIDATION.md`). |
| **Placement is the other half** | After the tail, a baked shadowmask's replace/overlay branch overwrites it and the `USE_VERTEX_LIGHTING` apply never sees it. |
| **`RT_MASK_ANSWERS_HERE` applies unchanged** | `!bool(scene_data_block.data.flags & SCENE_DATA_FLAGS_IN_ALPHA_PASS)`, compile-time `true` under `USE_OPAQUE_PREPASS` or `ALPHA_ANTIALIASING_EDGE_USED`. This mask is marched over the pre-pass depth too, so it describes exactly the fragments that pre-pass contains, and a genuinely alpha-blended fragment must not read it. |
| **The `sun_fade` term is not optional** | `sun_fade = smoothstep(fade_from, fade_to, vertex.z)` is the sun's distance fade. The cascade path fades the combined term further down, contact shadow included; the raytraced path's fade is already baked into `shadow` and that block is skipped, so without this line the contact term alone would survive to the horizon at full strength on one path and fade out on the other. The march has no world-space range limit of its own — its reach is bounded in pixels by the quality tier — so nothing else would bound it. |

## Restricting what casts

`screen_space_shadows/restrict_casters` (off by default): only geometry the acceleration structure
will **not** hold casts, through one byte per pixel written in the depth pre-pass and read at the
march's caster reads. Why it ships off: `docs/features/screen-space-shadows.md`,
`docs/HISTORY.md`.

| Point | Detail |
| --- | --- |
| **A correctness change, not an optimization** | Everything in the structure already has an exact traced shadow from the same light, so for those pixels the screen space term can only darken *past* the traced answer — near-field truncation and one pixel of rasterization overshoot push the same way, and `min()` keeps whichever is darker. On grass it is the best answer available; on a wall it is a wrong dark smudge over a right one. |
| **Cost to authors** | Alpha-scissor foliage passes `casts_shadows()`, so it is in the structure and stops casting a screen space shadow when this is on: today a leaf card casts a correctly cut-out contact shadow while its traced shadow is the whole quad (the trace ignores the cutout — `docs/internals/rt-shadows.md`), and afterwards it keeps only the quad. It coarsens rather than vanishing, and nothing surfaces it; the answer for authors is `cast_shadow = Off` on the foliage as well, putting it back in the screen space set (`docs/features/screen-space-shadows.md`). |

### The predicate

`_is_screen_space_shadow_caster()` in `renderer_scene_cull.cpp` is
`!_casts_into_acceleration_structure()`, and `CullRTCasters::operator()` — which decides what goes
*into* the structure — calls the same helper, so the two are exact complements **by construction**;
they were two hand-maintained copies and disagreeing is no longer expressible. The structure
**rejects** the instance, making it a screen space caster, when any one of three instance-level
tests holds: `cast_shadows == SHADOW_CASTING_SETTING_OFF`; `base_type` neither `INSTANCE_MESH` nor
`INSTANCE_MULTIMESH`; `InstanceGeometryData` null or `!geom->can_cast_shadows`.

| Point | Detail |
| --- | --- |
| `CullRTCasters` extras | It additionally rejects `!instance->visible`, a null `base`, and repeats via `instance->rt_caster_pass` — its own business: an invisible instance rasterizes no pre-pass pixel, and the pass counter is per-query bookkeeping rather than eligibility. |
| `can_cast_shadows` | The engine's own answer, computed in `_update_dirty_instance` from `material_casts_shadows()` over every surface plus the material overlay. That is what puts alpha-scissor foliage on the structure's side of the line. |
| **Instance level on purpose** | The predicate does not see the per-surface `shadow_caster_surface_mask`, per-element multimesh culling, light range, or the BLAS budget. All of those make the structure hold *less* than the instance-level test assumes, so ignoring them can only **over-include** — a pixel describing itself in both terms, which `min()` absorbs by construction. Only under-inclusion loses a shadow, and this never under-includes. "Improving" the predicate by consulting the per-surface mask starts under-including and starts losing shadows. |

### Getting the flag to the GPU

| Seam — the flag is **pushed** at the instance, never polled | Requirement, and what a miss does |
| --- | --- |
| `instance_set_base()` | Creation — miss it and a new instance carries the default until something else dirties it. |
| `instance_geometry_set_cast_shadows_setting()` | The runtime one: `cast_shadow = Off` on a grass field is how this is authored, and it must start casting in the same frame. |
| `_update_dirty_instance()` | Placed **outside** the `if (can_cast_shadows != geom->can_cast_shadows)` guard, because a material swap leaving `can_cast_shadows` alone can still be the first time this instance's flag is computed. |
| `set_screen_space_shadow_caster(bool)` | **Pure virtual** on `RenderGeometryInstance`; `RenderGeometryInstanceBase` implements it (Forward+, Mobile and GLES3 inherit) and `GeometryInstanceDummy` needs its own empty override or the dummy rasterizer fails to build as an abstract class. |
| The base implementation must call `_mark_dirty()` | It writes `data->screen_space_shadow_caster`, which nothing reads until `_geometry_instance_update` rebuilds `base_flags`. Without the dirty mark the value sits in `data` forever, `INSTANCE_DATA_FLAG_SSS_CASTER` is never set, the mask comes back zero everywhere, and with the setting on **the screen space shadow disappears from the whole frame** — it compiles, it runs, and it reads as the setting breaking the feature. |
| `INSTANCE_DATA_FLAG_SSS_CASTER = 1 << 0` | Bits 0 and 1 were free in the inherited enum, the rest starting at `1 << 2`. Set in `_geometry_instance_update` **after** `ginstance->base_flags = 0`, in `base_flags` rather than the per-frame flags — caster status then costs no per-frame CPU work, the point being that this geometry left the structure precisely to stop paying one. Mirrored as `INSTANCE_FLAGS_SSS_CASTER (1 << 0)` in `scene_forward_clustered_inc.glsl`, read under `MODE_RENDER_SSS_CASTER` to write `sss_caster_output_buffer`. The two enums are matched only by a comment. |
| The chain to the instance data buffer is **pass-mode independent** | Which is why the flag arrives whatever mode the pre-pass ends up in: `_fill_render_list` seeds `uint32_t flags = inst->base_flags` (`render_forward_clustered.cpp:1005`) and stores the result in `inst->flags_cache` (`:1116`); `_fill_instance_data` copies `instance_data.flags = inst->flags_cache` (`:891`). A porter debugging an empty caster mask walks these three lines. |

### The pre-pass attachment and its variant

| Seam — every one of these fails silently | Requirement, and what a miss does |
| --- | --- |
| `ensure_sss_caster_texture()` | Creates `RB_TEX_SSS_CASTER` (`SNAME("sss_caster")`) as `R8_UNORM`, usage `SAMPLING \| COLOR_ATTACHMENT \| CAN_COPY_FROM`, at the buffers' internal size, with **no MSAA twin**, deliberately. `get_sss_caster()` beside it is an unused accessor with no callers. |
| `_fill_render_list()`'s dynamic-instance condition | Dead code kept for symmetry: it is never called with any `PASS_MODE_DEPTH_NORMAL_ROUGHNESS*` mode, the depth pre-pass reusing `render_list[RENDER_LIST_OPAQUE]` filled under `PASS_MODE_COLOR`. |
| `DEPTH_FB_ROUGHNESS_SSS_CASTER` | Depth + normal/roughness + caster, selecting the MSAA normal/roughness twin as the other cases do. With no MSAA caster texture to pair with it, dropping the MSAA refusal hands RD a framebuffer mixing sample counts, rejected outright ("if an attachment is marked as multisample, all of them should be multisample and use the same number of samples") — the second, harder reason the MSAA refusal is a refusal. |
| `case` in `_render_list()` instantiating `_render_list_template<>` for `PASS_MODE_DEPTH_NORMAL_ROUGHNESS_SSS_CASTER` | Its `default:` is a comment, so a missing case is a pre-pass that draws nothing, with no message. |
| `case` in `_render_list_template()` setting `pipeline_key.version` | With `ERR_FAIL_COND_MSG` on `view_count > 1`. Missing, the wrong pipeline version is bound. |
| Two `depth_pass_clear` entries, one per color attachment | **Zero means "not a caster"**, so the sky and any pixel the pre-pass does not draw cannot cast. |
| `depth_pass_mode` chain order | `using_voxelgi` tested first and winning, the restricted branch next, **before** `is_raytracing_scene_available()`. Put the restricted branch after the raytracing branch and it is unreachable, the mask is never written, and the setting reads as doing nothing. The VoxelGI precedence is structural: `sss_caster_output_buffer` and `voxel_gi_buffer` are both `layout(location = 1)` under `MODE_RENDER_NORMAL_ROUGHNESS`, and no variant defines both. |
| `PIPELINE_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_AND_SSS_CASTER`, before `PIPELINE_VERSION_COLOR_PASS` | That enum is hashed rather than packed, so its order is free, but it needs a `case` in `_get_shader_version()` **and** in `_create_pipeline()`'s blend state switch, sharing `blend_state_depth_normal_roughness_giprobe` — `create_disabled(2)`, two color attachments, which is what this pass has. Falling through to the one-attachment state fails pipeline creation against the render pass, silently, through the same null-pipeline path. |
| **The shader group** — the bug that reads as "the setting does nothing" | The variant is pushed with `SHADER_GROUP_ADVANCED` and `default_enabled` false, and a disabled group is not an error condition: `ShaderRD::_allocate_placeholders` fills every variant of a disabled group with `RD::shader_create_placeholder()`, a valid RID with no stages. So `get_shader_variant()` returns non-null, `ShaderData::_create_pipeline` gets past its `ERR_FAIL_COND(shader_rid.is_null())`, `render_pipeline_create` fails, and the only message is the bare `ERR_FAIL_COND(pipeline.is_null())` on the next line, which says nothing about shader groups. The ubershader retry hits the same placeholder, `pipeline_valid` stays false, every surface is skipped, and **the entire depth pre-pass draws nothing** — no depth, no normal/roughness, no caster mask — so the march reads a cleared depth buffer. Fix: one line in `_render_scene`, in the same branch that selects the pass mode, `scene_shader.enable_advanced_shader_group(p_render_data->scene_data->view_count > 1);`. Enable it there, not at init, which would compile the whole advanced set for every project. |
| **The variant numbering invariant** | `ShaderVersion`'s constants are not an enum — they are the indices at which `init()` pushes each `VariantDefine`, and the depth block is pushed twice, once per value of `ubershader`. `SHADER_VERSION_COLOR_PASS` must equal the number of depth variants pushed per iteration. This variant made that ten: `SHADER_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_AND_SSS_CASTER = 9`, `SHADER_VERSION_COLOR_PASS = 10`. Two things in `_get_shader_version()` depend on it: `ubershader_base = SHADER_VERSION_COLOR_PASS`, and the color pass index `SHADER_VERSION_COLOR_PASS * 2 + shader_flags`. **A violation produces no error of any kind** — every index stays in range (`VERTEX_INPUT_MASKS_SIZE` derives from the same constant and shrinks in step), the lookup succeeds, and the wrong shader is bound: ubershader depth requests shift down one slot, color pass indices shift down two, so the first two land inside the ubershader depth block and get a `MODE_RENDER_DEPTH` shader bound for a color draw. Push the new variant **last** in the depth block and bump the constant in the same edit. |
| **These pipelines are not precompiled** — the feature's real cost | `GlobalPipelineData` carries `use_normal_and_roughness`, `use_voxelgi` and `use_sdfgi` and has **no bit for this pass mode**; the test setting `use_normal_and_roughness` names `PASS_MODE_DEPTH_NORMAL_ROUGHNESS` only, `_mesh_compile_pipelines_for_surface` has no block for the new pipeline version, and `_get_depth_framebuffer_format_for_pipeline(p_can_be_storage, p_samples, p_normal_roughness, p_voxelgi)` has no parameter that would produce this format (the VoxelGI format cannot stand in — an `R8_UNORM` second attachment is not the VoxelGI `R32UI` one). So with the setting on, every material compiles its pre-pass pipeline the first time it is drawn: `get_pipeline` misses, the specialized request is queued, and the ubershader retry compiles with `p_wait_for_compilation` true and stalls the render thread. A hitch on first sight of new geometry, not a per-frame cost. A port either reproduces it knowingly or adds the bit, the compile block and the framebuffer format parameter. |

### The march's caster side

| Point | Detail |
| --- | --- |
| `layout(set = 0, binding = 2) uniform sampler2D caster_mask_texture` | Bound with the **same `depth_sampler`** the depth texture uses. Deliberate: an off-screen mask read returns 0, "not a caster", agreeing with the off-screen depth read returning the far plane, "no occluder". A repeat or clamp-to-edge sampler here casts from the screen's edge texels. |
| No mask bound | The uniform takes `DEFAULT_RD_TEXTURE_WHITE` and `FLAG_RESTRICT_CASTERS` is left clear, so `!has_flag(FLAG_RESTRICT_CASTERS) \|\|` short-circuits and no fetch happens. Unlike the shadow mask, the 4x4 default is safe at any size here because the read is a normalized `textureLod`, not a `texelFetch`. |
| **Only the caster side is restricted** | `may_cast[i]` is fetched at the same coordinate as `depths.x`; `sampling_depth[]` and `depth_thickness_scale[]` describe the **receiver** and must keep coming from the full depth buffer. Point either at the mask and `depth_thickness_scale` is zero on every non-caster pixel, dividing by zero in `depth_scale` and making `early_out_pixel()` reject every non-caster: grass self-shadows and the ground it stands on receives nothing. |
| `debug_view = Caster Mask` | Writes `may_cast[0] ? 1.0 : 0.0`. White is a caster; with the restriction off it is white everywhere, the correct answer rather than a broken one. |

One select at the shared-memory store, because `depth_data` already encodes "cannot shadow" as a
value — `1e10`, the sentinel the `i != 0` overshoot case writes. Nothing new crosses the barrier
and the wavefront layout is unchanged:

    depth_data[(i * WAVE_SIZE) + int(gl_LocalInvocationID.x)] = may_cast[i] ? stored_depth : 1e10;

### Three refusals of its own, on top of the pass's

`_using_restricted_sss_casters()` tests in order: the project setting;
`_using_screen_space_shadows()` (so the pass's own refusals — reflection probe, multiview,
orthographic — carry through); `is_raytraced_directional_available()`; a visible VoxelGI; MSAA. In
every refusal **the screen space pass still runs, unrestricted, exactly as before** — none is a
fallback to a degraded path.

| Refusal | Why |
| --- | --- |
| **Requires the SUN to be raytraced**, not merely that a structure exists | The premise is that anything it stops casting already casts a correct traced shadow *from this light*. With `raytraced_shadows/directional/enabled` off, the structure holds only geometry gathered near raytraced lamps and the sun is on a demoted cascade, so restricting would take the contact shadow away from geometry receiving none from anywhere else. Gate on `is_raytracing_scene_available()` instead and a scene with one raytraced lamp and a shadow-mapped sun loses its grass shadows. |
| **A visible VoxelGI**, `WARN_PRINT_ONCE` | The pass mode chain gives `PASS_MODE_DEPTH_NORMAL_ROUGHNESS_VOXEL_GI` priority outright, so the caster variant never runs and nothing writes the mask. The check belongs in this predicate rather than at the bind, because the mask texture is a named render buffer living until the buffers are reconfigured, cleared by nothing: before this existed, turning the camera toward a VoxelGI left the march reading whichever frame last wrote a caster mask against this frame's depth. The warning cannot fire for a project that merely has a VoxelGI — it is reached only with `restrict_casters` on, the pass enabled and the sun raytraced. |
| **MSAA**, `WARN_PRINT_ONCE` | The caster flag would have to be resolved with the depth's own `best_index` sample; averaging or OR-ing it casts from a depth belonging to a surface that was never a caster, which shows up only as shadows at silhouettes with nothing above them — the one artifact nobody looks for on foliage. The framebuffer sample-count mismatch above makes it a hard refusal rather than a judgment call. The MSAA resolve branch in `_render_scene` lists the new pass mode alongside the other two; unreachable today, and not MSAA support. |

Two properties of `_using_restricted_sss_casters()` itself:

| Property of the predicate | Consequence |
| --- | --- |
| **Called twice per frame** — to pick the pass mode in `_render_scene`, and in `_render_screen_space_shadows` to decide whether to bind the mask | Every reason the pre-pass can lose its slot must live inside it. The two agree on the sun because `raytraced_shadows/directional/enabled` is snapshotted once per frame in `RaytracingScene::update_frame_settings()` (`renderer_rd/environment/rt_scene.cpp`) rather than read live; make that a live read and within one frame you can write a mask nothing binds, or bind a mask nothing wrote. |
| **Both calls happen before it is known whether any light needs the pass** | The pass mode is chosen in `_render_scene`, while whether a directional light is actually casting is settled only in `_render_screen_space_shadows` from `get_sss_light().valid`. So a scene with the setting on and no shadow-casting sun still pays the `R8` attachment, the extra pre-pass target and the advanced-group compile for nothing — the same tradeoff as the forced depth pre-pass, worth stating because the CPU-side flag really is free while the GPU-side attachment is not. |

## Settings plumbing

| Point | Detail |
| --- | --- |
| Registration | All under `rendering/lights_and_shadows/screen_space_shadows/` in `core/config/project_settings.cpp`, all live. |
| `enabled` | `GLOBAL_DEF_BASIC`, and **not** restart-required and must not be marked so: read through `GLOBAL_GET_CACHED` every frame, with the effect built lazily, so it takes effect the next frame. |
| Read sites | `enabled` in `_using_screen_space_shadows`; `restrict_casters` in `_using_restricted_sss_casters`; everything else in `_render_screen_space_shadows`, which clamps `quality` to `QUALITY_MAX - 1` and `debug_view` to `DEBUG_VIEW_MAX - 1` before casting. |
| `debug_view` | Read as an int and clamped, so **the `PROPERTY_HINT_ENUM` string is positional**: append to `DebugView` and not to the hint string (or the reverse) and every value from that point on names a different view than the inspector says. `DEBUG_VIEW_CASTER_MASK` is appended after `DEBUG_VIEW_WAVE_INDEX`, `Caster Mask` last in the hint string. |
| Any bound-setting change | Run `godot --headless --doctool .` and commit the result; no surviving CI job catches a stale `doc/classes/ProjectSettings.xml` (`docs/VALIDATION.md`). |
