# Ambient occlusion: VBAO

VBAO adds local contact darkening from the visible depth buffer. It is the fork's **Ground Truth** SSAO method: GTAO slice geometry with a visibility bitmask. It does not trace the scene or provide bounced light. Tune its strength with AMD GI enabled if that is your final lighting configuration.

## Enable and select

Use Forward+, enable SSAO on the active `Environment`, and select `Environment.SSAO_METHOD_GROUND_TRUTH`. `SSAO_METHOD_DEFAULT` instead follows `rendering/environment/ssao/method`: `0` is legacy SSAO (the shipped default), `1` is Ground Truth. `SSAO_METHOD_SCREEN_SPACE` explicitly selects legacy SSAO.

This implementation is single-view; multiview falls back to legacy SSAO. Orthographic reconstruction is incomplete: use legacy SSAO for orthographic cameras. Reflection-probe renders do not run this effect.

## Controls

These project settings are live, under `rendering/environment/ssao/ground_truth/`.

| Setting | Shipped default | Meaning |
| --- | --- | --- |
| `visibility_bitmask` | `true` | Finite-thickness visibility sectors; `false` selects the horizon-based gather. |
| `scale_radius_with_distance` | `true` | Keeps sampling footprint approximately constant on screen. Disable for fixed world-space radius. |
| `screen_radius` | `0.1` | Footprint multiplier when distance scaling is on; environment radius also scales it. |
| `thickness` | `0.3` | Estimated occluder thickness for bitmask visibility. Larger values strengthen thin objects' occlusion. |
| `slices` | `4` | Angular sampling directions; more improve coverage and increase cost. |
| `steps_per_slice` | `8` | Samples along each side of a slice; more increase cost. |
| `intensity_scale` | `0.5` | Multiplies the environment's SSAO intensity. |
| `shading_rate` | `1` (Checkerboard) | `0` is quarter resolution. Used only when SSAO half size is enabled. |

`rendering/environment/ssao/half_size` defaults to `true`: checkerboard gathers half the pixels, quarter about one quarter. Turning half size off gathers at full internal resolution. All modes produce a full internal-resolution AO result.

Environment radius, intensity, power and SSAO fadeout still apply. Legacy SSAO quality, adaptive sampling, blur, detail, horizon and sharpness controls do not become VBAO sampling controls; use the settings above. Start with shipped VBAO defaults before increasing samples or radius.

## Testing and limits

Check corners, thin poles, ground contact and silhouettes while stationary and moving. A larger radius changes the look and can expose depth-only halos. Off-screen surfaces and hidden layers cannot occlude. The spatial sampling pattern is stable, but there is no VBAO temporal accumulation; reduced resolution can retain visible patterning.

Compare at the same **internal** resolution and lighting. Changing DLSS, FSR2 or render scale changes both cost and available depth detail. Use the GPU profiler's `Process GTAO` entry to separate AO from lighting/upscaling cost. Allocation failures fail toward unoccluded white where a final target is available.

Engine rebuild notes: `docs/internals/ambient-occlusion.md` in the fork repository. Related guides: [AMD GI](amd-gi.md), [DLSS](dlss.md).
