# Rendering troubleshooting

Start with the installed build and its log. Change one setting at a time and keep
the original values. This is a diagnostic index, not a list of guaranteed causes.

| Symptom | First checks | Details |
| --- | --- | --- |
| A new light is softer or more expensive than in stock Godot | New light defaults differ even with RT disabled; inspect explicit size/shadow properties | [RT shadows](features/rt-shadows.md) |
| RT shadows do not appear | Forward+, Vulkan/ray-query support, master switch/restart, light and mesh shadow eligibility; look for fallback warnings | [RT shadows](features/rt-shadows.md) |
| A cutout casts a rectangle, or wind/billboard shadows disagree with the mesh | RT shadows do not generally evaluate native material alpha or custom vertex displacement; GI material support does not automatically change shadow tracing | [RT shadows](features/rt-shadows.md) |
| Transparent receivers or fog lose a light's shadow | A screen-space RT mask is not a general replacement for shadow maps; inspect `shadow_map_enabled` and the feature's receiver limits | [RT shadows](features/rt-shadows.md) |
| VBAO looks flat, excessively dark or unchanged | SSAO must be enabled in the Environment; check estimator selection, radius/intensity and renderer support before increasing samples | [Ambient occlusion](features/ambient-occlusion.md) |
| Contact shadows disappear near screen edges or miss off-screen casters | They use visible depth; compare RT/shadow-map coverage and caster filtering | [Screen-space shadows](features/screen-space-shadows.md) |
| AMD GI is absent | Check capability warnings, perspective camera, compatible GI/SSIL state, geometry/material exclusions and current diagnostics | [AMD GI](features/amd-gi.md), [diagnostics](features/amd-gi-debug.md) |
| A material or MultiMesh appears in raster rendering but not in GI | Use exclusion reports; investigate supported transforms, overlays, passes, opacity and data ownership instead of assuming all Godot shaders are traceable | [AMD GI](features/amd-gi.md) |
| Reflections shimmer, blur or change with movement | Separate trace/probe thresholds, half-resolution reconstruction, filter choice and history. Compare still, forward/backward and strafe motion. More smoothing is not automatically more correct | [AMD GI](features/amd-gi.md), [testing](TESTING.md) |
| Periodic GI debugging spikes | Turn off statistics/readback diagnostics before profiling; separate shader preparation from steady-state cost | [Diagnostics](features/amd-gi-debug.md) |
| Firing/blinking lights cause spikes or lighting changes | Capture CPU and GPU separately; compare active light count, emissive materials, particles and scene updates. Do not diagnose every spike as acceleration-structure work | [Testing](TESTING.md) |
| DLSS requested but a fallback runs | Inspect effective upscaler/status, Windows/Vulkan/GPU support, signed matching Streamline DLLs and binary path | [DLSS](features/dlss.md) |
| A project/editor exits with a CUDA/NVIDIA DLL fault | Verify the build includes the Streamline shutdown-order fix; preserve engine/SDK logs and new dumps. The faulting DLL name alone is not a root cause | [DLSS](features/dlss.md), [testing](TESTING.md) |
| An export differs from the editor | Check matching custom export templates and deployed runtime DLLs. A missing packaged debug template is not proof that Godot cannot build one | [DLSS](features/dlss.md), [testing](TESTING.md) |

If the symptom persists, provide the reproduction and evidence above. Avoid
changing drivers, deleting caches/saves, disabling unrelated overlays or replacing
rendering algorithms solely because their names appear in a log.
