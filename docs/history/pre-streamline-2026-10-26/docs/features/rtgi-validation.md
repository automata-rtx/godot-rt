> Historical snapshot from `66bd97e00d` before the 2026-10-26 documentation audit. Claims and line numbers may be superseded. Do not use as current configuration guidance.

# Legacy RT GI transport validator

This uncached diffuse integrator is a diagnostic, **not AMD GI and not a shipping preset**.
Use [AMD GI controls](amd-gi.md) for the actual implementation. The validator still uses the old material capture atlas.
Do not use high-sample validator images to represent AMD GI progress.

## Controls

These project settings are live and can be changed with `ProjectSettings.set_setting()`:

| Setting under `rendering/global_illumination/rt_validation/` | Default | Meaning |
| --- | --- | --- |
| `enabled` | `false` | Explicitly opt into the validation integrator |
| `samples_per_pixel` | `1` | Independent paths per internal pixel; 1–4096 |
| `bounces` | `2` | Secondary diffuse encounters; 1–8 |
| `max_distance` | `50.0` | Ray segment limit and camera-centered gathering box half-extent, in world units |

For example:

```gdscript
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/samples_per_pixel", 1)
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/bounces", 3)
ProjectSettings.set_setting("rendering/global_illumination/rt_validation/enabled", true)
```

The project must already enable RT shadows at startup so uploaded mesh buffers have
acceleration-structure usage. This mode requires Vulkan Forward+, a WorldEnvironment,
one view, and no MSAA. SDFGI, SSIL, VoxelGI, and lightmaps must be disabled for the
comparison; native settings are preserved, not changed automatically. Set ambient
light to zero for a pure transport comparison, as the rig does; existing authored
ambient light otherwise remains part of the baseline. The shared
geometry budget can defer initialization until later frames.


Historical captures, comparisons and limitations: [archive](../history/AMD_GI_ARCHIVE.md#snapshot-rtgi-validation).
