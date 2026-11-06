# Finding fork settings

Project Settings **General** contains the main feature switches and quality
choices. **Advanced Fork Options** contains diagnostics, experimental modes,
filter internals, and specialized compatibility/setup controls. General's stock
Advanced Settings switch does not bring these fork controls back into General.
Both tabs edit the original setting keys: saved projects and runtime overlays
keep working. The 20 main controls are:

| Feature | Controls kept in General |
| --- | --- |
| AMD GI | Enabled, probe spacing, multibounce, reflections enabled, half resolution, trace roughness threshold |
| RT shadows | Enabled (restart), samples per light, softness scale, directional enabled, scatter casters and distance |
| Screen-space shadows | Enabled, quality, hardness, restrict casters |
| VBAO | SSAO method, Ground Truth shading rate; scene strength/radius stay on Environment |
| DLSS / Streamline | Enabled (restart), frame generation; viewport scaling mode/scale stay in their normal locations |

The remaining 78 controls are in Advanced Fork Options: sampler alternatives,
cache/history tuning, denoiser internals, debug views/reports, the reference GI
renderer, shadow coverage/fallback adjustments, VBAO internals, and Streamline
paths/logging/preset/experimental mask. Advanced does not mean ineffective: these
settings still apply, including existing saved overrides. Use each feature guide
for their purpose and tradeoffs. Light size, shadow-map supplementation, material
properties, and the Environment's AO controls remain normal authoring properties.


The presentation change requires a build containing the new tab. In an older
build, these same keys remain in General, usually behind Advanced Settings.
Moving controls does not update an installed executable.

Retired RT-shadow keys `denoiser/adaptive_temporal` and `denoiser/lag_response`
are ignored. The conservative temporal filter is the sole temporal implementation;
`denoiser/temporal_frames=1` still requests spatial-only filtering.
