# AMD GI: setup and runtime controls

AMD GI supplies diffuse indirect lighting and glossy reflections without baking,
authored probes, or special UV layouts. This fork adapts AMD Capsaicin GI 1.2 to
Godot materials, lights, scene changes, and Vulkan. It is not a general replacement
for every Godot GI feature. Start with the defaults below; there is no validated
universal performance preset.

The [optional improvement experiments](amd-gi-improvements.md) add live, independent
response/scheduling/cache-transition switches. They default off and preserve the
original algorithm as the comparison baseline.

## Enable it

1. Use **Vulkan Forward+**, a perspective camera, a single view, an Environment
   (normally a WorldEnvironment), and **MSAA disabled**.
2. Enable `rendering/lights_and_shadows/raytraced_shadows/enabled` **before engine
   startup** and restart after changing it. The current implementation needs this
   shared tracing infrastructure even if your purpose is GI. Existing mesh buffers
   cannot acquire acceleration-structure usage through a later live toggle.
3. Enable `rendering/global_illumination/amd_gi/enabled`. This setting itself is live
   once the startup prerequisite is satisfied.
4. Disable SDFGI and SSIL in the Environment and remove visible VoxelGI instances.
   These conflicts suppress AMD GI; the fork does not silently rewrite their settings.

Hardware must support Vulkan ray queries, buffer device addresses and half floats,
with at least 38 storage-buffer bindings per stage and aggregate pipeline layout, 12 storage-image
bindings per stage and aggregate pipeline layout, eight color attachments, and 32 KiB compute shared
memory. The source capability check is authoritative; an older warning still
mentions 32 buffers.

## Which objects participate

`GI_MODE_STATIC` (the default) and `GI_MODE_DYNAMIC` both participate and may move.
`GI_MODE_DISABLED` omits the object from ray transport; a visible surface can still
receive GI through the screen-space input. Lightmapped objects and material-overlay
objects are omitted from transport individually. No lightmap UV is required.

Ordinary CPU-managed 3D MultiMesh supports visible instance counts, transforms,
colors, and custom data. GPU-indirect MultiMesh and shader-driven ray-geometry
displacement are unsupported. Do not assume a moving grass shader has matching ray
geometry merely because its visible surface receives GI. Source materials requiring
raster derivatives are omitted from transport with a warning; arbitrary transparency,
layered/multipass materials, and custom deformation are not universally supported.
For engine-level material contracts, consult `docs/internals/rt-materials.md` in the
fork repository.

Orthographic views retain native lighting with no AMD GI output. Negative/subtractive
lights retain their native direct effect but are excluded from GI sampling and
feedback. These are deliberate scope limits of this personal fork. AMD GI takes
precedence over the separate `rt_validation/enabled` diagnostic backend. Native
SSR is suppressed when AMD reflection pipelines are ready and reflections enabled.

## Recommended starting controls

All short names below have the prefix `rendering/global_illumination/amd_gi/`.
These are the actual registered defaults, not project-specific overrides.

| Setting | Default | Meaning / tradeoff |
| --- | --- | --- |
| `enabled` | `false` | Master GI switch; enable after satisfying the startup prerequisite. |
| `probe_spacing` | `16` | Choose 8, 16, or 32. Approximately 1, 1/4, or 1/16 primary probe ray per internal pixel per frame; larger spacing reduces update density. Stored probes retain an 8-pixel grid. |
| `multibounce` | `true` | Secondary cache transport. Disabling removes continuation/indirect work and its storage, but removes indirect bounces. |
| `denoiser` | `true` | Diffuse temporal/spatial denoising. Reflection filtering has its own selector. |
| `importance_sampling` | `true` | Guides diffuse probe directions using previous radiance and surface cosine, without adding primary rays. |
| `brdf_sampling` | `true` | Uses native albedo/metalness/roughness for AMD's choice of specular or diffuse-guided samples. |
| `adaptive_sampling` | `true` | Redirects the existing probe update budget toward uncovered tiles. |
| `probe_cache` | `true` | Retains displaced probes for reuse; disabling saves the retained pool and related work. |
| `cache_all_hits` | `true` | Accumulates every registered cell hit. Disabling selects one hit per cell; it does not reduce the primary probe-ray count. |
| `emissive_sampling` | `true` | Samples triangle emitters for world-cache lighting. Disabling retains emission seen by primary hits. |
| `sky_sampling` | `1` | 0: uniform hemisphere; **1: cosine hemisphere**; 2: luminance importance. Cosine is the recommended starting point. Importance can help a bright, concentrated sky but adds texture reads. Independent of probe `importance_sampling`. |
| `light_resampling` | `false` | Optional temporal reuse of previous light samples. Fresh GridStream light sampling remains active when false. Reuse adds substantial memory/work; compare on the intended scene. |
| `reflections/enabled` | `true` | Separate glossy path; disabling skips it and releases its sized resources. |
| `reflections/half_resolution` | `true` | Rotating samples at one per 2x2 internal pixels. Full resolution costs more but can improve fine geometry. |
| `reflections/denoiser` | `1` | 0: AMD split-ratio X/Y; **1: AMD a-trous**; 2: disabled. Split is a comparison option with detail/stability/striping tradeoffs, not a proven faster or better preset. |
| `reflections/filter_passes` | `4` | 2-8 a-trous reconstruction passes; unused by split mode. |
| `reflections/firefly_filter` | `true` | AMD rank marking and cleanup before reflection reconstruction. Independent of denoiser selection. |
| `reflections/ray_compaction` | `true` | GPU compaction/indirect dispatch for rays that actually need tracing; preserves the sampling algorithm. |

Primary probe rays are only part of the cost: light visibility, continuations, and
glossy rays add work. Both GI and reflections scale with **internal rendering
resolution**, which may differ from the window resolution when upscaling is active.

## Live changes and remaining limits

```gdscript
const GI := "rendering/global_illumination/amd_gi/"
ProjectSettings.set_setting(GI + "enabled", true)
ProjectSettings.set_setting(GI + "sky_sampling", 1)
ProjectSettings.set_setting(GI + "reflections/denoiser", 1)
```

These changes affect every eligible viewport and need not be saved to disk.
Each viewport has its own histories. Sampling/filter changes reset relevant
histories; resource-layout changes can reallocate buffers and briefly stall.
Debug view changes do not reset histories. Allow settling before comparing images.

Glossy reconstruction still has a reported issue on thin/specific faces, with
blur and artifacts more apparent during forward/backward motion. The alternate
denoiser is not an accepted fix. The complete optional-mode matrix has prepared
fixtures but no recorded hardware acceptance; successful default rendering does
not validate every combination.

Use [diagnostics and advanced controls](amd-gi-debug.md) for overlay integration,
exclusion reports, cache views, sky comparisons, and reflection tuning. Engine
maintainers should read `docs/internals/amd-gi.md` and
`docs/AMD_GI_ADAPTER_DECISIONS.md` in the fork repository before changing transport.

For bounded cache/denoiser responsiveness and distant-detail experiments, see
[live tuning and game-panel integration](amd-gi-tuning.md). Defaults remain unchanged.
