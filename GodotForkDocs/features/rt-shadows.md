# Raytraced shadows

Raytraced shadows replace eligible lights' opaque-surface shadow maps with hardware ray queries. This is a Forward+ Vulkan feature requiring ray-query and buffer-device-address support. It is also the shared geometry prerequisite for AMD GI; enabling AMD GI does not make every light use raytraced shadows.

## Enable and control

Enable **Rendering → Lights And Shadows → Raytraced Shadows → Enabled**, then restart the editor and game. Mesh buffers acquire acceleration-structure usage when uploaded; this master switch cannot safely be enabled midway through a run.

Local lights use raytracing when eligible and `shadow_enabled` is true. Enable `directional/enabled` separately for DirectionalLight3D. Other settings below can change at runtime with `ProjectSettings.set_setting()`; changing a setting does not save it to disk. Directional routing and its fallback-map settings are snapshotted together at the next frame boundary.

All paths below are relative to `rendering/lights_and_shadows/raytraced_shadows/`.

| Setting | Default | Purpose |
| --- | --- | --- |
| `enabled` | `false` | Master switch; restart required, including for AMD GI's shared geometry. |
| `samples_per_light` | `1` | Rays per selected light and pixel. More samples reduce noise and increase GPU cost. |
| `max_ray_distance` | `0` | Optional ray-distance cap; zero leaves the light-derived range. |
| `softness_scale` | `1.0` | Scales light-size softness, from zero to one. |
| `accurate_occluder_distance` | `true` | Nearest blocker for more consistent soft-shadow filtering; disabling permits early termination. |
| `denoiser/enabled` | `true` | Temporal and spatial filtering. Disable to inspect raw sampling. |
| `denoiser/spatial_passes` | `3` | A-trous iterations, 1–5. |
| `denoiser/temporal_frames` | `32` | Accumulation window, 1–64; longer history can increase lag. |
| `denoiser/min_filter_pixels` | `1.0` | Minimum spatial reach where a nonzero penumbra exists. |
| `denoiser/history_clamp_sigma` | `2.0` | History-clamping strength; zero disables clamping. |
| `denoiser/lag_response` | `1.0` | Response to rejected/clamped history, 0–1. |
| `directional/enabled` | `false` | Opt the sun into raytracing. |
| `directional/caster_distance_scale` | `2.0` | Extra caster-search extent toward the sun, relative to its shadow distance. |
| `directional/scatter_casters` | `1` | MultiMesh directional coverage: 0 disabled, 1 near camera, 2 full distance. |
| `directional/scatter_distance` | `25.0` | Radius for near-camera MultiMesh directional coverage. |
| `directional/demoted_shadow_mode` | `2` | Remaining directional map: 0 keep authored, 1 orthogonal, 2 two splits. |
| `directional/demoted_shadow_size` | `1024` | Remaining directional atlas size; zero keeps native configuration. |

For OmniLight3D and SpotLight3D, `light_size` controls emitter size in meters; new nodes default to shadows enabled and size `0.05`. DirectionalLight3D instead exposes `light_angular_distance` in degrees, defaulting to `0.25`. Authored properties remain authoritative.

`Light3D.shadow_map_enabled` explicitly retains a supplementary map for consumers that cannot use the opaque screen-space RT result, such as transparent shading and local-light volumetric fog. It does not replace opaque RT shading with a map. Without that supplement, transparent receivers can be unshadowed by an RT light. Directional volumetric fog has a separate ray-query path.

## Coverage and limits

- MeshInstance3D and MultiMesh geometry can cast, including CPU particles/GridMap when represented by MultiMesh. GPU particles use screen-space shadows where configured; they are not triangle-AS casters.
- Current skinned/blend-shape positions and in-place vertex/index updates are supported. Custom shader vertex displacement is not applied to the acceleration structure. A waving raster blade can therefore disagree with its traced shape.
- Alpha-cutout textures are not evaluated by the shadow ray query: admitted triangles are opaque. Material shadow-casting exclusions are honored, but this does not provide texture-shaped foliage shadows.
- `cast_shadow = Off` removes an instance from **shadow** collection. AMD GI can still need its geometry for transport. Do not use that property as a promise of zero AS cost.
- Layer masks are folded from 32 bits into 8 for ray queries; layers 9–32 alias lower layers. Use the first eight layers when exact RT isolation matters.
- At most 255 lights have stable RT slots. Each pixel shadows at most four selected lights. Additional overlapping RT lights can illuminate it without RT occlusion; this is not a per-pixel fallback to shadow maps.
- The gather and shadow TLAS have 65,536-entry ceilings; a surface or MultiMesh element can consume an entry. Surface-specific exclusion uses a 32-bit mask, so do not depend on independent exclusion beyond surface 31.
- Geometry admission is budgeted. A scene with many new surfaces can acquire traced shadows over several updates; reducing display resolution does not remove this geometry work.
- Ray queries use the mesh's main triangle geometry rather than raster LOD selection or `ArrayMesh.shadow_mesh`. Triangle backface culling is disabled in the shadow TLAS.

Screen-space shadows complement geometry missing from RT, but only see screen-visible depth. See [screen-space shadows](screen-space-shadows.md). AMD GI evaluates source materials separately; its material support does not change the opaque shadow-query rule above.

## Testing and diagnosis

Use a small, windowed resolution for controlled comparisons. Separate CPU scene/AS preparation from GPU tracing and filtering. Animated crowds and large MultiMeshes can be expensive before any pixel is shaded. When isolating GI or reflection behavior, disable expensive optional scatter; enable it deliberately when testing scatter coverage.

`GODOT_RT_DEBUG=1`, set before process launch, enables collection/build diagnostics and averaged CPU timings. Compare raw and denoised shadows, hard and soft lights, and static versus moving geometry before changing defaults. Avoid treating one project's timing as a general performance guarantee.

For rebuilding this feature on another Godot version, use `docs/internals/rt-shadows.md` and `docs/internals/rt-materials.md` in the fork repository. These describe implementation, not additional project setup.
